import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Panel flotante que puede recibir teclado (para el buscador) sin activar la app al hacer clic.
final class BoardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = BoardStore()
    private let ui = PanelState()
    private var panel: BoardPanel!
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var cancellables: Set<AnyCancellable> = []

    private var alwaysOnTop: Bool {
        get { UserDefaults.standard.object(forKey: "alwaysOnTop") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "alwaysOnTop") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildPanel()
        buildStatusItem()
        hotKey = HotKey { [weak self] in self?.focusSearch() }
        panel.orderFrontRegardless()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.orderFrontRegardless()
        return true
    }

    // MARK: panel

    private func buildPanel() {
        panel = BoardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 480),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.title = "Switchpanel"
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        applyLevel()
        panel.contentView = NSHostingView(rootView: BoardView(store: store, ui: ui))
        ui.activate = { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.panel.makeKeyAndOrderFront(nil)
        }
        if !panel.setFrameUsingName("SwitchpanelPanel"), let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.maxX - 360, y: v.maxY - 500))
        }
        panel.setFrameAutosaveName("SwitchpanelPanel")
    }

    private func applyLevel() {
        panel.isFloatingPanel = alwaysOnTop
        panel.level = alwaysOnTop ? .floating : .normal
    }

    private func focusSearch() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        ui.focusToken += 1
    }

    @objc private func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    // MARK: barra de menú

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "Switchpanel")
        statusItem.button?.imagePosition = .imageLeading
        rebuildMenu()

        // Cantidad de sesiones esperando, al lado del ícono.
        store.$sessions.combineLatest(store.$snoozed)
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions, _ in
                guard let self else { return }
                let waiting = sessions.filter { $0.state == .waiting && !self.store.isSnoozed($0) }.count
                self.statusItem.button?.title = waiting > 0 ? " \(waiting)" : ""
            }
            .store(in: &cancellables)
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Show / hide panel"), action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Search sessions (⌥Space)"), action: #selector(searchFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        let top = menu.addItem(withTitle: String(localized: "Always on top"), action: #selector(toggleOnTop), keyEquivalent: "")
        top.state = alwaysOnTop ? .on : .off
        let login = menu.addItem(withTitle: String(localized: "Open at login"), action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: String(localized: "Open config.json"), action: #selector(openConfig), keyEquivalent: "")
        menu.addItem(languageMenuItem())
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
    }

    private func languageMenuItem() -> NSMenuItem {
        let current = store.config.language ?? "auto"
        let submenu = NSMenu()
        // Los idiomas van con su propio nombre, para encontrarlos aunque la app esté en otro.
        for (code, title) in [("auto", String(localized: "Automatic (system)")), ("en", "English"), ("es", "Español")] {
            let item = submenu.addItem(withTitle: title, action: #selector(chooseLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = code == current ? .on : .off
        }
        let item = NSMenuItem(title: String(localized: "Language"), action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// Guarda el idioma y reabre la app: los textos localizados se cargan al arrancar.
    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String, code != (store.config.language ?? "auto") else { return }
        store.setLanguage(code)
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.1; done; open \"$0\"",
                              Bundle.main.bundlePath]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    @objc private func searchFromMenu() { focusSearch() }

    @objc private func toggleOnTop() {
        alwaysOnTop.toggle()
        applyLevel()
        rebuildMenu()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Switchpanel: login item: \(error)")
        }
        rebuildMenu()
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(store.boardDir.appendingPathComponent("config.json"))
    }
}

/// "language" de config.json ("en", "es" o "auto"): fuerza el idioma de la app, igual que el hook.
/// Tiene que correr antes de cargar cualquier texto localizado.
private func applyLanguagePreference() {
    let dir = ProcessInfo.processInfo.environment["SWITCHPANEL_DIR"] ?? NSHomeDirectory() + "/.switchpanel"
    let url = URL(fileURLWithPath: dir).appendingPathComponent("config.json")
    let lang = (try? Data(contentsOf: url))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["language"] as? String
    if let lang, ["en", "es"].contains(lang) {
        UserDefaults.standard.set([lang], forKey: "AppleLanguages")
    } else {
        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    }
}

@main
enum SwitchpanelApp {
    static func main() {
        applyLanguagePreference()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
