import Foundation

final class Store {
    let folder: URL
    let timezone: TimeZone

    init(folder: URL, timezone: TimeZone = .current) {
        self.folder = folder
        self.timezone = timezone
    }

    func appendCapture(noteText: String, noteId: String?, tasks: [Todo], at time: Date) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = DailyFile.url(in: folder, on: time, timezone: timezone)
        var doc = readOrCreate(at: url, on: time)
        for task in tasks { doc.appendTodo(task) }
        if !noteText.isEmpty, let noteId {
            doc.appendNote(text: noteText, at: time, id: noteId)
        }
        try doc.serialize(timezone: timezone).write(to: url, atomically: true, encoding: .utf8)
    }

    func appendNote(text: String, at time: Date, id: String) throws {
        try appendCapture(noteText: text, noteId: id, tasks: [], at: time)
    }

    func toggleTodo(id: String, on date: Date) throws {
        let url = DailyFile.url(in: folder, on: date, timezone: timezone)
        var doc = readOrCreate(at: url, on: date)
        guard let idx = doc.tasks.firstIndex(where: { $0.id == id }) else { return }
        doc.tasks[idx].done.toggle()
        doc.tasks[idx].completedAt = doc.tasks[idx].done ? Date() : nil
        try doc.serialize(timezone: timezone).write(to: url, atomically: true, encoding: .utf8)
    }

    func replaceTasks(_ tasks: [Todo], on date: Date) throws {
        let url = DailyFile.url(in: folder, on: date, timezone: timezone)
        var doc = readOrCreate(at: url, on: date)
        doc.tasks = tasks
        try doc.serialize(timezone: timezone).write(to: url, atomically: true, encoding: .utf8)
    }

    func readDoc(on date: Date) throws -> MarkdownDoc {
        let url = DailyFile.url(in: folder, on: date, timezone: timezone)
        return readOrCreate(at: url, on: date)
    }

    private func readOrCreate(at url: URL, on date: Date) -> MarkdownDoc {
        if let existing = try? String(contentsOf: url, encoding: .utf8),
           let parsed = try? MarkdownDoc.parse(existing, timezone: timezone) {
            return parsed
        }
        return MarkdownDoc(date: startOfDay(date))
    }

    private func startOfDay(_ d: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        return cal.startOfDay(for: d)
    }
}
