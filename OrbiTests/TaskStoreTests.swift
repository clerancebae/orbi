import Foundation
import SwiftData
import Testing
@testable import Orbi

@MainActor
final class TestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
    func advance(minutes: Double) { now = now.addingTimeInterval(minutes * 60) }
}

@MainActor
struct TaskStoreTests {
    let container = AppEnvironment.makeInMemoryContainer()
    let clock: TestClock
    let calendar: Calendar

    init() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Istanbul")!  // fixed, valid identifier
        calendar = cal
        clock = TestClock(cal.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 10))!)
    }

    func makeStore() -> TaskStore {
        let clock = self.clock
        return TaskStore(context: container.mainContext, now: { clock.now }, calendar: calendar, live: false)
    }

    @Test func addTrimsAndRejectsEmpty() {
        let store = makeStore()
        #expect(store.add(title: "   ") == nil)
        let task = store.add(title: "  Write docs ", estimatedMinutes: 25)
        #expect(task?.title == "Write docs")
        #expect(task?.estimatedMinutes == 25)
        #expect(task?.plannedDate == calendar.startOfDay(for: clock.now))
        #expect(store.tasks.count == 1)
    }

    @Test func addFromInputParsesEstimate() {
        let store = makeStore()
        let task = store.add(input: "Review PR 45m")
        #expect(task?.title == "Review PR")
        #expect(task?.estimatedMinutes == 45)
    }

    @Test func onlyOneActiveTask() throws {
        let store = makeStore()
        let a = try #require(store.add(title: "A"))
        let b = try #require(store.add(title: "B"))

        store.start(a)
        #expect(a.status == .active)

        store.start(b)
        #expect(b.status == .active)
        #expect(a.status == .todo)
        #expect(store.tasks.filter { $0.status == .active }.count == 1)
        #expect(store.activeTask?.id == b.id)
    }

    @Test func pausingBanksElapsedTime() throws {
        let store = makeStore()
        let a = try #require(store.add(title: "A", estimatedMinutes: 30))
        let b = try #require(store.add(title: "B"))

        store.start(a)
        clock.advance(minutes: 10)
        store.start(b)          // pauses A
        #expect(a.spentSeconds == 600)
        #expect(a.startedAt == nil)

        clock.advance(minutes: 5)
        store.start(a)          // resume A
        clock.advance(minutes: 3)
        store.refresh()
        #expect(store.elapsedSeconds(a) == 13 * 60)
        #expect(store.remainingSeconds(a) == 17 * 60)
        #expect(b.spentSeconds == 300)
    }

    @Test func sleepIsNotCountedAsWork() throws {
        let store = makeStore()
        let task = try #require(store.add(title: "Docs", estimatedMinutes: 30))
        store.start(task)
        clock.advance(minutes: 10)
        store.systemWillSleep()
        #expect(task.status == .active)
        clock.advance(minutes: 600)  // lid closed for 10 hours
        #expect(store.elapsedSeconds(task) == 10 * 60)
        store.systemDidWake()
        clock.advance(minutes: 5)
        store.refresh()
        #expect(store.elapsedSeconds(task) == 15 * 60)
        #expect(store.remainingSeconds(task) == 15 * 60)
        store.pause(task)
        #expect(task.spentSeconds == 15 * 60)
    }

    @Test func remainingGoesNegativeWhenOver() throws {
        let store = makeStore()
        let a = try #require(store.add(title: "A", estimatedMinutes: 5))
        store.start(a)
        clock.advance(minutes: 7)
        store.refresh()
        #expect(store.remainingSeconds(a) == -120)
    }

    @Test func completeStopsTimerAndRecordsTime() throws {
        let store = makeStore()
        let a = try #require(store.add(title: "A"))
        store.start(a)
        clock.advance(minutes: 20)
        #expect(store.completeActive())
        #expect(a.status == .done)
        #expect(a.completedAt == clock.now)
        #expect(a.spentSeconds == 1200)
        #expect(store.activeTask == nil)
        #expect(store.completeActive() == false)
    }

    @Test func startNextPicksFirstTodoInOrder() throws {
        let store = makeStore()
        let a = try #require(store.add(title: "A"))
        let b = try #require(store.add(title: "B"))
        store.complete(a)
        #expect(store.startNext())
        #expect(b.status == .active)
        #expect(store.startNext() == false)  // B is active, nothing else todo
    }

    @Test func moveReordersOpenTasks() throws {
        let store = makeStore()
        store.add(title: "A"); store.add(title: "B"); store.add(title: "C")
        store.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(store.openTasks.map(\.title) == ["C", "A", "B"])
    }

    @Test func reopenPutsTaskAtEnd() throws {
        let store = makeStore()
        let a = try #require(store.add(title: "A"))
        store.add(title: "B")
        store.complete(a)
        store.reopen(a)
        #expect(a.status == .todo)
        #expect(a.completedAt == nil)
        #expect(store.openTasks.map(\.title) == ["B", "A"])
    }

    @Test func deleteRemovesTask() throws {
        let store = makeStore()
        let a = try #require(store.add(title: "A"))
        store.delete(a)
        #expect(store.tasks.isEmpty)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<TaskItem>()) == 0)
    }

    @Test func unfinishedTasksRollOverToNextDay() throws {
        let store = makeStore()
        let a = try #require(store.add(title: "Unfinished"))
        let b = try #require(store.add(title: "Finished"))
        store.complete(b)
        store.start(a)

        clock.advance(minutes: 24 * 60)
        store.refresh()

        let today = calendar.startOfDay(for: clock.now)
        #expect(store.tasks.map(\.title) == ["Unfinished"])
        #expect(a.plannedDate == today)
        #expect(a.status == .active)  // still running across midnight
        #expect(b.plannedDate < today)
    }

    @Test func dataSurvivesNewStoreInstance() throws {
        let store = makeStore()
        let a = try #require(store.add(title: "Persisted", estimatedMinutes: 15))
        store.start(a)

        let reloaded = makeStore()
        #expect(reloaded.activeTask?.title == "Persisted")
        #expect(reloaded.activeTask?.estimatedMinutes == 15)
    }

    @Test func repairsMultipleActiveTasks() throws {
        let context = container.mainContext
        let today = calendar.startOfDay(for: clock.now)
        context.insert(TaskItem(title: "Old", plannedDate: today, sortIndex: 0, status: .active,
                                startedAt: clock.now.addingTimeInterval(-600)))
        context.insert(TaskItem(title: "New", plannedDate: today, sortIndex: 1, status: .active,
                                startedAt: clock.now.addingTimeInterval(-60)))
        try context.save()

        let store = makeStore()
        #expect(store.tasks.filter { $0.status == .active }.count == 1)
        #expect(store.activeTask?.title == "New")
    }
}

@MainActor
struct EndingSoonTests {
    let container = AppEnvironment.makeInMemoryContainer()
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))

    func makeStore(_ fired: @escaping (String) -> Void) -> TaskStore {
        let clock = self.clock
        let store = TaskStore(context: container.mainContext, now: { clock.now }, live: false)
        store.onEndingSoon = { fired($0.title) }
        return store
    }

    @Test func firesOnceWhenCrossingFiveMinutes() throws {
        var fired: [String] = []
        let store = makeStore { fired.append($0) }
        let task = try #require(store.add(title: "Docs", estimatedMinutes: 20))
        store.start(task)

        clock.advance(minutes: 14); store.refresh()
        #expect(fired.isEmpty)                // 6m left

        clock.advance(minutes: 1); store.refresh()
        #expect(fired == ["Docs"])            // exactly 5m left

        clock.advance(minutes: 1); store.refresh()
        clock.advance(minutes: 10); store.refresh()
        #expect(fired == ["Docs"])            // never twice
    }

    @Test func extendingRearmsThePrompt() throws {
        var fired = 0
        let store = makeStore { _ in fired += 1 }
        let task = try #require(store.add(title: "Docs", estimatedMinutes: 10))
        store.start(task)
        clock.advance(minutes: 6); store.refresh()   // 4m left
        #expect(fired == 1)

        store.extend(task, byMinutes: 15)             // 19m left
        #expect(task.estimatedMinutes == 25)
        #expect(fired == 1)

        clock.advance(minutes: 14); store.refresh()   // 5m left
        #expect(fired == 2)
    }

    @Test func shortTaskDoesNotPromptImmediately() throws {
        var fired = 0
        let store = makeStore { _ in fired += 1 }
        let task = try #require(store.add(title: "Quick", estimatedMinutes: 3))
        store.start(task)
        clock.advance(minutes: 1); store.refresh()
        #expect(fired == 0)
    }

    @Test func noEstimateNeverPrompts() throws {
        var fired = 0
        let store = makeStore { _ in fired += 1 }
        let task = try #require(store.add(title: "Open-ended"))
        store.start(task)
        clock.advance(minutes: 60); store.refresh()
        #expect(fired == 0)
    }

    @Test func extendWithoutEstimateStartsFromElapsed() throws {
        let store = makeStore { _ in }
        let task = try #require(store.add(title: "Open-ended"))
        store.start(task)
        clock.advance(minutes: 12); store.refresh()
        store.extend(task, byMinutes: 15)
        #expect(task.estimatedMinutes == 27)
    }
}

@MainActor
struct TimeUpTests {
    let container = AppEnvironment.makeInMemoryContainer()
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))

    @Test func timeUpFiresOnceAndTakesPrecedence() throws {
        let clock = self.clock
        let store = TaskStore(context: container.mainContext, now: { clock.now }, live: false)
        var events: [String] = []
        store.onEndingSoon = { _ in events.append("soon") }
        store.onTimeUp = { _ in events.append("up") }
        let task = try #require(store.add(title: "Docs", estimatedMinutes: 10))
        store.start(task)

        clock.advance(minutes: 5); store.refresh()   // 5m left
        clock.advance(minutes: 5); store.refresh()   // 0m left
        clock.advance(minutes: 3); store.refresh()   // over
        #expect(events == ["soon", "up"])

        // Asleep through both thresholds: only "time's up".
        events.removeAll()
        store.extend(task, byMinutes: 15)            // 12m left
        clock.advance(minutes: 20); store.refresh()
        #expect(events == ["up"])
    }
}
