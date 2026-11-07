import Foundation

/// A single pending wake-up. Scheduling again replaces the previous one, so there is
/// never more than one timer per owner (spec §6: no polling).
@MainActor
final class OneShotTimer {
    private var timer: Timer?
    private let tolerance: TimeInterval

    init(tolerance: TimeInterval = 10) {
        self.tolerance = tolerance
    }

    /// Fires `action` at `date` (immediately if it's in the past). `nil` just cancels.
    func schedule(at date: Date?, action: @escaping @MainActor @Sendable () -> Void) {
        cancel()
        guard let date else { return }
        let timer = Timer(fire: date, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
