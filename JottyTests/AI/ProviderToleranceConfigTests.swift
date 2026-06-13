// JottyTests/AI/ProviderToleranceConfigTests.swift
// Offline coverage for the per-provider tolerance config + the
// tolerance-parameterised FixtureComparator (AI-SPEC §7.3). Runs in the normal
// suite — no network, no API keys, no daemon.
//
// Dedicated file so `-only-testing:JottyTests/ProviderToleranceConfigTests`
// targets it precisely (matches the plan's verify filter).

import XCTest
@testable import Jotty

final class ProviderToleranceConfigTests: XCTestCase {

    // MARK: - Test 1 — decode all 7 provider entries

    func testDecodesAllSevenProviders() throws {
        let expected: [(id: String, jaccard: Double, lower: Double, upper: Double)] = [
            ("apple-fm", 0.6, 0.6, 1.6),
            ("ollama-qwen2.5-3b", 0.55, 0.55, 1.7),
            ("ollama-llama3.2-3b", 0.55, 0.55, 1.7),
            ("ollama-phi3.5-3.8b", 0.55, 0.55, 1.7),
            ("claude-haiku-4-5", 0.5, 0.5, 1.8),
            ("gpt-4o-mini", 0.5, 0.5, 1.8),
            ("gemini-2.5-flash", 0.5, 0.5, 1.8),
        ]

        for entry in expected {
            let tol = try ProviderToleranceConfig.tolerance(for: entry.id)
            XCTAssertEqual(tol.providerID, entry.id)
            XCTAssertEqual(tol.titleJaccardMin, entry.jaccard, accuracy: 1e-9,
                           "jaccardMin for \(entry.id)")
            XCTAssertEqual(tol.titleLengthRatio.lowerBound, entry.lower, accuracy: 1e-9,
                           "lengthRatio lower for \(entry.id)")
            XCTAssertEqual(tol.titleLengthRatio.upperBound, entry.upper, accuracy: 1e-9,
                           "lengthRatio upper for \(entry.id)")
            XCTAssertTrue(tol.applyDurationGuardrail,
                          "all seed providers declare the duration guardrail")
        }
    }

    func testClaudeSeedValuesExplicit() throws {
        let tol = try ProviderToleranceConfig.tolerance(for: "claude-haiku-4-5")
        XCTAssertEqual(tol.titleJaccardMin, 0.5, accuracy: 1e-9)
        XCTAssertEqual(tol.titleLengthRatio, 0.5...1.8)
    }

    // MARK: - Test 2 — unknown provider throws (does not crash)

    func testUnknownProviderThrowsDescriptiveError() {
        XCTAssertThrowsError(try ProviderToleranceConfig.tolerance(for: "nope-9000")) { error in
            guard case ProviderToleranceConfigError.unknownProvider(let id) = error else {
                return XCTFail("expected .unknownProvider, got \(error)")
            }
            XCTAssertEqual(id, "nope-9000")
            XCTAssertTrue("\(error)".contains("nope-9000"),
                          "error description should name the missing provider")
        }
    }

    // MARK: - Test 3 — baseline equivalence (refactor is behavior-preserving)

    func testBaselineEquivalenceOverTitlePairTable() {
        // (actual, expected) pairs spanning pass + fail outcomes.
        let pairs: [(String, String)] = [
            ("email jamie about the q2 plan", "email jamie about q2 plan"),     // substring/stop-word pass
            ("fix the auth bug", "auth bug"),                                   // substring pass
            ("buy groceries", "completely unrelated topic shift"),             // jaccard fail
            ("review the quarterly budget report", "budget report"),           // pass
            ("call mum", "call mum tonight before the meeting starts please"), // too long → fail
            ("", "some expected title"),                                        // empty actual
            ("ship the release", "ship release"),                              // stop-word pass
            ("schedule dentist appointment", "schedule a dentist appt"),       // borderline
        ]

        for (actual, expected) in pairs {
            let twoArg = FixtureComparator.compareTitle(actual: actual, expected: expected)
            let baselineArg = FixtureComparator.compareTitle(
                actual: actual, expected: expected, tolerance: .baseline)
            XCTAssertEqual(
                twoArg, baselineArg,
                "two-arg form must equal .baseline form for ('\(actual)' vs '\(expected)'): "
                + "twoArg=\(String(describing: twoArg)) baseline=\(String(describing: baselineArg))"
            )
        }
    }

    // MARK: - Test 4 — loosened tolerance admits what baseline rejects

    func testLoosenedToleranceAdmitsBaselineRejection() throws {
        // A verbose cloud-style title whose content-word Jaccard is exactly 0.5:
        // fails baseline (>= 0.6) but passes the looser claude tolerance
        // (>= 0.5), with length inside both windows so only the Jaccard knob
        // decides the outcome.
        let actual = "finalize budget forecast deck numbers"
        let expected = "finalize budget forecast report"

        let baselineResult = FixtureComparator.compareTitle(
            actual: actual, expected: expected, tolerance: .baseline)
        XCTAssertNotNil(baselineResult,
                        "this pair must FAIL at baseline 0.6 Jaccard to make the test meaningful")

        let claude = try ProviderToleranceConfig.tolerance(for: "claude-haiku-4-5")
        let loosened = FixtureComparator.compareTitle(
            actual: actual, expected: expected, tolerance: claude)
        XCTAssertNil(loosened,
                     "looser claude tolerance must ADMIT the verbose title baseline rejects; "
                     + "got: \(String(describing: loosened))")
    }
}
