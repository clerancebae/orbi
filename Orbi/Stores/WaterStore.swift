import Foundation
import Observation
import OSLog
import SwiftData

/// Today's water count, +1 and undo.
@MainActor
@Observable
final class WaterStore {
    private(set) var todayCount = 0
    private(set) var lastLogDate: Date?
    private(set) var lastError: String?

    /// Called after a glass is logged (from any surface). Resets the reminder countdown.
    @ObservationIgnored var onLogged: (() -> Void)?

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let glassSize: () -> Int
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let log = Logger(subsystem: "com.berke.Orbi", category: "WaterStore")

    init(context: ModelContext, glassSize: @escaping () -> Int,
         now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.context = context
        self.glassSize = glassSize
        self.now = now
        self.calendar = calendar
        refresh()
    }

    func refresh() {
        let (start, end) = todayBounds()
        do {
            todayCount = try context.fetchCount(FetchDescriptor<WaterLog>(
                predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end }))
            var latest = FetchDescriptor<WaterLog>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
            latest.fetchLimit = 1
            lastLogDate = try context.fetch(latest).first?.timestamp
        } catch {
            report(error, "Loading water")
        }
    }

    func add() {
        context.insert(WaterLog(timestamp: now(), amountMl: max(1, glassSize())))
        save()
        refresh()
        onLogged?()
    }

    /// Removes today's most recent glass. Returns false if there's nothing to undo today.
    @discardableResult
    func undoLast() -> Bool {
        let (start, end) = todayBounds()
        var descriptor = FetchDescriptor<WaterLog>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = 1
        do {
            guard let last = try context.fetch(descriptor).first else { return false }
            context.delete(last)
            save()
            refresh()
            return true
        } catch {
            report(error, "Undo")
            return false
        }
    }

    private func todayBounds() -> (Date, Date) {
        let start = calendar.startOfDay(for: now())
        // Adding one day to a valid start of day always succeeds in the Gregorian-family calendars we use.
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start, end)
    }

    private func save() {
        do {
            try context.save()
            lastError = nil
        } catch {
            report(error, "Saving water")
        }
    }

    private func report(_ error: Error, _ action: String) {
        log.error("\(action, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        lastError = "\(action) failed: \(error.localizedDescription)"
    }
}
