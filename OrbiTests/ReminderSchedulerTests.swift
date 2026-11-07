import Foundation
import Testing
@testable import Orbi

@MainActor
final class FakeMeetings: MeetingProviding {
    var meetings: [(start: Date, end: Date)] = []
    func meetingEnd(containing date: Date) -> Date? {
        meetings.filter { $0.start <= date && $0.end > date }.map(\.end).max()
    }
}

@MainActor
final class FakeNotifier: WaterReminderPosting {
    var posted = 0
    var cleared = 0
    func postWaterReminder() { posted += 1 }
    func clearWaterReminder() { cleared += 1 }
}

@MainActor
struct ReminderSchedulerTests {
    let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Istanbul")!  // valid fixed identifier
        cal.firstWeekday = 2
        return cal
    }()
    let meetings = FakeMeetings()
    let notifier = FakeNotifier()
    var settings = ReminderSettings(enabled: true, intervalMinutes: 45,
                                    workStartMinutes: 9 * 60, workEndMinutes: 18 * 60,
                                    includeWeekends: false)

    /// 2026-11-04 is a Wednesday.
    func date(day: Int = 4, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func makeScheduler(clock: TestClock, lastWater: Date? = nil, armed: ((Date?) -> Void)? = nil) -> ReminderScheduler {
        let s = settings
        return ReminderScheduler(settings: { s }, now: { clock.now }, calendar: calendar,
                                 lastWater: lastWater, meetings: meetings, notifier: notifier,
                                 armTimer: armed ?? { _ in })
    }

    // MARK: pure nextDue

    @Test func dueOneIntervalAfterAnchorDuringWork() {
        let due = ReminderScheduler.nextDue(anchor: date(10), now: date(10), settings: settings, calendar: calendar)
        #expect(due == date(10, 45))
    }

    @Test func beforeWorkdayFirstReminderIsOneIntervalIn() {
        let due = ReminderScheduler.nextDue(anchor: date(7), now: date(7), settings: settings, calendar: calendar)
        #expect(due == date(9, 45))
    }

    @Test func afterWorkdayMovesToNextWorkday() {
        let due = ReminderScheduler.nextDue(anchor: date(17, 40), now: date(17, 40), settings: settings, calendar: calendar)
        #expect(due == date(day: 5, 9, 45))
    }

    @Test func fridayEveningSkipsWeekend() {
        let due = ReminderScheduler.nextDue(anchor: date(day: 6, 17, 30), now: date(day: 6, 17, 30),
                                            settings: settings, calendar: calendar)
        #expect(due == date(day: 9, 9, 45))  // Monday
    }

    @Test func weekendsIncludedWhenEnabled() {
        var s = settings
        s.includeWeekends = true
        let due = ReminderScheduler.nextDue(anchor: date(day: 6, 17, 30), now: date(day: 6, 17, 30),
                                            settings: s, calendar: calendar)
        #expect(due == date(day: 7, 9, 45))  // Saturday
    }

    @Test func overdueFiresNow() {
        let due = ReminderScheduler.nextDue(anchor: date(9), now: date(11), settings: settings, calendar: calendar)
        #expect(due == date(11))
    }

    @Test func disabledOrInvalidMeansNoReminder() {
        var off = settings; off.enabled = false
        #expect(ReminderScheduler.nextDue(anchor: date(10), now: date(10), settings: off, calendar: calendar) == nil)
        var bad = settings; bad.workEndMinutes = bad.workStartMinutes
        #expect(ReminderScheduler.nextDue(anchor: date(10), now: date(10), settings: bad, calendar: calendar) == nil)
    }

    // MARK: behaviour

    @Test func firesPostsAndRearms() {
        let clock = TestClock(date(10))
        var armed: [Date?] = []
        let scheduler = makeScheduler(clock: clock) { armed.append($0) }
        scheduler.start()
        #expect(armed.last == date(10, 45))

        clock.now = date(10, 45)
        scheduler.timerFired()
        #expect(notifier.posted == 1)
        #expect(scheduler.isDue)
        #expect(armed.last == date(11, 30))
    }

    @Test func neverFiresEarly() {
        let clock = TestClock(date(10))
        let scheduler = makeScheduler(clock: clock)
        scheduler.start()
        clock.now = date(10, 20)
        scheduler.timerFired()
        #expect(notifier.posted == 0)
        #expect(scheduler.nextDue == date(10, 45))
    }

    @Test func defersDuringMeetingThenFires() {
        let clock = TestClock(date(10))
        let scheduler = makeScheduler(clock: clock)
        scheduler.start()
        meetings.meetings = [(date(10, 30), date(11))]

        clock.now = date(10, 45)
        scheduler.timerFired()
        #expect(notifier.posted == 0)
        #expect(scheduler.deferredForMeeting)
        #expect(scheduler.nextDue == date(11, 2))

        clock.now = date(11, 2)
        scheduler.timerFired()
        #expect(notifier.posted == 1)
        #expect(scheduler.deferredForMeeting == false)
    }

    @Test func backToBackMeetingsKeepDeferring() {
        let clock = TestClock(date(10))
        let scheduler = makeScheduler(clock: clock)
        scheduler.start()
        meetings.meetings = [(date(10, 30), date(11)), (date(11), date(12))]

        clock.now = date(10, 45)
        scheduler.timerFired()
        clock.now = date(11, 2)
        scheduler.timerFired()
        #expect(notifier.posted == 0)
        #expect(scheduler.nextDue == date(12, 2))
    }

    @Test func loggingWaterResetsCountdownAndClears() {
        let clock = TestClock(date(10))
        let scheduler = makeScheduler(clock: clock)
        scheduler.start()
        clock.now = date(10, 45)
        scheduler.timerFired()
        #expect(scheduler.isDue)

        clock.now = date(10, 50)
        scheduler.waterLogged()
        #expect(scheduler.isDue == false)
        #expect(notifier.cleared == 1)
        #expect(scheduler.nextDue == date(11, 35))
    }

    @Test func snoozeFifteenMinutes() {
        let clock = TestClock(date(10, 45))
        let scheduler = makeScheduler(clock: clock, lastWater: date(10))
        scheduler.start()
        scheduler.timerFired()
        scheduler.snooze(minutes: 15)
        #expect(scheduler.nextDue == date(11))
        #expect(scheduler.isDue == false)
    }

    @Test func wakingAfterHoursDoesNotNotify() {
        let clock = TestClock(date(17, 30))
        let scheduler = makeScheduler(clock: clock, lastWater: date(17))
        scheduler.start()
        #expect(scheduler.nextDue == date(17, 45))

        clock.now = date(20)          // laptop was asleep
        scheduler.systemWoke()
        #expect(notifier.posted == 0)
        #expect(scheduler.nextDue == date(day: 5, 9, 45))
    }

    @Test func relaunchKeepsRecentWaterAnchor() {
        let clock = TestClock(date(10, 20))
        let scheduler = makeScheduler(clock: clock, lastWater: date(10))
        scheduler.start()
        #expect(scheduler.nextDue == date(10, 45))
    }

    @Test func relaunchWithOldWaterStartsFresh() {
        let clock = TestClock(date(14))
        let scheduler = makeScheduler(clock: clock, lastWater: date(9))
        scheduler.start()
        #expect(scheduler.nextDue == date(14, 45))
    }
}
