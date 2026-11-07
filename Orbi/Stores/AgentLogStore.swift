import Foundation
import Observation
import OSLog

/// One thing an AI agent did, as seen through Orbi: a permission request (and your answer)
/// or a finished turn (with the agent's last message and your reply).
struct AgentEvent: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case permission, finished }
    enum Outcome: String, Codable, Sendable {
        case allowed, denied, terminal, replied, dismissed
        /// Answered in the terminal / the agent went on before you answered here.
        case elsewhere
    }

    var id: String
    var date: Date
    var kind: Kind
    /// "Claude wants to use Bash", "Claude finished ✓".
    var title: String
    /// "Orbi" or "Orbi · 7 min" (project, duration).
    var subtitle: String?
    /// Permission: the command or file. Finished: the agent's last message.
    var detail: String?
    var outcome: Outcome?
    /// Your reply from the bubble, if any.
    var reply: String?
    /// Bundle id of the terminal / IDE, for "go to project".
    var app: String?
}

/// An agent session that's in the middle of a turn.
struct RunningAgent: Identifiable, Equatable, Sendable {
    var id: String { session }
    let session: String
    let agent: String
    let project: String?
    let app: String?
    let startedAt: Date
}

/// Per-day totals for the summary line. Kept apart from the capped event list, so a busy
/// day with more than 100 events still adds up.
struct AgentDayStats: Codable, Equatable, Sendable {
    var seconds = 0
    var turns = 0
    var projects: [String] = []
    var allowed = 0
    var denied = 0
    var replies = 0
    /// Optional so logs written before token counting still decode.
    var tokens: Int?
    /// Agent seconds per project, for tasks linked to a project. Optional for older logs.
    var projectSeconds: [String: Int]?

    /// Adds another day's totals (for the week).
    mutating func add(_ other: AgentDayStats) {
        seconds += other.seconds
        turns += other.turns
        for project in other.projects where !projects.contains(project) { projects.append(project) }
        allowed += other.allowed
        denied += other.denied
        replies += other.replies
        if let t = other.tokens { tokens = (tokens ?? 0) + t }
        if let more = other.projectSeconds {
            var mine = projectSeconds ?? [:]
            for (project, s) in more { mine[project, default: 0] += s }
            projectSeconds = mine
        }
    }
}

/// A plan limit that just crossed a warning level ("Claude 5-hour limit: 80% used").
struct LimitWarning: Equatable, Sendable {
    let window: String
    let percent: Int
    let reset: Date?
}

/// What AI agents did and are doing. Events: newest first, last 100. Day stats: last 30 days.
/// Both are kept in `agent-log.json` next to the SwiftData store; plain JSON on purpose (a
/// small rolling log needs no schema migration of the main store). Running sessions and
/// open questions live in memory only.
@MainActor
@Observable
final class AgentLogStore {
    static let maxEvents = 100
    static let maxDays = 30
    /// A session with no news for this long is dropped (e.g. the terminal was closed mid-turn).
    static let staleAfter: TimeInterval = 3 * 60 * 60

    private(set) var events: [AgentEvent] = []
    private(set) var days: [String: AgentDayStats] = [:]
    private(set) var running: [RunningAgent] = []
    /// Ids of ask bubbles waiting for your answer.
    private(set) var openAsks: Set<String> = []
    /// Sessions whose turn ended and you haven't looked yet: it's your turn. Cleared by the
    /// session's next prompt, by answering its reply bubble, or by opening the panel.
    private(set) var finishedUnseen: Set<String> = []
    /// Latest Claude plan limits (from the status line hook); nil until one arrives.
    private(set) var limits: UsageLimits?
    /// Messages you queued for a running session, keyed by session. Each is also a file
    /// `queue/<session>.txt` that the hook sends as the next prompt when the turn ends.
    private(set) var queued: [String: String] = [:]

    /// Agents waiting on you: open questions plus finished turns you haven't seen.
    var waitingForYou: Int { openAsks.count + finishedUnseen.count }

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let queueDirectory: URL?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let log = Logger(subsystem: "com.berke.Orbi", category: "AgentLog")

    /// - Parameter fileURL: nil keeps everything in memory only (tests, demo mode).
    /// - Parameter queueDirectory: where queued messages go for the hook; nil = memory only.
    init(fileURL: URL?, queueDirectory: URL? = nil, now: @escaping () -> Date = Date.init,
         calendar: Calendar = .current) {
        self.fileURL = fileURL
        self.queueDirectory = queueDirectory
        self.now = now
        self.calendar = calendar
        load()
        loadQueue()
    }

    // MARK: - Events

    func add(_ event: AgentEvent) {
        events.removeAll { $0.id == event.id }
        events.insert(event, at: 0)
        if events.count > Self.maxEvents { events.removeLast(events.count - Self.maxEvents) }
        save()
    }

    /// Records the answer once; later answers for the same id (e.g. the hook's cancel after
    /// you already clicked) don't overwrite it.
    func setOutcome(id: String, _ outcome: AgentEvent.Outcome, reply: String? = nil) {
        openAsks.remove(id)
        guard let index = events.firstIndex(where: { $0.id == id }), events[index].outcome == nil else { return }
        events[index].outcome = outcome
        events[index].reply = reply
        updateToday { stats in
            switch outcome {
            case .allowed: stats.allowed += 1
            case .denied: stats.denied += 1
            case .replied: stats.replies += 1
            default: break
            }
        }
        save()
    }

    func askOpened(_ id: String) { openAsks.insert(id) }

    /// Clears the list (not the day totals).
    func clear() {
        events.removeAll()
        save()
    }

    // MARK: - Running sessions

    func start(_ context: AgentContext, at date: Date? = nil) {
        guard let session = context.session else { return }
        finishedUnseen.remove(session)
        pruneStale()
        running.removeAll { $0.session == session }
        running.append(RunningAgent(session: session, agent: context.agent ?? "Agent", project: context.project,
                                    app: context.app, startedAt: date ?? now()))
    }

    func stop(session: String) {
        running.removeAll { $0.session == session }
    }

    /// A turn ended: stop the session and count it for today.
    func finishTurn(_ context: AgentContext) {
        if let session = context.session {
            stop(session: session)
            finishedUnseen.insert(session)
        }
        updateToday { stats in
            stats.turns += 1
            stats.seconds += context.seconds ?? 0
            if let tokens = context.tokens, tokens > 0 { stats.tokens = (stats.tokens ?? 0) + tokens }
            if let project = context.project {
                if !stats.projects.contains(project) { stats.projects.append(project) }
                if let seconds = context.seconds, seconds > 0 {
                    stats.projectSeconds = stats.projectSeconds ?? [:]
                    stats.projectSeconds?[project, default: 0] += seconds
                }
            }
        }
        save()
    }

    // MARK: - Queued messages

    /// Only Claude can be handed a message when its turn ends (see `agent_hook.py`).
    static func canQueue(session: String) -> Bool { session.hasPrefix("claude-") }

    /// Queues `text` as the session's next prompt (replaces an earlier one).
    func queue(_ text: String, session: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, URLRouter.isValidSession(session) else { return }
        queued[session] = trimmed
        guard let url = queueFile(session) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(trimmed.utf8).write(to: url, options: .atomic)
        } catch {
            log.error("Queueing for \(session, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func unqueue(session: String) {
        queued.removeValue(forKey: session)
        if let url = queueFile(session) { try? FileManager.default.removeItem(at: url) }
    }

    /// The hook sent a queued message: the turn ended, and the next one starts right away.
    func queuedSent(_ context: AgentContext) {
        guard let session = context.session else { return }
        queued.removeValue(forKey: session)
        updateToday { $0.replies += 1 }
        start(context)
        save()
    }

    private func queueFile(_ session: String) -> URL? {
        queueDirectory?.appending(path: session + ".txt")
    }

    /// Queued messages still waiting from before a relaunch.
    private func loadQueue() {
        guard let queueDirectory,
              let urls = try? FileManager.default.contentsOfDirectory(at: queueDirectory, includingPropertiesForKeys: nil)
        else { return }
        for url in urls where url.pathExtension == "txt" {
            let session = url.deletingPathExtension().lastPathComponent
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty { queued[session] = text }
        }
    }

    // MARK: - Plan limit warnings

    nonisolated static let warnAt = [80, 95]

    /// Warning levels the new report crossed upward (at most one per window: the highest).
    /// A different reset time means a new window, which starts from 0 %.
    nonisolated static func limitWarnings(old: UsageLimits?, new: UsageLimits) -> [LimitWarning] {
        func check(_ name: String, _ oldUsed: Int?, _ oldReset: Date?, _ newUsed: Int?, _ newReset: Date?) -> LimitWarning? {
            guard let newUsed else { return nil }
            let sameWindow: Bool = switch (oldReset, newReset) {
            case let (a?, b?): abs(a.timeIntervalSince(b)) < 120
            case (nil, nil): true
            default: false
            }
            let before = sameWindow ? (oldUsed ?? 0) : 0
            guard let level = warnAt.last(where: { before < $0 && $0 <= newUsed }) else { return nil }
            return LimitWarning(window: name, percent: level, reset: newReset)
        }
        return [check("5-hour", old?.fiveHour, old?.fiveHourReset, new.fiveHour, new.fiveHourReset),
                check("weekly", old?.week, old?.weekReset, new.week, new.weekReset)].compactMap { $0 }
    }

    func setLimits(_ new: UsageLimits) {
        guard new != limits else { return }
        limits = new
        save()
    }

    /// You've seen it: from the panel (all sessions) or a reply bubble (one session).
    func markSeen(session: String? = nil) {
        if let session { finishedUnseen.remove(session) } else if !finishedUnseen.isEmpty { finishedUnseen.removeAll() }
    }

    func pruneStale() {
        let cutoff = now().addingTimeInterval(-Self.staleAfter)
        running.removeAll { $0.startedAt < cutoff }
    }

    // MARK: - Day stats

    var today: AgentDayStats { days[dayKey(now())] ?? AgentDayStats() }

    /// Totals of every day from `start` (any time that day) through today.
    func stats(since start: Date) -> AgentDayStats {
        let first = dayKey(start)
        var total = AgentDayStats()
        for (key, day) in days where key >= first { total.add(day) }
        return total
    }

    /// Projects agents worked in (last 30 days and right now), for linking tasks. Sorted.
    var knownProjects: [String] {
        var all = Set(days.values.flatMap(\.projects))
        for agent in running { if let p = agent.project { all.insert(p) } }
        return all.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func updateToday(_ change: (inout AgentDayStats) -> Void) {
        let key = dayKey(now())
        var stats = days[key] ?? AgentDayStats()
        change(&stats)
        days[key] = stats
        if days.count > Self.maxDays {
            for old in days.keys.sorted().prefix(days.count - Self.maxDays) { days.removeValue(forKey: old) }
        }
    }

    private func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Persistence

    private struct File: Codable {
        var events: [AgentEvent]
        var days: [String: AgentDayStats]?
        var limits: UsageLimits?
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        if let file = try? Self.decoder.decode(File.self, from: data) {
            events = file.events
            days = file.days ?? [:]
            limits = file.limits
        } else if let old = try? Self.decoder.decode([AgentEvent].self, from: data) {
            events = old  // first version: a bare array
        } else {
            log.error("agent-log.json unreadable, starting empty")
        }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Self.encoder.encode(File(events: events, days: days, limits: limits)).write(to: fileURL, options: .atomic)
        } catch {
            log.error("Saving agent-log.json failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
