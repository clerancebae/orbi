import Foundation
import Observation
import OSLog

/// What Touch Bar widgets and scripts (and later Claude) read from `status.json`.
struct StatusSnapshot: Codable, Equatable, Sendable {
    struct Task: Codable, Equatable, Sendable {
        var title: String
        var status: String
        var estimateMin: Int?
        var spentMin: Int
    }
    struct Upcoming: Codable, Equatable, Sendable {
        var title: String
        var date: String
        var estimateMin: Int?
    }
    struct Reading: Codable, Equatable, Sendable {
        var title: String
        var url: String
        var savedAt: Date
        var opened: Bool
        var snoozed: Bool
    }

    struct Finished: Codable, Equatable, Sendable {
        var title: String
        var url: String
        var finishedAt: Date
    }

    var activeTask: String?
    /// Negative when over the estimate; nil without an estimate.
    var remainingMin: Int?
    var elapsedMin: Int?
    var water: Int
    var waterGoal: Int
    var waterReminderDue: Bool
    var nextWaterReminder: Date?
    var readingCount: Int
    var nextEvent: String?
    var tasks: [Task]
    var upcoming: [Upcoming]
    var reading: [Reading]
    /// Finished read-later items, most recent first (last 30).
    var read: [Finished]
    var updatedAt: Date

    /// Equal ignoring `updatedAt`, so an unchanged state is not rewritten.
    func sameContent(as other: StatusSnapshot) -> Bool {
        var a = self, b = other
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        return a == b
    }
}

/// Writes `status.json` to the App Group container only when the observed state changes
/// (which includes the once-per-minute task tick while a task is active).
@MainActor
final class StatusExporter {
    private let fileURL: URL
    private let makeSnapshot: () -> StatusSnapshot
    private var lastWritten: StatusSnapshot?
    private var writePending = false
    private let log = Logger(subsystem: "com.berke.Orbi", category: "StatusExporter")

    init(fileURL: URL, snapshot: @escaping () -> StatusSnapshot) {
        self.fileURL = fileURL
        self.makeSnapshot = snapshot
    }

    func start() {
        writeIfChanged(track: true)
    }

    /// Builds the snapshot inside observation tracking, writes it if it changed, and
    /// re-arms tracking. Changes in one run-loop turn are coalesced into one write.
    private func writeIfChanged(track: Bool) {
        let snapshot = withObservationTracking {
            makeSnapshot()
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleWrite() }
        }
        guard lastWritten.map({ !$0.sameContent(as: snapshot) }) ?? true else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Self.encoder.encode(snapshot).write(to: fileURL, options: .atomic)
            lastWritten = snapshot
        } catch {
            log.error("Writing status.json failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleWrite() {
        guard !writePending else { return }
        writePending = true
        DispatchQueue.main.async { [weak self] in
            self?.writePending = false
            self?.writeIfChanged(track: true)
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
