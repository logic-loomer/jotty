// JottyTests/AI/FixtureComparator.swift
// Pure comparator implementing AI-SPEC §5.3 rules + greedy bipartite task matcher.
// No XCTest imports — usable from both the harness and unit tests.

import Foundation
@testable import Jotty

enum FixtureComparator {

    // MARK: - Field comparators

    /// PASS if lowercased+whitespace-normalized `expected` is a substring of
    /// `actual` AND `actual.count <= 1.5 × expected.count`.
    static func compareTitle(actual: String, expected: String) -> String? {
        let na = normalize(actual)
        let ne = normalize(expected)
        guard na.contains(ne) else {
            return "title mismatch: expected substring '\(ne)' not found in actual '\(na)'"
        }
        let maxLen = Int(Double(ne.count) * 1.5)
        guard na.count <= maxLen else {
            return "title too long: actual '\(na)' (\(na.count) chars) > 1.5× expected '\(ne)' (\(ne.count) chars, max \(maxLen))"
        }
        return nil
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
    /// actualNorm.count. Otherwise 0.
    static func substringScore(_ actualNorm: String, _ expNorm: String) -> Int {
        guard !expNorm.isEmpty, !actualNorm.isEmpty else { return 0 }
        if actualNorm.contains(expNorm) { return expNorm.count + 1 }
        if expNorm.contains(actualNorm) { return actualNorm.count }
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
