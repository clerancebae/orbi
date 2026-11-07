import EventKit
import Foundation
import Observation
import OSLog

struct UpcomingEvent: Equatable, Sendable {
    var title: String
    var start: Date
    var end: Date
}

/// Read-only EventKit access: today's next event and "am I in a meeting right now?".
/// If access is denied, everything quietly returns nil and the UI hides calendar bits.
@MainActor
@Observable
final class CalendarService: MeetingProviding {
    enum Access: Equatable { case notDetermined, granted, denied }

    private(set) var access: Access
    private(set) var nextEvent: UpcomingEvent?

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let timer = OneShotTimer(tolerance: 5)
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private let log = Logger(subsystem: "com.berke.Orbi", category: "Calendar")

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
        access = Self.currentAccess()
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied  // denied, restricted, or write-only (can't read events)
        }
    }

    func requestAccess() async {
        guard access == .notDetermined else { return }
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            log.error("Calendar access request failed: \(error.localizedDescription, privacy: .public)")
        }
        access = Self.currentAccess()
        refresh()
    }

    /// Recomputes today's next event and wakes up again when it starts.
    func refresh() {
        guard access == .granted else {
            nextEvent = nil
            timer.cancel()
            return
        }
        let current = now()
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: current))
            ?? current.addingTimeInterval(86_400)
        nextEvent = relevantEvents(from: current, to: endOfDay)
            .filter { $0.startDate > current }
            .min { $0.startDate < $1.startDate }
            .map { UpcomingEvent(title: $0.title ?? "Event", start: $0.startDate, end: $0.endDate) }

        timer.schedule(at: nextEvent?.start.addingTimeInterval(1)) { [weak self] in self?.refresh() }
    }

    func meetingEnd(containing date: Date) -> Date? {
        guard access == .granted else { return nil }
        return relevantEvents(from: date.addingTimeInterval(-12 * 3600), to: date.addingTimeInterval(60))
            .filter { $0.startDate <= date && $0.endDate > date }
            .map(\.endDate)
            .max()
    }

    /// Timed, busy, not cancelled, not declined by me.
    private func relevantEvents(from start: Date, to end: Date) -> [EKEvent] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).filter { event in
            !event.isAllDay
                && event.availability != .free
                && event.status != .canceled
                && event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
        }
    }
}
