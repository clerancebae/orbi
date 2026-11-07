import Foundation
import OSLog

/// `orbi://` actions: every surface (Touch Bar, scripts, the MCP server, agent hooks) ends up here.
extension AppEnvironment {
    private static let urlLog = Logger(subsystem: "com.berke.Orbi", category: "URLRouter")

    /// Entry point for `orbi://` URLs (Touch Bar, scripts, Claude). Malformed URLs are
    /// logged and ignored — never a crash.
    func handle(url: URL) {
        switch URLRouter.parse(url) {
        case .success(let action):
            Self.urlLog.info("URL action: \(url.absoluteString, privacy: .public)")
            perform(action)
        case .failure(let error):
            Self.urlLog.error("Ignored URL \(url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// "Claude 5-hour limit: 80% used" · "Resets 14:30".
    private func showLimitWarnings(_ warnings: [LimitWarning]) {
        guard !warnings.isEmpty else { return }
        let title = "Claude " + warnings.map { "\($0.window) limit: \($0.percent)% used" }.joined(separator: " · ")
        let resets = warnings.compactMap { warning in
            warning.reset.map { reset in
                let style: Date.FormatStyle = Calendar.current.isDateInToday(reset)
                    ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute()
                // One window: "Resets Sun 02:00"; two: "Resets: 5-hour at 14:30 · weekly at Mon 09:00".
                return warnings.count == 1 ? reset.formatted(style) : "\(warning.window) at \(reset.formatted(style))"
            }
        }
        let message = resets.isEmpty ? nil : (warnings.count == 1 ? "Resets " : "Resets: ") + resets.joined(separator: " · ")
        notifyBubble.show(title: title, message: message)
    }

    func perform(_ action: OrbiAction) {
        switch action {
        case .waterAdd:
            waterStore.add()
        case .waterUndo:
            waterStore.undoLast()
        case .taskStartNext:
            taskStore.startNext()
        case .taskComplete:
            taskStore.completeActive()
        case let .taskAdd(title, minutes, day, project):
            taskStore.add(title: title, estimatedMinutes: minutes,
                          on: day.resolve(now: .now, calendar: .current), project: project)
        case let .readingSave(url, title):
            readingStore.save(url: url, title: title)
        case .readingOpenNext:
            readingStore.openNext()
        case let .notify(title, message, sticky, app):
            notifyBubble.show(title: title, message: message, sticky: sticky, app: app)
        case .notifyDismiss:
            notifyBubble.dismissSticky()
        case let .ask(ask):
            askBubble.show(ask)
        case let .askCancel(id):
            askBubble.cancel(id: id)
        case let .agentLog(title, subtitle, detail, context, reply):
            agentLog.add(AgentEvent(id: UUID().uuidString, date: .now, kind: .finished, title: title,
                                    subtitle: subtitle, detail: detail, outcome: reply == nil ? nil : .replied,
                                    reply: reply, app: context.app))
            agentLog.finishTurn(context)
            // A queued message went out: the agent is already on its next turn.
            if reply != nil { agentLog.queuedSent(context) }
        case let .agentStart(context):
            agentLog.start(context)
            if let project = context.project { taskStore.startLinked(project: project) }
        case let .agentStop(session):
            agentLog.stop(session: session)
        case let .usage(limits):
            let warnings = settings.limitWarnings ? AgentLogStore.limitWarnings(old: agentLog.limits, new: limits) : []
            agentLog.setLimits(limits)
            showLimitWarnings(warnings)
        case .capture:
            Self.urlLog.info("orbi://capture arrives with the quick-capture panel (Phase 4)")
        }
    }
}
