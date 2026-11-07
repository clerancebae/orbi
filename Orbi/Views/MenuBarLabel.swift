import SwiftUI

/// Pure formatting for the menu bar label, kept out of the view for testing.
enum MenuBarText {
    static let titleLimit = 18

    /// "API docs · 23m", "API docs · +4m" (over the estimate; the orbit turns orange), or
    /// "API docs · 12m" (elapsed, no estimate). The orbit icon carries the state, so no emoji.
    static func activeTask(title: String, remainingSeconds: Int?, elapsedSeconds: Int) -> String {
        let short = title.truncated(to: titleLimit)
        guard let remaining = remainingSeconds else {
            return "\(short) · \(DurationText.minutes(DurationText.floorMinutes(elapsedSeconds)))"
        }
        if remaining >= 0 {
            return "\(short) · \(DurationText.minutes(DurationText.ceilMinutes(remaining)))"
        }
        return "\(short) · +\(DurationText.minutes(DurationText.ceilMinutes(-remaining)))"
    }

    /// "💧5/8", or "🔔💧5/8" while a reminder is waiting for an answer.
    static func water(count: Int, goal: Int, reminderDue: Bool) -> String {
        (reminderDue ? "🔔💧" : "💧") + "\(count)/\(goal)"
    }

    /// "Standup 14:00"
    static func event(title: String, start: Date) -> String {
        "\(title.truncated(to: titleLimit)) \(start.formatted(date: .omitted, time: .shortened))"
    }

    static func compose(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.joined(separator: "   ")
    }
}

/// The always-visible menu bar item: the orbit icon (its colour and fill are the status) and a
/// short text. Re-renders only when observed state changes (task ticks ≤ once/min while
/// active, agents start/stop/ask, water logged, reminder due, next event changes).
struct MenuBarLabel: View {
    let tasks: TaskStore
    let water: WaterStore
    let settings: AppSettings
    let reminders: ReminderScheduler
    let calendar: CalendarService
    let agents: AgentLogStore
    let appearance: MenuBarAppearance

    var body: some View {
        let active = tasks.activeTask
        let state = MenuBarIconState.current(
            agentsRunning: agents.running.count, agentsWaiting: agents.openAsks.count,
            remainingSeconds: active.flatMap { tasks.remainingSeconds($0) },
            estimateSeconds: active?.estimatedMinutes.map { $0 * 60 })
        let waterText: String? = settings.showWater
            ? MenuBarText.water(count: water.todayCount, goal: settings.waterGoal, reminderDue: reminders.isDue)
            : nil
        let mainText: String? = if let active {
            MenuBarText.activeTask(title: active.title, remainingSeconds: tasks.remainingSeconds(active),
                                   elapsedSeconds: tasks.elapsedSeconds(active))
        } else if let event = calendar.nextEvent {
            MenuBarText.event(title: event.title, start: event.start)
        } else {
            nil
        }
        let text = MenuBarText.compose([mainText, waterText])

        HStack(spacing: 5) {
            Image(nsImage: MenuBarIcon.image(for: state, darkMenuBar: appearance.isDark))
            if !text.isEmpty { Text(text) }
        }
        .accessibilityLabel("Orbi")
    }
}
