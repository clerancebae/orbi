import AppKit

/// Owns the AppEnvironment so it exists before any URL event is delivered, and receives
/// `orbi://` URLs (Touch Bar buttons, scripts, Claude).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let env = AppEnvironment()

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { env.handle(url: url) }
    }
}
