import SwiftData
import SwiftUI

@main
struct OrbiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var env: AppEnvironment { delegate.env }

    var body: some Scene {
        MenuBarExtra {
            PanelView(storeError: env.storeError)
                .environment(env.loginItems)
                .environment(env.settings)
                .environment(env.taskStore)
                .environment(env.waterStore)
                .environment(env.readingStore)
                .environment(env.reminders)
                .environment(env.notifications)
                .environment(env.calendar)
                .environment(env.agentLog)
                .modelContainer(env.modelContainer)
        } label: {
            MenuBarLabel(tasks: env.taskStore, water: env.waterStore, settings: env.settings,
                         reminders: env.reminders, calendar: env.calendar, agents: env.agentLog)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(env.settings)
                .environment(env.loginItems)
                .environment(env.calendar)
                .environment(env.notifications)
                .environment(env.reminders)
        }
    }
}
