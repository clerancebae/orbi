import AppKit

/// "Go to project": brings the terminal / IDE an agent runs in to the front, by bundle id
/// (the hook reads it from `__CFBundleIdentifier` / `TERM_PROGRAM`). App-level only: picking
/// the exact window or tab would need Automation access to every terminal.
@MainActor
enum AgentApps {
    /// Goes through NSWorkspace: since macOS 14, `NSRunningApplication.activate()` from an app
    /// that isn't active itself (Orbi never is: its bubbles are non-activating panels) is
    /// silently ignored. Opening the app via Launch Services brings a running copy to the front.
    static func activate(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// "Terminal", "Visual Studio Code", … for tooltips; nil if the app isn't installed.
    static func name(_ bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
            FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
        }
    }
}
