import Foundation
import SwiftData
import Testing
@testable import Orbi

@MainActor
struct ReadingStoreTests {
    let container = AppEnvironment.makeInMemoryContainer()
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    final class Opened { var urls: [URL] = [] }
    let opened = Opened()

    func makeStore() -> ReadingStore {
        let clock = self.clock, opened = self.opened
        return ReadingStore(context: container.mainContext, now: { clock.now }, opener: { opened.urls.append($0) })
    }

    let a = URL(string: "https://example.com/a")!
    let b = URL(string: "https://www.example.org/b")!

    @Test func saveNewestFirstAndDedupes() {
        let store = makeStore()
        store.save(url: a, title: "A")
        clock.advance(minutes: 1)
        store.save(url: b, title: nil)
        store.save(url: a, title: "A again")
        #expect(store.items.map(\.url) == [b, a])
        #expect(store.items.last?.title == "A")
        #expect(store.items.first?.title == "example.org/b")
    }

    @Test func openMarksOpenedButNotFinished() {
        let store = makeStore()
        let item = store.save(url: a, title: "A")
        store.open(item)
        #expect(opened.urls == [a])
        #expect(item.openedAt == clock.now)
        #expect(item.finishedAt == nil)
        #expect(store.items.count == 1)
    }

    @Test func finishMovesToReadAndIsKept() {
        let store = makeStore()
        let item = store.save(url: a, title: "A")
        store.finish(item)
        #expect(store.items.isEmpty)
        #expect(item.finishedAt == clock.now)
        #expect(store.finishedToday.map(\.title) == ["A"])
        #expect(store.finishedEarlier.isEmpty)

        clock.advance(minutes: 24 * 60)
        store.refresh()
        #expect(store.finishedToday.isEmpty)
        #expect(store.finishedEarlier.map(\.title) == ["A"])   // still kept the next day
    }

    @Test func unfinishAndClearEarlier() {
        let store = makeStore()
        let old = store.save(url: a, title: "Old")
        store.finish(old)
        clock.advance(minutes: 24 * 60)
        let today = store.save(url: b, title: "Today")
        store.finish(today)

        store.clearFinishedEarlier()
        #expect(store.finished.map(\.title) == ["Today"])   // today's read items survive "Clear all"

        store.unfinish(today)
        #expect(store.items.map(\.title) == ["Today"])
        #expect(store.finished.isEmpty)
    }

    @Test func savingAFinishedLinkAgainCreatesNewItem() {
        let store = makeStore()
        let first = store.save(url: a, title: "A")
        store.finish(first)
        let again = store.save(url: a, title: "A")
        #expect(again.id != first.id)
        #expect(store.items.count == 1)
        #expect(store.finished.count == 1)
    }

    @Test func openNextPicksOldestNotSnoozed() {
        let store = makeStore()
        let old = store.save(url: a, title: "Old")
        clock.advance(minutes: 10)
        store.save(url: b, title: "New")
        store.snooze(old, until: clock.now.addingTimeInterval(3600))

        #expect(store.openNext())
        #expect(opened.urls == [b])

        clock.advance(minutes: 61)
        store.refresh()
        #expect(store.openNext())
        #expect(opened.urls == [b, a])
    }

    @Test func summaryIgnoresSnoozed() throws {
        let store = makeStore()
        #expect(store.pendingSummary() == nil)
        let first = store.save(url: a, title: "First")
        clock.advance(minutes: 60 * 24 * 2)
        store.save(url: b, title: "Second")
        let summary = try #require(store.pendingSummary())
        #expect(summary.count == 2)
        #expect(summary.oldestTitle == "First")

        store.snooze(first, until: clock.now.addingTimeInterval(3600))
        #expect(store.pendingSummary()?.count == 1)
        #expect(store.pendingSummary()?.oldestTitle == "Second")
    }

    @Test func relativeDayText() {
        let now = clock.now
        #expect(RelativeDay.text(for: now, now: now) == "today")
        #expect(RelativeDay.text(for: now.addingTimeInterval(-86_400), now: now) == "yesterday")
        #expect(RelativeDay.text(for: now.addingTimeInterval(-5 * 86_400), now: now) == "5 days ago")
    }
}

@MainActor
struct ReadingNudgeTests {
    let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Istanbul")!  // valid fixed identifier
        return cal
    }()
    let config = ReadingNudgeScheduler.Config(enabled: true, minutes: 21 * 60)

    func date(day: Int = 7, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test func nextNudgeTimes() {
        #expect(ReadingNudgeScheduler.nextNudge(now: date(10), config: config, lastCheckedDay: nil, calendar: calendar) == date(21))
        // Launched after 21:00 without a nudge today → now.
        #expect(ReadingNudgeScheduler.nextNudge(now: date(22), config: config, lastCheckedDay: "2026-11-06", calendar: calendar) == date(22))
        // Already checked today → tomorrow.
        #expect(ReadingNudgeScheduler.nextNudge(now: date(22), config: config, lastCheckedDay: "2026-11-07", calendar: calendar) == date(day: 8, 21))
        var off = config; off.enabled = false
        #expect(ReadingNudgeScheduler.nextNudge(now: date(10), config: off, lastCheckedDay: nil, calendar: calendar) == nil)
    }

    @Test func atMostOncePerDay() {
        let clock = TestClock(date(21))
        var lastDay: String?
        var posted: [Int] = []
        var hasItems = true
        let cfg = config
        let scheduler = ReadingNudgeScheduler(
            config: { cfg }, now: { clock.now }, calendar: calendar,
            summary: { hasItems ? ReadingSummary(count: 3, oldestSavedAt: clock.now, oldestTitle: "X") : nil },
            post: { posted.append($0.count) },
            lastCheckedDay: { lastDay }, setLastCheckedDay: { lastDay = $0 },
            armTimer: { _ in })
        scheduler.rearm()
        scheduler.fire()
        scheduler.fire()
        clock.advance(minutes: 60)
        scheduler.rearm()
        scheduler.fire()
        #expect(posted == [3])
        #expect(scheduler.nextNudge == date(day: 8, 21))

        // Next day with nothing waiting: no nudge, but still counts as checked.
        hasItems = false
        clock.now = date(day: 8, 21)
        scheduler.fire()
        #expect(posted == [3])
        #expect(lastDay == "2026-11-08")
    }
}

@MainActor
struct UpcomingTaskTests {
    @Test func addForTomorrowGoesToUpcomingThenRollsIn() throws {
        let container = AppEnvironment.makeInMemoryContainer()
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = TaskStore(context: container.mainContext, now: { clock.now }, live: false)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: clock.now)!

        let task = try #require(store.add(title: "Tomorrow thing", estimatedMinutes: 30, on: tomorrow))
        #expect(store.tasks.isEmpty)
        #expect(store.upcoming.map(\.title) == ["Tomorrow thing"])
        #expect(task.plannedDate == Calendar.current.startOfDay(for: tomorrow))

        clock.advance(minutes: 24 * 60)
        store.refresh()
        #expect(store.tasks.map(\.title) == ["Tomorrow thing"])
        #expect(store.upcoming.isEmpty)
    }
}

@MainActor
struct StatusSnapshotTests {
    @Test func encodesSpecFieldsAndIgnoresTimestampForEquality() throws {
        let a = StatusSnapshot(activeTask: "API docs", remainingMin: 23, elapsedMin: 2, water: 5, waterGoal: 8,
                               waterReminderDue: false, nextWaterReminder: nil, readingCount: 3,
                               nextEvent: "14:00 Standup", tasks: [], upcoming: [], reading: [], read: [],
                               updatedAt: Date(timeIntervalSince1970: 0))
        var b = a
        b.updatedAt = Date(timeIntervalSince1970: 100)
        #expect(a.sameContent(as: b))
        b.water = 6
        #expect(!a.sameContent(as: b))

        let json = try JSONSerialization.jsonObject(with: StatusExporter.encoder.encode(a)) as? [String: Any]
        #expect(json?["activeTask"] as? String == "API docs")
        #expect(json?["remainingMin"] as? Int == 23)
        #expect(json?["water"] as? Int == 5)
        #expect(json?["waterGoal"] as? Int == 8)
        #expect(json?["readingCount"] as? Int == 3)
        #expect(json?["nextEvent"] as? String == "14:00 Standup")
        #expect(json?["updatedAt"] as? String == "1970-01-01T00:00:00Z")
    }
}
