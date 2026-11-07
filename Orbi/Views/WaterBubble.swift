import SwiftUI

/// Water & break reminder shown as a bubble under the menu bar item (instead of a system
/// notification, which macOS always puts in the top-right corner).
@MainActor
final class WaterReminderBubble: WaterReminderPosting {
    static let key = "water"
    private let presenter: BubblePresenter
    private let water: WaterStore
    private let settings: AppSettings
    /// Set after the scheduler exists (it owns the reminder state the bubble reflects).
    weak var reminders: ReminderScheduler?

    init(presenter: BubblePresenter, water: WaterStore, settings: AppSettings) {
        self.presenter = presenter
        self.water = water
        self.settings = settings
    }

    func postWaterReminder() {
        guard let reminders else { return }
        let water = self.water, settings = self.settings
        presenter.show(key: Self.key, sound: "Glass") { close in
            WaterReminderView(water: water, settings: settings, reminders: reminders, close: close)
        }
    }

    func clearWaterReminder() {
        presenter.close(Self.key)
    }
}

private struct WaterReminderView: View {
    let water: WaterStore
    let settings: AppSettings
    let reminders: ReminderScheduler
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BubbleHeader(title: "💧 Water break", close: close)

            Text("\(water.todayCount) of \(settings.waterGoal) glasses today. Stand up and stretch for a minute.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Snooze 15m") { reminders.snooze(minutes: 15) }
                Spacer()
                Button("Drank ✓") { water.add() }
                    .buttonStyle(.borderedProminent)
            }
        }
        // Water logged or snoozed from anywhere (panel, Touch Bar, URL) closes it.
        .onChange(of: reminders.isDue) { _, isDue in
            if !isDue { close() }
        }
    }
}
