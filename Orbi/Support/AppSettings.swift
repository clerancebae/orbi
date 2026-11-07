import Foundation
import Observation

/// Reminder-relevant settings as a value, so the scheduler's logic stays pure and testable.
struct ReminderSettings: Equatable, Sendable {
    var enabled: Bool
    var intervalMinutes: Int
    /// Minutes from midnight.
    var workStartMinutes: Int
    var workEndMinutes: Int
    var includeWeekends: Bool

    static let `default` = ReminderSettings(enabled: true, intervalMinutes: 45,
                                            workStartMinutes: 9 * 60, workEndMinutes: 18 * 60,
                                            includeWeekends: true)

    var isValid: Bool { intervalMinutes > 0 && workEndMinutes > workStartMinutes }
}

/// User settings, stored in the App Group's UserDefaults suite.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let waterGoal = "waterGoal"
        static let glassSizeMl = "glassSizeMl"
        static let remindersEnabled = "remindersEnabled"
        static let reminderIntervalMinutes = "reminderIntervalMinutes"
        static let workStartMinutes = "workStartMinutes"
        static let workEndMinutes = "workEndMinutes"
        static let includeWeekends = "includeWeekends"
        static let readingNudgeEnabled = "readingNudgeEnabled"
        static let readingNudgeMinutes = "readingNudgeMinutes"
        static let lastReadingNudgeDay = "lastReadingNudgeDay"
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// Called after any reminder-related setting changes.
    @ObservationIgnored var onReminderSettingsChange: (() -> Void)?
    /// Called after a reading-nudge setting changes.
    @ObservationIgnored var onReadingNudgeChange: (() -> Void)?

    var waterGoal: Int { didSet { defaults.set(waterGoal, forKey: Key.waterGoal) } }
    var glassSizeMl: Int { didSet { defaults.set(glassSizeMl, forKey: Key.glassSizeMl) } }
    var remindersEnabled: Bool { didSet { persist(remindersEnabled, Key.remindersEnabled) } }
    var reminderIntervalMinutes: Int { didSet { persist(reminderIntervalMinutes, Key.reminderIntervalMinutes) } }
    var workStartMinutes: Int { didSet { persist(workStartMinutes, Key.workStartMinutes) } }
    var workEndMinutes: Int { didSet { persist(workEndMinutes, Key.workEndMinutes) } }
    var includeWeekends: Bool { didSet { persist(includeWeekends, Key.includeWeekends) } }
    var readingNudgeEnabled: Bool {
        didSet { defaults.set(readingNudgeEnabled, forKey: Key.readingNudgeEnabled); onReadingNudgeChange?() }
    }
    var readingNudgeMinutes: Int {
        didSet { defaults.set(readingNudgeMinutes, forKey: Key.readingNudgeMinutes); onReadingNudgeChange?() }
    }

    /// Day ("YYYY-MM-DD") the reading nudge last ran. Not observed; only the scheduler uses it.
    var lastReadingNudgeDay: String? {
        get { defaults.string(forKey: Key.lastReadingNudgeDay) }
        set { defaults.set(newValue, forKey: Key.lastReadingNudgeDay) }
    }

    init(defaults: UserDefaults) {
        let d = ReminderSettings.default
        defaults.register(defaults: [
            Key.waterGoal: 8,
            Key.glassSizeMl: 250,
            Key.remindersEnabled: d.enabled,
            Key.reminderIntervalMinutes: d.intervalMinutes,
            Key.workStartMinutes: d.workStartMinutes,
            Key.workEndMinutes: d.workEndMinutes,
            Key.includeWeekends: d.includeWeekends,
            Key.readingNudgeEnabled: true,
            Key.readingNudgeMinutes: 21 * 60,
        ])
        self.defaults = defaults
        waterGoal = defaults.integer(forKey: Key.waterGoal)
        glassSizeMl = defaults.integer(forKey: Key.glassSizeMl)
        remindersEnabled = defaults.bool(forKey: Key.remindersEnabled)
        reminderIntervalMinutes = defaults.integer(forKey: Key.reminderIntervalMinutes)
        workStartMinutes = defaults.integer(forKey: Key.workStartMinutes)
        workEndMinutes = defaults.integer(forKey: Key.workEndMinutes)
        includeWeekends = defaults.bool(forKey: Key.includeWeekends)
        readingNudgeEnabled = defaults.bool(forKey: Key.readingNudgeEnabled)
        readingNudgeMinutes = defaults.integer(forKey: Key.readingNudgeMinutes)
    }

    var readingNudgeConfig: ReadingNudgeScheduler.Config {
        .init(enabled: readingNudgeEnabled, minutes: readingNudgeMinutes)
    }

    var reminderSettings: ReminderSettings {
        ReminderSettings(enabled: remindersEnabled, intervalMinutes: reminderIntervalMinutes,
                         workStartMinutes: workStartMinutes, workEndMinutes: workEndMinutes,
                         includeWeekends: includeWeekends)
    }

    private func persist(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        onReminderSettingsChange?()
    }
}
