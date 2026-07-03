import Foundation

/// Pure subsequence scorer for the ⌘K command palette (SC2 ranking core, CMDB-02).
///
/// Greedy left-to-right variant of fts_fuzzy_match (Forrest Smith): every query
/// character must appear in order in the candidate, or the result is `nil`.
/// Both sides are folded ONCE with case+diacritic-insensitive, locale-nil folding,
/// which is what makes scoring deterministic and locale-independent (RESEARCH
/// §Fuzzy Scorer). No I/O, no state — exhaustively unit-testable.
///
/// Pinned weights (tests assert exact values — change them only with the tests):
/// - +16 per matched char at a word start (index 0 or preceded by space/`-`/`_`/`/`/`.`);
///   word-start takes precedence over consecutive — a char never gets both.
/// - +8 per matched char consecutive with the previous match.
/// - +1 per any other matched char.
/// - -1 per unmatched candidate char before the FIRST match, floored at -9.
/// - +10 when the folded candidate has the folded query as a prefix.
/// - Empty query → 0 (matches everything; no prefix bonus).
enum FuzzyScorer {

    /// Characters whose FOLLOWING character counts as a word start.
    private static let wordSeparators: Set<Character> = [" ", "-", "_", "/", "."]

    /// nil = query is not a subsequence of candidate. Higher = better. Deterministic.
    static func score(query: String, candidate: String) -> Int? {
        let q = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let c = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)

        // Empty query matches everything at 0 — no prefix bonus (hasPrefix("") is
        // true for every string, so this MUST short-circuit before the bonus).
        guard !q.isEmpty else { return 0 }

        var total = 0
        var qi = q.startIndex
        var prevMatched = false
        var leading = 0

        for ci in c.indices {
            guard qi < q.endIndex else { break }
            if c[ci] == q[qi] {
                if isWordStart(in: c, at: ci) {
                    total += 16   // word-start precedence over consecutive
                } else if prevMatched {
                    total += 8
                } else {
                    total += 1
                }
                prevMatched = true
                qi = q.index(after: qi)
            } else {
                if qi == q.startIndex { leading += 1 }
                prevMatched = false
            }
        }

        guard qi == q.endIndex else { return nil }   // not a subsequence

        total -= min(leading, 9)
        if c.hasPrefix(q) { total += 10 }
        return total
    }

    /// A word start is index 0 or a char preceded by one of `wordSeparators`.
    private static func isWordStart(in s: String, at i: String.Index) -> Bool {
        guard i > s.startIndex else { return true }
        return wordSeparators.contains(s[s.index(before: i)])
    }
}
