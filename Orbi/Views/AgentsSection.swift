import SwiftUI

/// Panel section: what your AI agents did. Permission requests with your answer, finished
/// turns with the agent's last message and your reply. Click a row to read the full text.
struct AgentsSection: View {
    @Environment(AgentLogStore.self) private var store
    @State private var expanded: Set<String> = []
    @State private var showAll = false

    private static let collapsedCount = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Agents", systemImage: "sparkles").font(.subheadline.weight(.semibold))
                Spacer()
                if !store.events.isEmpty {
                    Button("Clear") { store.clear(); expanded.removeAll() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            if store.events.isEmpty {
                Text("Nothing yet. Claude's permission requests and finished turns show up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if showAll {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) { rows(store.events) }
                }
                .frame(maxHeight: 320)
            } else {
                rows(Array(store.events.prefix(Self.collapsedCount)))
            }

            if store.events.count > Self.collapsedCount {
                Button(showAll ? "Show less" : "Show all \(store.events.count)") { showAll.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private func rows(_ events: [AgentEvent]) -> some View {
        ForEach(events) { event in
            AgentEventRow(event: event, isExpanded: expanded.contains(event.id)) {
                if expanded.contains(event.id) { expanded.remove(event.id) } else { expanded.insert(event.id) }
            }
        }
    }
}

private struct AgentEventRow: View {
    let event: AgentEvent
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: event.kind == .permission ? "lock.shield" : "checkmark.bubble")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title).font(.callout).lineLimit(1)
                        Text(secondLine).font(.caption).foregroundStyle(.secondary).lineLimit(isExpanded ? nil : 1)
                    }
                    Spacer(minLength: 4)
                    if let badge {
                        Text(badge.text)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(badge.color)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide details" : "Show details")

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let detail = event.detail {
                        ScrollView {
                            Text(event.kind == .permission ? AttributedString(detail) : Self.markdown(detail))
                                .font(event.kind == .permission ? .system(.caption, design: .monospaced) : .callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 180)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if let reply = event.reply {
                        Label(reply, systemImage: "arrowshape.turn.up.left")
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .padding(.leading, 22)
            }
        }
    }

    private var secondLine: String {
        let time = event.date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
        let preview = isExpanded ? nil : event.detail.map { Self.oneLine($0) }
        return [event.subtitle, time, preview].compactMap { $0 }.joined(separator: " · ")
    }

    private var badge: (text: String, color: Color)? {
        switch event.outcome {
        case .allowed: ("Allowed", .green)
        case .denied: ("Denied", .red)
        case .terminal, .elsewhere: ("Terminal", .secondary)
        case .replied: ("Replied", .accentColor)
        case .dismissed, nil: nil
        }
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "**", with: "")
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
