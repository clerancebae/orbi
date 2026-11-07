import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LoginItemService.self) private var loginItems
    @Environment(CalendarService.self) private var calendar
    @Environment(NotificationService.self) private var notifications
    @Environment(ReminderScheduler.self) private var reminders
    @Environment(AgentConnections.self) private var agents
    @State private var copied: String?

    private static let intervals = [20, 30, 45, 60, 90, 120]

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("AI agents") {
                ForEach(agents.availableAgents) { kind in
                    LabeledContent(kind.displayName) {
                        HStack(spacing: 8) {
                            Text(statusText(kind)).foregroundStyle(.secondary)
                            switch agents.status(kind) {
                            case .connected:
                                Button("Disconnect") { agents.disconnect(kind) }
                            case .outdated:
                                Button("Update") { agents.connect(kind) }
                            case .notConnected:
                                Button("Connect") { agents.connect(kind) }.buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }
                Toggle("Reply from the “finished” bubble", isOn: $settings.agentReplies)
                    .help("Off: a plain “finished” bubble instead of one with a reply field")
                Text("Adds Orbi's hooks to the agent's settings.json (your own hooks stay; a backup is kept): "
                     + "permission and reply bubbles, 🤖 in the menu bar, the Agents list.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = agents.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                LabeledContent("Let Claude see your day (MCP)") {
                    HStack(spacing: 8) {
                        if let command = agents.claudeMCPCommand {
                            Button(copied == "cli" ? "Copied ✓" : "Copy Claude Code command") { copy(command, as: "cli") }
                        }
                        if let json = agents.mcpJSON {
                            Button(copied == "json" ? "Copied ✓" : "Copy JSON") { copy(json, as: "json") }
                                .help("For Claude Desktop, Cursor and other MCP clients")
                        }
                    }
                }
            }

            Section("Panel") {
                Toggle("Water (panel, menu bar and reminders)", isOn: $settings.showWater)
                Toggle("Read later (panel and daily reminder)", isOn: $settings.showReading)
                Text("Turn these off if you only want Orbi for your AI agents.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if settings.showWater {
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
            }

            if settings.showReading {
                Section("Read later") {
                    Toggle("Daily reminder", isOn: $settings.readingNudgeEnabled)
                    DatePicker("At", selection: time(\.readingNudgeMinutes), displayedComponents: .hourAndMinute)
                        .disabled(!settings.readingNudgeEnabled)
                    Text("At most once a day, only if something is waiting.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
        .onAppear { agents.refresh() }
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

    private func statusText(_ kind: AgentKind) -> String {
        switch agents.status(kind) {
        case .connected: "Connected ✓"
        case .outdated: "Needs update"
        case .notConnected: "Not connected"
        }
    }

    private func copy(_ text: String, as key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = key
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
