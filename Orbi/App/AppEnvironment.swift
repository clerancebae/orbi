import AppKit
import Foundation
import OSLog
import SwiftData

/// Builds the shared ModelContainer and long-lived services once, at launch.
@MainActor
final class AppEnvironment {
    static let schema = Schema([TaskItem.self, WaterLog.self, ReadingItem.self])

    let modelContainer: ModelContainer
    let loginItems: LoginItemService
    let settings: AppSettings
    let taskStore: TaskStore
    let waterStore: WaterStore
    let notifications: NotificationService
    let calendar: CalendarService
    let reminders: ReminderScheduler
    let bubbles: BubblePresenter
    let endingSoonBubble: EndingSoonBubbleController
    let waterBubble: WaterReminderBubble
    let readingStore: ReadingStore
    let readingNudgeBubble: ReadingNudgeBubble
    let readingNudge: ReadingNudgeScheduler
    let notifyBubble: NotifyBubble
    let askBubble: AskBubble
    let agentLog: AgentLogStore
    let agentConnections: AgentConnections
    let menuBarAppearance = MenuBarAppearance()
    /// nil in demo mode, so a throwaway in-memory session never overwrites the real status.json.
    let statusExporter: StatusExporter?
    private var systemObservers: [NSObjectProtocol] = []
    /// Non-nil when the on-disk store couldn't be opened and we fell back to memory.
    let storeError: String?

    private static let log = Logger(subsystem: "com.berke.Orbi", category: "AppEnvironment")

    init() {
        loginItems = LoginItemService()
        settings = AppSettings(defaults: SharedContainer.defaults)
        notifications = NotificationService()
        calendar = CalendarService()

        let demoBubble = Self.isDemoMode()

        do {
            if demoBubble { throw DemoMode() }
            try SharedContainer.ensureDirectories()
            let config = ModelConfiguration(schema: Self.schema, url: SharedContainer.storeURL)
            modelContainer = try ModelContainer(for: Self.schema, configurations: config)
            storeError = nil
            Self.log.info("Store opened at \(SharedContainer.storeURL.path, privacy: .public)")
        } catch is DemoMode {
            storeError = nil
            modelContainer = Self.makeInMemoryContainer()
        } catch {
            Self.log.error("Opening store failed, using in-memory store: \(error.localizedDescription, privacy: .public)")
            storeError = error.localizedDescription
            modelContainer = Self.makeInMemoryContainer()
        }

        taskStore = TaskStore(context: modelContainer.mainContext)
        bubbles = BubblePresenter()
        endingSoonBubble = EndingSoonBubbleController(store: taskStore, presenter: bubbles)

        let settings = self.settings
        waterStore = WaterStore(context: modelContainer.mainContext, glassSize: { settings.glassSizeMl })
        waterBubble = WaterReminderBubble(presenter: bubbles, water: waterStore, settings: settings)
        reminders = ReminderScheduler(
            settings: { settings.reminderSettings },
            lastWater: waterStore.lastLogDate,
            meetings: calendar,
            notifier: waterBubble
        )
        waterBubble.reminders = reminders

        readingStore = ReadingStore(context: modelContainer.mainContext)
        readingNudgeBubble = ReadingNudgeBubble(presenter: bubbles, store: readingStore)
        notifyBubble = NotifyBubble(presenter: bubbles)
        agentLog = AgentLogStore(fileURL: demoBubble ? nil : SharedContainer.agentLogURL)
        askBubble = AskBubble(presenter: bubbles, log: agentLog)
        agentConnections = AgentConnections(replies: { settings.agentReplies })
        // Only the installed copy repairs hook paths, so a debug build never redirects them.
        if !demoBubble, Bundle.main.bundlePath.hasPrefix("/Applications/") {
            agentConnections.repairIfOutdated()
        }
        let readingStore = self.readingStore, readingNudgeBubble = self.readingNudgeBubble
        readingNudge = ReadingNudgeScheduler(
            config: { settings.readingNudgeConfig },
            summary: { readingStore.pendingSummary() },
            post: { readingNudgeBubble.show($0) },
            lastCheckedDay: { settings.lastReadingNudgeDay },
            setLastCheckedDay: { settings.lastReadingNudgeDay = $0 }
        )

        statusExporter = demoBubble ? nil : StatusExporter(fileURL: SharedContainer.statusFileURL) {
            StatusSnapshotBuilder.current
        }

        StatusSnapshotBuilder.environment = self
        wire()

        #if DEBUG
        // Debug-only: `open Orbi.app --args -OrbiDemoBubble` shows the bubble with a
        // throwaway in-memory task, for checking its look without waiting for a real timer.
        if ScreenshotMode.isOn {
            ScreenshotMode.run(self)
        } else if demoBubble, let task = taskStore.add(title: "Write API docs", estimatedMinutes: 5) {
            taskStore.start(task)
            // Wait until launch finishes so the menu bar item exists to anchor to.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [endingSoonBubble] in
                endingSoonBubble.show(for: task)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [reminders] in
                reminders.fireNowForTesting()
            }
        }
        #endif
    }

    /// Connects stores and services. Every surface goes through the stores, so e.g. logging
    /// water from a notification action resets the reminder exactly like the panel's +1.
    private func wire() {
        let bubble = endingSoonBubble
        taskStore.onEndingSoon = { [weak bubble] task in bubble?.show(for: task) }
        taskStore.onTimeUp = { [weak bubble] task in bubble?.show(for: task) }

        let reminders = self.reminders
        let water = waterStore
        let settings = self.settings
        water.onLogged = { [weak reminders] in reminders?.waterLogged() }
        settings.onReminderSettingsChange = { [weak reminders] in reminders?.settingsChanged() }

        notifications.configure()
        notifications.onDrank = { [weak water] in water?.add() }
        notifications.onSnooze = { [weak reminders] in reminders?.snooze(minutes: 15) }
        notifications.waterSummary = { [weak water, weak settings] in
            guard let water, let settings else { return "Time for a glass of water." }
            return "\(water.todayCount) of \(settings.waterGoal) glasses today. Stand up and stretch for a minute."
        }

        reminders.start()
        settings.onReadingNudgeChange = { [weak readingNudge] in readingNudge?.rearm() }
        settings.onAgentRepliesChange = { [weak agentConnections] in agentConnections?.reconnectConnected() }
        readingNudge.rearm()
        statusExporter?.start()

        let handler: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.systemDidChange() }
        }
        systemObservers.append(NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main, using: handler))
        systemObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: handler))

        let notifications = self.notifications
        let calendar = self.calendar
        Task {
            await notifications.requestAuthorization()
            await calendar.requestAccess()
            reminders.settingsChanged()  // calendar access may change deferral behaviour
        }
    }

    private func systemDidChange() {
        waterStore.refresh()
        readingStore.refresh()
        calendar.refresh()
        reminders.systemWoke()
        readingNudge.rearm()
    }

    /// Debug builds only: `-OrbiDemoBubble` / `-OrbiScreenshots` run on a throwaway in-memory store.
    @inline(never)
    private static func isDemoMode() -> Bool {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-OrbiDemoBubble") || args.contains("-OrbiScreenshots")
        #else
        false
        #endif
    }

    static func makeInMemoryContainer() -> ModelContainer {
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            // An in-memory container with a valid schema cannot fail short of a programming error.
            fatalError("Could not create in-memory ModelContainer: \(error)")
        }
    }
}

/// Marker used to route debug demo mode to an in-memory store.
private struct DemoMode: Error {}
