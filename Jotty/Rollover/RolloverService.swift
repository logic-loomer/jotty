import Foundation

final class RolloverService {
    let store: Store
    let statePath: URL
    let timezone: TimeZone
    let maxLookbackDays: Int

    init(store: Store, statePath: URL, timezone: TimeZone = .current, maxLookbackDays: Int = 14) {
        self.store = store
        self.statePath = statePath
        self.timezone = timezone
        self.maxLookbackDays = maxLookbackDays
    }

    func run(now: Date) throws {
        let cal = calendar()
        let today = cal.startOfDay(for: now)

        let lastRollover = readState() ?? today
        let lookbackStart = max(
            cal.date(byAdding: .day, value: -maxLookbackDays, to: today) ?? today,
            cal.startOfDay(for: lastRollover)
        )

        var collected: [Todo] = []
        var cursor = cal.date(byAdding: .day, value: -1, to: today)!
        while cursor >= lookbackStart {
            var doc = (try? store.readDoc(on: cursor)) ?? MarkdownDoc(date: cursor)
            var changed = false
            var rewritten: [Todo] = []
            for taskItem in doc.tasks {
                var task = taskItem
                if !task.done && task.rolledTo == nil {
                    var copy = task
                    copy.rolledTo = nil
                    collected.append(copy)
                    task.rolledTo = today
                    changed = true
                }
                rewritten.append(task)
            }
            if changed {
                doc.tasks = rewritten
                try store.replaceTasks(doc.tasks, on: cursor)
            }
            cursor = cal.date(byAdding: .day, value: -1, to: cursor)!
        }

        if !collected.isEmpty {
            var todayDoc = (try? store.readDoc(on: today)) ?? MarkdownDoc(date: today)
            todayDoc.tasks.append(contentsOf: collected)
            try store.replaceTasks(todayDoc.tasks, on: today)
        }

        try writeState(today)
    }

    private func readState() -> Date? {
        guard let s = try? String(contentsOf: statePath, encoding: .utf8) else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = timezone
        return f.date(from: s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func writeState(_ date: Date) throws {
        try FileManager.default.createDirectory(at: statePath.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = timezone
        try f.string(from: date).write(to: statePath, atomically: true, encoding: .utf8)
    }

    private func calendar() -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = timezone; return c
    }
}
