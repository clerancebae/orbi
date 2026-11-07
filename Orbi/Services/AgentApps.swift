import AppKit

/// "Go to project": brings the terminal / IDE an agent runs in to the front, by bundle id
/// (the hook reads it from `__CFBundleIdentifier` / `TERM_PROGRAM`). App-level only: picking
/// the exact window or tab would need Automation access to every terminal.
@MainActor
enum AgentApps {
    static func activate(_ bundleID: String) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    /// "Terminal", "Visual Studio Code", … for tooltips; nil if the app isn't installed.
    static func name(_ bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
            FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
        }
    }
}
