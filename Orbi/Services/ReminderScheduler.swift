import Foundation
import Observation
import OSLog

@MainActor
protocol MeetingProviding: AnyObject {
    /// End of the meeting happening at `date`, or nil if not in a meeting.
    func meetingEnd(containing date: Date) -> Date?
}

@MainActor
protocol WaterReminderPosting: AnyObject {
    func postWaterReminder()
    func clearWaterReminder()
}

/// Water & break reminders. Event-driven: computes the next due time and arms exactly one
/// one-shot timer. Logging water, snoozing, settings changes and waking from sleep re-arm it.
@MainActor
@Observable
final class ReminderScheduler {
    private(set) var nextDue: Date?
    /// A reminder was shown and not yet answered (water logged / snoozed).
    private(set) var isDue = false
    /// The next fire is a deferral to the end of a calendar event.
    private(set) var deferredForMeeting = false

    static let meetingGrace: TimeInterval = 2 * 60

    @ObservationIgnored private let settings: () -> ReminderSettings
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private weak var meetings: (any MeetingProviding)?
    @ObservationIgnored private weak var notifier: (any WaterReminderPosting)?
    @ObservationIgnored private let armOverride: ((Date?) -> Void)?
    /// Focus mode: a reminder due now waits until this turns false (`quietEnded()`).
    @ObservationIgnored private let quiet: () -> Bool
    /// A reminder came due during focus and is owed once it ends.
    @ObservationIgnored private(set) var owedAfterQuiet = false
    @ObservationIgnored private let timer = OneShotTimer(tolerance: 15)
    /// Start of the current countdown (last glass of water, or last reminder shown).
    @ObservationIgnored private var anchor: Date
    /// Explicit next fire (snooze or meeting deferral), overriding the computed time.
    @ObservationIgnored private var overrideDue: Date?
    @ObservationIgnored private let log = Logger(subsystem: "com.berke.Orbi", category: "Reminders")

    /// - Parameters:
    ///   - lastWater: most recent glass, so a relaunch doesn't restart the countdown.
    ///   - armTimer: test hook replacing the real timer; receives each armed date.
    init(settings: @escaping () -> ReminderSettings,
         now: @escaping () -> Date = Date.init,
         calendar: Calendar = .current,
         lastWater: Date?,
         meetings: (any MeetingProviding)?,
         notifier: (any WaterReminderPosting)?,
         quiet: @escaping () -> Bool = { false },
         armTimer: ((Date?) -> Void)? = nil) {
        self.quiet = quiet
        self.settings = settings
        self.now = now
        self.calendar = calendar
        self.meetings = meetings
        self.notifier = notifier
        self.armOverride = armTimer
        let current = now()
        let interval = TimeInterval(settings().intervalMinutes * 60)
        if let lastWater, current.timeIntervalSince(lastWater) < interval {
            anchor = lastWater
        } else {
            anchor = current
        }
    }

    // MARK: - Events

    func start() { rearm() }

    func waterLogged() {
        owedAfterQuiet = false
        anchor = now()
        overrideDue = nil
        isDue = false
        deferredForMeeting = false
        notifier?.clearWaterReminder()
        rearm()
    }

    func snooze(minutes: Int = 15) {
        overrideDue = now().addingTimeInterval(TimeInterval(minutes * 60))
        isDue = false
        deferredForMeeting = false
        notifier?.clearWaterReminder()
        rearm()
    }

    func settingsChanged() { rearm() }

    /// After sleep/wake or a day change: fire if overdue, otherwise re-arm.
    func systemWoke() {
        if let due = nextDue, due <= now() {
            timerFired()
        } else {
            rearm()
        }
    }

    func timerFired() {
        let current = now()
        // Never act early (e.g. a stray call); timers only ever fire late.
        if let due = nextDue, due > current.addingTimeInterval(1) {
            rearm()
            return
        }
        overrideDue = nil
        deferredForMeeting = false
        let s = settings()

        guard s.enabled, Self.isWithinWorkingHours(current, settings: s, calendar: calendar) else {
            rearm()
            return
        }
        if let end = meetings?.meetingEnd(containing: current), end > current {
            overrideDue = end.addingTimeInterval(Self.meetingGrace)
            deferredForMeeting = true
            log.info("In a meeting; deferring reminder to \(self.overrideDue!.formatted(), privacy: .public)") // set on the line above
            rearm()
            return
        }

        if quiet() {
            // Focus: no bubble now; one is owed when the task stops. Count down from here meanwhile.
            owedAfterQuiet = true
            anchor = current
            rearm()
            return
        }

        notifier?.postWaterReminder()
        isDue = true
        anchor = current
        rearm()
    }

    /// Focus ended (task paused / done, or focus turned off): show a reminder owed during it.
    func quietEnded() {
        guard owedAfterQuiet else { return }
        owedAfterQuiet = false
        overrideDue = now()
        rearm()
    }

    #if DEBUG
    /// Debug-only: run the fire path now (ignores the due time and working hours, but still
    /// defers during a meeting), so notifications and actions can be tried without waiting.
    func fireNowForTesting() {
        let current = now()
        if let end = meetings?.meetingEnd(containing: current), end > current {
            overrideDue = end.addingTimeInterval(Self.meetingGrace)
            deferredForMeeting = true
            rearm()
            return
        }
        overrideDue = nil
        deferredForMeeting = false
        notifier?.postWaterReminder()
        isDue = true
        anchor = current
        rearm()
    }
    #endif

    private func rearm() {
        nextDue = overrideDue ?? Self.nextDue(anchor: anchor, now: now(), settings: settings(), calendar: calendar)
        if let armOverride {
            armOverride(nextDue)
        } else {
            timer.schedule(at: nextDue) { [weak self] in self?.timerFired() }
        }
    }

    // MARK: - Pure logic

    /// Next reminder time: one interval after `anchor`, moved into working hours.
    /// Before the workday starts, the first reminder is one interval into the workday.
    nonisolated static func nextDue(anchor: Date, now: Date, settings: ReminderSettings, calendar: Calendar) -> Date? {
        guard settings.enabled, settings.isValid else { return nil }
        let interval = TimeInterval(settings.intervalMinutes * 60)
        let candidate = max(anchor.addingTimeInterval(interval), now)
        let firstDay = calendar.startOfDay(for: candidate)

        for offset in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay),
                  let window = workingWindow(on: day, settings: settings, calendar: calendar) else { continue }
            if offset == 0 {
                if candidate > window.end { continue }
                if candidate >= window.start { return candidate }
            }
            return min(window.start.addingTimeInterval(interval), window.end)
        }
        return nil
    }

    nonisolated static func isWithinWorkingHours(_ date: Date, settings: ReminderSettings, calendar: Calendar) -> Bool {
        guard let window = workingWindow(on: calendar.startOfDay(for: date), settings: settings, calendar: calendar) else {
            return false
        }
        return date >= window.start && date <= window.end
    }

    nonisolated static func workingWindow(on day: Date, settings: ReminderSettings, calendar: Calendar) -> (start: Date, end: Date)? {
        guard settings.isValid else { return nil }
        if !settings.includeWeekends && calendar.isDateInWeekend(day) { return nil }
        guard let start = calendar.date(byAdding: .minute, value: settings.workStartMinutes, to: day),
              let end = calendar.date(byAdding: .minute, value: settings.workEndMinutes, to: day) else { return nil }
        return (start, end)
    }
}
