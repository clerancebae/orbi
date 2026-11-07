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

    /// Agents waiting on you: open questions plus finished turns you haven't seen.
    var waitingForYou: Int { openAsks.count + finishedUnseen.count }

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let log = Logger(subsystem: "com.berke.Orbi", category: "AgentLog")

    /// - Parameter fileURL: nil keeps everything in memory only (tests, demo mode).
    init(fileURL: URL?, now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.fileURL = fileURL
        self.now = now
        self.calendar = calendar
        load()
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
            if let project = context.project, !stats.projects.contains(project) { stats.projects.append(project) }
        }
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
            try Self.encoder.encode(File(events: events, days: days)).write(to: fileURL, options: .atomic)
        } catch {
            log.error("Saving agent-log.json failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
