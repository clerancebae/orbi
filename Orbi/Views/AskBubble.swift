import OSLog
import SwiftUI

/// Interactive bubble for AI agents (`orbi://ask`): approve a permission, or read the agent's
/// last message and reply, without switching to the terminal. The answer goes to
/// `answers/<id>.json`, where the waiting hook (`mcp/agent_hook.py`) picks it up.
/// Each question has its own bubble, so two sessions asking at once stack.
@MainActor
final class AskBubble {
    enum Action: String { case allow, always, deny, terminal, reply, dismiss }

    private let presenter: BubblePresenter
    private let agentLog: AgentLogStore
    private let hotkeysEnabled: () -> Bool
    private let log = Logger(subsystem: "com.berke.Orbi", category: "AskBubble")

    /// Open questions, oldest first; the global shortcuts act on the newest of each kind.
    private struct OpenAsk {
        let id: String
        let kind: AgentAsk.Kind
        let respond: (Action, String?) -> Void
        let focus: AskFocus
    }
    private var open: [OpenAsk] = []

    init(presenter: BubblePresenter, log agentLog: AgentLogStore, hotkeysEnabled: @escaping () -> Bool = { true }) {
        self.presenter = presenter
        self.agentLog = agentLog
        self.hotkeysEnabled = hotkeysEnabled
        Self.removeOldAnswers()
    }

    /// Answers nobody picked up (the hook timed out or was killed) are removed after a day.
    private static func removeOldAnswers() {
        let fm = FileManager.default
        let dir = SharedContainer.answersDirectory
        let cutoff = Date.now.addingTimeInterval(-24 * 60 * 60)
        for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fm.removeItem(at: url) }
        }
    }

    private static func key(_ id: String) -> String { "ask-" + id }

    func show(_ ask: AgentAsk) {
        agentLog.add(AgentEvent(id: ask.id, date: .now, kind: ask.kind == .permission ? .permission : .finished,
                                title: ask.title, subtitle: ask.message, detail: ask.detail, app: ask.context.app))
        agentLog.askOpened(ask.id)
        if ask.kind == .reply { agentLog.finishTurn(ask.context) }  // the turn is over; Orbi waits for you
        let key = Self.key(ask.id)
        let sound = ask.kind == .permission ? "Ping" : "Glass"
        let focus = AskFocus()
        let respond: (Action, String?) -> Void = { [weak self] action, text in
            guard let self else { return }
            self.answer(ask.id, action: action, text: text)
            if ask.kind == .reply, let session = ask.context.session { self.agentLog.markSeen(session: session) }
            self.presenter.close(key)
            self.forget(ask.id)
        }
        let shortcuts = hotkeysEnabled()
        presenter.show(key: key, sound: sound, interactive: true) { _ in
            AskView(ask: ask, focus: focus, shortcuts: shortcuts, answer: respond)
        }
        open.removeAll { $0.id == ask.id }
        open.append(OpenAsk(id: ask.id, kind: ask.kind, respond: respond, focus: focus))
        updateHotkeys()
    }

    /// Answered elsewhere: just close.
    func cancel(id: String) {
        agentLog.setOutcome(id: id, .elsewhere)
        presenter.close(Self.key(id))
        forget(id)
    }

    // MARK: - Global shortcuts

    private func forget(_ id: String) {
        open.removeAll { $0.id == id }
        updateHotkeys()
    }

    /// Registers ⌥⌘Y / ⌥⌘N while a permission bubble is open and ⌥⌘R while a reply bubble is.
    func updateHotkeys() {
        let keys = HotKeyService.shared
        let enabled = hotkeysEnabled()
        if enabled, open.contains(where: { $0.kind == .permission }) {
            keys.register(.allow) { [weak self] in self?.newest(.permission)?.respond(.allow, nil) }
            keys.register(.deny) { [weak self] in self?.newest(.permission)?.respond(.deny, nil) }
        } else {
            keys.unregister(.allow)
            keys.unregister(.deny)
        }
        if enabled, open.contains(where: { $0.kind == .reply }) {
            keys.register(.reply) { [weak self] in
                guard let self, let ask = self.newest(.reply) else { return }
                self.presenter.focus(Self.key(ask.id))
                ask.focus.requests += 1
            }
        } else {
            keys.unregister(.reply)
        }
    }

    private func newest(_ kind: AgentAsk.Kind) -> OpenAsk? { open.last { $0.kind == kind } }

    private func answer(_ id: String, action: Action, text: String?) {
        let outcome: AgentEvent.Outcome = switch action {
        case .allow, .always: .allowed
        case .deny: .denied
        case .terminal: .terminal
        case .reply: .replied
        case .dismiss: .dismissed
        }
        agentLog.setOutcome(id: id, outcome, reply: action == .reply ? text : nil)
        var payload: [String: String] = ["id": id, "action": action.rawValue]
        if let text { payload["text"] = text }
        do {
            let dir = SharedContainer.answersDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: payload)
            try data.write(to: dir.appending(path: id + ".json"), options: .atomic)
        } catch {
            log.error("Could not write answer \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Lets a global shortcut move keyboard focus into a bubble's reply field.
@MainActor
@Observable
final class AskFocus {
    var requests = 0
}

private struct AskView: View {
    let ask: AgentAsk
    let focus: AskFocus
    /// Show the global shortcut hints.
    let shortcuts: Bool
    let answer: (AskBubble.Action, String?) -> Void
    @State private var reply = ""
    @FocusState private var replyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ✕ means "not here": permission falls back to the terminal dialog, reply is dropped.
            BubbleHeader(title: ask.title, app: ask.context.app) {
                answer(ask.kind == .permission ? .terminal : .dismiss, nil)
            }
            if let message = ask.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            switch ask.kind {
            case .permission: permission
            case .reply: replyBody
            }
        }
    }

    @ViewBuilder private var permission: some View {
        if let detail = ask.detail {
            Text(detail)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(6)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        }
        HStack(spacing: 8) {
            Button { answer(.terminal, nil) } label: { Image(systemName: "terminal") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Answer in the terminal instead")
            if shortcuts {
                Text("\(HotKeyService.Key.allow.label) / \(HotKeyService.Key.deny.label)")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .help("Allow / Deny from any app")
            }
            Spacer()
            Button("Deny") { answer(.deny, nil) }
                .help(shortcuts ? "Deny (\(HotKeyService.Key.deny.label) from any app)" : "Deny")
            if let rule = ask.alwaysRule {
                Button("Always") { answer(.always, nil) }
                    .help("Allow, and don't ask again for \(rule) in this project")
            }
            Button("Allow") { answer(.allow, nil) }
                .buttonStyle(.borderedProminent)
                .help(shortcuts ? "Allow (\(HotKeyService.Key.allow.label) from any app)" : "Allow")
        }
    }

    @ViewBuilder private var replyBody: some View {
        if let detail = ask.detail {
            ScrollView {
                Text(Self.markdown(detail))
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)
        }
        TextField(shortcuts ? "Reply… (\(HotKeyService.Key.reply.label))" : "Reply…", text: $reply, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...4)
            .focused($replyFocused)
            .onSubmit(send)
            .onChange(of: focus.requests) { _, _ in replyFocused = true }
        HStack(spacing: 8) {
            Button("Continue") { answer(.reply, "Continue.") }
                .help("Tell the agent to keep going")
            Spacer()
            Button("Done") { answer(.dismiss, nil) }
            Button("Send", action: send)
                .buttonStyle(.borderedProminent)
                .disabled(trimmedReply.isEmpty)
        }
    }

    private var trimmedReply: String { reply.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send() {
        guard !trimmedReply.isEmpty else { return }
        answer(.reply, trimmedReply)
    }

    /// Agents answer in Markdown; render inline styles, keep line breaks.
    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
