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
}
