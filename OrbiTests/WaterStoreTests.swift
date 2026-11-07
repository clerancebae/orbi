import Foundation
import SwiftData
import Testing
@testable import Orbi

@MainActor
struct WaterStoreTests {
    let container = AppEnvironment.makeInMemoryContainer()
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))

    func makeStore() -> WaterStore {
        let clock = self.clock
        return WaterStore(context: container.mainContext, glassSize: { 300 }, now: { clock.now })
    }

    @Test func addCountsAndNotifies() throws {
        let store = makeStore()
        var logged = 0
        store.onLogged = { logged += 1 }
        store.add(); store.add()
        #expect(store.todayCount == 2)
        #expect(logged == 2)
        #expect(store.lastLogDate == clock.now)
        let logs = try container.mainContext.fetch(FetchDescriptor<WaterLog>())
        #expect(logs.allSatisfy { $0.amountMl == 300 })
    }

    @Test func undoRemovesMostRecent() {
        let store = makeStore()
        store.add()
        clock.advance(minutes: 30)
        store.add()
        #expect(store.undoLast())
        #expect(store.todayCount == 1)
        #expect(store.lastLogDate == clock.now.addingTimeInterval(-1800))
    }

    @Test func undoWithNothingTodayIsNoop() {
        let store = makeStore()
        #expect(store.undoLast() == false)
    }

    @Test func countResetsNextDayAndUndoDoesNotTouchYesterday() {
        let store = makeStore()
        store.add(); store.add()
        clock.advance(minutes: 24 * 60)
        store.refresh()
        #expect(store.todayCount == 0)
        #expect(store.undoLast() == false)
    }
}
