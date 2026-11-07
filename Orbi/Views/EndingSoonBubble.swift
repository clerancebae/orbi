import SwiftUI

/// Task bubble: "5m left — +5m / +15m / Finish", and again at time-up with a break hint.
@MainActor
final class EndingSoonBubbleController {
    static let key = "task"
    private let store: TaskStore
    private let presenter: BubblePresenter

    init(store: TaskStore, presenter: BubblePresenter) {
        self.store = store
        self.presenter = presenter
    }

    func show(for task: TaskItem) {
        let store = self.store
        let id = task.id
        presenter.show(key: Self.key) { close in
            EndingSoonView(taskID: id, store: store, close: close)
        }
    }

    func close() { presenter.close(Self.key) }
}

private struct EndingSoonView: View {
    let taskID: UUID
    let store: TaskStore
    let close: () -> Void

    var body: some View {
        content
            // Close automatically if the task is completed/paused/switched from anywhere else.
            .onChange(of: store.activeTask?.id) { _, newID in
                if newID != taskID { close() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let task = store.activeTask, task.id == taskID {
            VStack(alignment: .leading, spacing: 10) {
                BubbleHeader(title: headline(for: task), close: close)

                Text(task.title)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)

                Text(isTimeUp(task) ? "Finish, or need more time? Then take a water + 2 min break." : "Need more time?")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("+5m") { extend(task, 5) }
                    Button("+15m") { extend(task, 15) }
                    Spacer()
                    Button("Finish") {
                        store.complete(task)
                        close()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        } else {
            Color.clear.frame(height: 1).onAppear(perform: close)
        }
    }

    private func isTimeUp(_ task: TaskItem) -> Bool {
        (store.remainingSeconds(task) ?? 1) <= 0
    }

    private func headline(for task: TaskItem) -> String {
        guard let remaining = store.remainingSeconds(task) else { return "⏳ Time check" }
        if remaining <= 0 { return "⏰ Time's up" }
        return "⏳ \(DurationText.minutes(DurationText.ceilMinutes(remaining))) left"
    }

    private func extend(_ task: TaskItem, _ minutes: Int) {
        store.extend(task, byMinutes: minutes)
        close()
    }
}
