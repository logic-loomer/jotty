import Foundation

final class Store {
    let folder: URL
    let timezone: TimeZone

    init(folder: URL, timezone: TimeZone = .current) {
        self.folder = folder
        self.timezone = timezone
    }

    func appendNote(text: String, at time: Date, id: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = DailyFile.url(in: folder, on: time, timezone: timezone)

        var doc: MarkdownDoc
        if let existing = try? String(contentsOf: url, encoding: .utf8),
           let parsed = try? MarkdownDoc.parse(existing, timezone: timezone) {
            doc = parsed
        } else {
            doc = MarkdownDoc(date: startOfDay(time))
        }
        doc.appendNote(text: text, at: time, id: id)
        try doc.serialize(timezone: timezone).write(to: url, atomically: true, encoding: .utf8)
    }

    private func startOfDay(_ d: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        return cal.startOfDay(for: d)
    }
}
