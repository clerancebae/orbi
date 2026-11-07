import Foundation

/// This calendar week at a glance: agent time, tasks done, things read, water.
/// Shown at the bottom of the panel and in `status.json` (`get_status`).
struct WeekSummary: Codable, Equatable, Sendable {
    /// First day of the week, "YYYY-MM-DD".
    var since: String
    var agentSeconds: Int
    var agentTurns: Int
    var tokens: Int?
    var tasksDone: Int
    var read: Int
    var water: Int

    /// Start of the calendar week containing `now` (the user's first weekday).
    static func start(of now: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
    }

    @MainActor
    static func make(tasks: TaskStore, water: WaterStore, reading: ReadingStore, agents: AgentLogStore,
                     now: Date = .now, calendar: Calendar = .current) -> WeekSummary {
        let start = start(of: now, calendar: calendar)
        let agent = agents.stats(since: start)
        let c = calendar.dateComponents([.year, .month, .day], from: start)
        return WeekSummary(
            since: String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0),
            agentSeconds: agent.seconds,
            agentTurns: agent.turns,
            tokens: agent.tokens,
            tasksDone: tasks.doneCount(since: start),
            read: reading.finished.filter { ($0.finishedAt ?? .distantPast) >= start }.count,
            water: water.count(since: start))
    }

    /// "This week: 9h 10m agents · 23 tasks · 6 read · 31 glasses", or nil when there's nothing yet.
    func text(showWater: Bool = true, showReading: Bool = true) -> String? {
        var parts: [String] = []
        if agentSeconds >= 60 { parts.append("\(DurationText.minutes(DurationText.floorMinutes(agentSeconds))) agents") }
        if tasksDone > 0 { parts.append(tasksDone == 1 ? "1 task" : "\(tasksDone) tasks") }
        if showReading && read > 0 { parts.append("\(read) read") }
        if showWater && water > 0 { parts.append(water == 1 ? "1 glass" : "\(water) glasses") }
        return parts.isEmpty ? nil : "This week: " + parts.joined(separator: " · ")
    }
}
