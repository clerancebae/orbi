import AppKit
import SwiftUI

/// Shows small floating bubbles anchored under Orbi's menu bar item. Each bubble has a
/// key ("task", "water"); showing a key again replaces that bubble. Several bubbles stack
/// downward; only the top one carries the arrow pointing at the item.
@MainActor
final class BubblePresenter {
    static let width: CGFloat = 300
    private static let edgeMargin: CGFloat = 8
    private static let gapBelowMenuBar: CGFloat = 2
    private static let gapBetween: CGFloat = 8

    private struct Entry {
        let key: String
        let panel: NSPanel
        let host: NSHostingView<AnyView>
        let makeView: (_ arrowX: CGFloat?) -> AnyView
    }

    private var entries: [Entry] = []

    func isShowing(_ key: String) -> Bool { entries.contains { $0.key == key } }

    /// - Parameter content: the bubble body; receives a `close` action.
    /// - Parameter interactive: the bubble can take keyboard focus (text fields) once clicked.
    ///   It never grabs focus by itself, so typing elsewhere is never hijacked.
    func show<Content: View>(key: String, sound: String? = "Tink", interactive: Bool = false,
                             @ViewBuilder content: @escaping (_ close: @escaping () -> Void) -> Content) {
        close(key, animated: false)

        let closeAction: () -> Void = { [weak self] in self?.close(key) }
        let makeView: (CGFloat?) -> AnyView = { arrowX in
            AnyView(BubbleChrome(arrowX: arrowX) { content(closeAction) })
        }
        let host = NSHostingView(rootView: makeView(nil))
        let panel = Self.makePanel(interactive: interactive)
        panel.contentView = host
        entries.append(Entry(key: key, panel: panel, host: host, makeView: makeView))

        layout(appearing: key)
        if let sound { NSSound(named: sound)?.play() }
    }

    /// App that was in front before `focus`, and the bubble it was for: closing that bubble
    /// hands the keyboard back to it.
    private var returnTo: (key: String, bundleID: String)?

    /// Gives the bubble the keyboard, e.g. to type a reply after a global shortcut. A key
    /// non-activating panel of an inactive app still doesn't get keystrokes (they go to the
    /// app in front; found in testing), so Orbi activates for the moment and gives the
    /// keyboard back when the bubble closes.
    func focus(_ key: String) {
        guard let panel = entries.first(where: { $0.key == key })?.panel else { return }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier, let id = front.bundleIdentifier {
            returnTo = (key, id)
        }
        NSApp.activate()  // allowed: the hotkey press is the user's latest input, sent to Orbi
        panel.makeKeyAndOrderFront(nil)
    }

    func close(_ key: String, animated: Bool = true) {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return }
        let panel = entries.remove(at: index).panel
        panel.orderOut(nil)
        layout(appearing: nil)
        if let back = returnTo, back.key == key {
            returnTo = nil
            AgentApps.activate(back.bundleID)
        }
    }

    // MARK: - Layout

    private func layout(appearing newKey: String?) {
        guard !entries.isEmpty else { return }
        let anchor = Self.statusItemFrame()
        let screen = anchor.flatMap { frame in NSScreen.screens.first { $0.frame.intersects(frame) } }
            ?? NSScreen.screens.first
        guard let screen else { return }

        let itemMidX = anchor?.midX ?? (screen.visibleFrame.maxX - 40)
        let x = min(max(itemMidX - Self.width / 2, screen.frame.minX + Self.edgeMargin),
                    screen.frame.maxX - Self.width - Self.edgeMargin)
        // Always where the menu bar normally ends. With an auto-hiding menu bar (or an app in
        // full screen) the status item's window sits above the screen, which pushed bubbles
        // partly off the top; now they stay put and the bar slides down just above them.
        let barBottom = screen.frame.maxY - Self.menuBarHeight(on: screen)
        var top = min(anchor?.minY ?? barBottom, barBottom) - Self.gapBelowMenuBar

        for (index, entry) in entries.enumerated() {
            let arrowX: CGFloat? = index == 0 ? itemMidX - x : nil
            entry.host.rootView = entry.makeView(arrowX)
            let height = entry.host.fittingSize.height
            entry.host.frame.size = CGSize(width: Self.width, height: height)
            let frame = NSRect(x: x, y: top - height, width: Self.width, height: height)

            if entry.key == newKey {
                // Drop in from slightly higher, fading in.
                entry.panel.setFrame(frame.offsetBy(dx: 0, dy: 6), display: false)
                entry.panel.alphaValue = 0
                entry.panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    entry.panel.animator().alphaValue = 1
                    entry.panel.animator().setFrame(frame, display: true)
                }
            } else {
                entry.panel.setFrame(frame, display: true, animate: false)
            }
            top = frame.minY - Self.gapBetween
        }
    }

    private static func makePanel(interactive: Bool) -> NSPanel {
        let panelClass: NSPanel.Type = interactive ? KeyablePanel.self : NSPanel.self
        let panel = panelClass.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    /// Height of the menu bar on `screen`, also while it's hidden: the bar's thickness, the
    /// notch area (taller bar on notched Macs), or the space it takes when shown.
    private static func menuBarHeight(on screen: NSScreen) -> CGFloat {
        max(NSStatusBar.system.thickness, screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    /// Screen frame of our MenuBarExtra item. SwiftUI doesn't expose the NSStatusItem, but
    /// its button lives in an `NSStatusBarWindow` owned by this app, whose frame is the item's.
    private static func statusItemFrame() -> NSRect? {
        // `NSApp` is nil until the app finishes launching, so go through Optional.
        (NSApp?.windows ?? [])
            .first { $0.className.contains("NSStatusBarWindow") && $0.isVisible }
            .map(\.frame)
    }
}

/// Borderless panels can't become key by default; this one can (on click), for text input.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Material background + border, with the arrow when this bubble is the top one.
private struct BubbleChrome<Content: View>: View {
    let arrowX: CGFloat?
    @ViewBuilder let content: Content

    var body: some View {
        let shape = BubbleShape(arrowX: arrowX)
        content
            .padding(14)
            .padding(.top, arrowX == nil ? 0 : BubbleShape.arrowHeight)
            .frame(width: BubblePresenter.width, alignment: .leading)
            .background(.regularMaterial, in: shape)
            .overlay(shape.stroke(.separator, lineWidth: 0.5))
    }
}

/// Header row shared by bubbles: title, optional "go to app" (↗), and ✕.
struct BubbleHeader: View {
    let title: String
    /// Bundle id of the agent's terminal / IDE; shows a ↗ button that brings it forward.
    var app: String? = nil
    let close: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer()
            if let app {
                GoToAppButton(bundleID: app)
            }
            Button(action: close) {
                Image(systemName: "xmark").font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Dismiss")
        }
    }
}

/// ↗ button that brings an agent's terminal / IDE to the front.
struct GoToAppButton: View {
    let bundleID: String

    var body: some View {
        Button { AgentApps.activate(bundleID) } label: {
            Image(systemName: "arrow.up.forward.app").font(.caption.weight(.semibold))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Go to \(AgentApps.name(bundleID) ?? "the agent")")
    }
}

/// Rounded rectangle with an optional small upward arrow pointing at the menu bar item.
private struct BubbleShape: Shape {
    static let arrowHeight: CGFloat = 8
    static let arrowWidth: CGFloat = 18
    static let cornerRadius: CGFloat = 12

    var arrowX: CGFloat?

    func path(in rect: CGRect) -> Path {
        let r = Self.cornerRadius
        guard let arrowX else {
            return Path(roundedRect: rect, cornerRadius: r, style: .continuous)
        }
        let top = rect.minY + Self.arrowHeight
        // Keep the arrow clear of the rounded corners.
        let tipX = min(max(arrowX, rect.minX + r + Self.arrowWidth / 2),
                       rect.maxX - r - Self.arrowWidth / 2)

        var p = Path()
        p.move(to: CGPoint(x: rect.minX + r, y: top))
        p.addLine(to: CGPoint(x: tipX - Self.arrowWidth / 2, y: top))
        p.addQuadCurve(to: CGPoint(x: tipX, y: rect.minY), control: CGPoint(x: tipX - 3, y: rect.minY + 1))
        p.addQuadCurve(to: CGPoint(x: tipX + Self.arrowWidth / 2, y: top), control: CGPoint(x: tipX + 3, y: rect.minY + 1))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: top))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: top), tangent2End: CGPoint(x: rect.maxX, y: top + r), radius: r)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r), radius: r)
        p.addLine(to: CGPoint(x: rect.minX, y: top + r))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: top), tangent2End: CGPoint(x: rect.minX + r, y: top), radius: r)
        p.closeSubpath()
        return p
    }
}
