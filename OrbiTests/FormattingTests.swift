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
        #expect(MenuBarText.activeTask(title: "API docs", remainingSeconds: 23 * 60 - 30, elapsedSeconds: 0) == "🎯 API docs · 23m")
        #expect(MenuBarText.activeTask(title: "API docs", remainingSeconds: 0, elapsedSeconds: 0) == "🎯 API docs · 0m")
    }

    @Test func overtimeShowsPlus() {
        #expect(MenuBarText.activeTask(title: "API docs", remainingSeconds: -1, elapsedSeconds: 0) == "⏰ API docs · +1m")
        #expect(MenuBarText.activeTask(title: "API docs", remainingSeconds: -240, elapsedSeconds: 0) == "⏰ API docs · +4m")
    }

    @Test func elapsedWithoutEstimate() {
        #expect(MenuBarText.activeTask(title: "API docs", remainingSeconds: nil, elapsedSeconds: 125) == "🎯 API docs · 2m")
    }

    @Test func longTitlesTruncate() {
        let text = MenuBarText.activeTask(title: "Refactor the notification pipeline", remainingSeconds: 60, elapsedSeconds: 0)
        #expect(text == "🎯 Refactor the noti… · 1m")
    }

    @Test func hoursFormat() {
        #expect(DurationText.minutes(90) == "1h 30m")
        #expect(DurationText.minutes(120) == "2h")
        #expect(DurationText.minutes(65) == "1h 05m")
    }
}
