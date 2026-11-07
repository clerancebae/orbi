import Foundation
import SwiftData
import Testing
@testable import Orbi

struct SharedContainerTests {
    @Test func groupIDIsTeamPrefixed() {
        #expect(SharedContainer.groupID.hasSuffix("com.berke.orbi"))
        #expect(SharedContainer.groupID.split(separator: ".").first?.count == 10)
    }

    @Test func storeLivesInsideRoot() {
        #expect(SharedContainer.storeURL.path.hasPrefix(SharedContainer.rootURL.path))
        #expect(SharedContainer.statusFileURL.lastPathComponent == "status.json")
    }

    @Test @MainActor func taskItemRoundTripsInMemory() throws {
        let container = AppEnvironment.makeInMemoryContainer()
        let context = container.mainContext
        context.insert(TaskItem(title: "Write spec", estimatedMinutes: 25, plannedDate: .now, sortIndex: 0))
        try context.save()
        let items = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(items.count == 1)
        #expect(items.first?.status == .todo)
    }
}
