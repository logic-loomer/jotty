import XCTest
@testable import Jotty

/// Phase 9 plan 01 / SC2 (CMDB-02): the pure `FuzzyScorer` subsequence scorer.
/// Weights are PINNED so ranking drift is caught: per matched char +16 word-start
/// (index 0 or preceded by space/-/_ / /.), else +8 consecutive-with-previous-match,
/// else +1 (word-start takes precedence over consecutive); -1 per unmatched candidate
/// char before the FIRST match floored at -9; +10 folded-prefix bonus. Both sides are
/// folded once with case+diacritic-insensitive, locale-nil folding (deterministic).
/// nil = query is not a subsequence of the candidate. Empty query scores 0.
final class FuzzyScorerTests: XCTestCase {

    // MARK: - Pinned weight values

    func testWordStartPlusNonConsecutiveMatch() {
        // "td" in "today": t at index 0 (word-start +16), d at index 2
        // (not consecutive, not word-start: +1). No leading penalty, no prefix.
        XCTAssertEqual(FuzzyScorer.score(query: "td", candidate: "today"), 17)
    }

    func testConsecutiveRunWithPrefixBonus() {
        // "tod" in "today": t +16, o consecutive +8, d consecutive +8, prefix +10.
        XCTAssertEqual(FuzzyScorer.score(query: "tod", candidate: "today"), 42)
    }

    func testWordStartAfterHyphenSeparator() {
        // "cb" in "command-bar": c word-start +16, b word-start after '-' +16.
        XCTAssertEqual(FuzzyScorer.score(query: "cb", candidate: "command-bar"), 32)
    }

    func testWordStartAfterEachSeparator() {
        // The char AFTER each of space / - / _ / '/' / . counts as a word start:
        // +16 for the match, -2 leading penalty ("a" + separator unmatched) = 14.
        XCTAssertEqual(FuzzyScorer.score(query: "x", candidate: "a x"), 14)
        XCTAssertEqual(FuzzyScorer.score(query: "x", candidate: "a-x"), 14)
        XCTAssertEqual(FuzzyScorer.score(query: "x", candidate: "a_x"), 14)
        XCTAssertEqual(FuzzyScorer.score(query: "x", candidate: "a/x"), 14)
        XCTAssertEqual(FuzzyScorer.score(query: "x", candidate: "a.x"), 14)
    }

    // MARK: - Leading penalty

    func testLeadingUnmatchedCharsPenalize() {
        // "k" in "task": match at index 3 (+1); 3 unmatched chars before the
        // first match penalize -3 -> total -2.
        XCTAssertEqual(FuzzyScorer.score(query: "k", candidate: "task"), -2)
    }

    func testLeadingPenaltyFloorsAtMinusNine() {
        // 12 unmatched chars before the first match still only cost -9:
        // match +1, floor -9 -> -8.
        let candidate = String(repeating: "a", count: 12) + "z"
        XCTAssertEqual(FuzzyScorer.score(query: "z", candidate: candidate), -8)
    }

    // MARK: - Non-subsequence rejection

    func testNonSubsequenceReturnsNil() {
        XCTAssertNil(FuzzyScorer.score(query: "xyz", candidate: "today"))
    }

    func testQueryLongerThanRemainingMatchesReturnsNil() {
        XCTAssertNil(FuzzyScorer.score(query: "todayy", candidate: "today"))
    }

    // MARK: - Folding

    func testCaseFoldingMatchesRegardlessOfCase() {
        XCTAssertEqual(FuzzyScorer.score(query: "TOD", candidate: "today"),
                       FuzzyScorer.score(query: "tod", candidate: "today"))
    }

    func testDiacriticFoldingMatchesAccentedCandidate() {
        let accented = FuzzyScorer.score(query: "cafe", candidate: "café")
        XCTAssertNotNil(accented)
        // Folding happens ONCE on both sides, so the accented candidate scores
        // identically to its plain form (including the prefix bonus).
        XCTAssertEqual(accented, FuzzyScorer.score(query: "cafe", candidate: "cafe"))
    }

    // MARK: - Empty inputs

    func testEmptyQueryScoresZeroAgainstAnyCandidate() {
        XCTAssertEqual(FuzzyScorer.score(query: "", candidate: "today"), 0)
        XCTAssertEqual(FuzzyScorer.score(query: "", candidate: ""), 0)
        XCTAssertEqual(FuzzyScorer.score(query: "", candidate: "command-bar"), 0)
    }

    func testEmptyCandidateWithNonEmptyQueryReturnsNil() {
        XCTAssertNil(FuzzyScorer.score(query: "a", candidate: ""))
    }

    // MARK: - Determinism

    func testScoreIsDeterministicAcrossRepeatedCalls() {
        let pairs: [(String, String)] = [
            ("td", "today"),
            ("cb", "command-bar"),
            ("k", "task"),
            ("cafe", "café"),
            ("", "anything"),
            ("xyz", "today"),
        ]
        for (query, candidate) in pairs {
            let first = FuzzyScorer.score(query: query, candidate: candidate)
            for _ in 0..<5 {
                XCTAssertEqual(FuzzyScorer.score(query: query, candidate: candidate), first,
                               "score(\(query), \(candidate)) must be deterministic")
            }
        }
    }
}
