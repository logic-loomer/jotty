import Foundation

/// Ordered document skeleton for a day file (phase 10 — lossless round-trip).
///
/// `MarkdownDoc.parse` classifies every line/block of a day file into exactly
/// one ordered `Span`, capturing DOCUMENT ORDER plus every byte the old
/// three-regex parser used to discard (foreign prose, plain non-Jotty
/// checkboxes, unknown `##`/`###` sections, blank lines, the document tail, and
/// unrecognized per-task `key:value` tokens). Plan 10-01 only CAPTURES this
/// skeleton; plan 10-02's span-aware `serialize` is the consumer that
/// reconciles it back to bytes. Until then `serialize` still rebuilds from the
/// flat `tasks`/`notes` projections, so the suite stays green.
///
/// Frozen enum, one case per span kind.
enum Span: Equatable {
    case frontmatter(FrontmatterSpan)
    case taskLine(TaskSpan)
    case note(NoteSpan)
    /// Verbatim passthrough: prose, blank lines, foreign checkboxes, unknown
    /// `##`/`###` sections, the `## Tasks`/`## Notes` HEADER lines themselves,
    /// and the document tail. Byte-for-byte (LF-normalized).
    case raw(String)
}

/// The frontmatter head block. `date` is Jotty-owned (equals `MarkdownDoc.date`);
/// `created` and any unknown keys live INSIDE `originalBlock` and are reused
/// verbatim on serialize (never re-derived).
struct FrontmatterSpan: Equatable {
    /// The exact `---\n…\n---` text incl. both delimiter lines (LF-normalized).
    let originalBlock: String
    /// The parsed frontmatter `date` (Jotty-owned).
    let date: Date
}

/// A recognized Jotty task line (`- [x] text <!-- id:… … -->`).
struct TaskSpan: Equatable {
    /// The Todo exactly as parsed from this line.
    let pristine: Todo
    /// The exact source line, WITHOUT the trailing `\n`.
    let originalText: String
    /// Unrecognized `key:value` tokens, in file order (e.g. `priority:high`),
    /// captured verbatim instead of being discarded (SC3 capture half).
    let unknownTokens: [String]
}

/// A recognized Jotty note (`### HH:mm <!-- id:n_… -->` header + body).
struct NoteSpan: Equatable {
    /// The Note exactly as parsed.
    let pristine: Note
    /// The exact source block (header + body), verbatim, no trailing `\n`.
    let originalText: String
}
