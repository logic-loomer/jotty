// JottyTests/AI/CrossProviderTests.swift
// Cross-provider evaluation harness — the Phase 4 release gate (AI-SPEC §7).
// The same 35 Phase 3 fixtures run against every provider with per-provider
// tolerances from cross-provider-tolerances.json. A provider that RUNS must
// clear the release-blocker dims (3 Date Restraint, 4 Time-Block Discipline,
// 6 Hallucination Rate) at 100% (AI-SPEC §7.2) or the test FAILS.
//
// Gating (AI-SPEC §7.4) keeps developers without keys un-blocked:
//   - testAppleFM       — always runs (skips only if Apple Intelligence absent)
//   - testOllamaQwen    — XCTSkipUnless a local daemon answers /api/version
//   - testClaude/OpenAI/Gemini — XCTSkipUnless JOTTY_TEST_CLOUD_PROVIDERS=1 AND
//     the per-provider env key is present. The env key is written into a
//     TEST-scoped Keychain service at setUp and deleted at tearDown; the
//     production Keychain is never touched (AI-SPEC §7.5).
//
// Every run writes report.md + mismatches.json under
// ~/Library/Application Support/Jotty/debug/eval-runs/<ISO timestamp>/ (§7.7).

import XCTest
import FoundationModels
@testable import Jotty

final class CrossProviderTests: XCTestCase {

    // Test-scoped Keychain service — never the production "com.jotty.api-keys".
    private static let testKeychainService = "com.jotty.api-keys.tests"

    // MARK: - Fixture types (mirror extraction-fixtures.json schema)

    private struct FixtureFile: Decodable { let fixtures: [Fixture] }

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

    // MARK: - Release-blocker dimension map (AI-SPEC §7.2)

    /// failure_mode_tested values that map to dims 3, 4, or 6 — hard release
    /// blockers (identical mapping to the Phase 3 AppleFM full harness).
    private static let blockerModes: [String: String] = [
        "soon_hallucinated_date": "dim3 Date Restraint",
        "duration_vs_timeblock": "dim4 Time-Block Discipline",
        "wellness_hallucination": "dim6 Hallucination Rate",
        "past_tense_fabrication": "dim6 Hallucination Rate",
    ]

    // MARK: - tearDown — scrub the test Keychain unconditionally

    override func tearDownWithError() throws {
        let store = KeychainAPIKeyStore(service: Self.testKeychainService)
        for account in ["claude", "openai", "gemini"] {
            try? store.delete(account: account)
        }
    }

    // MARK: - Tests (gated per AI-SPEC §7.4)

    func testAppleFM() async throws {
        switch SystemLanguageModel.default.availability {
        case .available: break
        default: throw XCTSkip("Apple Intelligence not available on this machine.")
        }
        let tolerance = try ProviderToleranceConfig.tolerance(for: "apple-fm")
        try await runFixtures(providerID: "apple-fm", tolerance: tolerance) { _ in
            AppleFMProvider()
        }
    }

    func testOllamaQwen() async throws {
        let baseURL = URL(string: "http://127.0.0.1:11434")!
        let daemonUp = await Self.ollamaDaemonUp(baseURL: baseURL)
        try XCTSkipUnless(daemonUp, "Ollama daemon not running.")
        let tolerance = try ProviderToleranceConfig.tolerance(for: "ollama-qwen2.5-3b")
        try await runFixtures(providerID: "ollama-qwen2.5-3b", tolerance: tolerance) { _ in
            OllamaProvider(model: "qwen2.5:3b", baseURL: baseURL)
        }
    }

    func testClaude() async throws {
        let store = try Self.skipUnlessCloud(envKey: "ANTHROPIC_API_KEY", account: "claude")
        let tolerance = try ProviderToleranceConfig.tolerance(for: "claude-haiku-4-5")
        try await runFixtures(providerID: "claude-haiku-4-5", tolerance: tolerance) { _ in
            ClaudeProvider(keychain: store, model: "claude-haiku-4-5")
        }
    }

    func testOpenAI() async throws {
        let store = try Self.skipUnlessCloud(envKey: "OPENAI_API_KEY", account: "openai")
        let tolerance = try ProviderToleranceConfig.tolerance(for: "gpt-4o-mini")
        try await runFixtures(providerID: "gpt-4o-mini", tolerance: tolerance) { _ in
            OpenAIProvider(keychain: store, model: "gpt-4o-mini")
        }
    }

    func testGemini() async throws {
        let store = try Self.skipUnlessCloud(envKey: "GEMINI_API_KEY", account: "gemini")
        let tolerance = try ProviderToleranceConfig.tolerance(for: "gemini-2.5-flash")
        try await runFixtures(providerID: "gemini-2.5-flash", tolerance: tolerance) { _ in
            GeminiProvider(keychain: store, model: "gemini-2.5-flash")
        }
    }

    // MARK: - Cloud gate + test-scoped key injection (AI-SPEC §7.5)

    /// Skips unless JOTTY_TEST_CLOUD_PROVIDERS=1 AND the per-provider env key is
    /// present. On success, writes the env key into the TEST-scoped Keychain and
    /// returns a store bound to that service. tearDown scrubs it.
    private static func skipUnlessCloud(envKey: String, account: String) throws -> KeychainAPIKeyStore {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["JOTTY_TEST_CLOUD_PROVIDERS"] == "1",
                          "Set JOTTY_TEST_CLOUD_PROVIDERS=1 to run cloud-provider tests.")
        guard let key = env[envKey], !key.isEmpty else {
            throw XCTSkip("\(envKey) not set — skipping cloud provider test.")
        }
        let store = KeychainAPIKeyStore(service: testKeychainService)
        try store.write(account: account, key: key)
        return store
    }

    private static func ollamaDaemonUp(baseURL: URL) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/version"))
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - The matrix runner

    /// Scorecard row per fixture.
    private struct Scorecard {
        let id: String
        let mode: String
        let isBlockerMode: Bool
        let reasons: [String]
        var passed: Bool { reasons.isEmpty }
    }

    private func runFixtures(
        providerID: String,
        tolerance: ProviderTolerance,
        makeProvider: @escaping (Fixture) -> AIProvider
    ) async throws {
        let fixtures = try loadFixtures()
        XCTAssertEqual(fixtures.count, 35,
                       "expected 35 fixtures committed at v0.3; got \(fixtures.count)")

        var cards: [Scorecard] = []

        for fixture in fixtures {
            let isBlocker = Self.blockerModes[fixture.failure_mode_tested] != nil
            guard let tz = TimeZone(identifier: fixture.timezone) else {
                cards.append(Scorecard(id: fixture.id, mode: fixture.failure_mode_tested,
                                       isBlockerMode: isBlocker,
                                       reasons: ["bad timezone: \(fixture.timezone)"]))
                continue
            }
            guard let now = parseAnchor(fixture.now) else {
                cards.append(Scorecard(id: fixture.id, mode: fixture.failure_mode_tested,
                                       isBlockerMode: isBlocker,
                                       reasons: ["bad now anchor: \(fixture.now)"]))
                continue
            }

            let provider = makeProvider(fixture)
            let actual: ExtractionResult
            do {
                actual = try await provider.extractTasks(from: fixture.input, now: now, timezone: tz)
            } catch {
                cards.append(Scorecard(id: fixture.id, mode: fixture.failure_mode_tested,
                                       isBlockerMode: isBlocker,
                                       reasons: ["extractTasks threw: \(error)"]))
                continue
            }

            let reasons = compare(actual: actual, fixture: fixture, tz: tz, tolerance: tolerance)
            cards.append(Scorecard(id: fixture.id, mode: fixture.failure_mode_tested,
                                   isBlockerMode: isBlocker, reasons: reasons))
        }

        // Always write a report (green or red) per §7.7.
        writeReport(providerID: providerID, tolerance: tolerance, cards: cards)

        // RELEASE-BLOCKER BAR — dims 3/4/6 must be 100% for a provider that runs.
        let blockerFailures = cards.filter { $0.isBlockerMode && !$0.passed }
        let blockerIDs = blockerFailures.map(\.id)
        XCTAssertEqual(
            blockerIDs, [],
            "[\(providerID)] RELEASE BLOCKER failures (dims 3/4/6 must be 100%):\n"
            + blockerFailures.flatMap { card in
                card.reasons.map { "\(card.id) [\(card.mode) → \(Self.blockerModes[card.mode] ?? "?")]: \($0)" }
            }.joined(separator: "\n")
        )

        // Non-blocker dims (1, 2, 5, 7, 8): recorded only, never asserted (§7.2).
        let nonBlocker = cards.filter { !$0.isBlockerMode && !$0.passed }
        if !nonBlocker.isEmpty {
            let lines = nonBlocker.flatMap { card in
                card.reasons.map { "\(card.id) [\(card.mode)]: \($0)" }
            }
            print("⚠️ [\(providerID)] NON-BLOCKER failures (\(nonBlocker.count) fixtures, "
                  + "tracked not gated):\n" + lines.joined(separator: "\n"))
        }
    }

    // MARK: - Per-fixture comparison (tolerance-aware)

    private func compare(
        actual: ExtractionResult,
        fixture: Fixture,
        tz: TimeZone,
        tolerance: ProviderTolerance
    ) -> [String] {
        var ms: [String] = []

        if let m = FixtureComparator.compareTaskCount(
            actual: actual.tasks.count, expected: fixture.expected.tasks.count) {
            ms.append(m)
        }

        let pairs = FixtureComparator.matchTasks(
            actual: actual.tasks,
            expected: fixture.expected.tasks,
            actualTitle: { $0.title },
            expectedTitle: { $0.title }
        )

        for pair in pairs {
            switch pair {
            case .matched(let a, let e):
                if let m = FixtureComparator.compareTitle(
                    actual: a.title, expected: e.title, tolerance: tolerance) {
                    ms.append(m)
                }
                if let m = FixtureComparator.compareDueDate(
                    actual: a.dueDate, expected: e.dueDate, tz: tz) {
                    ms.append(m)
                }
                if let m = FixtureComparator.compareTimeBlock(
                    actual: a.timeBlock,
                    expectedStart: e.timeBlock?.start,
                    expectedEnd: e.timeBlock?.end) {
                    ms.append(m)
                }
                if let m = FixtureComparator.compareCalendarBlock(
                    actual: a.calendarBlock, expected: e.calendarBlock) {
                    ms.append(m)
                }
            case .unmatched(let e):
                ms.append("expected task '\(e.title)' had no overlapping actual task")
            case .extra(let a):
                ms.append("extra actual task '\(a.title)' not in expected (over-extraction)")
            }
        }

        if let m = FixtureComparator.compareNoteBody(
            actual: actual.noteBody, expected: fixture.expected.note_body) {
            ms.append(m)
        }
        return ms
    }

    // MARK: - Report writer (AI-SPEC §7.7)

    private func writeReport(
        providerID: String,
        tolerance: ProviderTolerance,
        cards: [Scorecard]
    ) {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }

        let stampFmt = ISO8601DateFormatter()
        stampFmt.formatOptions = [.withInternetDateTime]
        stampFmt.timeZone = TimeZone(identifier: "UTC")
        let isoStamp = stampFmt.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dir = appSupport
            .appendingPathComponent("Jotty/debug/eval-runs/\(isoStamp)", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("⚠️ could not create eval-runs dir: \(error)")
            return
        }

        let total = cards.count
        let passed = cards.filter(\.passed).count
        let blockerTotal = cards.filter(\.isBlockerMode).count
        let blockerPassed = cards.filter { $0.isBlockerMode && $0.passed }.count

        var md = """
        # Cross-provider eval — \(providerID)

        - Run: \(isoStamp)
        - Tolerance: jaccardMin=\(tolerance.titleJaccardMin), \
        lengthRatio=\(tolerance.titleLengthRatio.lowerBound)...\(tolerance.titleLengthRatio.upperBound), \
        durationGuardrail=\(tolerance.applyDurationGuardrail)
        - Fixtures passed: \(passed)/\(total)
        - Release-blocker dims (3/4/6): \(blockerPassed)/\(blockerTotal) \
        \(blockerPassed == blockerTotal ? "✅ PASS" : "❌ FAIL")

        | fixture | failure_mode | blocker | result | reasons |
        |---------|--------------|---------|--------|---------|

        """
        for c in cards.sorted(by: { ($0.isBlockerMode ? 0 : 1, $0.id) < ($1.isBlockerMode ? 0 : 1, $1.id) }) {
            let result = c.passed ? "pass" : "FAIL"
            let reasons = c.reasons.isEmpty ? "" : c.reasons.joined(separator: "; ")
                .replacingOccurrences(of: "|", with: "\\|")
            md += "| \(c.id) | \(c.mode) | \(c.isBlockerMode ? "yes" : "") | \(result) | \(reasons) |\n"
        }

        try? md.data(using: .utf8)?.write(to: dir.appendingPathComponent("report.md"))

        // mismatches.json — only the failing fixtures.
        let mismatches = cards.filter { !$0.passed }.map { card -> [String: Any] in
            [
                "fixture": card.id,
                "failure_mode": card.mode,
                "blocker": card.isBlockerMode,
                "reasons": card.reasons,
            ]
        }
        let payload: [String: Any] = [
            "provider": providerID,
            "run": isoStamp,
            "mismatches": mismatches,
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("mismatches.json"))
        }

        print("📊 [\(providerID)] eval report written to \(dir.path)")
    }

    // MARK: - Loading helpers

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
}
