#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `Orbi.app --args -OrbiScreenshots` runs on a throwaway in-memory store
/// seeded with sample data, shows the agent bubbles and opens the panel in a plain window, so
/// README screenshots never show anyone's real tasks or agent history.
@MainActor
enum ScreenshotMode {
    static let flag = "-OrbiScreenshots"
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains(flag) }

    private static var panelWindow: NSWindow?

    static func run(_ env: AppEnvironment) {
        seed(env)
        // After launch, so the menu bar item exists for the bubbles to anchor to.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showBubbles(env)
            showPanel(env)
        }
    }

    private static func seed(_ env: AppEnvironment) {
        let now = Date.now
        let tasks = env.taskStore
        if let review = tasks.add(title: "Review PR #42", estimatedMinutes: 20) {
            tasks.start(review)
            review.startedAt = now.addingTimeInterval(-18 * 60)
            tasks.complete(review)
        }
        if let docs = tasks.add(title: "Write API docs", estimatedMinutes: 45) {
            tasks.start(docs)
            docs.startedAt = now.addingTimeInterval(-22 * 60)
        }
        tasks.add(title: "Fix flaky login test", estimatedMinutes: 30)
        tasks.add(title: "Plan sprint")
        tasks.refresh()

        for _ in 0..<3 { env.waterStore.add() }
        env.readingStore.save(url: URL(string: "https://www.swift.org/documentation/concurrency/")!,
                              title: "Swift concurrency, a practical guide")
        env.readingStore.save(url: URL(string: "https://modelcontextprotocol.io/docs")!,
                              title: "Designing good MCP servers")

        let log = env.agentLog
        let terminal = "com.apple.Terminal"
        // Earlier today.
        for (project, minutes) in [("web", 34), ("api", 51), ("orbi", 23), ("api", 18)] {
            log.finishTurn(AgentContext(project: project, seconds: minutes * 60))
        }
        log.add(AgentEvent(id: "s1", date: now.addingTimeInterval(-95 * 60), kind: .finished,
                           title: "Claude finished ✓", subtitle: "web · 34 min",
                           detail: "Migrated the settings page to the new design system. Screenshots are in the PR.",
                           app: terminal))
        log.add(AgentEvent(id: "s2", date: now.addingTimeInterval(-48 * 60), kind: .permission,
                           title: "Claude wants to use Bash", subtitle: "api", detail: "npm test -- --runInBand",
                           app: terminal))
        log.setOutcome(id: "s2", .allowed)
        log.add(AgentEvent(id: "s3", date: now.addingTimeInterval(-41 * 60), kind: .permission,
                           title: "Claude wants to use Bash", subtitle: "api", detail: "rm -rf build/ node_modules/",
                           app: terminal))
        log.setOutcome(id: "s3", .denied)
        log.add(AgentEvent(id: "s4", date: now.addingTimeInterval(-12 * 60), kind: .finished,
                           title: "Claude finished ✓", subtitle: "orbi · 23 min",
                           detail: "Added the Agents list and a daily summary. All 83 tests pass.\n\nWant me to update the README?",
                           app: terminal))
        log.setOutcome(id: "s4", .replied, reply: "Yes, and add screenshots")
        // Working right now.
        log.start(AgentContext(session: "demo-1", agent: "Claude", project: "orbi", app: terminal),
                  at: now.addingTimeInterval(-4 * 60))
        log.start(AgentContext(session: "demo-2", agent: "Claude", project: "web", app: terminal),
                  at: now.addingTimeInterval(-11 * 60))
    }

    private static func showBubbles(_ env: AppEnvironment) {
        let terminal = "com.apple.Terminal"
        env.askBubble.show(AgentAsk(
            id: "demo-permission", kind: .permission, title: "Claude wants to use Bash", message: "orbi",
            detail: "git push origin main",
            context: AgentContext(session: "demo-1", agent: "Claude", project: "orbi", app: terminal)))
        env.askBubble.show(AgentAsk(
            id: "demo-reply", kind: .reply, title: "Claude finished ✓", message: "api · 7 min",
            detail: "Fixed the **flaky login test** (a race in the session mock) and added a regression test. "
                + "All 214 tests pass.\n\nShould I open a PR?",
            context: AgentContext(session: "demo-3", agent: "Claude", project: "api", app: terminal)))
    }

    /// The real panel content in a plain window, styled like the menu bar dropdown.
    private static func showPanel(_ env: AppEnvironment) {
        let content = PanelView(storeError: nil)
            .environment(env.loginItems)
            .environment(env.settings)
            .environment(env.taskStore)
            .environment(env.waterStore)
            .environment(env.readingStore)
            .environment(env.reminders)
            .environment(env.notifications)
            .environment(env.calendar)
            .environment(env.agentLog)
            .modelContainer(env.modelContainer)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(20)  // room for the shadow
        let host = NSHostingView(rootView: content)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .init(x: 80, y: 80), size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.title = "Orbi Screenshot Panel"
        window.contentView = host
        window.orderFrontRegardless()
        panelWindow = window
    }
}
#endif
