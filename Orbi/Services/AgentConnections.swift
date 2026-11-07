import Foundation
import Observation
import OSLog

/// The agent CLIs Orbi can wire itself into.
enum AgentKind: String, CaseIterable, Identifiable, Sendable {
    case claude, gemini
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .gemini: "Gemini CLI"
        }
    }

    /// `~/.claude/settings.json`, `~/.gemini/settings.json`.
    var settingsPath: String {
        switch self {
        case .claude: ".claude/settings.json"
        case .gemini: ".gemini/settings.json"
        }
    }
}

/// Pure JSON editing of an agent's `settings.json`: adds Orbi's hooks next to whatever the
/// user already has, and removes only Orbi's (recognised by the `agent_hook.py` command).
/// No file access here, so it's fully unit tested.
enum AgentHookConfig {
    static let marker = "agent_hook.py"

    enum Status: Equatable {
        case notConnected
        case connected
        /// Orbi's hooks are there but point at another copy of the script (app moved / updated).
        case outdated
    }

    /// The hook entries for `kind`, calling the script at `script`. `replies`: Claude's Stop hook
    /// runs async and offers a reply field; off = a plain "finished" bubble.
    static func hooks(for kind: AgentKind, script: String, replies: Bool = true) -> [String: [[String: Any]]] {
        let run = "/usr/bin/python3 -I '\(script)' \(kind.rawValue)"
        // After every tool call: plain shell checks for an open bubble; Python starts only then.
        let guarded = #"set -- "${TMPDIR:-/tmp}"/orbi-agent-hook/\#(kind.rawValue)-*.pending.*; "#
            + #"[ -e "$1" ] && exec \#(run) resume; echo "{}""#
        func entry(_ command: String, timeout: Int, extra: [String: Any] = [:]) -> [String: Any] {
            ["type": "command", "command": command, "timeout": timeout].merging(extra) { a, _ in a }
        }
        func group(_ hook: [String: Any], matcher: String? = nil) -> [[String: Any]] {
            var g: [String: Any] = ["hooks": [hook]]
            if let matcher { g["matcher"] = matcher }
            return [g]
        }
        switch kind {
        case .claude:
            return [
                "UserPromptSubmit": group(entry("\(run) prompt", timeout: 10)),
                "Stop": group(replies
                    ? entry("\(run) stop --reply", timeout: 3600, extra: ["asyncRewake": true])
                    : entry("\(run) stop", timeout: 10)),
                "PermissionRequest": group(entry("\(run) permission", timeout: 600)),
                "Notification": group(entry("\(run) wait", timeout: 10),
                                      matcher: "elicitation_dialog|agent_needs_input|idle_prompt"),
                "PostToolUse": group(entry(guarded, timeout: 10)),
            ]
        case .gemini:  // Gemini timeouts are in milliseconds.
            return [
                "BeforeAgent": group(entry("\(run) prompt", timeout: 10_000, extra: ["name": "orbi-turn-start"])),
                "AfterAgent": group(entry("\(run) stop", timeout: 10_000, extra: ["name": "orbi-finished"])),
                "Notification": group(entry("\(run) wait", timeout: 10_000, extra: ["name": "orbi-needs-you"])),
                "AfterTool": group(entry(guarded, timeout: 10_000, extra: ["name": "orbi-resume"])),
            ]
        }
    }

    /// Claude Code's status line: shows the plan limits and sends them to Orbi.
    static func statusLine(script: String) -> [String: Any] {
        ["type": "command", "command": "/usr/bin/python3 -I '\(script)' claude statusline", "padding": 0]
    }

    /// Connected only if Orbi's commands are exactly the current ones (script path, reply mode).
    /// Claude: Orbi's status line too, unless the user has a status line of their own.
    static func status(of settings: [String: Any], kind: AgentKind, script: String, replies: Bool = true) -> Status {
        let commands = orbiCommands(in: settings)
        guard !commands.isEmpty else { return .notConnected }
        if kind == .claude {
            guard let line = settings["statusLine"] as? [String: Any] else { return .outdated }
            if isOrbi(line) && line["command"] as? String != statusLine(script: script)["command"] as? String {
                return .outdated
            }
        }
        let wanted = hooks(for: kind, script: script, replies: replies).values
            .flatMap { $0.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } } }
        return commands.sorted() == wanted.sorted() ? .connected : .outdated
    }

    /// Removes any old Orbi hooks, then adds the current ones.
    static func connect(_ settings: [String: Any], kind: AgentKind, script: String,
                        replies: Bool = true) -> [String: Any] {
        var result = disconnect(settings)
        var hooksDict = result["hooks"] as? [String: Any] ?? [:]
        for (event, groups) in hooks(for: kind, script: script, replies: replies) {
            hooksDict[event] = (hooksDict[event] as? [[String: Any]] ?? []) + groups
        }
        result["hooks"] = hooksDict
        if kind == .claude && result["statusLine"] == nil { result["statusLine"] = statusLine(script: script) }
        return result
    }

    /// Removes only Orbi's hooks (and Orbi's status line); empty groups / events left behind are dropped.
    static func disconnect(_ settings: [String: Any]) -> [String: Any] {
        var settings = settings
        if let line = settings["statusLine"] as? [String: Any], isOrbi(line) { settings["statusLine"] = nil }
        guard var hooksDict = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooksDict {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let remaining = entries.filter { !isOrbi($0) }
                if remaining.isEmpty { return nil }
                var g = group
                g["hooks"] = remaining
                return g
            }
            hooksDict[event] = kept.isEmpty ? nil : kept
        }
        var result = settings
        result["hooks"] = hooksDict.isEmpty ? nil : hooksDict
        return result
    }

    private static func isOrbi(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String)?.contains(marker) == true
    }

    private static func orbiCommands(in settings: [String: Any]) -> [String] {
        guard let hooksDict = settings["hooks"] as? [String: Any] else { return [] }
        return hooksDict.values.flatMap { value -> [String] in
            (value as? [[String: Any]] ?? []).flatMap { group in
                (group["hooks"] as? [[String: Any]] ?? []).filter(isOrbi).compactMap { $0["command"] as? String }
            }
        }
    }
}

/// Settings → AI agents: connects Orbi to Claude Code / Gemini CLI by writing its hooks into
/// their `settings.json` (a backup is kept next to it the first time). Uses the scripts inside
/// Orbi.app, so nothing else needs to be downloaded.
@MainActor
@Observable
final class AgentConnections {
    private(set) var statuses: [AgentKind: AgentHookConfig.Status] = [:]
    private(set) var lastError: String?

    @ObservationIgnored private let home: URL
    @ObservationIgnored private let scriptsDirectory: URL?
    @ObservationIgnored private let replies: () -> Bool
    @ObservationIgnored private let log = Logger(subsystem: "com.berke.Orbi", category: "AgentConnections")

    init(home: URL = SharedContainer.realHomeDirectory, scriptsDirectory: URL? = Bundle.main.resourceURL,
         replies: @escaping () -> Bool = { true }) {
        self.home = home
        self.scriptsDirectory = scriptsDirectory
        self.replies = replies
        refresh()
    }

    var hookScript: String? {
        scriptsDirectory.map { $0.appending(path: "agent_hook.py").path }
            .flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
    }

    var mcpScript: String? {
        scriptsDirectory.map { $0.appending(path: "orbi_mcp.py").path }
            .flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
    }

    /// The agents installed on this Mac (their config folder exists). Claude Code is always offered.
    var availableAgents: [AgentKind] {
        AgentKind.allCases.filter { kind in
            kind == .claude || FileManager.default.fileExists(atPath: home.appending(path: ".\(kind.rawValue)").path)
        }
    }

    /// For Claude Code's `claude mcp add` (copied to the clipboard from Settings).
    var claudeMCPCommand: String? {
        mcpScript.map { "claude mcp add --scope user orbi -- /usr/bin/python3 -I '\($0)'" }
    }

    /// For Claude Desktop, Cursor and other MCP clients.
    var mcpJSON: String? {
        mcpScript.map {
            #"{ "mcpServers": { "orbi": { "command": "/usr/bin/python3", "args": ["-I", "\#($0)"] } } }"#
        }
    }

    func status(_ kind: AgentKind) -> AgentHookConfig.Status { statuses[kind] ?? .notConnected }

    func refresh() {
        guard let script = hookScript else { return }
        for kind in AgentKind.allCases {
            statuses[kind] = AgentHookConfig.status(of: readSettings(kind) ?? [:], kind: kind, script: script,
                                                    replies: replies())
        }
    }

    func connect(_ kind: AgentKind) {
        guard let script = hookScript else {
            lastError = "The hook script is missing from Orbi.app."
            return
        }
        let replies = replies()
        write(kind) { AgentHookConfig.connect($0, kind: kind, script: script, replies: replies) }
    }

    /// After a setting that changes the hooks (reply mode): rewrite the connected agents.
    func reconnectConnected() {
        refresh()
        for kind in AgentKind.allCases where status(kind) != .notConnected { connect(kind) }
    }

    func disconnect(_ kind: AgentKind) {
        write(kind) { AgentHookConfig.disconnect($0) }
    }

    /// At launch: if Orbi's hooks point at an old copy of the script (the app was moved or
    /// replaced), point them at this one. Never connects anything that wasn't connected.
    func repairIfOutdated() {
        for kind in AgentKind.allCases where status(kind) == .outdated { connect(kind) }
    }

    // MARK: - Files

    private func settingsURL(_ kind: AgentKind) -> URL { home.appending(path: kind.settingsPath) }

    private func readSettings(_ kind: AgentKind) -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL(kind)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func write(_ kind: AgentKind, change: ([String: Any]) -> [String: Any]) {
        let url = settingsURL(kind)
        let fm = FileManager.default
        do {
            var current: [String: Any] = [:]
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                // Refuse to touch a file we can't parse rather than overwrite the user's settings.
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                current = parsed
                let backup = url.appendingPathExtension("orbi-backup")
                if !fm.fileExists(atPath: backup.path) { try data.write(to: backup) }
            }
            let updated = change(current)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let out = try JSONSerialization.data(withJSONObject: updated,
                                                 options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try out.write(to: url, options: .atomic)
            lastError = nil
            log.info("Updated \(url.path, privacy: .public)")
        } catch {
            lastError = "Couldn't update \(kind.settingsPath): \(error.localizedDescription)"
            log.error("Updating \(url.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }
}
