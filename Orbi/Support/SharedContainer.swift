import Foundation
import OSLog

/// Locations shared between the app, the Safari extension (Phase 5) and Touch Bar scripts.
/// Everything lives in the App Group container so all surfaces see the same data.
enum SharedContainer {
    private static let log = Logger(subsystem: "com.berke.Orbi", category: "SharedContainer")

    /// The App Group ID, injected into Info.plist at build time as `$(TeamIdentifierPrefix)com.berke.orbi`
    /// so the team ID lives in one place (project.yml).
    static let groupID: String = {
        if let id = Bundle.main.object(forInfoDictionaryKey: "OrbiAppGroupID") as? String, !id.isEmpty {
            return id
        }
        return "NB6868HT2X.com.berke.orbi"
    }()

    /// Root of the App Group container, or the app's own Application Support as a fallback
    /// (e.g. when the entitlement is missing). The fallback is logged, never fatal.
    static let rootURL: URL = {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            return url
        }
        log.error("App Group container unavailable for \(groupID, privacy: .public); falling back to Application Support")
        return URL.applicationSupportDirectory.appending(path: "Orbi", directoryHint: .isDirectory)
    }()

    /// Directory holding the SwiftData store.
    static var storeDirectory: URL {
        rootURL.appending(path: "Library/Application Support/Orbi", directoryHint: .isDirectory)
    }

    static var storeURL: URL { storeDirectory.appending(path: "Orbi.store") }

    /// Rolling log of agent activity (`AgentLogStore`).
    static var agentLogURL: URL { storeDirectory.appending(path: "agent-log.json") }

    /// `status.json`, read by Claude (MCP) and Touch Bar tools. Deliberately NOT in the group
    /// container: macOS 15+ blocks other apps' processes from reading group containers. The
    /// sandbox allows this one folder via a home-relative temporary-exception entitlement.
    static var statusFileURL: URL {
        realHomeDirectory.appending(path: "Library/Application Support/Orbi/status.json")
    }

    /// Answers to agent questions (`<id>.json`), read by `mcp/agent_hook.py`. Same allowed folder.
    static var answersDirectory: URL {
        realHomeDirectory.appending(path: "Library/Application Support/Orbi/answers", directoryHint: .isDirectory)
    }

    /// Messages queued for a running agent (`<session>.txt`), sent by `mcp/agent_hook.py`. Same allowed folder.
    static var queueDirectory: URL {
        realHomeDirectory.appending(path: "Library/Application Support/Orbi/queue", directoryHint: .isDirectory)
    }

    /// The user's real home folder. Inside the sandbox `NSHomeDirectory()` points into the
    /// app container, so read it from the password database instead.
    static let realHomeDirectory: URL = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }()

    /// Settings shared across targets. Falls back to `.standard` if the suite can't be created.
    /// UserDefaults is documented as thread-safe but not marked Sendable.
    nonisolated(unsafe) static let defaults: UserDefaults = UserDefaults(suiteName: groupID) ?? .standard

    static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
    }
}
