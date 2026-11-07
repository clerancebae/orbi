import SwiftUI

/// Panel section: what your AI agents did. Permission requests with your answer, finished
/// turns with the agent's last message and your reply. Click a row to read the full text.
struct AgentsSection: View {
    @Environment(AgentLogStore.self) private var store
    @Environment(AgentConnections.self) private var connections
    @State private var expanded: Set<String> = []
    @State private var showAll = false

    private static let collapsedCount = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Agents", systemImage: "sparkles").font(.subheadline.weight(.semibold))
                Spacer()
                if let limits = store.limits {
                    LimitsView(limits: limits)
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

            // Clear only in the full list: rarely needed, so it stays out of the header.
            if store.events.count > Self.collapsedCount {
                HStack {
                    Button(showAll ? "Show less" : "Show all \(store.events.count)") { showAll.toggle() }
                    Spacer()
                    if showAll {
                        Button("Clear") { store.clear(); expanded.removeAll(); showAll = false }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)
            }
        }
    }

    /// "Today: 2h 10m · 14 turns · 230k tokens". Approvals and replies show on the rows themselves.
    static func summary(_ s: AgentDayStats) -> String? {
        guard s.turns > 0 else { return nil }
        var parts: [String] = []
        if s.seconds >= 60 { parts.append(DurationText.minutes(DurationText.floorMinutes(s.seconds))) }
        parts.append(s.turns == 1 ? "1 turn" : "\(s.turns) turns")
        if let tokens = s.tokens, tokens > 0 { parts.append(tokenText(tokens)) }
        return "Today: " + parts.joined(separator: " · ")
    }

    /// "850 tokens", "12k tokens", "1.4M tokens".
    static func tokenText(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM tokens", Double(n) / 1_000_000) }
        if n >= 1000 { return "\(Int((Double(n) / 1000).rounded()))k tokens" }
        return "\(n) tokens"
    }

    private func rows(_ events: [AgentEvent]) -> some View {
        ForEach(events) { event in
            AgentEventRow(event: event, isExpanded: expanded.contains(event.id)) {
                if expanded.contains(event.id) { expanded.remove(event.id) } else { expanded.insert(event.id) }
            }
        }
    }
}

/// Claude plan limits, in the section header: "5h ▬▬▭ 60% · Week ▬▬▬ 81%" (what's left). Reset times on hover.
private struct LimitsView: View {
    let limits: UsageLimits

    var body: some View {
        HStack(spacing: 12) {
            if let used = shown(limits.fiveHour, reset: limits.fiveHourReset) {
                gauge("5h", used: used, reset: limits.fiveHourReset)
            }
            if let used = shown(limits.week, reset: limits.weekReset) {
                gauge("Week", used: used, reset: limits.weekReset)
            }
        }
        .font(.caption)
    }

    /// A window that has reset since the last report is back to 0 % used.
    private func shown(_ used: Int?, reset: Date?) -> Int? {
        guard let used else { return nil }
        if let reset, reset < .now { return 0 }
        return used
    }

    private func gauge(_ title: String, used: Int, reset: Date?) -> some View {
        HStack(spacing: 5) {
            Text(title).foregroundStyle(.secondary)
            Capsule().fill(.quaternary)
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule().fill(color(used)).frame(width: g.size.width * CGFloat(100 - used) / 100)
                    }
                }
                .frame(width: 40, height: 4)
            Text("\(100 - used)%").monospacedDigit()
        }
        .help(helpText(title, used: used, reset: reset))
    }

    private func color(_ used: Int) -> Color { used >= 90 ? .red : used >= 70 ? .orange : .green }

    /// "5h: 60% left, resets 14:30" (or "Mon 09:00" when it's not today).
    private func helpText(_ title: String, used: Int, reset: Date?) -> String {
        var text = "Claude \(title): \(100 - used)% left"
        if let reset, reset > .now {
            let style: Date.FormatStyle = Calendar.current.isDateInToday(reset)
                ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute()
            text += ", resets \(reset.formatted(style))"
        }
        return text
    }
}

/// A session in the middle of a turn: "orbi · working 4m" (like the event rows; the agent name on hover).
/// Claude sessions can get a queued message: it goes out as the next prompt the moment the turn ends.
private struct RunningRow: View {
    @Environment(AgentLogStore.self) private var store
    let agent: RunningAgent
    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var canQueue: Bool { AgentLogStore.canQueue(session: agent.session) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ProgressView().controlSize(.mini).frame(width: 16)
                // Static minutes (refreshed whenever the panel re-renders), not a per-second timer.
                let minutes = max(1, DurationText.floorMinutes(Int(Date.now.timeIntervalSince(agent.startedAt))))
                (Text(agent.project ?? agent.agent)
                    + Text(" · working \(DurationText.minutes(minutes))").foregroundStyle(.secondary))
                    .font(.callout).monospacedDigit().lineLimit(1)
                Spacer(minLength: 4)
                if canQueue && !editing && store.queued[agent.session] == nil {
                    Button { startEditing() } label: { Image(systemName: "text.badge.plus") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Queue the next message: sent as soon as \(agent.agent) finishes")
                }
                if hovering, let app = agent.app {
                    GoToAppButton(bundleID: app)
                }
            }

            if let queued = store.queued[agent.session] {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary).frame(width: 16)
                    Text(queued).font(.callout).lineLimit(2)
                        .help("Sent as soon as \(agent.agent) finishes this turn")
                    Spacer(minLength: 4)
                    Button { draft = queued; startEditing() } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Edit")
                    Button { store.unqueue(session: agent.session) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Don't send")
                }
                .font(.caption)
            } else if editing {
                TextField("Next message, sent when \(agent.agent) finishes", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false; draft = "" }
                    .padding(.leading, 22)
            }
        }
        .help(agent.agent)
        .onHover { hovering = $0 }
    }

    private func startEditing() {
        if store.queued[agent.session] != nil { store.unqueue(session: agent.session) }
        editing = true
        fieldFocused = true
    }

    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { store.queue(text, session: agent.session) }
        editing = false
        draft = ""
    }
}

/// One line per event: "✓ api · Fixed the flaky login test…   7m". Click for the full text;
/// ↗ shows on hover.
private struct AgentEventRow: View {
    let event: AgentEvent
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: event.kind == .permission ? "lock.shield" : "checkmark.bubble")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(line).font(.callout).lineLimit(1)
                    Spacer(minLength: 4)
                    if let badge {
                        Text(badge.text)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(badge.color)
                    } else {
                        Text(Self.shortAge(event.date))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if hovering, let app = event.app {
                        GoToAppButton(bundleID: app)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide details" : event.title)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text([event.title, event.subtitle, Self.relativeTime(event.date)].compactMap { $0 }
                        .joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
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
        .onHover { hovering = $0 }
    }

    /// "api · Fixed the flaky login test…": the project (first part of the subtitle) and the text.
    private var line: String {
        let project = event.subtitle?.components(separatedBy: " · ").first
        let text = event.detail.map { Self.oneLine($0) } ?? event.title
        return [project, text].compactMap { $0 }.joined(separator: " · ")
    }

    /// Only a denial is coloured; the rest stays quiet.
    private var badge: (text: String, color: Color)? {
        switch event.outcome {
        case .allowed: ("Allowed", .secondary)
        case .denied: ("Denied", .red)
        case .terminal, .elsewhere: ("Terminal", .secondary)
        case .replied: ("Replied", .secondary)
        case .dismissed, nil: nil
        }
    }

    /// "now", "12m", "3h", "2d".
    static func shortAge(_ date: Date, now: Date = .now) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 { return "\(minutes / 60)h" }
        return "\(minutes / (24 * 60))d"
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
