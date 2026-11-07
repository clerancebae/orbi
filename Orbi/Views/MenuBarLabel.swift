import SwiftUI

/// Pure formatting for the menu bar label, kept out of the view for testing.
enum MenuBarText {
    static let titleLimit = 18

    /// "🎯 API docs · 23m", "⏰ API docs · +4m" (over estimate), or "🎯 API docs · 12m" (elapsed, no estimate).
    static func activeTask(title: String, remainingSeconds: Int?, elapsedSeconds: Int) -> String {
        let short = title.truncated(to: titleLimit)
        guard let remaining = remainingSeconds else {
            return "🎯 \(short) · \(DurationText.minutes(DurationText.floorMinutes(elapsedSeconds)))"
        }
        if remaining >= 0 {
            return "🎯 \(short) · \(DurationText.minutes(DurationText.ceilMinutes(remaining)))"
        }
        return "⏰ \(short) · +\(DurationText.minutes(DurationText.ceilMinutes(-remaining)))"
    }

    /// "💧5/8", or "🔔💧5/8" while a reminder is waiting for an answer.
    static func water(count: Int, goal: Int, reminderDue: Bool) -> String {
        (reminderDue ? "🔔💧" : "💧") + "\(count)/\(goal)"
    }

    /// "🤖", "🤖2" (two sessions working), "🔔🤖" (one is waiting for your answer); nil when idle.
    static func agents(running: Int, waiting: Int) -> String? {
        guard running > 0 || waiting > 0 else { return nil }
        let count = max(running, 1)
        return (waiting > 0 ? "🔔🤖" : "🤖") + (count > 1 ? "\(count)" : "")
    }

    /// "📅 14:00"
    static func event(start: Date) -> String {
        "📅 " + start.formatted(date: .omitted, time: .shortened)
    }

    static func compose(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.joined(separator: "   ")
    }
}

/// The always-visible menu bar label. Re-renders only when observed state changes
/// (task ticks ≤ once/min while active, water logged, reminder due, next event changes).
struct MenuBarLabel: View {
    let tasks: TaskStore
    let water: WaterStore
    let settings: AppSettings
    let reminders: ReminderScheduler
    let calendar: CalendarService
    let agents: AgentLogStore

    var body: some View {
        let waterText: String? = settings.showWater
            ? MenuBarText.water(count: water.todayCount, goal: settings.waterGoal, reminderDue: reminders.isDue)
            : nil
        let agentText = MenuBarText.agents(running: agents.running.count, waiting: agents.openAsks.count)
        if let active = tasks.activeTask {
            Text(MenuBarText.compose([
                agentText,
                MenuBarText.activeTask(title: active.title,
                                       remainingSeconds: tasks.remainingSeconds(active),
                                       elapsedSeconds: tasks.elapsedSeconds(active)),
                waterText,
            ]))
        } else if let event = calendar.nextEvent {
            Text(MenuBarText.compose([agentText, MenuBarText.event(start: event.start), waterText]))
        } else if let agentText {
            Text(MenuBarText.compose([agentText, waterText]))
        } else {
            HStack(spacing: 4) {
                Image(systemName: "checklist")
                if let waterText { Text(waterText) }
            }
            .accessibilityLabel("Orbi")
        }
    }
}
