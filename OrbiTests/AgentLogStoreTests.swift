import Foundation
import Testing
@testable import Orbi

@MainActor
struct AgentLogStoreTests {
    func event(_ id: String, kind: AgentEvent.Kind = .permission) -> AgentEvent {
        AgentEvent(id: id, date: .now, kind: kind, title: "Claude wants to use Bash", subtitle: "Orbi", detail: "ls")
    }

    @Test func newestFirstAndCapped() {
        let store = AgentLogStore(fileURL: nil)
        for i in 0..<(AgentLogStore.maxEvents + 5) { store.add(event("e\(i)")) }
        #expect(store.events.count == AgentLogStore.maxEvents)
        #expect(store.events.first?.id == "e\(AgentLogStore.maxEvents + 4)")
    }

    @Test func outcomeIsRecordedOnce() {
        let store = AgentLogStore(fileURL: nil)
        store.add(event("a", kind: .finished))
        store.setOutcome(id: "a", .replied, reply: "push it")
        store.setOutcome(id: "a", .elsewhere)  // the hook's cancel after the click
        #expect(store.events[0].outcome == .replied)
        #expect(store.events[0].reply == "push it")
        store.setOutcome(id: "missing", .allowed)  // no crash, no entry
        #expect(store.events.count == 1)
    }

    @Test func tokensAndLimitsAreKept() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "agent-log-tokens-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentLogStore(fileURL: url)
        store.finishTurn(AgentContext(session: "a", tokens: 12_000))
        store.finishTurn(AgentContext(session: "a"))
        store.finishTurn(AgentContext(session: "a", tokens: 500))
        #expect(store.today.tokens == 12_500)
        let limits = UsageLimits(fiveHour: 23, fiveHourReset: Date(timeIntervalSince1970: 1_793_000_000),
                                 week: 41, weekReset: nil, updated: Date(timeIntervalSince1970: 1_792_990_000))
        store.setLimits(limits)
        let reopened = AgentLogStore(fileURL: url)
        #expect(reopened.today.tokens == 12_500)
        #expect(reopened.limits == limits)
        #expect(AgentsSection.summary(reopened.today)?.contains("13k tokens") == true)
    }

    @Test func persistsAcrossLaunches() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "agent-log-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentLogStore(fileURL: url)
        store.add(event("p"))
        store.setOutcome(id: "p", .allowed)
        let reopened = AgentLogStore(fileURL: url)
        #expect(reopened.events.map(\.id) == ["p"])
        #expect(reopened.events[0].outcome == .allowed)
        reopened.clear()
        #expect(AgentLogStore(fileURL: url).events.isEmpty)
    }

    @Test func runningSessionsAndDayStats() {
        let clock = TestClock(Date(timeIntervalSince1970: 1_793_000_000))
        let store = AgentLogStore(fileURL: nil, now: { clock.now })
        store.start(AgentContext(session: "claude-1", agent: "Claude", project: "Orbi", app: "com.apple.Terminal"))
        store.start(AgentContext(session: "claude-2", agent: "Claude", project: "api"))
        store.start(AgentContext(session: "claude-1", agent: "Claude", project: "Orbi"))  // restart, no duplicate
        #expect(store.running.map(\.session) == ["claude-2", "claude-1"])
        store.finishTurn(AgentContext(session: "claude-1", project: "Orbi", seconds: 420))
        store.finishTurn(AgentContext(session: "claude-x", project: "Orbi", seconds: 60))
        #expect(store.running.map(\.session) == ["claude-2"])
        #expect(store.today.turns == 2)
        #expect(store.today.seconds == 480)
        #expect(store.today.projects == ["Orbi"])
        store.start(AgentContext(session: "ignored"))
        store.stop(session: "ignored")
        store.start(AgentContext())  // no session → ignored
        #expect(store.running.count == 1)
        clock.advance(minutes: 4 * 60)
        store.pruneStale()
        #expect(store.running.isEmpty)  // closed terminal mid-turn
    }

    @Test func outcomesCountForToday() {
        let store = AgentLogStore(fileURL: nil)
        for (id, outcome) in [("a", AgentEvent.Outcome.allowed), ("b", .allowed), ("c", .denied), ("d", .replied), ("e", .terminal)] {
            store.add(event(id))
            store.askOpened(id)
            store.setOutcome(id: id, outcome)
        }
        #expect(store.openAsks.isEmpty)
        #expect((store.today.allowed, store.today.denied, store.today.replies) == (2, 1, 1))
    }

    @Test func readsFirstVersionFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "agent-log-v1-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let v1 = #"[{"id":"x","date":"2026-11-07T10:00:00Z","kind":"finished","title":"Claude finished ✓"}]"#
        try Data(v1.utf8).write(to: url)
        let store = AgentLogStore(fileURL: url)
        #expect(store.events.map(\.id) == ["x"])
        store.finishTurn(AgentContext(project: "Orbi", seconds: 90))
        #expect(AgentLogStore(fileURL: url).today.turns == 1)  // saved in the new format
    }

    @Test func finishedTurnIsYourTurnUntilSeen() {
        let store = AgentLogStore(fileURL: nil)
        store.start(AgentContext(session: "a"))
        store.start(AgentContext(session: "b"))
        #expect(store.waitingForYou == 0)
        store.finishTurn(AgentContext(session: "a", seconds: 30))
        store.finishTurn(AgentContext(session: "b", seconds: 30))
        #expect(store.waitingForYou == 2)
        store.start(AgentContext(session: "a"))  // you typed the next prompt in session a
        #expect(store.finishedUnseen == ["b"])
        store.markSeen(session: "b")             // answered b's reply bubble
        #expect(store.waitingForYou == 0)
        store.finishTurn(AgentContext(session: "a"))
        store.askOpened("q1")
        #expect(store.waitingForYou == 2)
        store.markSeen()                          // opened the panel
        #expect(store.waitingForYou == 1)         // the open question still waits
        store.stop(session: "a")                  // idle/interrupted doesn't count as "your turn"
        #expect(store.finishedUnseen.isEmpty)
    }
}
