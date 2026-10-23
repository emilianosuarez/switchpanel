import Darwin
import Foundation

/// Lee ~/.switchpanel (lo escribe hooks/switchpanel.py) y se actualiza solo.
final class BoardStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var config = BoardConfig()
    @Published private(set) var now = Date()
    @Published private(set) var snoozed: [String: Date] = [:]

    let boardDir: URL
    private var sessionsDir: URL { boardDir.appendingPathComponent("sessions") }
    private var configURL: URL { boardDir.appendingPathComponent("config.json") }
    private var locksDir: URL { boardDir.appendingPathComponent("locks") }

    private var timer: Timer?
    private var watcher: DispatchSourceFileSystemObject?

    init() {
        let env = ProcessInfo.processInfo.environment["SWITCHPANEL_DIR"]
        boardDir = URL(fileURLWithPath: env ?? NSHomeDirectory() + "/.switchpanel")
        if let saved = UserDefaults.standard.dictionary(forKey: "snoozed") as? [String: Date] {
            snoozed = saved.filter { $0.value > Date() }
        }
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reload() }
        watchSessionsDir()
    }

    // MARK: lectura

    func reload() {
        now = Date()
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: configURL),
           let cfg = try? decoder.decode(BoardConfig.self, from: data) {
            config = cfg
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        var all: [Session] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let s = try? decoder.decode(Session.self, from: data) else { continue }
            all.append(s)
        }
        // Solo sesiones vivas, y una por terminal (tras /clear queda la vieja en la misma tty).
        var byTTY: [String: Session] = [:]
        for s in all where s.status != "ended" && isAlive(s.pid) {
            let key = s.tty ?? s.session_id
            if let other = byTTY[key], (other.updated_at ?? "") > (s.updated_at ?? "") { continue }
            byTTY[key] = s
        }
        let fresh = Array(byTTY.values)
        if fresh != sessions { sessions = fresh }
        snoozed = snoozed.filter { $0.value > now }
    }

    private func isAlive(_ pid: Int?) -> Bool {
        guard let pid, pid > 0 else { return false }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    private func watchSessionsDir() {
        let fd = open(sessionsDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.reload() }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    // MARK: consultas

    func account(for s: Session) -> AccountConfig {
        config.accounts[s.account ?? ""] ?? AccountConfig(name: s.account ?? "?", emoji: "•", color: "gray")
    }

    func project(for s: Session) -> ProjectConfig {
        let path = s.project ?? s.cwd ?? ""
        return config.projects[path] ?? ProjectConfig(name: (path as NSString).lastPathComponent, color: "gray")
    }

    func isSnoozed(_ s: Session) -> Bool {
        (snoozed[s.session_id] ?? .distantPast) > now
    }

    func matches(_ s: Session, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return true }
        let p = project(for: s)
        let haystack = [p.name, p.short ?? "", s.taskName, s.title ?? "", account(for: s).name, s.project ?? ""]
            .joined(separator: " ").lowercased()
        return q.split(separator: " ").allSatisfy { haystack.contains($0) }
    }

    // MARK: escritura (con el mismo flock que usa switchpanel.py)

    func snooze(_ s: Session, for seconds: TimeInterval?) {
        if let seconds { snoozed[s.session_id] = Date().addingTimeInterval(seconds) } else { snoozed[s.session_id] = nil }
        UserDefaults.standard.set(snoozed, forKey: "snoozed")
    }

    func setLabel(_ s: Session, _ label: String?) {
        let url = sessionsDir.appendingPathComponent("\(s.session_id).json")
        updateJSON(url, lock: s.session_id) { obj in
            let clean = label?.trimmingCharacters(in: .whitespaces)
            obj["label"] = (clean?.isEmpty ?? true) ? NSNull() : clean
        }
        reload()
    }

    func updateProject(_ path: String, name: String? = nil, color: String? = nil) {
        updateJSON(configURL, lock: "config") { obj in
            var projects = obj["projects"] as? [String: Any] ?? [:]
            var p = projects[path] as? [String: Any] ?? ["name": (path as NSString).lastPathComponent]
            if let name, !name.isEmpty { p["name"] = name }
            if let color { p["color"] = color }
            projects[path] = p
            obj["projects"] = projects
        }
        reload()
    }

    /// "auto", "en" o "es": lo leen el hook (en cada evento) y la app (al arrancar).
    func setLanguage(_ language: String) {
        updateJSON(configURL, lock: "config") { $0["language"] = language }
        reload()
    }

    private func updateJSON(_ url: URL, lock: String, _ change: (inout [String: Any]) -> Void) {
        try? FileManager.default.createDirectory(at: locksDir, withIntermediateDirectories: true)
        let lockFD = open(locksDir.appendingPathComponent("\(lock).lock").path, O_WRONLY | O_CREAT, 0o644)
        guard lockFD >= 0 else { return }
        flock(lockFD, LOCK_EX)
        defer { flock(lockFD, LOCK_UN); close(lockFD) }

        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = parsed
        }
        change(&obj)
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? out.write(to: url, options: .atomic)
    }
}
