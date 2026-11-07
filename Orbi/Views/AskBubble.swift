import OSLog
import SwiftUI

/// Interactive bubble for AI agents (`orbi://ask`): approve a permission, or read the agent's
/// last message and reply, without switching to the terminal. The answer goes to
/// `answers/<id>.json`, where the waiting hook (`mcp/agent_hook.py`) picks it up.
/// Each question has its own bubble, so two sessions asking at once stack.
@MainActor
final class AskBubble {
    enum Action: String { case allow, deny, terminal, reply, dismiss }

    private let presenter: BubblePresenter
    private let log = Logger(subsystem: "com.berke.Orbi", category: "AskBubble")

    init(presenter: BubblePresenter) {
        self.presenter = presenter
    }

    private static func key(_ id: String) -> String { "ask-" + id }

    func show(_ ask: AgentAsk) {
        let key = Self.key(ask.id)
        let sound = ask.kind == .permission ? "Ping" : "Glass"
        presenter.show(key: key, sound: sound, interactive: true) { [weak self] close in
            AskView(ask: ask) { action, text in
                self?.answer(ask.id, action: action, text: text)
                close()
            }
        }
    }

    /// Answered elsewhere: just close.
    func cancel(id: String) {
        presenter.close(Self.key(id))
    }

    private func answer(_ id: String, action: Action, text: String?) {
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

private struct AskView: View {
    let ask: AgentAsk
    let answer: (AskBubble.Action, String?) -> Void
    @State private var reply = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ✕ means "not here": permission falls back to the terminal dialog, reply is dropped.
            BubbleHeader(title: ask.title) {
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
            Button("Terminal") { answer(.terminal, nil) }
                .buttonStyle(.borderless)
                .help("Answer in the terminal instead")
            Spacer()
            Button("Deny") { answer(.deny, nil) }
            Button("Allow") { answer(.allow, nil) }
                .buttonStyle(.borderedProminent)
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
        TextField("Reply…", text: $reply, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...4)
            .onSubmit(send)
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
