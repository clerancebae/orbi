import SwiftUI

/// Dropdown panel root.
struct PanelView: View {
    let storeError: String?
    @Environment(LoginItemService.self) private var loginItems
    @Environment(TaskStore.self) private var tasks
    @Environment(WaterStore.self) private var water
    @Environment(ReadingStore.self) private var reading
    @Environment(NotificationService.self) private var notifications
    @Environment(CalendarService.self) private var calendar
    @Environment(AgentLogStore.self) private var agentLog
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentsSection()
            Divider()
            TodaySection()
            Divider()
            WaterSection()
            Divider()
            ReadingSection()

            if let storeError {
                Label("Data not saved: \(storeError)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            tasks.refresh()
            water.refresh()
            reading.refresh()
            calendar.refresh()
            loginItems.refresh()
            agentLog.pruneStale()
        }
        .task { await notifications.refreshAuthorization() }
    }

    @ViewBuilder
    private var footer: some View {
        if let event = calendar.nextEvent {
            Label {
                Text("\(event.start.formatted(date: .omitted, time: .shortened))  \(event.title)")
                    .lineLimit(1)
            } icon: {
                Image(systemName: "calendar")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        HStack {
            Button {
                openSettings()
                NSApp.activate()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .controlSize(.small)
            .keyboardShortcut(",")

            Spacer()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .controlSize(.small)
        }

        if loginItems.needsApproval {
            Button("Approve login item in System Settings…") { loginItems.openSystemSettings() }
                .buttonStyle(.link)
                .font(.caption)
        }
    }
}
