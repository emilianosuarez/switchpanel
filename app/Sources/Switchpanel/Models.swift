import Foundation
import SwiftUI

/// Mismo formato que escribe hooks/switchpanel.py: "2026-10-22T16:42:55-0300".
let boardDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
    return f
}()

func parseDate(_ s: String?) -> Date? {
    s.flatMap { boardDateFormatter.date(from: $0) }
}

struct SessionSummary: Codable, Hashable {
    var task: String?
    var text: String?
    var next_steps: [String]?
    var waiting_for: String?
    var at: String?
}

struct Session: Codable, Identifiable, Hashable {
    var session_id: String
    /// Qué agente escribió la sesión ("claude-code"); las anteriores a este campo no lo tienen.
    var agent: String?
    var account: String?
    var project: String?
    var cwd: String?
    var tty: String?
    var pid: Int?
    var status: String?
    var attention: String?
    var attention_at: String?
    var label: String?
    var title: String?
    var turns: Int?
    var summary_turn: Int?
    var summary: SessionSummary?
    var last_prompt: String?
    var prompt_at: String?
    var done_at: String?
    var updated_at: String?

    var id: String { session_id }
    var agentID: String { agent ?? "claude-code" }

    enum State: Int {
        case waiting = 0, done = 1, working = 2, idle = 3

        var symbol: String {
            switch self {
            case .waiting: return "⏳"
            case .done: return "✅"
            case .working: return "⚙️"
            case .idle: return "💤"
            }
        }

        var meaning: String {
            switch self {
            case .waiting: return String(localized: "Waiting for you: asked for a permission or left a question/decision")
            case .done: return String(localized: "Done: your turn, but nothing specific is pending")
            case .working: return String(localized: "Working")
            case .idle: return String(localized: "Idle: you haven't written anything yet")
            }
        }
    }

    /// Misma regla que state_symbol() en switchpanel.py.
    var state: State {
        switch status {
        case "working": return .working
        case "waiting_permission": return .waiting
        case "done", "waiting_input":
            if let w = summary?.waiting_for, !w.isEmpty, summary_turn == turns { return .waiting }
            return .done
        default: return .idle
        }
    }

    /// Qué espera Claude de vos, si algo.
    var waitingReason: String? {
        if status == "waiting_permission" { return attention ?? String(localized: "Needs a permission") }
        if state == .waiting { return summary?.waiting_for }
        return nil
    }

    /// Desde cuándo está en el estado actual.
    var since: Date? {
        switch state {
        case .waiting where status == "waiting_permission": return parseDate(attention_at)
        case .waiting, .done: return parseDate(done_at) ?? parseDate(updated_at)
        case .working: return parseDate(prompt_at) ?? parseDate(updated_at)
        case .idle: return parseDate(updated_at)
        }
    }

    var taskName: String {
        for candidate in [label, title, summary?.task] {
            if let c = candidate?.trimmingCharacters(in: .whitespaces), !c.isEmpty { return c }
        }
        return String(localized: "(untitled)")
    }
}

struct AccountConfig: Codable, Hashable {
    var name: String
    var emoji: String?
    var color: String?
}

struct ProjectConfig: Codable, Hashable {
    var name: String
    var color: String?
    var short: String?
}

struct BoardConfig: Codable {
    var language: String?
    var accounts: [String: AccountConfig] = [:]
    var projects: [String: ProjectConfig] = [:]
}

/// Paleta compartida con switchpanel.py (nombre -> hex).
enum Palette {
    static let names = ["blue", "green", "orange", "purple", "pink", "teal", "yellow", "red", "gray"]
    static let hex: [String: UInt32] = [
        "blue": 0x2F80ED, "green": 0x27AE60, "orange": 0xF2994A, "purple": 0x9B51E0,
        "pink": 0xEB5CA8, "teal": 0x2BB5C4, "yellow": 0xF2C94C, "red": 0xEB5757,
        "gray": 0x8A8A8A,
    ]
    /// Nombres de configs viejas (en español), igual que COLOR_ALIASES en switchpanel.py.
    static let aliases = [
        "azul": "blue", "verde": "green", "naranja": "orange", "violeta": "purple", "rosa": "pink",
        "turquesa": "teal", "amarillo": "yellow", "rojo": "red", "gris": "gray",
    ]

    static func canonical(_ name: String?) -> String {
        let n = (name ?? "").lowercased()
        return hex[n] != nil ? n : aliases[n] ?? "gray"
    }

    /// Nombre para mostrar en el idioma de la app.
    static func displayName(_ name: String) -> String {
        Bundle.main.localizedString(forKey: name.capitalized, value: nil, table: nil)
    }

    static func color(_ name: String?) -> Color {
        let v = hex[canonical(name)]!
        return Color(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}

func relativeTime(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "" }
    let s = Int(now.timeIntervalSince(date))
    if s < 60 { return String(localized: "now") }
    if s < 3600 { return "\(s / 60) min" }
    if s < 86400 { return "\(s / 3600) h" }
    return "\(s / 86400) d"
}
