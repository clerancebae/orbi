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
        case let .taskAdd(title, minutes, day):
            taskStore.add(title: title, estimatedMinutes: minutes,
                          on: day.resolve(now: .now, calendar: .current))
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
        case let .agentLog(title, subtitle, detail, context):
            agentLog.add(AgentEvent(id: UUID().uuidString, date: .now, kind: .finished, title: title,
                                    subtitle: subtitle, detail: detail, app: context.app))
            agentLog.finishTurn(context)
        case let .agentStart(context):
            agentLog.start(context)
        case let .agentStop(session):
            agentLog.stop(session: session)
        case let .usage(limits):
            agentLog.setLimits(limits)
        case .capture:
            Self.urlLog.info("orbi://capture arrives with the quick-capture panel (Phase 4)")
        }
    }
}
