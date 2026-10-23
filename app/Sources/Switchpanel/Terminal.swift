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
        queue.async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error { NSLog("Switchpanel: AppleScript failed: \(error)") }
        }
    }
}
