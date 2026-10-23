import AppKit
import SwiftUI

/// Estado de la UI que también toca el AppDelegate (atajo global).
final class PanelState: ObservableObject {
    enum Editing: Equatable {
        case task(String)     // session_id
        case project(String)  // ruta del proyecto
    }

    @Published var query = ""
    @Published var focusToken = 0
    @Published var editing: Editing?
    /// Explicación que se muestra al pie del panel mientras el mouse está sobre un ícono.
    @Published var hint: String?
    /// Hace key al panel (lo setea el AppDelegate); necesario para escribir en un campo.
    var activate: () -> Void = {}
}

struct BoardView: View {
    @ObservedObject var store: BoardStore
    @ObservedObject var ui: PanelState
    @FocusState private var searchFocused: Bool
    @State private var expanded: Set<String> = []
    @State private var showLegend = false

    private var visible: [Session] {
        store.sessions.filter { store.matches($0, query: ui.query) }
    }

    private var inbox: [Session] {
        visible
            .filter { $0.state == .waiting && !store.isSnoozed($0) }
            .sorted { ($0.since ?? .distantFuture) < ($1.since ?? .distantFuture) }
    }

    /// Cuenta -> proyecto -> sesiones, ordenado por nombre.
    private var groups: [(account: AccountConfig, projects: [(path: String, project: ProjectConfig, sessions: [Session])])] {
        let byAccount = Dictionary(grouping: visible) { $0.account ?? "" }
        return byAccount.map { key, sessions in
            let byProject = Dictionary(grouping: sessions) { $0.project ?? $0.cwd ?? "" }
            let projects = byProject.map { path, list in
                (path: path,
                 project: store.project(for: list[0]),
                 sessions: list.sorted { a, b in
                     a.state.rawValue != b.state.rawValue
                         ? a.state.rawValue < b.state.rawValue
                         : (a.since ?? .distantPast) > (b.since ?? .distantPast)
                 })
            }
            .sorted { $0.project.name.localizedCaseInsensitiveCompare($1.project.name) == .orderedAscending }
            return (account: store.account(for: sessions[0]), projects: projects)
        }
        .sorted { $0.account.name < $1.account.name }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if visible.isEmpty {
                Text(store.sessions.isEmpty ? LocalizedStringKey("No open Claude Code sessions") : "No results")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if !inbox.isEmpty { inboxSection }
                        ForEach(groups, id: \.account.name) { group in
                            accountSection(group.account, group.projects)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let hint = ui.hint {
                Text(hint)
                    .font(.system(size: 11))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                    .overlay(alignment: .top) { Divider() }
                    .allowsHitTesting(false)
            }
        }
        .environmentObject(ui)
        .frame(minWidth: 280, minHeight: 160)
        .onChange(of: ui.focusToken) { searchFocused = true }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search project or task  (⌥Space)", text: $ui.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit(jumpToFirst)
                .onExitCommand { ui.query = "" }
            if !ui.query.isEmpty {
                Button { ui.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Button { showLegend.toggle() } label: { Image(systemName: "questionmark.circle") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .hoverHint(String(localized: "What each icon means"))
                .popover(isPresented: $showLegend, arrowEdge: .bottom) { LegendView() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .padding(.top, 22) // barra de título transparente
    }

    private var inboxSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(text: String(localized: "NEEDS YOU (\(inbox.count))"), color: Palette.color("yellow"))
            ForEach(inbox) { s in
                SessionRow(session: s, store: store, ui: ui, showProject: true, showReason: true, expanded: $expanded)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.color("yellow").opacity(0.08)))
        .padding(.bottom, 6)
    }

    private func accountSection(_ account: AccountConfig,
                                _ projects: [(path: String, project: ProjectConfig, sessions: [Session])]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(text: "\(account.emoji ?? "") \(account.name.uppercased())", color: .secondary)
            ForEach(projects, id: \.path) { p in
                HStack(spacing: 6) {
                    Circle().fill(Palette.color(p.project.color)).frame(width: 9, height: 9)
                    if ui.editing == .project(p.path) {
                        InlineEditor(initial: p.project.name, ui: ui) { store.updateProject(p.path, name: $0) }
                            .font(.system(size: 12, weight: .semibold))
                    } else {
                        Text(p.project.name).font(.system(size: 12, weight: .semibold))
                    }
                    Spacer()
                }
                .padding(.top, 4)
                .padding(.leading, 4)
                .contentShape(Rectangle())
                .onTapGesture { ui.editing = .project(p.path) }
                .hoverHint(String(localized: "Click: rename project · Right-click: change color"))
                .contextMenu { ProjectMenu(path: p.path, project: p.project, store: store, ui: ui) }
                ForEach(p.sessions) { s in
                    SessionRow(session: s, store: store, ui: ui, showProject: false, showReason: false, expanded: $expanded)
                        .padding(.leading, 12)
                }
            }
        }
        .padding(.bottom, 6)
    }

    private func jumpToFirst() {
        let first = inbox.first ?? groups.first?.projects.first?.sessions.first
        if let first {
            TerminalJumper.focus(tty: first.tty)
            ui.query = ""
        }
    }
}

struct LegendView: View {
    private let states: [Session.State] = [.waiting, .done, .working, .idle]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Legend").font(.system(size: 12, weight: .bold))
            ForEach(states, id: \.rawValue) { state in
                row(state.symbol, state.meaning)
            }
            row("●", String(localized: "Project color (right-click to change it)"))
            row("🌙", String(localized: "Snoozed: hidden from \"Needs you\" for a while"))
            Divider()
            Text("Click a row: go to its terminal · ⌥Space: search")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(symbol).frame(width: 18)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SectionHeader: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .padding(.leading, 4)
            .padding(.bottom, 2)
    }
}

struct SessionRow: View {
    let session: Session
    @ObservedObject var store: BoardStore
    @ObservedObject var ui: PanelState
    let showProject: Bool
    let showReason: Bool
    @Binding var expanded: Set<String>
    @State private var hovering = false

    private var isExpanded: Bool { expanded.contains(session.id) }

    var body: some View {
        let project = store.project(for: session)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if showProject {
                    Circle().fill(Palette.color(project.color)).frame(width: 8, height: 8)
                }
                Text(session.state.symbol).font(.system(size: 11))
                    .hoverHint(session.state.meaning)
                VStack(alignment: .leading, spacing: 1) {
                    if ui.editing == .task(session.id) {
                        InlineEditor(initial: session.label ?? session.taskName, ui: ui) { store.setLabel(session, $0) }
                            .font(.system(size: 12))
                    } else {
                        Text(showProject ? "\(project.name) · \(session.taskName)" : session.taskName)
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                    if showReason, let reason = session.waitingReason, !reason.isEmpty {
                        Text(reason)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                if store.isSnoozed(session) {
                    Image(systemName: "moon.zzz").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if hovering && ui.editing != .task(session.id) {
                    Button { ui.editing = .task(session.id) } label: {
                        Image(systemName: "pencil").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .hoverHint(String(localized: "Rename task"))
                }
                Text(relativeTime(session.since, now: store.now))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    if isExpanded { expanded.remove(session.id) } else { expanded.insert(session.id) }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .hoverHint(String(localized: "Show summary and next steps"))
            }
            if isExpanded { details }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { TerminalJumper.focus(tty: session.tty) }
        .contextMenu { menu(project: project) }
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let text = session.summary?.text, !text.isEmpty {
                Text(text)
            }
            if let reason = session.waitingReason, !reason.isEmpty {
                Text("⏳ Waiting for: ").bold().foregroundColor(Palette.color("yellow")) + Text(reason)
            }
            if let steps = session.summary?.next_steps, !steps.isEmpty {
                Text("Next steps").bold().foregroundColor(Palette.color("teal"))
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    Text("•  \(step)")
                }
            }
            if session.summary == nil, let prompt = session.last_prompt {
                Text("Last request: ").bold() + Text(prompt)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.primary.opacity(0.85))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 20)
        .padding(.bottom, 2)
    }

    @ViewBuilder private func menu(project: ProjectConfig) -> some View {
        Button("Go to terminal") { TerminalJumper.focus(tty: session.tty) }
        Button("Rename task…") { ui.editing = .task(session.id) }
        Divider()
        if store.isSnoozed(session) {
            Button("Unsnooze") { store.snooze(session, for: nil) }
        } else {
            Button("Snooze 30 min") { store.snooze(session, for: 30 * 60) }
            Button("Snooze 2 h") { store.snooze(session, for: 2 * 3600) }
        }
        Divider()
        if let path = session.project {
            ProjectMenu(path: path, project: project, store: store, ui: ui)
        }
    }
}

struct ProjectMenu: View {
    let path: String
    let project: ProjectConfig
    let store: BoardStore
    let ui: PanelState

    var body: some View {
        Menu("Color of \(project.name)") {
            ForEach(Palette.names, id: \.self) { name in
                Button(Palette.displayName(name)) { store.updateProject(path, color: name) }
            }
        }
        Button("Rename project…") { ui.editing = .project(path) }
    }
}

/// Campo para renombrar en el lugar: Enter guarda, Esc cancela.
struct InlineEditor: View {
    let initial: String
    @ObservedObject var ui: PanelState
    let onCommit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit {
                onCommit(text)
                ui.editing = nil
            }
            .onExitCommand { ui.editing = nil }
            .onAppear {
                text = initial
                ui.activate()
                DispatchQueue.main.async { focused = true }
            }
    }
}

/// Tooltip propio: los nativos (.help) no aparecen en un panel que no activa la app,
/// y un popover tapa el ícono y parpadea; por eso el texto va al pie del panel.
struct HoverHint: ViewModifier {
    let text: String
    @EnvironmentObject private var ui: PanelState

    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside {
                ui.hint = text
            } else if ui.hint == text {
                ui.hint = nil
            }
        }
    }
}

extension View {
    func hoverHint(_ text: String) -> some View { modifier(HoverHint(text: text)) }
}
