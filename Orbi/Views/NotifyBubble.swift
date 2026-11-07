import SwiftUI

/// Small info bubble under the menu bar item, e.g. "Claude finished ✓". Closes itself.
@MainActor
final class NotifyBubble {
    static let key = "notify"
    static let visibleSeconds: TimeInterval = 10

    private let presenter: BubblePresenter
    private var autoClose: DispatchWorkItem?

    init(presenter: BubblePresenter) {
        self.presenter = presenter
    }

    func show(title: String, message: String?) {
        presenter.show(key: Self.key, sound: "Glass") { close in
            VStack(alignment: .leading, spacing: 6) {
                BubbleHeader(title: title, close: close)
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // One pending close at a time; a new notice restarts the countdown.
        autoClose?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.presenter.close(Self.key) }
        autoClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleSeconds, execute: work)
    }
}
