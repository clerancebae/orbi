import SwiftUI

/// Panel section: what your AI agents did. Permission requests with your answer, finished
/// turns with the agent's last message and your reply. Click a row to read the full text.
struct AgentsSection: View {
    @Environment(AgentLogStore.self) private var store
    @Environment(AgentConnections.self) private var connections
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

            if let summary = Self.summary(store.today) {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(store.running) { agent in
                RunningRow(agent: agent)
            }

            if store.events.isEmpty && store.running.isEmpty {
                Text("Nothing yet. Running agents, permission requests and finished turns show up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if connections.status(.claude) != .connected {
                    Button("Connect Claude Code") { connections.connect(.claude) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            } else if showAll {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) { rows(store.events) }
                }
                .frame(maxHeight: 320)
                // Without this the scroll view's height collapses in the menu bar window.
                .fixedSize(horizontal: false, vertical: true)
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

    /// "Today: 2 h 10 min across 3 projects · 14 turns · 12 approved, 1 denied · 3 replies"
    static func summary(_ s: AgentDayStats) -> String? {
        guard s.turns > 0 || s.allowed + s.denied + s.replies > 0 else { return nil }
        var parts: [String] = []
        if s.seconds >= 60 {
            let projects = s.projects.count > 1 ? " across \(s.projects.count) projects" : ""
            parts.append("\(DurationText.minutes(DurationText.floorMinutes(s.seconds)))\(projects)")
        }
        if s.turns > 0 { parts.append(s.turns == 1 ? "1 turn" : "\(s.turns) turns") }
        if s.allowed + s.denied > 0 {
            parts.append(s.denied > 0 ? "\(s.allowed) approved, \(s.denied) denied" : "\(s.allowed) approved")
        }
        if s.replies > 0 { parts.append(s.replies == 1 ? "1 reply" : "\(s.replies) replies") }
        return "Today: " + parts.joined(separator: " · ")
    }

    private func rows(_ events: [AgentEvent]) -> some View {
        ForEach(events) { event in
            AgentEventRow(event: event, isExpanded: expanded.contains(event.id)) {
                if expanded.contains(event.id) { expanded.remove(event.id) } else { expanded.insert(event.id) }
            }
        }
    }
}

/// A session in the middle of a turn: "Claude · Orbi · working 4 min".
private struct RunningRow: View {
    let agent: RunningAgent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ProgressView().controlSize(.mini).frame(width: 16)
            Text([agent.agent, agent.project].compactMap { $0 }.joined(separator: " · "))
                .font(.callout).lineLimit(1)
            // Static minutes (refreshed whenever the panel re-renders), not a per-second timer.
            Text("working " + DurationText.minutes(max(1, DurationText.floorMinutes(Int(Date.now.timeIntervalSince(agent.startedAt))))))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            Spacer(minLength: 4)
            if let app = agent.app {
                GoToAppButton(bundleID: app)
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
                    if let app = event.app {
                        GoToAppButton(bundleID: app)
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
        let time = Self.relativeTime(event.date)
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

    /// "just now" for the first minute (the plain formatter says "in 0 sec." for a fresh event).
    static func relativeTime(_ date: Date, now: Date = .now) -> String {
        if abs(now.timeIntervalSince(date)) < 60 { return "just now" }
        return date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "**", with: "")
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
