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
    /// POSIX/Gregorian-pinned formatter for every machine-readable key this file
    /// writes or parses (DailyFile discipline, WR): an unpinned `yyyy` under a
    /// Buddhist/Japanese region calendar writes era-shifted years (`2569-07-11`)
    /// into frontmatter/tokens that a Gregorian parse cannot map back — and the
    /// mixed pinned/unpinned state made a file written under one region setting
    /// unreadable under another. ISO8601DateFormatter is inherently pinned.
    ///
    /// Known limitation (same class as `Store.allDayDates`' documented filename
    /// case, accepted): a token value written era-shifted by a PRE-pin build under
    /// a non-Gregorian region (`due:2569-07-11`) still parses — as Gregorian year
    /// 2569, a far-future date — and is not migrated.
    private static func pinnedFormatter(_ format: String, timezone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = DailyFile.calendar(timezone: timezone)
        f.dateFormat = format
        f.timeZone = timezone
        return f
    }

    private func canonicalSynthesize(timezone: TimeZone) -> String {
        let dateFmt = Self.pinnedFormatter("yyyy-MM-dd", timezone: timezone)

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
        let timeFmt = Self.pinnedFormatter("HH:mm", timezone: timezone)
        let isoFmt = ISO8601DateFormatter()
        isoFmt.timeZone = timezone
        isoFmt.formatOptions = [.withInternetDateTime]
        let dateOnlyFmt = Self.pinnedFormatter("yyyy-MM-dd", timezone: timezone)

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
            // The bare wall-clock form re-anchors onto the DOC's day at parse time, so
            // a block on any other day (e.g. an "@tomorrow @3pm" capture written into
            // today's file) silently shifted to the doc's day on the next reload while
            // its calendar event stayed put — the drift pass then falsely reported the
            // event deleted. Day-qualify the token whenever the block's start day is
            // not the doc's day; same-day blocks keep the bare form byte-identical.
            let cal = DailyFile.calendar(timezone: timezone)
            if cal.startOfDay(for: tb.start) == cal.startOfDay(for: date) {
                meta += " time:\(timeFmt.string(from: tb.start))-\(timeFmt.string(from: tb.end))"
            } else {
                meta += " time:\(dateOnlyFmt.string(from: tb.start))T"
                    + "\(timeFmt.string(from: tb.start))-\(timeFmt.string(from: tb.end))"
            }
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
        let timeFmt = Self.pinnedFormatter("HH:mm", timezone: timezone)
        return "### \(timeFmt.string(from: note.time)) <!-- id:\(note.id) -->\n\(note.text)"
    }

    /// Re-renders the frontmatter block from `date` alone. Only reachable for a
    /// fresh/date-mismatch doc; a parsed doc's `date` is `let` (A1) so
    /// `f.date == self.date` always holds and `originalBlock` is reused instead
    /// (preserving `created:` + any unknown keys). Fresh docs route through
    /// `canonicalSynthesize`, so this is a defensive fallback only.
    private func reRenderFrontmatter(timezone: TimeZone) -> String {
        let dateFmt = Self.pinnedFormatter("yyyy-MM-dd", timezone: timezone)
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
    /// terminating newline (P-Delete). After the ordered walk, brand-new live ids
    /// (present in `tasks`/`notes` but carried by no span) are injected into their
    /// `## Tasks`/`## Notes` region — after the last existing task/note line, or
    /// (region emptied/absent) after the header or synthesized at the canonical
    /// position — WITHOUT moving any foreign `raw` span (SC4, P-Insert).
    private func reconcileWalk(timezone: TimeZone) -> String {
        // WR-01: group live tasks by id in array order so N spans sharing an id map
        // POSITIONALLY to N live tasks (not all to the first). Previously a by-id
        // dictionary collapsed duplicates, so the second same-id span re-rendered as
        // the first — silent data loss and a dup-id file was not byte-stable. With
        // per-id occurrence tracking the k-th span pairs to the k-th live entry.
        var liveTasksByID: [String: [Todo]] = [:]
        for t in tasks { liveTasksByID[t.id, default: []].append(t) }
        var taskOccurrence: [String: Int] = [:]
        // Same WR-01 positional grouping for NOTES: a sync-conflict merge (or a
        // copy-pasted note block keeping its `<!-- id:… -->` header) leaves two note
        // spans with one id, and the old first-wins dictionary re-rendered the second
        // as a copy of the first on the next write — silent body loss.
        var liveNotesByID: [String: [Note]] = [:]
        for n in notes { liveNotesByID[n.id, default: []].append(n) }
        var noteOccurrence: [String: Int] = [:]

        // Ids the skeleton already carries a span for — everything else in the
        // live arrays is brand-new and gets injected below (SC4).
        var spanTaskIDs: Set<String> = []
        var spanNoteIDs: Set<String> = []
        for span in spans {
            if case .taskLine(let ts) = span { spanTaskIDs.insert(ts.pristine.id) }
            if case .note(let ns) = span { spanNoteIDs.insert(ns.pristine.id) }
        }

        // Injection anchors (indices into `parts`), captured during the walk: the
        // last emitted task/note line; the raw span carrying each `## Tasks`/
        // `## Notes` header (fallback when a region emitted no live line, e.g.
        // replaceTasks emptied it); and the frontmatter position (last resort for
        // synthesizing an absent section at the canonical spot — P-Insert).
        var lastTaskIdx: Int? = nil
        var lastNoteIdx: Int? = nil
        var tasksHeaderIdx: Int? = nil
        var notesHeaderIdx: Int? = nil
        var frontmatterIdx: Int? = nil

        var parts: [String] = []
        for span in spans {
            switch span {
            case .raw(let s):
                parts.append(s)
                // The `## Tasks`/`## Notes` header lines live inside a raw span
                // (the tokenizer never adopts them). Record the FIRST raw carrying
                // each header as the fallback injection anchor.
                let rawLines = s.split(separator: "\n", omittingEmptySubsequences: false)
                if tasksHeaderIdx == nil,
                   rawLines.contains(where: { Self.sectionHeader(of: String($0)) == "## Tasks" }) {
                    tasksHeaderIdx = parts.count - 1
                }
                if notesHeaderIdx == nil,
                   rawLines.contains(where: { Self.sectionHeader(of: String($0)) == "## Notes" }) {
                    notesHeaderIdx = parts.count - 1
                }
            case .frontmatter(let f):
                parts.append(f.date == date
                    ? f.originalBlock
                    : reRenderFrontmatter(timezone: timezone))
                frontmatterIdx = parts.count - 1
            case .taskLine(let ts):
                let tid = ts.pristine.id
                let k = taskOccurrence[tid, default: 0]
                // id gone (or fewer live copies than spans → this duplicate deleted): omit.
                guard let group = liveTasksByID[tid], k < group.count else { continue }
                let live = group[k]
                taskOccurrence[tid] = k + 1
                parts.append(live == ts.pristine
                    ? ts.originalText
                    : renderTaskLine(live, unknownTokens: ts.unknownTokens, timezone: timezone))
                lastTaskIdx = parts.count - 1
            case .note(let ns):
                let nid = ns.pristine.id
                let k = noteOccurrence[nid, default: 0]
                // id gone (or fewer live copies than spans → this duplicate deleted): omit.
                guard let group = liveNotesByID[nid], k < group.count else { continue }
                let live = group[k]
                noteOccurrence[nid] = k + 1
                parts.append(live == ns.pristine
                    ? ns.originalText
                    : renderNoteBlock(live, timezone: timezone))
                lastNoteIdx = parts.count - 1
            }
        }

        // SC4 new-id injection. Notes FIRST (they sit lower in the document, so
        // inserting them cannot shift the task anchors computed above); tasks
        // second. `filter` preserves live-array order (P-Insert order).
        let newNotes = notes.filter { !spanNoteIDs.contains($0.id) }
        if !newNotes.isEmpty {
            // Prefix each block with "\n" so the "\n" part-join yields the canonical
            // blank line between note blocks (matches canonicalSynthesize spacing).
            let rendered = newNotes.map { "\n" + renderNoteBlock($0, timezone: timezone) }
            if let idx = lastNoteIdx ?? notesHeaderIdx {
                parts.insert(contentsOf: rendered, at: idx + 1)
            } else {
                // No `## Notes` region anywhere → synthesize it after the task
                // region (canonical: Notes follow Tasks), else after frontmatter.
                let anchor = lastTaskIdx ?? tasksHeaderIdx ?? frontmatterIdx ?? -1
                parts.insert(contentsOf: ["\n## Notes\n"] + rendered, at: anchor + 1)
            }
        }

        let newTasks = tasks.filter { !spanTaskIDs.contains($0.id) }
        if !newTasks.isEmpty {
            let rendered = newTasks.map { renderTaskLine($0, unknownTokens: [], timezone: timezone) }
            if let idx = lastTaskIdx ?? tasksHeaderIdx {
                parts.insert(contentsOf: rendered, at: idx + 1)
            } else {
                // No `## Tasks` region → synthesize at the canonical position:
                // immediately after frontmatter, before any foreign body span
                // (and before a `## Notes` that may have just been injected).
                let anchor = frontmatterIdx ?? -1
                parts.insert(contentsOf: ["\n## Tasks\n"] + rendered, at: anchor + 1)
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

        let dateFmt = pinnedFormatter("yyyy-MM-dd", timezone: timezone)

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

            // CR-01/WR-02: emit a `## Tasks`/`## Notes` header line as its OWN raw
            // span so serialize's injection anchor is line-precise. Otherwise a bare
            // header coalesces with the downstream tail (incl. the NEXT header) into
            // one span, and a new task injected after `## Tasks` lands under `## Notes`.
            // Splitting at an existing `\n` boundary is byte-neutral (reconcileWalk
            // re-joins with "\n"). The header line is captured VERBATIM (trailing
            // whitespace preserved for byte-stability) but recognized via
            // `sectionHeader` which ignores trailing whitespace (WR-02) so a
            // near-canonical `## Tasks ` is reused, not duplicated.
            if MarkdownDoc.sectionHeader(of: line) != nil {
                flushRaw()
                doc.spans.append(.raw(line))
                i += 1
                continue
            }

            pendingRaw.append(line)
            i += 1
        }
        flushRaw()
        return doc
    }

    /// Returns the canonical section header (`## Tasks`/`## Notes`) a line denotes,
    /// ignoring trailing whitespace (WR-02), else nil. Shared by `parse` (to break
    /// the header onto its own raw span) and `reconcileWalk` (to recognize the
    /// injection anchor) so a near-canonical header is reused, never duplicated.
    private static func sectionHeader(of line: String) -> String? {
        let trimmed = line.replacingOccurrences(of: "\\s+$", with: "",
                                                options: .regularExpression)
        if trimmed == "## Tasks" { return "## Tasks" }
        if trimmed == "## Notes" { return "## Notes" }
        return nil
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
        let dateOnlyFmt = pinnedFormatter("yyyy-MM-dd", timezone: calendar.timeZone)

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
                // Two forms: bare "HH:mm-HH:mm" (block on the doc's own day) and
                // day-qualified "yyyy-MM-ddTHH:mm-HH:mm" (block on another day —
                // e.g. an "@tomorrow @3pm" capture; the bare form re-anchored such
                // a block onto the doc's day, silently shifting it).
                var blockDay = parsedDate
                var clock = value
                if value.count > 11,
                   value[value.index(value.startIndex, offsetBy: 10)] == "T",
                   let qualified = dateOnlyFmt.date(from: String(value.prefix(10))) {
                    blockDay = qualified
                    clock = String(value.dropFirst(11))
                }
                let halves = clock.split(separator: "-", maxSplits: 1)
                if halves.count == 2,
                   let startDate = absoluteTime(String(halves[0]),
                                                on: blockDay, calendar: calendar),
                   var endDate = absoluteTime(String(halves[1]),
                                              on: blockDay, calendar: calendar) {
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
