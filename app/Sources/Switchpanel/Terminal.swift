import Foundation

/// Salta a la pestaña de Terminal.app que corresponde a una tty.
enum TerminalJumper {
    private static let queue = DispatchQueue(label: "switchpanel.terminal")

    static func focus(tty: String?) {
        guard let tty, tty.hasPrefix("/dev/tty") else { return }
        let script = """
        tell application "Terminal"
            repeat with w in windows
                try
                    repeat with i from 1 to (count of tabs of w)
                        if tty of tab i of w is "\(tty)" then
                            set selected tab of w to tab i of w
                            set index of w to 1
                            activate
                            return
                        end if
                    end repeat
                end try
            end repeat
        end tell
        """
        run(script)
    }

    /// Abre una ventana de Terminal en el proyecto y arranca `claude` con la cuenta indicada.
    static func newSession(in directory: String, configDir: String?) {
        // La cuenta por defecto (~/.claude) debe correr SIN CLAUDE_CONFIG_DIR (ver switchpanel.py).
        let defaultDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        let account: String
        if let configDir, (configDir as NSString).standardizingPath != defaultDir {
            account = "env CLAUDE_CONFIG_DIR=\(shellQuote(configDir))"
        } else {
            account = "env -u CLAUDE_CONFIG_DIR"
        }
        let command = appleScriptString("cd \(shellQuote(directory)) && \(account) claude")
        // Ventana nueva y no pestaña: Terminal no tiene comando para pestañas y simular ⌘T
        // exige permiso de Accesibilidad. Si Terminal estaba cerrada, se usa la ventana con la
        // que arranca para no dejar una vacía.
        let script = """
        tell application "Terminal"
            if it is running then
                do script \(command)
            else
                activate
                repeat 50 times
                    if (count of windows) > 0 then exit repeat
                    delay 0.1
                end repeat
                if (count of windows) > 0 then
                    do script \(command) in front window
                else
                    do script \(command)
                end if
            end if
            activate
        end tell
        """
        run(script)
    }

    private static func run(_ script: String) {
        queue.async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error { NSLog("Switchpanel: AppleScript failed: \(error)") }
        }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
