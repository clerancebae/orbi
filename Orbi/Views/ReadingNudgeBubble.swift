import SwiftUI

/// Daily read-later nudge as a bubble: "3 items waiting — oldest saved 5 days ago".
@MainActor
final class ReadingNudgeBubble {
    static let key = "reading"
    private let presenter: BubblePresenter
    private let store: ReadingStore

    init(presenter: BubblePresenter, store: ReadingStore) {
        self.presenter = presenter
        self.store = store
    }

    func show(_ summary: ReadingSummary) {
        let store = self.store
        presenter.show(key: Self.key, sound: "Tink") { close in
            VStack(alignment: .leading, spacing: 10) {
                BubbleHeader(title: "📚 \(summary.count) \(summary.count == 1 ? "item" : "items") waiting", close: close)
                Text("Oldest saved \(RelativeDay.text(for: summary.oldestSavedAt, now: .now)): \(summary.oldestTitle)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Later", action: close)
                    Spacer()
                    Button("Open next") {
                        store.openNext()
                        close()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}
