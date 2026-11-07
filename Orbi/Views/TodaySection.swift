import SwiftUI

struct TodaySection: View {
    @Environment(TaskStore.self) private var store
    @State private var newTask = ""
    @FocusState private var addFieldFocused: Bool

    private let rowHeight: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            TextField("Add task — e.g. “Write docs 25m”", text: $newTask)
                .textFieldStyle(.roundedBorder)
                .focused($addFieldFocused)
                .onSubmit(addTask)

            if store.tasks.isEmpty {
                Text("Nothing planned yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                list
            }

            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var header: some View {
        HStack {
            Label("Today", systemImage: "checklist").font(.subheadline.weight(.semibold))
            Spacer()
            if !store.tasks.isEmpty {
                Text("\(store.doneTasks.count)/\(store.tasks.count) done")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private var list: some View {
        List {
            ForEach(store.openTasks) { task in
                TaskRow(task: task)
            }
            .onMove { store.move(fromOffsets: $0, toOffset: $1) }

            ForEach(store.doneTasks) { task in
                TaskRow(task: task)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, rowHeight)
        .frame(height: min(CGFloat(store.tasks.count) * rowHeight + 4, 300))
    }

    private func addTask() {
        if store.add(input: newTask) != nil { newTask = "" }
        addFieldFocused = true
    }
}

private struct TaskRow: View {
    @Environment(TaskStore.self) private var store
    let task: TaskItem

    @State private var isEditing = false
    @State private var draftTitle = ""

    private static let estimatePresets = [10, 15, 25, 45, 60, 90]

    var body: some View {
        HStack(spacing: 8) {
            leadingButton

            if isEditing {
                TextField("Title", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .onSubmit(commitRename)
                    .onExitCommand { isEditing = false }
            } else {
                Text(task.title)
                    .lineLimit(1)
                    .strikethrough(task.status == .done)
                    .foregroundStyle(task.status == .done ? .secondary : .primary)
                    .fontWeight(task.status == .active ? .semibold : .regular)
                    .onTapGesture(count: 2, perform: beginRename)
            }

            Spacer(minLength: 4)

            Text(timeText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(isOver ? .orange : .secondary)

            if task.status != .done {
                Button { store.complete(task) } label: {
                    Image(systemName: "checkmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Complete")
            }
        }
        .contextMenu { menu }
        .swipeActions {
            Button("Delete", role: .destructive) { store.delete(task) }
        }
    }

    @ViewBuilder
    private var leadingButton: some View {
        switch task.status {
        case .done:
            Button { store.reopen(task) } label: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .buttonStyle(.borderless).help("Reopen")
        case .active:
            Button { store.pause(task) } label: {
                Image(systemName: "pause.circle.fill").foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless).help("Pause")
        case .todo:
            Button { store.start(task) } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless).help("Start")
        }
    }

    @ViewBuilder
    private var menu: some View {
        switch task.status {
        case .todo: Button("Start") { store.start(task) }
        case .active: Button("Pause") { store.pause(task) }
        case .done: Button("Reopen") { store.reopen(task) }
        }
        if task.status != .done {
            Button("Complete") { store.complete(task) }
        }
        Button("Rename") { beginRename() }
        Menu("Estimate") {
            ForEach(Self.estimatePresets, id: \.self) { minutes in
                Button(DurationText.minutes(minutes)) { store.setEstimate(task, minutes: minutes) }
            }
            Divider()
            Button("No estimate") { store.setEstimate(task, minutes: nil) }
        }
        Divider()
        Button("Delete", role: .destructive) { store.delete(task) }
    }

    private var isOver: Bool {
        task.status == .active && (store.remainingSeconds(task) ?? 0) < 0
    }

    private var timeText: String {
        let elapsed = store.elapsedSeconds(task)
        switch task.status {
        case .active:
            guard let remaining = store.remainingSeconds(task) else {
                return DurationText.minutes(DurationText.floorMinutes(elapsed))
            }
            return remaining >= 0
                ? "\(DurationText.minutes(DurationText.ceilMinutes(remaining))) left"
                : "\(DurationText.minutes(DurationText.ceilMinutes(-remaining))) over"
        case .todo:
            if elapsed >= 60, let estimate = task.estimatedMinutes {
                return "\(DurationText.minutes(DurationText.floorMinutes(elapsed)))/\(DurationText.minutes(estimate))"
            }
            if elapsed >= 60 { return DurationText.minutes(DurationText.floorMinutes(elapsed)) }
            return task.estimatedMinutes.map(DurationText.minutes) ?? ""
        case .done:
            return elapsed >= 60 ? DurationText.minutes(DurationText.floorMinutes(elapsed)) : ""
        }
    }

    private func beginRename() {
        guard task.status != .done else { return }
        draftTitle = task.title
        isEditing = true
    }

    private func commitRename() {
        store.rename(task, to: draftTitle)
        isEditing = false
    }
}
