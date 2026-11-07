import Foundation
import SwiftData

@Model
final class ReadingItem {
    var id: UUID
    var url: URL
    var title: String
    var savedAt: Date
    /// First time it was opened. Opened ≠ finished.
    var openedAt: Date?
    var finishedAt: Date?
    var estimatedMinutes: Int?
    /// Snoozed until this time (excluded from nudges and "open next" until then).
    var remindAfter: Date?

    init(id: UUID = UUID(), url: URL, title: String, savedAt: Date = .now,
         openedAt: Date? = nil, finishedAt: Date? = nil,
         estimatedMinutes: Int? = nil, remindAfter: Date? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.savedAt = savedAt
        self.openedAt = openedAt
        self.finishedAt = finishedAt
        self.estimatedMinutes = estimatedMinutes
        self.remindAfter = remindAfter
    }
}
