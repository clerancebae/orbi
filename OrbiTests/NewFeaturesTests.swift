import Foundation
import SwiftData
import Testing
@testable import Orbi

/// Queued messages, plan limit warnings, task ↔ project links, focus mode, the weekly
/// summary, and the Codex / OpenCode connections.
@MainActor
struct NewFeaturesTests {
    let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Istanbul")!  // valid fixed identifier
        cal.firstWeekday = 2
        return cal
    }()

    /// 2026-11-04 is a Wednesday.
    func date(day: Int = 4, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "orbi-tests-\(UUID())", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Queued messages

    @Test func queueWritesFileAndSentClearsIt() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentLogStore(fileURL: nil, queueDirectory: dir)
        store.queue("  run the tests too ", session: "claude-s1")
        #expect(store.queued["claude-s1"] == "run the tests too")
        let file = dir.appending(path: "claude-s1.txt")
        #expect(try String(contentsOf: file, encoding: .utf8) == "run the tests too")

        // A relaunch picks it up again.
        #expect(AgentLogStore(fileURL: nil, queueDirectory: dir).queued["claude-s1"] == "run the tests too")

        store.unqueue(session: "claude-s1")
        #expect(store.queued.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // Bad session ids never become file names.
        store.queue("x", session: "../evil")
        #expect(store.queued.isEmpty)
    }

    @Test func queuedSentRestartsTheSession() {
        let store = AgentLogStore(fileURL: nil)
        let context = AgentContext(session: "claude-s1", agent: "Claude", project: "api", seconds: 120)
        store.queue("next", session: "claude-s1")
        store.finishTurn(context)
        store.queuedSent(context)
        #expect(store.queued.isEmpty)
        #expect(store.running.map(\.session) == ["claude-s1"])
        #expect(store.waitingForYou == 0)
        #expect(store.today.replies == 1)
        #expect(AgentLogStore.canQueue(session: "claude-s1"))
        #expect(!AgentLogStore.canQueue(session: "gemini-s1"))
    }

    @Test func routerReadsQueuedReplyAndProject() {
        let log = URLRouter.parse(URL(string: "orbi://agent/log?title=Done&reply=run%20tests&session=claude-s1")!)
        guard case .success(.agentLog(_, _, _, let context, let reply)) = log else {
            Issue.record("unexpected \(log)")
            return
        }
        #expect(reply == "run tests")
        #expect(context.session == "claude-s1")

        #expect(URLRouter.parse(URL(string: "orbi://task/add?title=Fix%20login&project=api")!)
                == .success(.taskAdd(title: "Fix login", minutes: nil, day: .today, project: "api")))
        #expect(URLRouter.parse(URL(string: "orbi://task/add?title=Fix%20login%20%23api%2025m")!)
                == .success(.taskAdd(title: "Fix login", minutes: 25, day: .today, project: "api")))
    }

    // MARK: - Plan limit warnings

    @Test func limitWarningsOnlyOnUpwardCrossings() {
        let reset = Date(timeIntervalSince1970: 1_793_000_000)
        func limits(_ five: Int?, week: Int? = nil, fiveReset: Date? = reset) -> UsageLimits {
            UsageLimits(fiveHour: five, fiveHourReset: fiveReset, week: week, weekReset: nil, updated: .now)
        }
        #expect(AgentLogStore.limitWarnings(old: limits(70), new: limits(79)).isEmpty)
        #expect(AgentLogStore.limitWarnings(old: limits(70), new: limits(81))
                == [LimitWarning(window: "5-hour", percent: 80, reset: reset)])
        #expect(AgentLogStore.limitWarnings(old: limits(81), new: limits(85)).isEmpty)  // already warned
        // Jumping past both levels: one warning, the higher one.
        #expect(AgentLogStore.limitWarnings(old: limits(50), new: limits(96)).map(\.percent) == [95])
        // A new window (different reset) starts from 0 %.
        #expect(AgentLogStore.limitWarnings(old: limits(85), new: limits(85, fiveReset: reset.addingTimeInterval(18_000)))
                .map(\.percent) == [80])
        // First report ever, weekly window.
        #expect(AgentLogStore.limitWarnings(old: nil, new: limits(nil, week: 90)).map(\.window) == ["weekly"])
    }

    // MARK: - Tasks ↔ projects

    @Test func parserExtractsProject() {
        #expect(TaskInputParser.parse("Fix login #api 25m") == .init(title: "Fix login", estimatedMinutes: 25, project: "api"))
        #expect(TaskInputParser.parse("#web Polish header") == .init(title: "Polish header", estimatedMinutes: nil, project: "web"))
        #expect(TaskInputParser.parse("C# review")?.project == nil)
        #expect(TaskInputParser.parse("Call #1 again")?.title == "Call #1 again")
    }

    @Test func agentStartStartsLinkedTaskOnlyWhenIdle() {
        let container = AppEnvironment.makeInMemoryContainer()
        let clock = TestClock(date(10))
        let store = TaskStore(context: container.mainContext, now: { clock.now }, calendar: calendar, live: false)
        var changes: [Bool] = []
        store.onActiveChange = { changes.append($0) }
        let plain = store.add(title: "Email")
        let linked = store.add(input: "Fix login #API")
        #expect(linked?.project == "API")

        #expect(store.startLinked(project: "web") == nil)
        #expect(store.startLinked(project: "api")?.id == linked?.id)  // case-insensitive
        #expect(changes == [true])

        // Something already runs: leave it alone.
        store.pause(linked!)
        store.start(plain!)
        #expect(store.startLinked(project: "api") == nil)
        #expect(store.activeTask?.id == plain?.id)

        store.complete(plain!)
        #expect(changes.last == false)
        clock.advance(minutes: 1)
        #expect(store.doneCount(since: date(9)) == 1)
        #expect(store.doneCount(since: date(11)) == 0)
    }

    @Test func projectSecondsAndWeekTotals() {
        let clock = TestClock(date(10))
        let store = AgentLogStore(fileURL: nil, now: { clock.now }, calendar: calendar)
        store.finishTurn(AgentContext(session: "a", project: "api", seconds: 600))
        clock.now = date(day: 5, 10)
        store.finishTurn(AgentContext(session: "a", project: "api", seconds: 300))
        store.finishTurn(AgentContext(session: "b", project: "web", seconds: 60))
        #expect(store.today.projectSeconds == ["api": 300, "web": 60])
        let week = store.stats(since: date(day: 2, 0))
        #expect(week.seconds == 960)
        #expect(week.turns == 3)
        #expect(week.projectSeconds == ["api": 900, "web": 60])
        #expect(store.stats(since: date(day: 5, 0)).turns == 2)
        #expect(store.knownProjects == ["api", "web"])
    }

    @Test func weekSummaryText() {
        let week = WeekSummary(since: "2026-11-02", agentSeconds: 33_000, agentTurns: 60, tokens: nil,
                               tasksDone: 23, read: 6, water: 31)
        #expect(week.text() == "This week: 9h 10m agents · 23 tasks · 6 read · 31 glasses")
        #expect(week.text(showWater: false, showReading: false) == "This week: 9h 10m agents · 23 tasks")
        #expect(WeekSummary(since: "", agentSeconds: 0, agentTurns: 0, tokens: nil, tasksDone: 0, read: 0, water: 0)
            .text() == nil)
        #expect(WeekSummary.start(of: date(15), calendar: calendar) == date(day: 2, 0))  // Monday
    }

    // MARK: - Focus mode

    @Test func waterReminderWaitsForFocusToEnd() {
        let clock = TestClock(date(10))
        let notifier = FakeNotifier()
        var quiet = true
        var armed: Date?
        let settings = ReminderSettings(enabled: true, intervalMinutes: 45, workStartMinutes: 9 * 60,
                                        workEndMinutes: 18 * 60, includeWeekends: true)
        let scheduler = ReminderScheduler(settings: { settings }, now: { clock.now }, calendar: calendar,
                                          lastWater: nil, meetings: nil, notifier: notifier,
                                          quiet: { quiet }, armTimer: { armed = $0 })
        scheduler.start()
        clock.now = armed!
        scheduler.timerFired()
        #expect(notifier.posted == 0)
        #expect(scheduler.owedAfterQuiet)

        quiet = false
        clock.advance(minutes: 5)
        scheduler.quietEnded()
        #expect(armed == clock.now)  // fires right away
        scheduler.timerFired()
        #expect(notifier.posted == 1)
        scheduler.quietEnded()  // nothing owed any more
        #expect(notifier.posted == 1)
    }

    @Test func readingNudgeWaitsForFocusToEnd() {
        let clock = TestClock(date(21))
        var lastDay: String?
        var posted = 0
        var quiet = true
        let scheduler = ReadingNudgeScheduler(
            config: { .init(enabled: true, minutes: 21 * 60) }, now: { clock.now }, calendar: calendar,
            summary: { ReadingSummary(count: 2, oldestSavedAt: clock.now, oldestTitle: "X") },
            post: { _ in posted += 1 },
            lastCheckedDay: { lastDay }, setLastCheckedDay: { lastDay = $0 },
            quiet: { quiet }, armTimer: { _ in })
        scheduler.rearm()
        scheduler.fire()
        #expect(posted == 0)
        #expect(lastDay == nil)
        quiet = false
        scheduler.quietEnded()
        scheduler.fire()
        #expect(posted == 1)
    }

    // MARK: - Codex / OpenCode

    @Test func codexFeatureFlag() {
        #expect(CodexConfig.enablingHooks("") == "[features]\ncodex_hooks = true\n")
        #expect(CodexConfig.enablingHooks("model = \"o4\"") == "model = \"o4\"\n\n[features]\ncodex_hooks = true\n")
        #expect(CodexConfig.enablingHooks("[features]\nfoo = 1\n") == "[features]\ncodex_hooks = true\nfoo = 1\n")
        #expect(CodexConfig.enablingHooks("[features]\ncodex_hooks = false\n") == "[features]\ncodex_hooks = true\n")
        let on = "model = 1\n[features]\ncodex_hooks = true\n"
        #expect(CodexConfig.hooksEnabled(on))
        #expect(CodexConfig.enablingHooks(on) == on)
        #expect(CodexConfig.hooksEnabled("features.codex_hooks = true\n"))
        #expect(!CodexConfig.hooksEnabled("[other]\ncodex_hooks = true\n"))
    }

    @Test func codexHooksAndOpenCodePlugin() {
        let script = "/Applications/Orbi.app/Contents/Resources/agent_hook.py"
        let settings = AgentHookConfig.connect([:], kind: .codex, script: script)
        let hooks = settings["hooks"] as? [String: Any]
        #expect(Set(hooks?.keys.map { $0 } ?? []) == ["UserPromptSubmit", "Stop"])
        #expect(AgentHookConfig.status(of: settings, kind: .codex, script: script) == .connected)
        #expect(settings["statusLine"] == nil)

        let plugin = OpenCodePlugin.source(script: script)
        #expect(plugin.contains("const SCRIPT = \"\(script)\";"))
        #expect(plugin.contains("session.idle"))
        #expect(OpenCodePlugin.status(of: plugin, script: script) == .connected)
        #expect(OpenCodePlugin.status(of: plugin, script: "/other/agent_hook.py") == .outdated)
        #expect(OpenCodePlugin.status(of: "export const Mine = 1", script: script) == .notConnected)
        #expect(OpenCodePlugin.status(of: nil, script: script) == .notConnected)
    }

    @Test func connectionsWriteCodexAndOpenCodeFiles() throws {
        let home = tempDir(), scripts = tempDir()
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: scripts) }
        try Data("#".utf8).write(to: scripts.appending(path: "agent_hook.py"))
        try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: ".config/opencode"), withIntermediateDirectories: true)
        try Data("model = \"x\"\n".utf8).write(to: home.appending(path: ".codex/config.toml"))

        let connections = AgentConnections(home: home, scriptsDirectory: scripts)
        #expect(connections.availableAgents == [.claude, .codex, .opencode])
        connections.connect(.codex)
        connections.connect(.opencode)
        #expect(connections.status(.codex) == .connected)
        #expect(connections.status(.opencode) == .connected)
        let toml = try String(contentsOf: home.appending(path: ".codex/config.toml"), encoding: .utf8)
        #expect(toml.contains("[features]\ncodex_hooks = true"))
        #expect(FileManager.default.fileExists(atPath: home.appending(path: ".codex/config.toml.orbi-backup").path))

        connections.disconnect(.opencode)
        connections.disconnect(.codex)
        #expect(connections.status(.opencode) == .notConnected)
        #expect(connections.status(.codex) == .notConnected)
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".config/opencode/plugins/orbi.js").path))
    }
}
