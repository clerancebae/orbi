import SwiftUI

struct ReadingSection: View {
    @Environment(ReadingStore.self) private var store
    @State private var newLink = ""
    @State private var showAll = false
    @State private var showEarlier = false

    private static let collapsedCount = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Read later", systemImage: "bookmark").font(.subheadline.weight(.semibold))
                Spacer()
                if !store.items.isEmpty {
                    Text("\(store.items.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }

            TextField("Paste a link to save…", text: $newLink)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveLink)

            if store.items.isEmpty && store.finishedToday.isEmpty {
                Text("Nothing saved.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(visibleItems) { item in
                    ReadingRow(item: item)
                }
                if store.items.count > Self.collapsedCount {
                    Button(showAll ? "Show less" : "Show all \(store.items.count)") { showAll.toggle() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                ForEach(store.finishedToday) { item in
                    FinishedRow(item: item)
                }
            }

            if !store.finishedEarlier.isEmpty {
                DisclosureGroup(isExpanded: $showEarlier) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(store.finishedEarlier) { item in
                                FinishedRow(item: item)
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                    HStack {
                        Spacer()
                        Button("Clear all", role: .destructive) { store.clearFinishedEarlier() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                } label: {
                    Text("Earlier read (\(store.finishedEarlier.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var visibleItems: [ReadingItem] {
        showAll ? store.items : Array(store.items.prefix(Self.collapsedCount))
    }

    private func saveLink() {
        let text = newLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host() != nil else { return }
        store.save(url: url)
        newLink = ""
    }
}

private struct ReadingRow: View {
    @Environment(ReadingStore.self) private var store
    let item: ReadingItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(item.openedAt != nil ? Color.orange : Color.secondary)
                .help(item.openedAt != nil ? "Opened, not finished" : "Not opened yet")
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .opacity(store.isSnoozed(item) ? 0.5 : 1)
            .contentShape(Rectangle())
            .onTapGesture { store.open(item) }

            Spacer(minLength: 4)

            Button { store.open(item) } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.borderless).help("Open")
            Button { store.finish(item) } label: { Image(systemName: "checkmark.circle") }
                .buttonStyle(.borderless).help("Done")
            Menu {
                Button("Snooze until tomorrow") { store.snoozeUntilTomorrow(item) }
                Button("Snooze for a week") {
                    store.snooze(item, until: Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now)
                }
                Divider()
                Button("Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
                }
                Button("Delete", role: .destructive) { store.delete(item) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .help(item.url.absoluteString)
    }

    private var icon: String {
        item.openedAt != nil ? "book" : "bookmark"
    }

    private var subtitle: String {
        var parts = [item.url.host(percentEncoded: false)?.replacingOccurrences(of: "www.", with: "") ?? ""]
        parts.append(RelativeDay.short(for: item.savedAt, now: store.currentDate))
        if item.openedAt != nil { parts.append("opened") }
        if let until = item.remindAfter, store.isSnoozed(item) {
            parts.append("snoozed until \(until.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// A finished item: struck through, ✓ toggles it back to unread, menu can delete.
private struct FinishedRow: View {
    @Environment(ReadingStore.self) private var store
    let item: ReadingItem

    var body: some View {
        HStack(spacing: 8) {
            Button { store.unfinish(item) } label: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .buttonStyle(.borderless)
            .help("Mark as not read")
            .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1).strikethrough()
                Text(subtitle).font(.caption2).lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .onTapGesture { store.open(item) }

            Spacer(minLength: 4)

            Menu {
                Button("Open again") { store.open(item) }
                Button("Mark as not read") { store.unfinish(item) }
                Button("Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
                }
                Divider()
                Button("Delete", role: .destructive) { store.delete(item) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .help(item.url.absoluteString)
    }

    private var subtitle: String {
        let host = item.url.host(percentEncoded: false)?.replacingOccurrences(of: "www.", with: "") ?? ""
        guard let finishedAt = item.finishedAt else { return host }
        return "\(host) · read \(RelativeDay.text(for: finishedAt, now: store.currentDate))"
    }
}
