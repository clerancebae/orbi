import SwiftUI

/// Small info bubble under the menu bar item, e.g. "Claude finished ✓". Closes itself after
/// 10 s, unless sticky ("Claude needs you"): that one stays until closed, replaced or dismissed.
@MainActor
final class NotifyBubble {
    static let key = "notify"
    static let visibleSeconds: TimeInterval = 10

    private let presenter: BubblePresenter
    private var autoClose: DispatchWorkItem?
    private var showingSticky = false

    init(presenter: BubblePresenter) {
        self.presenter = presenter
    }

    func show(title: String, message: String?, sticky: Bool = false, app: String? = nil) {
        presenter.show(key: Self.key, sound: sticky ? "Ping" : "Glass") { close in
            VStack(alignment: .leading, spacing: 6) {
                BubbleHeader(title: title, app: app, close: close)
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
        autoClose = nil
        showingSticky = sticky
        if sticky { return }
        let work = DispatchWorkItem { [weak self] in self?.presenter.close(Self.key) }
        autoClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleSeconds, execute: work)
    }

    /// Closes the bubble only if it's a sticky one, so a fresh "finished" notice isn't cut short.
    func dismissSticky() {
        guard showingSticky else { return }
        showingSticky = false
        presenter.close(Self.key)
    }
}
