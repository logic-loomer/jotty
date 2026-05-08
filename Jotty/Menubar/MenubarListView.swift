import SwiftUI

@MainActor
final class MenubarListModel: ObservableObject {
    @Published private(set) var tasks: [Todo] = []
    @Published private(set) var dateLabel: String = ""

    let store: Store
    private let timezone: TimeZone

    init(store: Store, timezone: TimeZone = .current) {
        self.store = store
        self.timezone = timezone
        reload()
    }

    func reload() {
        let now = Date()
        do {
            let doc = try store.readDoc(on: now)
            tasks = doc.tasks
        } catch {
            tasks = []
        }
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        f.timeZone = timezone
        dateLabel = f.string(from: now)
    }

    func toggle(_ task: Todo) {
        try? store.toggleTodo(id: task.id, on: Date())
        reload()
    }

    var doneCount: Int { tasks.filter(\.done).count }
}

struct MenubarListView: View {
    @ObservedObject var model: MenubarListModel
    let onCapture: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Jotty · \(model.dateLabel)")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(model.doneCount) of \(model.tasks.count) done")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Task list
            if model.tasks.isEmpty {
                Text("No tasks today. ⌘N to capture.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.tasks, id: \.id) { task in
                            Button(action: { model.toggle(task) }) {
                                HStack(spacing: 8) {
                                    Image(systemName: task.done ? "checkmark.square" : "square")
                                    Text(task.text)
                                        .strikethrough(task.done)
                                        .foregroundStyle(task.done ? .secondary : .primary)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 300)
            }

            Divider()

            // Footer
            HStack(spacing: 0) {
                Button("Capture") { onCapture() }
                    .keyboardShortcut("n", modifiers: .command)
                Spacer()
                Button("Settings") { onSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 300)
    }
}
