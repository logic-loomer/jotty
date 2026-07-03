import Foundation

struct Note: Equatable {
    /// Single authority for note-ID generation (CQ-09), parallel to `Todo.newID()`.
    ///
    /// The format is REQUIREMENTS-pinned (decision 2026-05-08): `n_<8 hex>` —
    /// "n_" plus the first 8 characters of a UUID string, lowercased. Same
    /// derivation the capture paths used inline before centralization.
    static func newID() -> String {
        "n_" + String(UUID().uuidString.prefix(8)).lowercased()
    }

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
            if let tb = task.timeBlock {
                meta += " time:\(timeFmt.string(from: tb.start))-\(timeFmt.string(from: tb.end))"
            }
            if let cal = task.calEventID,
               // T-5-01: a whitespace-bearing id would split into a bogus token and
               // corrupt the space-split metadata line — skip rather than corrupt.
               !cal.contains(where: { $0.isWhitespace }) {
                meta += " cal_event:\(cal)"
            }
            if let src = task.source,
               // T-7-02: source is `sourceID:itemID` (space-free GitHub id); guard anyway so
               // a malformed value can never split into bogus tokens.
               !src.contains(where: { $0.isWhitespace }) {
                meta += " source:\(src)"
            }
            if let su = task.sourceURL,
               // T-7-01: a whitespace-bearing url would split into a bogus token and corrupt
               // the space-split metadata line (Pitfall 4) — skip rather than corrupt.
               !su.contains(where: { $0.isWhitespace }) {
                meta += " source_url:\(su)"
            }
            // IN-01: the task line is `- [x] <text> <!-- <meta> -->`; a `text` containing
            // `<!--`/`-->` would shift the comment boundary and corrupt the round-trip
            // (calendar-sourced titles can now reach `task.text` via SC4 sync). Neutralize the
            // comment delimiters so parsing stays stable. Sanitize-on-create/sync handles
            // markdown; this guards the structural delimiters specifically.
            let safeText = task.text
                .replacingOccurrences(of: "<!--", with: "<!-")
                .replacingOccurrences(of: "-->", with: "->")
            out += "- [\(state)] \(safeText) <!-- \(meta) -->\n"
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
            var timeBlock: TimeBlock? = nil
            var calEventID: String? = nil
            var source: String? = nil
            var sourceURL: String? = nil

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
                case "time":
                    // value is "HH:mm-HH:mm"; build absolute Dates on parsedDate.
                    let halves = value.split(separator: "-", maxSplits: 1)
                    if halves.count == 2,
                       let startDate = absoluteTime(String(halves[0]),
                                                    on: parsedDate, calendar: calendar),
                       let endDate = absoluteTime(String(halves[1]),
                                                  on: parsedDate, calendar: calendar) {
                        timeBlock = TimeBlock(start: startDate, end: endDate)
                    }
                case "cal_event":
                    calEventID = value
                case "source":
                    source = value
                case "source_url":
                    sourceURL = value
                default:
                    break
                }
            }

            guard !id.isEmpty else { continue }

            let todo = Todo(id: id, text: taskText, createdAt: createdAt,
                            done: done, completedAt: completedAt,
                            dueDate: dueDate, rolledTo: rolledTo, sourceNote: sourceNote,
                            timeBlock: timeBlock, calEventID: calEventID,
                            source: source, sourceURL: sourceURL)
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

    /// Builds an absolute Date for an "HH:mm" wall-clock time on the given day,
    /// using the timezone-pinned gregorian calendar (matches note-time parsing).
    private static func absoluteTime(_ hhmm: String, on day: Date,
                                     calendar: Calendar) -> Date? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else {
            return nil
        }
        var comps = calendar.dateComponents([.year, .month, .day], from: day)
        comps.hour = h
        comps.minute = m
        return calendar.date(from: comps)
    }
}
