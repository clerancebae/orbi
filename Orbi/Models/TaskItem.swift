import Foundation
import SwiftData

enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case todo, active, done
}

@Model
final class TaskItem {
    var id: UUID
    var title: String
    var estimatedMinutes: Int?
    /// Start of the day this task belongs to.
    var plannedDate: Date
    var sortIndex: Int
    var status: TaskStatus
    /// Set when it becomes active; nil while paused/todo/done.
    var startedAt: Date?
    var completedAt: Date?
    var createdAt: Date
    /// Time spent in earlier active stints (pausing banks time here). See DECISIONS.md.
    var spentSeconds: Int = 0
    /// Agent project (folder name) this task belongs to: an agent starting a turn there starts
    /// the task if nothing else is running. Optional, so existing stores migrate on their own.
    var project: String?

    init(
        id: UUID = UUID(),
        title: String,
        estimatedMinutes: Int? = nil,
        plannedDate: Date,
        sortIndex: Int,
        status: TaskStatus = .todo,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.estimatedMinutes = estimatedMinutes
        self.plannedDate = plannedDate
        self.sortIndex = sortIndex
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.createdAt = createdAt
    }
}
