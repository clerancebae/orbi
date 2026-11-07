import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LoginItemService.self) private var loginItems
    @Environment(CalendarService.self) private var calendar
    @Environment(NotificationService.self) private var notifications
    @Environment(ReminderScheduler.self) private var reminders

    private static let intervals = [20, 30, 45, 60, 90, 120]

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Water") {
                Stepper("Daily goal: \(settings.waterGoal) glasses", value: $settings.waterGoal, in: 1...20)
                Stepper("Glass size: \(settings.glassSizeMl) ml", value: $settings.glassSizeMl, in: 100...1000, step: 50)
            }

            Section("Water & break reminders") {
                Toggle("Remind me", isOn: $settings.remindersEnabled)
                Picker("Every", selection: $settings.reminderIntervalMinutes) {
                    ForEach(Self.intervals, id: \.self) { Text("\($0) minutes").tag($0) }
                }
                DatePicker("Workday starts", selection: time(\.workStartMinutes), displayedComponents: .hourAndMinute)
                DatePicker("Workday ends", selection: time(\.workEndMinutes), displayedComponents: .hourAndMinute)
                Toggle("Also on weekends", isOn: $settings.includeWeekends)
                if settings.workEndMinutes <= settings.workStartMinutes {
                    Label("The workday must end after it starts.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Text("Reminders only come during working hours and wait until a calendar event is over.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Read later") {
                Toggle("Daily reminder", isOn: $settings.readingNudgeEnabled)
                DatePicker("At", selection: time(\.readingNudgeMinutes), displayedComponents: .hourAndMinute)
                    .disabled(!settings.readingNudgeEnabled)
                Text("At most once a day, only if something is waiting.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Permissions") {
                LabeledContent("Calendar", value: calendarStatus)
                LabeledContent("Notifications", value: notificationStatus)
                if notifications.authorization == .denied {
                    Button("Open Notification Settings…") { notifications.openSystemSettings() }
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginItems.isEnabled },
                    set: { loginItems.setEnabled($0) }
                ))
            }

            #if DEBUG
            Section("Debug") {
                Button("Send test reminder now") { reminders.fireNowForTesting() }
                Text("If a calendar event is happening now, this defers instead — same as the real reminder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #endif
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .task { await notifications.refreshAuthorization() }
    }

    /// Bridges "minutes from midnight" settings to a DatePicker.
    private func time(_ keyPath: ReferenceWritableKeyPath<AppSettings, Int>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(byAdding: .minute, value: settings[keyPath: keyPath],
                                      to: Calendar.current.startOfDay(for: .now)) ?? .now
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                settings[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private var calendarStatus: String {
        switch calendar.access {
        case .granted: "Allowed"
        case .denied: "Not allowed (System Settings → Privacy → Calendars)"
        case .notDetermined: "Not asked yet"
        }
    }

    private var notificationStatus: String {
        switch notifications.authorization {
        case .allowed: "Allowed"
        case .denied: "Off"
        case .unknown: "Not asked yet"
        }
    }
}
