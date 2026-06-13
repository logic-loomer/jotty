// JottyTests/AI/FixtureComparator.swift
// Pure comparator implementing AI-SPEC §5.3 rules + greedy bipartite task matcher.
// No XCTest imports — usable from both the harness and unit tests.

import Foundation
@testable import Jotty

enum FixtureComparator {

    // MARK: - Field comparators

    /// Stop-words dropped before semantic comparison.
    private static let stopWords: Set<String> = ["the", "a", "an", "for", "to", "on", "block"]

    /// Tokenize, lowercase, drop stop-words, return word set.
    private static func contentWords(_ s: String) -> Set<String> {
        let tokens = s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        return Set(tokens.filter { !stopWords.contains($0) })
    }

    /// Jaccard similarity of two word sets.
    private static func jaccardSimilarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        guard union > 0 else { return 1.0 }
        return Double(intersection) / Double(union)
    }

    /// PASS if:
    ///   (a) substring match after normalization, OR
    ///   (b) Jaccard of content-word sets ≥ 0.6 (tolerates stop-word differences)
    /// AND length-ratio check: actual length within [0.6 × expected, 1.6 × expected].
    ///
    /// Phase 3 two-arg form — preserved by delegating to the tolerance-aware
    /// overload with the Phase 3 baseline thresholds (AI-SPEC §7.3). Existing
    /// call sites are unchanged.
    static func compareTitle(actual: String, expected: String) -> String? {
        compareTitle(actual: actual, expected: expected,
                     tolerance: ProviderToleranceConfig.baseline)
    }

    /// Same algorithm + stop-word list as the Phase 3 comparator; only the
    /// numeric thresholds (Jaccard floor + length-ratio window) come from
    /// `tolerance` (AI-SPEC §7.3).
    static func compareTitle(actual: String, expected: String,
                             tolerance: ProviderTolerance) -> String? {
        let na = normalize(actual)
        let ne = normalize(expected)

        let lo = tolerance.titleLengthRatio.lowerBound
        let hi = tolerance.titleLengthRatio.upperBound
        let jaccardMin = tolerance.titleJaccardMin

        // Length-ratio gate.
        let minLen = Int(Double(ne.count) * lo)
        let maxLen = Int(Double(ne.count) * hi)
        if na.count > maxLen {
            return "title too long: actual '\(na)' (\(na.count) chars) > \(hi)× expected '\(ne)' (\(ne.count) chars, max \(maxLen))"
        }
        if na.count < minLen && !ne.isEmpty {
            return "title too short: actual '\(na)' (\(na.count) chars) < \(lo)× expected '\(ne)' (\(ne.count) chars, min \(minLen))"
        }

        // Substring match (original check).
        if na.contains(ne) { return nil }

        // Stop-word-stripped substring check.
        let aWords = contentWords(actual)
        let eWords = contentWords(expected)
        let aStripped = aWords.sorted().joined(separator: " ")
        let eStripped = eWords.sorted().joined(separator: " ")
        if aStripped.contains(eStripped) || eStripped.contains(aStripped) { return nil }

        // Jaccard fallback.
        let jaccard = jaccardSimilarity(aWords, eWords)
        if jaccard >= jaccardMin { return nil }

        return "title mismatch: actual '\(na)' vs expected '\(ne)' (Jaccard=\(String(format: "%.2f", jaccard)) < \(jaccardMin), no substring match after stop-word removal)"
    }

    /// Both nil → pass; one nil one set → fail; both set → compare yyyy-MM-dd in `tz`.
    static func compareDueDate(actual: Date?, expected: String?, tz: TimeZone) -> String? {
        switch (actual, expected) {
        case (.none, .none):
            return nil
        case (.some(let a), .none):
            return "dueDate should be nil, got \(dayString(a, tz: tz))"
        case (.none, .some(let e)):
            return "dueDate should be '\(e)', got nil"
        case (.some(let a), .some(let e)):
            let got = dayString(a, tz: tz)
            return got == e ? nil : "dueDate mismatch: expected '\(e)' got '\(got)'"
        }
    }

    /// Both nil → pass; expected nil + actual set → fail; expected set → compare ISO start/end.
    static func compareTimeBlock(
        actual: TimeBlock?,
        expectedStart: String?,
        expectedEnd: String?
    ) -> String? {
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withTimeZone]

        switch (actual, expectedStart, expectedEnd) {
        case (.none, .none, _):
            return nil
        case (.some, .none, _):
            return "timeBlock should be nil, got a block"
        case (.none, .some(let s), _):
            return "timeBlock should be set (start=\(s)), got nil"
        case (.some(let a), .some(let expStart), .some(let expEnd)):
            guard let eStart = isoFmt.date(from: expStart),
                  let eEnd = isoFmt.date(from: expEnd) else {
                return "timeBlock: could not parse expected ISO-8601 '\(expStart)' / '\(expEnd)'"
            }
            var msgs: [String] = []
            if abs(a.start.timeIntervalSince(eStart)) > 1 {
                msgs.append("timeBlock.start: expected \(expStart) got \(isoFmt.string(from: a.start))")
            }
            if abs(a.end.timeIntervalSince(eEnd)) > 1 {
                msgs.append("timeBlock.end: expected \(expEnd) got \(isoFmt.string(from: a.end))")
            }
            return msgs.isEmpty ? nil : msgs.joined(separator: "; ")
        case (.some, .some(let s), .none):
            return "timeBlock: expectedStart '\(s)' present but expectedEnd missing in fixture"
        }
    }

    static func compareTaskCount(actual: Int, expected: Int) -> String? {
        actual == expected ? nil : "task count mismatch: actual=\(actual) expected=\(expected)"
    }

    /// Whitespace-normalized substring.
    static func compareNoteBody(actual: String, expected: String) -> String? {
        let ne = normalize(expected)
        guard !ne.isEmpty else { return nil }
        return normalize(actual).contains(ne)
            ? nil
            : "note_body missing expected substring '\(ne)'"
    }

    static func compareCalendarBlock(actual: Bool, expected: Bool) -> String? {
        actual == expected ? nil : "calendarBlock mismatch: actual=\(actual) expected=\(expected)"
    }

    // MARK: - Greedy task matcher

    /// Element of a match result. The harness validates field-level rules
    /// only on `.matched` pairs; `.unmatched` and `.extra` are themselves
    /// failures.
    enum Pair<A, E> {
        case matched(actual: A, expected: E)
        case unmatched(expected: E)
        case extra(actual: A)
    }

    /// Pair actual ↔ expected via greedy title-overlap. For each expected task
    /// in declared order, pick the unmatched actual task whose normalized title
    /// overlaps the expected title the most (substringScore). Tie-break by
    /// proximity of lengths. An expected with no overlapping candidate becomes
    /// `.unmatched`. Leftover actuals become `.extra`.
    static func matchTasks<A, E>(
        actual: [A],
        expected: [E],
        actualTitle: (A) -> String,
        expectedTitle: (E) -> String
    ) -> [Pair<A, E>] {
        var unmatched = Array(actual.indices)
        var pairs: [Pair<A, E>] = []

        for exp in expected {
            let expNorm = normalize(expectedTitle(exp))
            let bestIdx = unmatched.max { lhs, rhs in
                substringScore(normalize(actualTitle(actual[lhs])), expNorm) <
                substringScore(normalize(actualTitle(actual[rhs])), expNorm)
            }
            guard let idx = bestIdx,
                  substringScore(normalize(actualTitle(actual[idx])), expNorm) > 0
            else {
                pairs.append(.unmatched(expected: exp))
                continue
            }
            pairs.append(.matched(actual: actual[idx], expected: exp))
            unmatched.removeAll { $0 == idx }
        }
        for i in unmatched { pairs.append(.extra(actual: actual[i])) }
        return pairs
    }

    // MARK: - Helpers

    /// Crude scoring: if `actualNorm` contains `expNorm` as a substring, score is
    /// expNorm.count + 1 (strongest). If `expNorm` contains `actualNorm`, score is
    /// actualNorm.count. Falls back to stop-word-aware Jaccard × 100 so that
    /// semantically-equivalent titles (differing only by stop-words) still match.
    static func substringScore(_ actualNorm: String, _ expNorm: String) -> Int {
        guard !expNorm.isEmpty, !actualNorm.isEmpty else { return 0 }
        if actualNorm.contains(expNorm) { return expNorm.count + 1 }
        if expNorm.contains(actualNorm) { return actualNorm.count }
        // Stop-word-stripped substring check.
        let aWords = contentWords(actualNorm)
        let eWords = contentWords(expNorm)
        let aStripped = aWords.sorted().joined(separator: " ")
        let eStripped = eWords.sorted().joined(separator: " ")
        if aStripped == eStripped { return expNorm.count }
        if aStripped.contains(eStripped) || eStripped.contains(aStripped) { return expNorm.count / 2 + 1 }
        // Jaccard fallback: return proportional score if ≥ 0.5 overlap.
        let jaccard = jaccardSimilarity(aWords, eWords)
        if jaccard >= 0.5 { return Int(jaccard * Double(expNorm.count)) }
        return 0
    }

    static func normalize(_ s: String) -> String {
        s.lowercased()
         .components(separatedBy: .whitespacesAndNewlines)
         .filter { !$0.isEmpty }
         .joined(separator: " ")
    }

    private static func dayString(_ date: Date, tz: TimeZone) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = tz
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
