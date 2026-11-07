import AppKit
import Observation

/// What the menu bar orbit shows. The orbit alone carries the state; colours are chosen to be
/// colour-blind safe: neutral (luminance only) for normal states, blue and orange (a pair
/// every common colour-vision deficiency can tell apart) for the two "look at me" states.
/// No green or red.
enum MenuBarIconState: Hashable {
    /// Nothing going on: faint orbit.
    case idle
    /// An agent is mid-turn: solid orbit.
    case working
    /// Active task with an estimate: the orbit fills in steps of 5% (0...20).
    case progress(Int)
    /// An agent waits for your answer: blue. Wins over everything else.
    case asking
    /// The active task ran over its estimate: orange.
    case over

    static let steps = 20

    /// Priority: asking > over > progress > working > idle.
    static func current(agentsRunning: Int, agentsWaiting: Int,
                        remainingSeconds: Int?, estimateSeconds: Int?) -> MenuBarIconState {
        if agentsWaiting > 0 { return .asking }
        if let remaining = remainingSeconds, remaining < 0 { return .over }
        if let remaining = remainingSeconds, let estimate = estimateSeconds, estimate > 0 {
            let done = Double(estimate - remaining) / Double(estimate)
            return .progress(min(steps, max(0, Int((done * Double(steps)).rounded(.down)))))
        }
        return agentsRunning > 0 ? .working : .idle
    }

    var isColored: Bool { self == .asking || self == .over }
}

/// Draws the orbit icon (18 × 18 pt, like the app icon: a planet inside a tilted orbit).
/// Neutral states are template images, so macOS tints them for the menu bar; coloured ones
/// draw the planet in the menu bar's text colour themselves. Images are cached per state.
@MainActor
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)
    static let blue = NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)
    static let orange = NSColor(srgbRed: 1, green: 0.58, blue: 0, alpha: 1)

    private struct Key: Hashable { let state: MenuBarIconState; let dark: Bool }
    private static var cache: [Key: NSImage] = [:]

    static func image(for state: MenuBarIconState, darkMenuBar: Bool) -> NSImage {
        // Template images don't depend on the menu bar's appearance.
        let key = Key(state: state, dark: state.isColored ? darkMenuBar : false)
        if let cached = cache[key] { return cached }
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(state, darkMenuBar: darkMenuBar, in: ctx)
            return true
        }
        image.isTemplate = !state.isColored
        image.accessibilityDescription = "Orbi"
        cache[key] = image
        return image
    }

    private static func draw(_ state: MenuBarIconState, darkMenuBar: Bool, in ctx: CGContext) {
        // Template images only use alpha, so "black" here becomes the menu bar's colour.
        let ink: NSColor = state.isColored ? (darkMenuBar ? .white : .black) : .black
        let c = CGPoint(x: 9, y: 9)
        let tilt = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: 0.42).scaledBy(x: 1, y: 0.42)
        func orbit(from a0: CGFloat, to a1: CGFloat) -> CGPath {
            let path = CGMutablePath()
            path.addArc(center: .zero, radius: 8, startAngle: a0, endAngle: a1, clockwise: false, transform: tilt)
            return path
        }
        func stroke(_ color: NSColor, _ width: CGFloat, _ path: CGPath) {
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.addPath(path)
            ctx.strokePath()
        }
        let full = orbit(from: 0, to: 2 * .pi)
        let width: CGFloat = 1.7

        switch state {
        case .idle:
            stroke(ink.withAlphaComponent(0.45), width, full)
        case .working:
            stroke(ink, width, full)
        case .progress(let step):
            stroke(ink.withAlphaComponent(0.3), width, full)
            if step > 0 {
                let end = CGFloat.pi / 2 + 2 * .pi * CGFloat(step) / CGFloat(MenuBarIconState.steps)
                stroke(ink, width + 0.2, orbit(from: .pi / 2, to: end))
            }
        case .asking:
            stroke(blue, width + 0.2, full)
        case .over:
            stroke(orange, width + 0.2, full)
        }
        ctx.setFillColor(ink.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 3.3, y: c.y - 3.3, width: 6.6, height: 6.6))
    }
}

/// Whether the menu bar is dark, read from Orbi's own status item window (it follows the
/// menu bar, not the app), so coloured icons draw the planet in the right colour.
@MainActor
@Observable
final class MenuBarAppearance {
    private(set) var isDark: Bool
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // The status item window exists only once launch finishes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.attach() }
    }

    private func attach() {
        guard let window = (NSApp?.windows ?? []).first(where: { $0.className.contains("NSStatusBarWindow") }) else {
            return
        }
        observation = window.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] window, _ in
            let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            Task { @MainActor in
                if self?.isDark != dark { self?.isDark = dark }
            }
        }
    }
}
