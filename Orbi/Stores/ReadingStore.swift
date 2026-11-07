import AppKit
import Foundation
import Observation
import OSLog
import SwiftData

struct ReadingSummary: Equatable, Sendable {
    var count: Int
    var oldestSavedAt: Date
    var oldestTitle: String
}

/// Read-later items. All surfaces (panel, URL scheme, Safari extension later) go through here.
@MainActor
@Observable
final class ReadingStore {
    /// Unfinished items, newest first.
    private(set) var items: [ReadingItem] = []
    /// Finished items, most recently finished first. Kept until the user deletes them.
    private(set) var finished: [ReadingItem] = []
    private(set) var lastError: String?
    /// Bumped when time-dependent state (snoozes) should be re-evaluated by views.
    private(set) var currentDate: Date

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let opener: (URL) -> Void
    @ObservationIgnored private let log = Logger(subsystem: "com.berke.Orbi", category: "ReadingStore")

    init(context: ModelContext, now: @escaping () -> Date = Date.init, calendar: Calendar = .current,
         opener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.context = context
        self.now = now
        self.calendar = calendar
        self.opener = opener
        self.currentDate = now()
        refresh()
    }

    func refresh() {
        currentDate = now()
        do {
            items = try context.fetch(FetchDescriptor<ReadingItem>(
                predicate: #Predicate { $0.finishedAt == nil },
                sortBy: [SortDescriptor(\.savedAt, order: .reverse)]))
            finished = try context.fetch(FetchDescriptor<ReadingItem>(
                predicate: #Predicate { $0.finishedAt != nil },
                sortBy: [SortDescriptor(\.finishedAt, order: .reverse)]))
        } catch {
            report(error, "Loading reading list")
        }
    }

    var finishedToday: [ReadingItem] {
        finished.filter { $0.finishedAt.map { calendar.isDate($0, inSameDayAs: currentDate) } ?? false }
    }

    var finishedEarlier: [ReadingItem] {
        finished.filter { $0.finishedAt.map { !calendar.isDate($0, inSameDayAs: currentDate) } ?? false }
    }

    func isSnoozed(_ item: ReadingItem) -> Bool {
        guard let until = item.remindAfter else { return false }
        return until > currentDate
    }

    /// Items not currently snoozed, oldest first.
    private var available: [ReadingItem] {
        items.filter { !isSnoozed($0) }.sorted { $0.savedAt < $1.savedAt }
    }

    /// Saves a link. Saving a URL that's already waiting returns the existing item.
    @discardableResult
    func save(url: URL, title: String? = nil) -> ReadingItem {
        refresh()
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let existing = items.first(where: { $0.url == url }) {
            if let cleanTitle, existing.title == Self.fallbackTitle(for: url) { existing.title = cleanTitle }
            save()
            return existing
        }
        let item = ReadingItem(url: url, title: cleanTitle ?? Self.fallbackTitle(for: url), savedAt: now())
        context.insert(item)
        save()
        refresh()
        return item
    }

    func open(_ item: ReadingItem) {
        opener(item.url)
        if item.openedAt == nil { item.openedAt = now() }
        item.remindAfter = nil
        save()
        refresh()
    }

    /// Opens the oldest unfinished, non-snoozed item. Returns false if there is none.
    @discardableResult
    func openNext() -> Bool {
        refresh()
        guard let next = available.first else { return false }
        open(next)
        return true
    }

    func finish(_ item: ReadingItem) {
        item.finishedAt = now()
        save()
        refresh()
    }

    /// Undo "done": back to the unfinished list.
    func unfinish(_ item: ReadingItem) {
        item.finishedAt = nil
        save()
        refresh()
    }

    /// Deletes finished items from before today.
    func clearFinishedEarlier() {
        for item in finishedEarlier { context.delete(item) }
        save()
        refresh()
    }

    func snooze(_ item: ReadingItem, until date: Date) {
        item.remindAfter = date
        save()
        refresh()
    }

    /// Tomorrow at 09:00.
    func snoozeUntilTomorrow(_ item: ReadingItem) {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now())) ?? now()
        snooze(item, until: calendar.date(byAdding: .hour, value: 9, to: tomorrow) ?? tomorrow)
    }

    func delete(_ item: ReadingItem) {
        context.delete(item)
        save()
        refresh()
    }

    /// What the daily nudge would say, or nil if nothing is waiting.
    func pendingSummary() -> ReadingSummary? {
        refresh()
        let waiting = available
        guard let oldest = waiting.first else { return nil }
        return ReadingSummary(count: waiting.count, oldestSavedAt: oldest.savedAt, oldestTitle: oldest.title)
    }

    static func fallbackTitle(for url: URL) -> String {
        let host = url.host(percentEncoded: false)?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
        let path = url.path(percentEncoded: false)
        return path.count > 1 ? host + path : host
    }

    private func save() {
        do {
            try context.save()
            lastError = nil
        } catch {
            report(error, "Saving reading list")
        }
    }

    private func report(_ error: Error, _ action: String) {
        log.error("\(action, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        lastError = "\(action) failed: \(error.localizedDescription)"
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum RelativeDay {
    /// "today", "yesterday", "5 days ago".
    static func text(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        default: return "\(days) days ago"
        }
    }

    /// Compact age for list rows: "today", "1d", "12d".
    static func short(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        return days < 1 ? "today" : "\(days)d"
    }
}
