import AppKit
import Observation

/// What the menu bar orbit shows: only your AI agents. Your own task timer stays in the text
/// next to it ("API docs · 23m" / "+4m"), so one shape never means two things.
/// Colour-blind safe: idle and working differ by shape (faint vs dashed), and the one colour
/// is blue.
enum MenuBarIconState: Hashable {
    /// No agent busy: faint orbit.
    case idle
    /// An agent is mid-turn: dashed orbit ("in motion", not "100% done").
    case working
    /// Your turn: an agent asks you something, or finished and you haven't looked yet. Blue.
    case asking

    static func current(agentsRunning: Int, agentsWaiting: Int) -> MenuBarIconState {
        if agentsWaiting > 0 { return .asking }
        return agentsRunning > 0 ? .working : .idle
    }

    var isColored: Bool { self == .asking }
}

/// Draws the orbit icon (18 × 18 pt, like the app icon: a planet inside a tilted orbit).
/// Neutral states are template images, so macOS tints them for the menu bar; coloured ones
/// draw the planet in the menu bar's text colour themselves. Images are cached per state.
@MainActor
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)
    static let blue = NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)

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
            ctx.setLineDash(phase: 0, lengths: [2.6, 2.0])
            stroke(ink, width, full)
            ctx.setLineDash(phase: 0, lengths: [])
        case .asking:
            stroke(blue, width + 0.2, full)
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
