import Foundation

struct Note: Equatable {
    let id: String
    let time: Date     // wall time of capture
    let text: String
}

struct MarkdownDoc: Equatable {
    let date: Date
    private(set) var notes: [Note] = []
    var tasks: [Todo] = []

    init(date: Date) { self.date = date }

    mutating func appendNote(text: String, at time: Date, id: String) {
        notes.append(Note(id: id, time: time, text: text))
    }

    mutating func appendTodo(_ task: Todo) {
        tasks.append(task)
    }

    func serialize(timezone: TimeZone = .current) -> String {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        dateFmt.timeZone = timezone
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        timeFmt.timeZone = timezone

        let isoFmt = ISO8601DateFormatter()
        isoFmt.timeZone = timezone
        isoFmt.formatOptions = [.withInternetDateTime]

        let dateOnlyFmt = DateFormatter()
        dateOnlyFmt.dateFormat = "yyyy-MM-dd"
        dateOnlyFmt.timeZone = timezone

        var out = """
        ---
        date: \(dateFmt.string(from: date))
        created: \(isoFmt.string(from: date))
        ---

        ## Tasks

        """

        for task in tasks {
            let state = task.done ? "x" : " "
            var meta = "id:\(task.id) created:\(isoFmt.string(from: task.createdAt))"
            if task.done, let ca = task.completedAt {
                meta += " done:\(isoFmt.string(from: ca))"
            }
            if let due = task.dueDate {
                meta += " due:\(dateOnlyFmt.string(from: due))"
            }
            if let rolled = task.rolledTo {
                meta += " rolled_to:\(dateOnlyFmt.string(from: rolled))"
            }
            if let sn = task.sourceNote {
                meta += " source_note:\(sn)"
            }
            out += "- [\(state)] \(task.text) <!-- \(meta) -->\n"
        }

        out += "\n## Notes\n\n"

        for note in notes {
            out += """

            ### \(timeFmt.string(from: note.time)) <!-- id:\(note.id) -->
            \(note.text)

            """
        }
        return out
    }

    static func parse(_ text: String, timezone: TimeZone = .current) throws -> MarkdownDoc {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        dateFmt.timeZone = timezone

        // Frontmatter date
        guard let dateMatch = text.firstMatch(of: /date:\s*(\d{4}-\d{2}-\d{2})/),
              let parsedDate = dateFmt.date(from: String(dateMatch.1)) else {
            throw NSError(domain: "Jotty", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "missing or invalid frontmatter date"])
        }

        var doc = MarkdownDoc(date: parsedDate)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone

        // Parse tasks: "- [<state>] <text> <!-- <metadata> -->"
        let taskRegex = /- \[(.)\] (.*?) <!-- (.+?) -->/
        let isoFmt = ISO8601DateFormatter()
        let dateOnlyFmt = DateFormatter()
        dateOnlyFmt.dateFormat = "yyyy-MM-dd"
        dateOnlyFmt.timeZone = timezone

        for match in text.matches(of: taskRegex) {
            let stateChar = String(match.1)
            let taskText = String(match.2)
            let metaBlob = String(match.3)

            // Parse whitespace-separated key:value tokens
            var id = ""
            var createdAt: Date = parsedDate
            var done = stateChar == "x"
            var completedAt: Date? = nil
            var dueDate: Date? = nil
            var rolledTo: Date? = nil
            var sourceNote: String? = nil

            let tokens = metaBlob.split(separator: " ", omittingEmptySubsequences: true)
            for token in tokens {
                let parts = token.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = String(parts[0])
                let value = String(parts[1])
                switch key {
                case "id":
                    id = value
                case "created":
                    if let d = isoFmt.date(from: value) { createdAt = d }
                case "done":
                    if let d = isoFmt.date(from: value) { completedAt = d }
                case "due":
                    dueDate = dateOnlyFmt.date(from: value)
                case "rolled_to":
                    rolledTo = dateOnlyFmt.date(from: value)
                case "source_note":
                    sourceNote = value
                default:
                    break
                }
            }

            guard !id.isEmpty else { continue }

            let todo = Todo(id: id, text: taskText, createdAt: createdAt,
                            done: done, completedAt: completedAt,
                            dueDate: dueDate, rolledTo: rolledTo, sourceNote: sourceNote)
            doc.tasks.append(todo)
        }

        // Parse note entries: "### HH:mm <!-- id:n_xxx -->\n<body>"
        let noteRegex = /### (\d{2}):(\d{2}) <!-- id:([^ ]+) -->\n([\s\S]*?)(?=\n\n### |\z)/
        for match in text.matches(of: noteRegex) {
            let h = Int(match.1)!
            let m = Int(match.2)!
            let id = String(match.3)
            let body = String(match.4).trimmingCharacters(in: .whitespacesAndNewlines)

            var comps = calendar.dateComponents([.year, .month, .day], from: parsedDate)
            comps.hour = h
            comps.minute = m
            let time = calendar.date(from: comps) ?? parsedDate

            doc.notes.append(Note(id: id, time: time, text: body))
        }
        return doc
    }
}
