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

    /// Ordered document skeleton captured at parse (phase 10-01). This is the
    /// contract plan 02's span-aware `serialize` reconciles against; no
    /// production caller reads it yet. `private(set)` so ONLY `parse` (same
    /// file) writes it, while `@testable` tests can read the ordered spans.
    /// Deliberately EXCLUDED from `==` (see below): whole-doc equality means
    /// "same logical content" (date/tasks/notes), exactly as before this plan,
    /// so skeleton churn never leaks into equality or dirty-detection.
    private(set) var spans: [Span] = []

    /// Test-only: the ordered span kinds as strings, for classification asserts.
    var spanKindsForTesting: [String] {
        spans.map {
            switch $0 {
            case .frontmatter: return "frontmatter"
            case .taskLine:    return "taskLine"
            case .note:        return "note"
            case .raw:         return "raw"
            }
        }
    }

    init(date: Date) { self.date = date }

    // Explicit Equatable: compare ONLY logical content (date/tasks/notes), NOT
    // the `spans` skeleton. No caller compares whole docs (verified); tests
    // compare `.tasks`/`.notes`. Excluding `spans` keeps `==` meaning identical
    // to today and avoids ordered-skeleton churn leaking into equality.
    static func == (lhs: MarkdownDoc, rhs: MarkdownDoc) -> Bool {
        lhs.date == rhs.date && lhs.tasks == rhs.tasks && lhs.notes == rhs.notes
    }

    mutating func appendNote(text: String, at time: Date, id: String) {
        notes.append(Note(id: id, time: time, text: text))
    }

    mutating func appendTodo(_ task: Todo) {
        tasks.append(task)
    }

    /// Span-aware serialize (phase 10-02). A fresh `MarkdownDoc(date:)` has no
    /// captured spans → `canonicalSynthesize` produces today's exact canonical
    /// layout (byte-identical to the pre-phase-10 output). A parsed doc walks its
    /// captured spans in original order and reconciles each Jotty span against
    /// the live `tasks`/`notes` arrays by id (`reconcileWalk`): untouched spans
    /// re-emit their captured bytes verbatim, mutated ones re-render, deleted ids
    /// are omitted, and brand-new ids are injected into their section.
    func serialize(timezone: TimeZone = .current) -> String {
        spans.isEmpty
            ? canonicalSynthesize(timezone: timezone)
            : reconcileWalk(timezone: timezone)
    }

    /// Fresh/empty-skeleton path: synthesize today's canonical layout. This is
    /// the pre-phase-10 serialize body, factored to call the shared
    /// `renderTaskLine`/`renderNoteBlock` renderers so the fresh path and the
    /// changed-span reconcile path share ONE renderer (I4/I5 live in one place).
    /// Byte-identical to the old output for every fresh-doc/appendTodo test.
    private func canonicalSynthesize(timezone: TimeZone) -> String {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        dateFmt.timeZone = timezone

        let isoFmt = ISO8601DateFormatter()
        isoFmt.timeZone = timezone
        isoFmt.formatOptions = [.withInternetDateTime]

        var out = """
        ---
        date: \(dateFmt.string(from: date))
        created: \(isoFmt.string(from: date))
        ---

        ## Tasks

        """

        for task in tasks {
            out += renderTaskLine(task, unknownTokens: [], timezone: timezone) + "\n"
        }

        out += "\n## Notes\n\n"

        for note in notes {
            out += "\n" + renderNoteBlock(note, timezone: timezone) + "\n"
        }
        return out
    }

    /// Renders one Jotty task line `- [x] <text> <!-- <meta> -->` WITHOUT a
    /// trailing newline (the fresh-path loop and the reconcile walk own spacing).
    /// Rebuilds Jotty's canonical meta tokens in fixed order (the whitespace-in-
    /// token skip guards I4 + the IN-01 `<!--`→`<!-` neutralize I5 live here, the
    /// single source of truth), THEN appends any captured `unknownTokens` verbatim
    /// before the closing ` -->` so a hand-added `priority:high` survives a
    /// re-render of a mutated line (SC3).
    private func renderTaskLine(_ task: Todo, unknownTokens: [String],
                                timezone: TimeZone) -> String {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        timeFmt.timeZone = timezone
        let isoFmt = ISO8601DateFormatter()
        isoFmt.timeZone = timezone
        isoFmt.formatOptions = [.withInternetDateTime]
        let dateOnlyFmt = DateFormatter()
        dateOnlyFmt.dateFormat = "yyyy-MM-dd"
        dateOnlyFmt.timeZone = timezone

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
        if let r = task.recur {
            // T-8-01: recur values are structurally space-free
            // (daily/weekly/weekday/custom:1,3,5) — guard anyway per the
            // established defensive pattern (Pitfall 4).
            let value = r.serialize()
            if !value.contains(where: { $0.isWhitespace }) {
                meta += " recur:\(value)"
            }
        }
        if let rs = task.recurSrc,
           // T-8-01: the marker is "<templateId>:<yyyy-MM-dd>" (space-free);
           // a whitespace-bearing value would split into bogus tokens — skip
           // rather than corrupt.
           !rs.contains(where: { $0.isWhitespace }) {
            meta += " recur_src:\(rs)"
        }
        if let sn = task.snooze {
            meta += " snooze:\(dateOnlyFmt.string(from: sn))"
        }
        // SC3: re-emit unrecognized `key:value` tokens (e.g. priority:high)
        // verbatim, in captured order, AFTER Jotty's own canonical tokens and
        // BEFORE the closing ` -->`.
        for token in unknownTokens {
            meta += " \(token)"
        }
        // IN-01: the task line is `- [x] <text> <!-- <meta> -->`. The parser
        // locates the metadata by the FIRST ` <!-- ` opener, then reads to the
        // first ` -->` after it. Only a `<!--` in `text` can forge that opener
        // and shift the boundary; a `-->` in text always sits BEFORE the real
        // opener, so it can never collide. Cluster 1 / INFO fix: neutralize the
        // comment-OPEN only, and leave `-->` untouched so ordinary arrows (e.g.
        // calendar-sourced titles via SC4 sync) round-trip byte-identical
        // instead of being irreversibly rewritten to `->` on every serialize.
        let safeText = task.text
            .replacingOccurrences(of: "<!--", with: "<!-")
        return "- [\(state)] \(safeText) <!-- \(meta) -->"
    }

    /// Renders one Jotty note block (`### HH:mm <!-- id:n_… -->` header + body)
    /// WITHOUT leading/trailing newlines; the caller owns the surrounding blank
    /// lines. Mirrors a `NoteSpan.originalText`'s header+body shape so a changed
    /// note re-renders into the same slot.
    private func renderNoteBlock(_ note: Note, timezone: TimeZone) -> String {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        timeFmt.timeZone = timezone
        return "### \(timeFmt.string(from: note.time)) <!-- id:\(note.id) -->\n\(note.text)"
    }

    /// Re-renders the frontmatter block from `date` alone. Only reachable for a
    /// fresh/date-mismatch doc; a parsed doc's `date` is `let` (A1) so
    /// `f.date == self.date` always holds and `originalBlock` is reused instead
    /// (preserving `created:` + any unknown keys). Fresh docs route through
    /// `canonicalSynthesize`, so this is a defensive fallback only.
    private func reRenderFrontmatter(timezone: TimeZone) -> String {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        dateFmt.timeZone = timezone
        let isoFmt = ISO8601DateFormatter()
        isoFmt.timeZone = timezone
        isoFmt.formatOptions = [.withInternetDateTime]
        return "---\ndate: \(dateFmt.string(from: date))\ncreated: \(isoFmt.string(from: date))\n---"
    }

    /// Populated-skeleton path: walk the captured spans in ORIGINAL ORDER and
    /// reconcile each Jotty span against the live `tasks`/`notes` arrays by id.
    /// Each emitted span contributes one element to `parts`; joining with "\n"
    /// reinserts the line-boundary newlines that `parse` consumed via
    /// `components(separatedBy:)`, so an untouched doc reconstructs
    /// byte-identically and a deleted span drops exactly its line plus the single
    /// terminating newline (P-Delete). New-id injection (SC4) is layered on in
    /// Task 2; this walk emits only existing spans.
    private func reconcileWalk(timezone: TimeZone) -> String {
        let liveTask = Dictionary(tasks.map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
        let liveNote = Dictionary(notes.map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })

        var parts: [String] = []
        for span in spans {
            switch span {
            case .raw(let s):
                parts.append(s)
            case .frontmatter(let f):
                parts.append(f.date == date
                    ? f.originalBlock
                    : reRenderFrontmatter(timezone: timezone))
            case .taskLine(let ts):
                guard let live = liveTask[ts.pristine.id] else { continue }  // id gone → omit
                parts.append(live == ts.pristine
                    ? ts.originalText
                    : renderTaskLine(live, unknownTokens: ts.unknownTokens, timezone: timezone))
            case .note(let ns):
                guard let live = liveNote[ns.pristine.id] else { continue }  // note removed → omit
                parts.append(live == ns.pristine
                    ? ns.originalText
                    : renderNoteBlock(live, timezone: timezone))
            }
        }
        return parts.joined(separator: "\n")
    }

    static func parse(_ rawText: String, timezone: TimeZone = .current) throws -> MarkdownDoc {
        // Cluster 1 / WARNING: normalize line endings BEFORE any regex. The note
        // header/body patterns match `-->\n` (LF only), so a CRLF- or CR-saved
        // daily file otherwise loses every note (tasks survive). Collapse \r\n
        // and lone \r to \n once, up front, so all downstream matching is LF.
        let text = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

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

        let calendar = DailyFile.calendar(timezone: timezone)

        // Line-oriented tokenizer: assign every line to exactly one ordered
        // Span (phase 10-01). Replaces the three whole-file `matches(of:)`
        // sweeps that discarded document order + interstitial content. The three
        // classifiers below are the same regexes, now applied per line/block.
        let taskRegex = /- \[(.)\] (.*?) <!-- (.+?) -->/
        // A note header is a WHOLE line "### HH:mm <!-- id:<non-space> -->".
        let noteHeaderRegex = /^### (\d{2}):(\d{2}) <!-- id:([^ ]+) -->/

        let lines = text.components(separatedBy: "\n")
        var pendingRaw: [String] = []

        // Coalesce a run of consecutive non-Jotty lines (prose, blanks, `##`
        // headers, foreign checkboxes, the tail) into a single `.raw` span.
        func flushRaw() {
            if !pendingRaw.isEmpty {
                doc.spans.append(.raw(pendingRaw.joined(separator: "\n")))
                pendingRaw.removeAll(keepingCapacity: true)
            }
        }

        var i = 0

        // Frontmatter head block: "---" … "---" at the top, captured VERBATIM so
        // plan 02's serialize can reuse `created:` + any unknown keys instead of
        // re-deriving them (L1/L2 fix). `date` is Jotty-owned (== doc.date).
        if lines.first == "---", let close = lines[1...].firstIndex(of: "---") {
            doc.spans.append(.frontmatter(FrontmatterSpan(
                originalBlock: lines[0...close].joined(separator: "\n"),
                date: parsedDate)))
            i = close + 1
        }

        while i < lines.count {
            let line = lines[i]

            // Note block: header line + body up to the terminator — the next real
            // note header, the next `## ` H2 section, or EOF (I2). A non-note
            // `### heading` inside the body stays put; a trailing foreign `## `
            // section is NOT swallowed (the Obsidian-fixture regression).
            if let nh = line.firstMatch(of: noteHeaderRegex) {
                flushRaw()
                var j = i + 1
                while j < lines.count {
                    let bodyLine = lines[j]
                    if bodyLine.firstMatch(of: noteHeaderRegex) != nil { break }
                    if bodyLine.hasPrefix("## ") { break }
                    j += 1
                }
                let originalText = lines[i..<j].joined(separator: "\n")
                let body = lines[(i + 1)..<j].joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let h = Int(nh.1)!
                let m = Int(nh.2)!
                let id = String(nh.3)
                var comps = calendar.dateComponents([.year, .month, .day], from: parsedDate)
                comps.hour = h
                comps.minute = m
                let time = calendar.date(from: comps) ?? parsedDate

                let note = Note(id: id, time: time, text: body)
                doc.spans.append(.note(NoteSpan(pristine: note, originalText: originalText)))
                doc.notes.append(note)
                i = j
                continue
            }

            // Task line: matches the task regex AND yields a non-empty `id:`
            // (mirror the L165 match + L255 empty-id guard). Otherwise the line
            // is foreign (P-Foreign) and falls through to `.raw` — never adopted.
            if let tm = line.firstMatch(of: taskRegex),
               let (todo, unknown) = parseTaskLine(state: String(tm.1),
                                                    text: String(tm.2),
                                                    metaBlob: String(tm.3),
                                                    on: parsedDate,
                                                    calendar: calendar) {
                flushRaw()
                doc.spans.append(.taskLine(TaskSpan(pristine: todo,
                                                    originalText: line,
                                                    unknownTokens: unknown)))
                doc.tasks.append(todo)
                i += 1
                continue
            }

            pendingRaw.append(line)
            i += 1
        }
        flushRaw()
        return doc
    }

    /// Parses one recognized Jotty task line's `<state> text <!-- meta -->` into
    /// its Todo plus the unrecognized `key:value` tokens (captured in file order,
    /// SC3). Returns nil when the meta blob carries no non-empty `id:` (the L255
    /// guard) so the caller classifies the line as a foreign `.raw` span.
    private static func parseTaskLine(state stateChar: String,
                                      text taskText: String,
                                      metaBlob: String,
                                      on parsedDate: Date,
                                      calendar: Calendar) -> (Todo, [String])? {
        let isoFmt = ISO8601DateFormatter()
        let dateOnlyFmt = DateFormatter()
        dateOnlyFmt.dateFormat = "yyyy-MM-dd"
        dateOnlyFmt.timeZone = calendar.timeZone

        var id = ""
        var createdAt: Date = parsedDate
        // WR-04/I6: accept uppercase X as done — hand-edited markdown (and many
        // editors' checkbox toggles) writes `- [X]`; parsing it as not-done would
        // silently rewrite the user's completion state as `- [ ]` on re-serialize.
        let done = stateChar.lowercased() == "x"
        var completedAt: Date? = nil
        var dueDate: Date? = nil
        var rolledTo: Date? = nil
        var sourceNote: String? = nil
        var timeBlock: TimeBlock? = nil
        var calEventID: String? = nil
        var source: String? = nil
        var sourceURL: String? = nil
        var recur: Recurrence? = nil
        var recurSrc: String? = nil
        var snooze: Date? = nil
        var unknownTokens: [String] = []

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
                   var endDate = absoluteTime(String(halves[1]),
                                              on: parsedDate, calendar: calendar) {
                    // I3: a wall-clock end at/before its start crossed midnight in
                    // the pinned timezone (e.g. 23:00-00:00) — roll the end forward
                    // one day so the interval survives round-trip in any zone.
                    if endDate < startDate {
                        endDate = calendar.date(byAdding: .day, value: 1, to: endDate) ?? endDate
                    }
                    timeBlock = TimeBlock(start: startDate, end: endDate)
                }
            case "cal_event":
                calEventID = value
            case "source":
                source = value
            case "source_url":
                sourceURL = value
            case "recur":
                // I8/T-8-02: a hand-edited malformed rule parses to nil — the task
                // degrades to non-recurring rather than crashing.
                recur = Recurrence.parse(value)
            case "recur_src":
                recurSrc = value
            case "snooze":
                snooze = dateOnlyFmt.date(from: value)
            default:
                // SC3 capture: a well-formed `key:value` with an UNRECOGNIZED key
                // (e.g. `priority:high`) is captured verbatim instead of discarded,
                // so plan 02's serialize can re-emit it on a rewrite of this line.
                unknownTokens.append(String(token))
            }
        }

        guard !id.isEmpty else { return nil }

        let todo = Todo(id: id, text: taskText, createdAt: createdAt,
                        done: done, completedAt: completedAt,
                        dueDate: dueDate, rolledTo: rolledTo, sourceNote: sourceNote,
                        timeBlock: timeBlock, calEventID: calEventID,
                        source: source, sourceURL: sourceURL,
                        recur: recur, recurSrc: recurSrc, snooze: snooze)
        return (todo, unknownTokens)
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
