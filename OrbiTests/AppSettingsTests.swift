import Foundation
import Testing
@testable import Orbi

@MainActor
struct AppSettingsTests {
    func makeSettings() -> AppSettings {
        let suite = "orbi-settings-test-\(UUID())"
        return AppSettings(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test func hidingSectionsAlsoTurnsTheirRemindersOff() {
        let settings = makeSettings()
        #expect(settings.showWater && settings.showReading && settings.agentReplies)
        #expect(settings.reminderSettings.enabled)
        #expect(settings.readingNudgeConfig.enabled)
        var reminderChanges = 0, nudgeChanges = 0, replyChanges = 0
        settings.onReminderSettingsChange = { reminderChanges += 1 }
        settings.onReadingNudgeChange = { nudgeChanges += 1 }
        settings.onAgentRepliesChange = { replyChanges += 1 }
        settings.showWater = false
        settings.showReading = false
        settings.agentReplies = false
        #expect(!settings.reminderSettings.enabled)
        #expect(!settings.readingNudgeConfig.enabled)
        #expect((reminderChanges, nudgeChanges, replyChanges) == (1, 1, 1))
        settings.showWater = true
        #expect(settings.reminderSettings.enabled)  // the reminder toggle itself was never changed
    }
}
