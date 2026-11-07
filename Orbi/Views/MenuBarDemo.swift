#if DEBUG
import Foundation
import Observation

/// Debug builds only: `Orbi.app --args -OrbiMenuBarDemo` cycles the menu bar icon through every
/// state every 4 s (with the state's name next to it), to check how each one looks in the real
/// menu bar. Runs on the throwaway in-memory store, like the other demo modes.
@MainActor
@Observable
final class MenuBarDemo {
    static let shared = MenuBarDemo()
    static let flag = "-OrbiMenuBarDemo"
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains(flag) }

    private(set) var state: MenuBarIconState?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var index = 0

    private static let sequence: [MenuBarIconState] = [
        .idle, .working, .progress(5), .progress(10), .progress(15), .progress(19), .asking, .over,
    ]

    func start() {
        state = Self.sequence[0]
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.index = (self.index + 1) % Self.sequence.count
                self.state = Self.sequence[self.index]
            }
        }
    }
}

extension MenuBarIconState {
    var demoName: String {
        switch self {
        case .idle: "idle"
        case .working: "agent working"
        case .progress(let step): "task \(step * 100 / MenuBarIconState.steps)%"
        case .asking: "agent asks you (blue)"
        case .over: "over time (orange)"
        }
    }
}
#endif
