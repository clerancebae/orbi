import AppKit
import Foundation
import Observation
import OSLog
import SwiftData

/// Today's tasks and the single active task. All task mutations go through here.
@MainActor
@Observable
final class TaskStore {
    /// Today's tasks (after rollover), unsorted; use `openTasks` / `doneTasks`.
    private(set) var tasks: [TaskItem] = []
    /// Tasks planned for later days (e.g. added for tomorrow via URL / Claude), soonest first.
    private(set) var upcoming: [TaskItem] = []
    /// Last time the store looked at the clock. Views compute times from this so they
    /// re-render exactly when the store ticks (once per minute while a task is active).
    private(set) var currentDate: Date
    private(set) var lastError: String?

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let live: Bool
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var loadedDay: Date?
    @ObservationIgnored private let log = Logger(subsystem: "com.berke.Orbi", category: "TaskStore")

    /// The "ending soon" prompt fires when the active task's remaining time drops to this.
    static let endingSoonThreshold = 5 * 60
    /// Called once when the active task crosses `endingSoonThreshold` (set by AppEnvironment).
    @ObservationIgnored var onEndingSoon: ((TaskItem) -> Void)?
    /// Called once when the active task's estimate runs out (suggest a break).
    @ObservationIgnored var onTimeUp: ((TaskItem) -> Void)?
    /// Remaining seconds at the previous check; a prompt fires only on a downward crossing.
    @ObservationIgnored private var lastRemaining: Int?

    /// - Parameter live: false in tests — no minute ticker, no system notifications.
    init(context: ModelContext, now: @escaping () -> Date = Date.init, calendar: Calendar = .current, live: Bool = true) {
        self.context = context
        self.now = now
        self.calendar = calendar
        self.live = live
        self.currentDate = now()
        if live { observeSystemEvents() }
        refresh()
    }

    // MARK: - Derived state

    var today: Date { calendar.startOfDay(for: currentDate) }

    var activeTask: TaskItem? { tasks.first { $0.status == .active } }

    var openTasks: [TaskItem] {
        tasks.filter { $0.status != .done }.sorted { $0.sortIndex < $1.sortIndex }
    }

    var doneTasks: [TaskItem] {
        tasks.filter { $0.status == .done }
            .sorted { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
    }

    func elapsedSeconds(_ task: TaskItem) -> Int {
        var total = task.spentSeconds
        if task.status == .active, let startedAt = task.startedAt {
            total += max(0, Int(currentDate.timeIntervalSince(startedAt)))
        }
        return total
    }

    /// Estimate minus elapsed (negative when over). nil when there's no estimate.
    func remainingSeconds(_ task: TaskItem) -> Int? {
        task.estimatedMinutes.map { $0 * 60 - elapsedSeconds(task) }
    }

    // MARK: - Loading

    /// Rolls unfinished tasks from earlier days into today, then reloads today's tasks.
    func refresh() {
        currentDate = now()
        let today = self.today
        do {
            try rollOver(into: today)
            let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.plannedDate == today })
            tasks = try context.fetch(descriptor)
            upcoming = try context.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.plannedDate > today },
                sortBy: [SortDescriptor(\.plannedDate), SortDescriptor(\.sortIndex)]))
            loadedDay = today
            enforceSingleActive()
        } catch {
            report(error, "Loading tasks")
        }
        checkEndingSoon()
        updateTicker()
    }

    private func rollOver(into today: Date) throws {
        let descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.plannedDate < today },
            sortBy: [SortDescriptor(\.plannedDate), SortDescriptor(\.sortIndex)]
        )
        // Status is filtered in memory: enum comparisons in #Predicate are unreliable in SwiftData.
        let stale = try context.fetch(descriptor).filter { $0.status != .done }
        guard !stale.isEmpty else { return }

        let todays = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.plannedDate == today }))
        var next = (todays.map(\.sortIndex).max() ?? -1) + 1
        for task in stale {
            task.plannedDate = today
            task.sortIndex = next
            next += 1
        }
        try context.save()
        log.info("Rolled \(stale.count) unfinished task(s) into today")
    }

    /// Repairs data that violates the single-active rule (e.g. edited by another process).
    private func enforceSingleActive() {
        let actives = tasks.filter { $0.status == .active }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
        guard actives.count > 1 else { return }
        for task in actives.dropFirst() { bankAndStop(task, as: .todo) }
        save()
    }

    // MARK: - Actions

    /// Adds a task for today, or for `day` (any date in that day) if given.
    @discardableResult
    func add(title: String, estimatedMinutes: Int? = nil, on day: Date? = nil) -> TaskItem? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        refreshIfDayChanged()
        tick()
        let estimate = estimatedMinutes.flatMap { $0 > 0 ? $0 : nil }
        let planned = max(calendar.startOfDay(for: day ?? currentDate), today)

        if planned == today {
            let task = TaskItem(title: trimmed, estimatedMinutes: estimate, plannedDate: today,
                                sortIndex: nextSortIndex(), createdAt: currentDate)
            context.insert(task)
            tasks.append(task)
            save()
            return task
        }

        let sameDay = upcoming.filter { $0.plannedDate == planned }
        let task = TaskItem(title: trimmed, estimatedMinutes: estimate, plannedDate: planned,
                            sortIndex: (sameDay.map(\.sortIndex).max() ?? -1) + 1, createdAt: currentDate)
        context.insert(task)
        save()
        refresh()
        return task
    }

    /// Adds from quick-add text, e.g. "Write docs 25m".
    @discardableResult
    func add(input: String) -> TaskItem? {
        guard let parsed = TaskInputParser.parse(input) else { return nil }
        return add(title: parsed.title, estimatedMinutes: parsed.estimatedMinutes)
    }

    /// Makes `task` the active one; any other active task is paused back to `.todo`.
    func start(_ task: TaskItem) {
        guard task.status == .todo else { return }
        tick()
        if let current = activeTask { bankAndStop(current, as: .todo) }
        task.status = .active
        task.startedAt = currentDate
        resetEndingSoonBaseline()
        save()
        updateTicker()
    }

    func pause(_ task: TaskItem) {
        guard task.status == .active else { return }
        tick()
        bankAndStop(task, as: .todo)
        save()
        updateTicker()
    }

    func toggle(_ task: TaskItem) {
        task.status == .active ? pause(task) : start(task)
    }

    func complete(_ task: TaskItem) {
        guard task.status != .done else { return }
        tick()
        bankAndStop(task, as: .done)
        task.completedAt = currentDate
        save()
        updateTicker()
    }

    func reopen(_ task: TaskItem) {
        guard task.status == .done else { return }
        tick()
        task.status = .todo
        task.completedAt = nil
        task.sortIndex = nextSortIndex()
        save()
    }

    /// Starts the first `.todo` task of today. Returns false if there is none.
    @discardableResult
    func startNext() -> Bool {
        refreshIfDayChanged()
        guard let next = openTasks.first(where: { $0.status == .todo }) else { return false }
        start(next)
        return true
    }

    /// Completes the active task. Returns false if nothing is active.
    @discardableResult
    func completeActive() -> Bool {
        refreshIfDayChanged()
        guard let active = activeTask else { return false }
        complete(active)
        return true
    }

    func delete(_ task: TaskItem) {
        tasks.removeAll { $0.id == task.id }
        context.delete(task)
        save()
        updateTicker()
    }

    func setEstimate(_ task: TaskItem, minutes: Int?) {
        task.estimatedMinutes = minutes.flatMap { $0 > 0 ? $0 : nil }
        tick()
        resetEndingSoonBaseline()
        save()
        updateTicker()
    }

    /// Adds time to a task's estimate. Without an estimate, extends from the time spent so far.
    func extend(_ task: TaskItem, byMinutes minutes: Int) {
        guard minutes > 0 else { return }
        tick()
        let base = task.estimatedMinutes ?? DurationText.ceilMinutes(elapsedSeconds(task))
        setEstimate(task, minutes: base + minutes)
    }

    func rename(_ task: TaskItem, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        task.title = trimmed
        save()
    }

    /// Reorders open tasks (indices are into `openTasks`).
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ordered = openTasks
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, task) in ordered.enumerated() { task.sortIndex = index }
        save()
    }

    // MARK: - Helpers

    /// Fires `onEndingSoon` when the active task's remaining time crosses the threshold
    /// downward. Starting a task, or changing its estimate, only sets the baseline, so a
    /// task started with ≤ 5m left never prompts immediately.
    private func checkEndingSoon() {
        guard let active = activeTask, let remaining = remainingSeconds(active) else {
            lastRemaining = nil
            return
        }
        defer { lastRemaining = remaining }
        guard let last = lastRemaining else { return }
        if last > 0, remaining <= 0 {
            onTimeUp?(active)          // takes precedence if both were crossed (e.g. after sleep)
        } else if last > Self.endingSoonThreshold, remaining <= Self.endingSoonThreshold {
            onEndingSoon?(active)
        }
    }

    private func resetEndingSoonBaseline() {
        lastRemaining = activeTask.flatMap(remainingSeconds)
    }

    private func bankAndStop(_ task: TaskItem, as status: TaskStatus) {
        if task.status == .active, let startedAt = task.startedAt {
            task.spentSeconds += max(0, Int(currentDate.timeIntervalSince(startedAt)))
        }
        task.startedAt = nil
        task.status = status
    }

    private func nextSortIndex() -> Int {
        (tasks.map(\.sortIndex).max() ?? -1) + 1
    }

    private func tick() {
        currentDate = now()
    }

    private func refreshIfDayChanged() {
        if calendar.startOfDay(for: now()) != loadedDay { refresh() }
    }

    private func save() {
        do {
            try context.save()
            lastError = nil
        } catch {
            report(error, "Saving tasks")
        }
    }

    private func report(_ error: Error, _ action: String) {
        log.error("\(action, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        lastError = "\(action) failed: \(error.localizedDescription)"
    }

    // MARK: - Minute ticker (only while a task is active)

    private func updateTicker() {
        ticker?.invalidate()
        ticker = nil
        guard live, let active = activeTask else { return }

        // Fire on the next whole-minute boundary of the task's elapsed time, then every 60s,
        // so the displayed minute flips exactly when it should.
        let elapsed = elapsedSeconds(active)
        let firstFire = now().addingTimeInterval(TimeInterval(60 - elapsed % 60))
        let timer = Timer(fire: firstFire, interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.minuteTick() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func minuteTick() {
        if calendar.startOfDay(for: now()) != loadedDay {
            refresh()
        } else {
            tick()
            checkEndingSoon()
        }
    }

    // MARK: - Sleep

    /// The Mac is going to sleep or the screen got locked: bank the active task's time so far.
    /// The task stays active, but time away (lunch, a task left running overnight) isn't work.
    func systemWillSleep() {
        guard let active = activeTask, let startedAt = active.startedAt else { return }
        tick()
        active.spentSeconds += max(0, Int(currentDate.timeIntervalSince(startedAt)))
        active.startedAt = nil
        save()
    }

    /// Back from sleep / unlocked: the active task's clock resumes from now.
    func systemDidWake() {
        tick()
        if let active = activeTask, active.startedAt == nil {
            active.startedAt = currentDate
            resetEndingSoonBaseline()
            save()
        }
        refresh()
    }

    private func observeSystemEvents() {
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main, using: refresh))
        let workspace = NSWorkspace.shared.notificationCenter
        // Delivered on the main queue and handled synchronously, before the Mac sleeps.
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        })
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil,
                                                 queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil,
                                                 queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        })
    }
}
