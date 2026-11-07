import SwiftUI

struct WaterSection: View {
    @Environment(WaterStore.self) private var water
    @Environment(AppSettings.self) private var settings
    @Environment(ReminderScheduler.self) private var reminders
    @Environment(NotificationService.self) private var notifications

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Water", systemImage: "drop").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(water.todayCount)/\(settings.waterGoal)")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(water.todayCount >= settings.waterGoal ? .green : .secondary)
            }

            HStack(spacing: 8) {
                glasses
                Spacer(minLength: 4)
                Button { water.undoLast() } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .disabled(water.todayCount == 0)
                    .help("Undo last glass")
                Button("+1") { water.add() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Log a glass (\(settings.glassSizeMl) ml)")
            }

            Text(reminderText)
                .font(.caption)
                .foregroundStyle(reminders.isDue ? .orange : .secondary)

            if notifications.authorization == .denied {
                Button("Notifications are off — turn them on in System Settings") {
                    notifications.openSystemSettings()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    /// One drop per glass of the goal (capped so the row never overflows).
    private var glasses: some View {
        let goal = min(settings.waterGoal, 12)
        return HStack(spacing: 3) {
            ForEach(0..<goal, id: \.self) { index in
                Image(systemName: index < water.todayCount ? "drop.fill" : "drop")
                    .foregroundStyle(index < water.todayCount ? Color.accentColor : Color.secondary.opacity(0.5))
                    .font(.caption)
            }
        }
    }

    private var reminderText: String {
        if reminders.isDue { return "Time for water — log a glass to reset the reminder." }
        guard settings.remindersEnabled else { return "Reminders are off." }
        guard let due = reminders.nextDue else { return "Check your working hours in Settings." }
        let time = due.formatted(date: .omitted, time: .shortened)
        if reminders.deferredForMeeting { return "In a meeting — reminder moved to \(time)." }
        if Calendar.current.isDateInToday(due) { return "Next reminder at \(time)." }
        if Calendar.current.isDateInTomorrow(due) { return "Next reminder tomorrow at \(time)." }
        return "Next reminder \(due.formatted(.dateTime.weekday(.wide).hour().minute()))."
    }
}
