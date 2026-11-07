import Foundation
import Testing
@testable import Orbi

struct AgentHookConfigTests {
    let script = "/Applications/Orbi.app/Contents/Resources/agent_hook.py"

    /// A user's own settings with an unrelated hook and other keys.
    var userSettings: [String: Any] {
        ["model": "opus", "permissions": ["allow": ["Bash(ls:*)"]],
         "hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]]]
    }

    func commands(_ s: [String: Any], _ event: String) -> [String] {
        ((s["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? [])
            .flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    @Test func connectKeepsUserSettingsAndIsIdempotent() {
        var s = AgentHookConfig.connect(userSettings, kind: .claude, script: script)
        s = AgentHookConfig.connect(s, kind: .claude, script: script)  // twice → no duplicates
        #expect(s["model"] as? String == "opus")
        #expect(commands(s, "Stop") == ["say done", "/usr/bin/python3 -I '\(script)' claude stop --reply"])
        #expect(commands(s, "PermissionRequest") == ["/usr/bin/python3 -I '\(script)' claude permission"])
        #expect(commands(s, "PostToolUse").first?.hasPrefix("set -- ") == true)
        #expect(AgentHookConfig.status(of: s, kind: .claude, script: script) == .connected)
        let stop = ((s["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.last?["hooks"] as? [[String: Any]]
        #expect(stop?.first?["asyncRewake"] as? Bool == true)
    }

    @Test func disconnectRemovesOnlyOrbi() {
        let connected = AgentHookConfig.connect(userSettings, kind: .claude, script: script)
        let s = AgentHookConfig.disconnect(connected)
        #expect(commands(s, "Stop") == ["say done"])
        #expect((s["hooks"] as? [String: Any])?.keys.sorted() == ["Stop"])
        #expect(AgentHookConfig.status(of: s, kind: .claude, script: script) == .notConnected)
        #expect(AgentHookConfig.disconnect(["model": "x"])["model"] as? String == "x")
    }

    @Test func oldScriptPathIsOutdated() {
        let old = AgentHookConfig.connect([:], kind: .claude, script: "/Users/me/Orbi/mcp/agent_hook.py")
        #expect(AgentHookConfig.status(of: old, kind: .claude, script: script) == .outdated)
        let fixed = AgentHookConfig.connect(old, kind: .claude, script: script)
        #expect(AgentHookConfig.status(of: fixed, kind: .claude, script: script) == .connected)
    }

    @Test func geminiUsesItsEventsAndMilliseconds() {
        let s = AgentHookConfig.connect([:], kind: .gemini, script: script)
        let hooks = s["hooks"] as? [String: Any]
        #expect(hooks?.keys.sorted() == ["AfterAgent", "AfterTool", "BeforeAgent", "Notification"])
        let entry = (hooks?["AfterAgent"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]]
        #expect(entry?.first?["timeout"] as? Int == 10_000)
        #expect(commands(s, "AfterAgent") == ["/usr/bin/python3 -I '\(script)' gemini stop"])
    }
}

@MainActor
struct AgentConnectionsTests {
    func temp() throws -> (home: URL, scripts: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "orbi-conn-\(UUID())")
        let scripts = root.appending(path: "Resources")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try Data().write(to: scripts.appending(path: "agent_hook.py"))
        try Data().write(to: scripts.appending(path: "orbi_mcp.py"))
        return (root.appending(path: "home"), scripts)
    }

    @Test func connectWritesSettingsAndKeepsABackup() throws {
        let (home, scripts) = try temp()
        let settings = home.appending(path: ".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"model":"opus"}"#.utf8).write(to: settings)

        let connections = AgentConnections(home: home, scriptsDirectory: scripts)
        #expect(connections.status(.claude) == .notConnected)
        connections.connect(.claude)
        #expect(connections.status(.claude) == .connected)
        #expect(connections.lastError == nil)
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        #expect(written?["model"] as? String == "opus")
        #expect(FileManager.default.fileExists(atPath: settings.path + ".orbi-backup"))
        #expect(connections.claudeMCPCommand?.contains("orbi_mcp.py") == true)

        connections.disconnect(.claude)
        #expect(connections.status(.claude) == .notConnected)
        // No ~/.gemini folder → Gemini isn't offered.
        #expect(connections.availableAgents == [.claude])
    }

    @Test func refusesToOverwriteUnparsableSettings() throws {
        let (home, scripts) = try temp()
        let settings = home.appending(path: ".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: settings)
        let connections = AgentConnections(home: home, scriptsDirectory: scripts)
        connections.connect(.claude)
        #expect(connections.lastError != nil)
        #expect(try String(contentsOf: settings, encoding: .utf8) == "{ not json")
    }
}
