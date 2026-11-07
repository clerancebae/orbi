import Foundation
import OSLog

/// Once-a-day "you have things to read" nudge at the configured time. One one-shot timer.
@MainActor
final class ReadingNudgeScheduler {
    struct Config: Equatable, Sendable {
        var enabled: Bool
        /// Minutes from midnight.
        var minutes: Int
    }

    private let config: () -> Config
    private let now: () -> Date
    private let calendar: Calendar
    private let summary: () -> ReadingSummary?
    private let post: (ReadingSummary) -> Void
    private let lastCheckedDay: () -> String?
    private let setLastCheckedDay: (String) -> Void
    private let armOverride: ((Date?) -> Void)?
    /// Focus mode: the nudge waits (no timer) until `quietEnded()`.
    private let quiet: () -> Bool
    private(set) var waitingForQuiet = false
    private let timer = OneShotTimer(tolerance: 30)
    private(set) var nextNudge: Date?

    init(config: @escaping () -> Config,
         now: @escaping () -> Date = Date.init,
         calendar: Calendar = .current,
         summary: @escaping () -> ReadingSummary?,
         post: @escaping (ReadingSummary) -> Void,
         lastCheckedDay: @escaping () -> String?,
         setLastCheckedDay: @escaping (String) -> Void,
         quiet: @escaping () -> Bool = { false },
         armTimer: ((Date?) -> Void)? = nil) {
        self.quiet = quiet
        self.config = config
        self.now = now
        self.calendar = calendar
        self.summary = summary
        self.post = post
        self.lastCheckedDay = lastCheckedDay
        self.setLastCheckedDay = setLastCheckedDay
        self.armOverride = armTimer
    }

    func rearm() {
        nextNudge = Self.nextNudge(now: now(), config: config(), lastCheckedDay: lastCheckedDay(), calendar: calendar)
        if let armOverride {
            armOverride(nextNudge)
        } else {
            timer.schedule(at: nextNudge) { [weak self] in self?.fire() }
        }
    }

    func fire() {
        let current = now()
        if let due = nextNudge, due > current.addingTimeInterval(1) { rearm(); return }
        let today = Self.dayKey(current, calendar: calendar)
        // Checked today already (nudged, or nothing was waiting): never more than one per day.
        guard lastCheckedDay() != today, config().enabled else { rearm(); return }
        if quiet() {
            // Not armed again until focus ends, so it can't fire in a loop.
            waitingForQuiet = true
            return
        }
        setLastCheckedDay(today)
        if let summary = summary() { post(summary) }
        rearm()
    }

    func quietEnded() {
        guard waitingForQuiet else { return }
        waitingForQuiet = false
        rearm()
    }

    /// Today's nudge time if not yet checked today (or right now, if that time already
    /// passed today); otherwise tomorrow's.
    nonisolated static func nextNudge(now: Date, config: Config, lastCheckedDay: String?, calendar: Calendar) -> Date? {
        guard config.enabled, (0..<(24 * 60)).contains(config.minutes) else { return nil }
        let today = calendar.startOfDay(for: now)
        guard let todayTime = calendar.date(byAdding: .minute, value: config.minutes, to: today) else { return nil }
        if lastCheckedDay != dayKey(now, calendar: calendar) {
            return max(todayTime, now)
        }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
        return calendar.date(byAdding: .minute, value: config.minutes, to: tomorrow)
    }

    nonisolated static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
