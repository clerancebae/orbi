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
        if demoBubble, let task = taskStore.add(title: "Write API docs", estimatedMinutes: 5) {
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

    // MARK: - URL scheme

    private static let urlLog = Logger(subsystem: "com.berke.Orbi", category: "URLRouter")

    /// Entry point for `orbi://` URLs (Touch Bar, scripts, Claude). Malformed URLs are
    /// logged and ignored — never a crash.
    func handle(url: URL) {
        switch URLRouter.parse(url) {
        case .success(let action):
            Self.urlLog.info("URL action: \(url.absoluteString, privacy: .public)")
            perform(action)
        case .failure(let error):
            Self.urlLog.error("Ignored URL \(url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    func perform(_ action: OrbiAction) {
        switch action {
        case .waterAdd:
            waterStore.add()
        case .waterUndo:
            waterStore.undoLast()
        case .taskStartNext:
            taskStore.startNext()
        case .taskComplete:
            taskStore.completeActive()
        case let .taskAdd(title, minutes, day):
            taskStore.add(title: title, estimatedMinutes: minutes,
                          on: day.resolve(now: .now, calendar: .current))
        case let .readingSave(url, title):
            readingStore.save(url: url, title: title)
        case .readingOpenNext:
            readingStore.openNext()
        case let .notify(title, message, sticky, app):
            notifyBubble.show(title: title, message: message, sticky: sticky, app: app)
        case .notifyDismiss:
            notifyBubble.dismissSticky()
        case let .ask(ask):
            askBubble.show(ask)
        case let .askCancel(id):
            askBubble.cancel(id: id)
        case let .agentLog(title, subtitle, detail, context):
            agentLog.add(AgentEvent(id: UUID().uuidString, date: .now, kind: .finished, title: title,
                                    subtitle: subtitle, detail: detail, app: context.app))
            agentLog.finishTurn(context)
        case let .agentStart(context):
            agentLog.start(context)
        case let .agentStop(session):
            agentLog.stop(session: session)
        case .capture:
            Self.urlLog.info("orbi://capture arrives with the quick-capture panel (Phase 4)")
        }
    }

    // MARK: - Status snapshot

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

    /// Debug builds only: `-OrbiDemoBubble` runs on a throwaway in-memory store.
    @inline(never)
    private static func isDemoMode() -> Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-OrbiDemoBubble")
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
