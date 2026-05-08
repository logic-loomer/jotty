import Foundation

struct Note: Equatable {
    let id: String
    let time: Date     // wall time of capture
    let text: String
}

struct MarkdownDoc: Equatable {
    let date: Date
    private(set) var notes: [Note] = []

    init(date: Date) { self.date = date }

    mutating func appendNote(text: String, at time: Date, id: String) {
        notes.append(Note(id: id, time: time, text: text))
    }

    func serialize() -> String {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        let isoFmt = ISO8601DateFormatter()

        var out = """
        ---
        date: \(dateFmt.string(from: date))
        created: \(isoFmt.string(from: date))
        ---

        ## Notes

        """

        for note in notes {
            out += """

            ### \(timeFmt.string(from: note.time)) <!-- id:\(note.id) -->
            \(note.text)

            """
        }
        return out
    }

    static func parse(_ text: String) throws -> MarkdownDoc {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"

        // Frontmatter date
        guard let dateMatch = text.firstMatch(of: /date:\s*(\d{4}-\d{2}-\d{2})/),
              let parsedDate = dateFmt.date(from: String(dateMatch.1)) else {
            throw NSError(domain: "Jotty", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "missing or invalid frontmatter date"])
        }

        var doc = MarkdownDoc(date: parsedDate)

        // Parse note entries: "### HH:mm <!-- id:n_xxx -->\n<body>"
        let noteRegex = /### (\d{2}):(\d{2}) <!-- id:([^ ]+) -->\n([\s\S]*?)(?=\n### |\z)/
        for match in text.matches(of: noteRegex) {
            let h = Int(match.1)!
            let m = Int(match.2)!
            let id = String(match.3)
            let body = String(match.4).trimmingCharacters(in: .whitespacesAndNewlines)

            var comps = Calendar.current.dateComponents([.year, .month, .day], from: parsedDate)
            comps.hour = h
            comps.minute = m
            let time = Calendar.current.date(from: comps) ?? parsedDate

            doc.notes.append(Note(id: id, time: time, text: body))
        }
        return doc
    }
}
