import Foundation

/// `status.json`: the snapshot Claude (MCP), Touch Bar tools and scripts read.
extension AppEnvironment {
    /// Reused: formatters are expensive to create and the snapshot is rebuilt on every change.
    private static let dayFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = .current
        return formatter
    }()

    func makeSnapshot(now: Date = .now) -> StatusSnapshot {
        let active = taskStore.activeTask
        let remaining = active.flatMap { taskStore.remainingSeconds($0) }
        let dayFormatter = Self.dayFormatter

        return StatusSnapshot(
            activeTask: active?.title,
            remainingMin: remaining.map { $0 >= 0 ? DurationText.ceilMinutes($0) : -DurationText.ceilMinutes(-$0) },
            elapsedMin: active.map { DurationText.floorMinutes(taskStore.elapsedSeconds($0)) },
            water: waterStore.todayCount,
            waterGoal: settings.waterGoal,
            waterReminderDue: reminders.isDue,
            nextWaterReminder: reminders.nextDue,
            readingCount: readingStore.items.count,
            nextEvent: calendar.nextEvent.map { "\($0.start.formatted(date: .omitted, time: .shortened)) \($0.title)" },
            tasks: (taskStore.openTasks + taskStore.doneTasks).map {
                .init(title: $0.title, status: $0.status.rawValue, estimateMin: $0.estimatedMinutes,
                      spentMin: DurationText.floorMinutes(taskStore.elapsedSeconds($0)))
            },
            upcoming: taskStore.upcoming.map {
                .init(title: $0.title, date: dayFormatter.string(from: $0.plannedDate), estimateMin: $0.estimatedMinutes)
            },
            reading: readingStore.items.map {
                .init(title: $0.title, url: $0.url.absoluteString, savedAt: $0.savedAt,
                      opened: $0.openedAt != nil, snoozed: readingStore.isSnoozed($0))
            },
            read: readingStore.finished.prefix(30).compactMap { item in
                item.finishedAt.map { .init(title: item.title, url: item.url.absoluteString, finishedAt: $0) }
            },
            agents: agentLog.events.prefix(10).map {
                .init(date: $0.date, kind: $0.kind.rawValue, title: $0.title, subtitle: $0.subtitle,
                      detail: $0.detail.map { String($0.prefix(300)) }, outcome: $0.outcome?.rawValue,
                      reply: $0.reply)
            },
            agentsRunning: agentLog.running.map { .init(agent: $0.agent, project: $0.project, since: $0.startedAt) },
            agentsToday: agentLog.today.turns > 0 ? agentLog.today : nil,
            updatedAt: now
        )
    }
}

/// Lets the exporter's closure reach the environment without a capture cycle during init.
@MainActor
enum StatusSnapshotBuilder {
    static weak var environment: AppEnvironment?
    static var current: StatusSnapshot {
        // The exporter only runs after `environment` is set at the end of init.
        environment?.makeSnapshot() ?? StatusSnapshot(
            activeTask: nil, remainingMin: nil, elapsedMin: nil, water: 0, waterGoal: 0,
            waterReminderDue: false, nextWaterReminder: nil, readingCount: 0, nextEvent: nil,
            tasks: [], upcoming: [], reading: [], read: [], updatedAt: .now)
    }
}
