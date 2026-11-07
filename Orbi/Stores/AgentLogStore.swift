import Foundation
import Observation
import OSLog

/// What AI agents did, as seen through Orbi: permission requests (and your answer) and
/// finished turns (with the agent's last message and your reply). Newest first, last 100,
/// kept in `agent-log.json` next to the SwiftData store. Plain JSON on purpose: it's a
/// short rolling log, so no schema migration for the main store.
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
}

@MainActor
@Observable
final class AgentLogStore {
    static let maxEvents = 100

    private(set) var events: [AgentEvent] = []
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let log = Logger(subsystem: "com.berke.Orbi", category: "AgentLog")

    /// - Parameter fileURL: nil keeps the log in memory only (tests, demo mode).
    init(fileURL: URL?) {
        self.fileURL = fileURL
        load()
    }

    func add(_ event: AgentEvent) {
        events.removeAll { $0.id == event.id }
        events.insert(event, at: 0)
        if events.count > Self.maxEvents { events.removeLast(events.count - Self.maxEvents) }
        save()
    }

    /// Records the answer once; later answers for the same id (e.g. a cancel after you
    /// already clicked) don't overwrite it.
    func setOutcome(id: String, _ outcome: AgentEvent.Outcome, reply: String? = nil) {
        guard let index = events.firstIndex(where: { $0.id == id }), events[index].outcome == nil else { return }
        events[index].outcome = outcome
        events[index].reply = reply
        save()
    }

    func clear() {
        events.removeAll()
        save()
    }

    // MARK: - Persistence

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
        do {
            events = try Self.decoder.decode([AgentEvent].self, from: data)
        } catch {
            log.error("agent-log.json unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Self.encoder.encode(events).write(to: fileURL, options: .atomic)
        } catch {
            log.error("Saving agent-log.json failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
