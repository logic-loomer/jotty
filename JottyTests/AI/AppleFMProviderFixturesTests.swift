// JottyTests/AI/AppleFMProviderFixturesTests.swift
// Full 35-fixture harness — all fixtures from extraction-fixtures.json.
// Uses FixtureComparator with greedy bipartite matcher.
// Dims 3, 4, 6 are hard release blockers (XCTFail on any failure).

import XCTest
import FoundationModels
@testable import Jotty

final class AppleFMProviderFixturesTests: XCTestCase {

    // MARK: - Fixture types (mirrors extraction-fixtures.json schema)

    private struct FixtureFile: Decodable {
        let fixtures: [Fixture]
    }

    private struct Fixture: Decodable {
        let id: String
        let input: String
        let now: String
        let timezone: String
        let expected: Expected
        let failure_mode_tested: String

        struct Expected: Decodable {
            let tasks: [ExpTask]
            let note_body: String
        }

        struct ExpTask: Decodable {
            let title: String
            let dueDate: String?
            let timeBlock: ExpTimeBlock?
            let calendarBlock: Bool
        }

        struct ExpTimeBlock: Decodable {
            let start: String
            let end: String
        }
    }

    // MARK: - Release-blocker dimension map

    /// failure_mode_tested values that map to dims 3, 4, or 6 — hard release blockers.
    private static let releaseblockerModes: Set<String> = [
        "soon_hallucinated_date",   // dim 3 — Date Restraint
        "duration_vs_timeblock",    // dim 4 — Time-Block Discipline
        "wellness_hallucination",   // dim 6 — Hallucination Rate
        "past_tense_fabrication",   // dim 6 — Hallucination Rate
    ]

    // MARK: - Helpers

    private func skipIfNoAppleFM() throws {
        switch SystemLanguageModel.default.availability {
        case .available:
            return
        default:
            throw XCTSkip("Apple Intelligence not available on this machine.")
        }
    }

    private func loadFixtures() throws -> [Fixture] {
        guard let url = Bundle(for: Self.self)
            .url(forResource: "extraction-fixtures", withExtension: "json") else {
            XCTFail("extraction-fixtures.json not found in test bundle")
            throw XCTSkip("missing extraction-fixtures.json")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FixtureFile.self, from: data).fixtures
    }

    private func parseAnchor(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withTimeZone]
        return f.date(from: iso)
    }

    // MARK: - Full suite

    func testAllFixtures() async throws {
        try skipIfNoAppleFM()

        let fixtures = try loadFixtures()
        XCTAssertEqual(fixtures.count, 35, "expected 35 fixtures committed at v0.3; got \(fixtures.count)")

        var allFailures: [(id: String, mode: String, reasons: [String])] = []
        var releaseblockerFailures: [(id: String, mode: String, reasons: [String])] = []

        for fixture in fixtures {
            guard let tz = TimeZone(identifier: fixture.timezone) else {
                allFailures.append((fixture.id, fixture.failure_mode_tested, ["bad timezone: \(fixture.timezone)"]))
                continue
            }
            guard let now = parseAnchor(fixture.now) else {
                allFailures.append((fixture.id, fixture.failure_mode_tested, ["bad now anchor: \(fixture.now)"]))
                continue
            }

            let provider = AppleFMProvider()
            let actual: ExtractionResult
            do {
                actual = try await provider.extractTasks(from: fixture.input, now: now, timezone: tz)
            } catch {
                let reason = "extractTasks threw: \(error)"
                allFailures.append((fixture.id, fixture.failure_mode_tested, [reason]))
                continue
            }

            let reasons = compare(actual: actual, fixture: fixture, tz: tz)
            if !reasons.isEmpty {
                allFailures.append((fixture.id, fixture.failure_mode_tested, reasons))
            }
        }

        // Partition into release-blocker vs non-blocker
        for entry in allFailures {
            if Self.releaseblockerModes.contains(entry.mode) {
                releaseblockerFailures.append(entry)
            }
        }

        // Report all failures
        if !allFailures.isEmpty {
            let lines = allFailures.flatMap { entry in
                entry.reasons.map { r in "\(entry.id) [\(entry.mode)]: \(r)" }
            }
            let report = "Eval failures (\(allFailures.count) fixtures):\n" + lines.joined(separator: "\n")
            print(report)

            // Hard fail on release-blocker dimensions (3, 4, 6)
            if !releaseblockerFailures.isEmpty {
                let blockerLines = releaseblockerFailures.flatMap { entry in
                    entry.reasons.map { r in "\(entry.id) [\(entry.mode)] [RELEASE BLOCKER]: \(r)" }
                }
                XCTFail("RELEASE BLOCKER failures (dims 3/4/6):\n" + blockerLines.joined(separator: "\n"))
            }

            // Non-blocker failures: log only (per checkpoint: defer-non-blocker resolution).
            // The release-blocker gate is the only XCTFail surface; non-blocker dims are
            // tracked as known-yellow and addressed in v0.3.x / v1.0 work.
            let nonblockerFailures = allFailures.filter { !Self.releaseblockerModes.contains($0.mode) }
            if !nonblockerFailures.isEmpty {
                let nbLines = nonblockerFailures.flatMap { entry in
                    entry.reasons.map { r in "\(entry.id) [\(entry.mode)]: \(r)" }
                }
                print("⚠️ NON-BLOCKER failures (\(nonblockerFailures.count) fixtures, deferred per checkpoint):\n" + nbLines.joined(separator: "\n"))
            }
        }
    }

    // MARK: - Per-fixture comparison

    private func compare(actual: ExtractionResult, fixture: Fixture, tz: TimeZone) -> [String] {
        var ms: [String] = []

        // Task count (strict)
        if let m = FixtureComparator.compareTaskCount(
            actual: actual.tasks.count,
            expected: fixture.expected.tasks.count
        ) { ms.append(m) }

        // Per-task field checks via greedy bipartite match
        let pairs = FixtureComparator.matchTasks(
            actual: actual.tasks,
            expected: fixture.expected.tasks,
            actualTitle: { $0.title },
            expectedTitle: { $0.title }
        )

        for pair in pairs {
            switch pair {
            case .matched(let a, let e):
                if let m = FixtureComparator.compareTitle(actual: a.title, expected: e.title) {
                    ms.append(m)
                }
                if let m = FixtureComparator.compareDueDate(actual: a.dueDate, expected: e.dueDate, tz: tz) {
                    ms.append(m)
                }
                if let m = FixtureComparator.compareTimeBlock(
                    actual: a.timeBlock,
                    expectedStart: e.timeBlock?.start,
                    expectedEnd: e.timeBlock?.end
                ) { ms.append(m) }
                if let m = FixtureComparator.compareCalendarBlock(actual: a.calendarBlock, expected: e.calendarBlock) {
                    ms.append(m)
                }
            case .unmatched(let e):
                ms.append("expected task '\(e.title)' had no overlapping actual task")
            case .extra(let a):
                ms.append("extra actual task '\(a.title)' not in expected (over-extraction)")
            }
        }

        // Note body (substring, whitespace-normalized)
        if let m = FixtureComparator.compareNoteBody(
            actual: actual.noteBody,
            expected: fixture.expected.note_body
        ) { ms.append(m) }

        return ms
    }
}
