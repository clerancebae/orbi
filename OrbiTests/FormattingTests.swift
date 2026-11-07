import Testing
@testable import Orbi

struct TaskInputParserTests {
    @Test(arguments: [
        ("Write docs 25m", "Write docs", 25 as Int?),
        ("Write docs 25min", "Write docs", 25),
        ("Deep work 2h", "Deep work", 120),
        ("Deep work 1h30m", "Deep work", 90),
        ("Deep work 1h30", "Deep work", 90),
        ("Call 911", "Call 911", nil),
        ("25m", "25m", nil),
        ("Plan sprint", "Plan sprint", nil),
        ("Too long 30h", "Too long 30h", nil),
        ("Zero 0m", "Zero 0m", nil),
        ("  spaced   15m  ", "spaced", 15),
    ])
    func parses(input: String, title: String, minutes: Int?) {
        #expect(TaskInputParser.parse(input) == .init(title: title, estimatedMinutes: minutes))
    }

    @Test func emptyIsNil() {
        #expect(TaskInputParser.parse("   ") == nil)
    }
}

struct MenuBarTextTests {
    @Test func remainingRoundsUp() {
        #expect(MenuBarText.activeTask(title: "API docs", remainingSeconds: 23 * 60 - 30, elapsedSeconds: 0) == "API docs · 23m")
        #expect(MenuBarText.activeTask(title: "API docs", remainingSeconds: 0, elapsedSeconds: 0) == "API docs · 0m")
    }

    @Test func overtimeShowsPlus() {
        #expect(MenuBarText.activeTask(title: "API docs", remainingSeconds: -1, elapsedSeconds: 0) == "API docs · +1m")
        #expect(MenuBarText.activeTask(title: "API docs", remainingSeconds: -240, elapsedSeconds: 0) == "API docs · +4m")
    }

    @Test func elapsedWithoutEstimate() {
        #expect(MenuBarText.activeTask(title: "API docs", remainingSeconds: nil, elapsedSeconds: 125) == "API docs · 2m")
    }

    @Test func longTitlesTruncate() {
        let text = MenuBarText.activeTask(title: "Refactor the notification pipeline", remainingSeconds: 60, elapsedSeconds: 0)
        #expect(text == "Refactor the noti… · 1m")
    }

    @Test func hoursFormat() {
        #expect(DurationText.minutes(90) == "1h 30m")
        #expect(DurationText.minutes(120) == "2h")
        #expect(DurationText.minutes(65) == "1h 05m")
    }
}

struct MenuBarAgentsTests {
    @Test func orbitState() {
        typealias S = MenuBarIconState
        #expect(S.current(agentsRunning: 0, agentsWaiting: 0) == .idle)
        #expect(S.current(agentsRunning: 2, agentsWaiting: 0) == .working)
        // Your turn wins: a question, or a finished turn you haven't seen, even while others work.
        #expect(S.current(agentsRunning: 1, agentsWaiting: 1) == .asking)
        #expect(S.current(agentsRunning: 0, agentsWaiting: 3) == .asking)
        #expect(S.asking.isColored && !S.working.isColored && !S.idle.isColored)
    }

    @Test func daySummary() {
        #expect(AgentsSection.summary(AgentDayStats()) == nil)
        let s = AgentDayStats(seconds: 7800, turns: 14, projects: ["Orbi", "api", "web"], allowed: 12, denied: 1, replies: 3)
        #expect(AgentsSection.summary(s) == "Today: 2h 10m across 3 projects · 14 turns · 12 approved, 1 denied · 3 replies")
        #expect(AgentsSection.summary(AgentDayStats(seconds: 30, turns: 1)) == "Today: 1 turn")
    }
}
