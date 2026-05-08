import Foundation

enum ISOTaskMapper {
    static func map(_ ai: [ExtractedTaskAI], in tz: TimeZone) -> [ExtractedTask] {
        let dayFmt = DateFormatter()
        dayFmt.calendar = Calendar(identifier: .gregorian)
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.timeZone = tz
        dayFmt.dateFormat = "yyyy-MM-dd"

        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withTimeZone]

        return ai.compactMap { item in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }

            let due = item.dueDateISO.flatMap { dayFmt.date(from: $0) }

            let block: TimeBlock? = {
                guard let s = item.blockStartISO,
                      let e = item.blockEndISO,
                      let start = isoFmt.date(from: s),
                      let end = isoFmt.date(from: e),
                      end > start else { return nil }
                return TimeBlock(start: start, end: end)
            }()

            return ExtractedTask(
                title: title,
                dueDate: due,
                timeBlock: block,
                calendarBlock: block != nil
            )
        }
    }
}
