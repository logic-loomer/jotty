// JottyTests/AI/OllamaTypesTests.swift
// Type-level tests for the Ollama model-management support types
// (plan 04-08, AI-SPEC §3.4 + §3.5):
//   - PullProgress NDJSON line decoding + fraction computation
//   - InstalledModel decoding of the documented /api/tags shape
//   - DiskSpace.ensureSpace 20%-headroom precheck (pure overload, no I/O)

import XCTest
@testable import Jotty

final class OllamaTypesTests: XCTestCase {

    // MARK: PullProgress

    /// Canonical pull phases per AI-SPEC §3.4. Every line must decode;
    /// `fraction` is nil unless both total and completed are present.
    func testPullProgressDecodesCanonicalPhases() throws {
        let lines = [
            #"{"status":"pulling manifest"}"#,
            #"{"status":"pulling 8eeb52dfb3bb","digest":"sha256:8eeb52dfb3bb","total":1928429856,"completed":241970}"#,
            #"{"status":"verifying sha256 digest"}"#,
            #"{"status":"writing manifest"}"#,
            #"{"status":"success"}"#,
        ]

        let decoded = try lines.map {
            try JSONDecoder().decode(PullProgress.self, from: Data($0.utf8))
        }

        XCTAssertEqual(decoded.map(\.status), [
            "pulling manifest",
            "pulling 8eeb52dfb3bb",
            "verifying sha256 digest",
            "writing manifest",
            "success",
        ])

        // Phases without total/completed report no fraction.
        XCTAssertNil(decoded[0].fraction)
        XCTAssertNil(decoded[2].fraction)
        XCTAssertNil(decoded[3].fraction)
        XCTAssertNil(decoded[4].fraction)

        // Layer-download phase: fraction == completed / total.
        XCTAssertEqual(decoded[1].digest, "sha256:8eeb52dfb3bb")
        XCTAssertEqual(decoded[1].total, 1_928_429_856)
        XCTAssertEqual(decoded[1].completed, 241_970)
        let fraction = try XCTUnwrap(decoded[1].fraction)
        XCTAssertEqual(fraction, 241_970.0 / 1_928_429_856.0, accuracy: 1e-12)
    }

    /// fraction caps at 1.0 even if the daemon reports completed > total.
    func testPullProgressFractionCapsAtOne() throws {
        let line = #"{"status":"pulling x","total":100,"completed":150}"#
        let progress = try JSONDecoder().decode(PullProgress.self, from: Data(line.utf8))
        XCTAssertEqual(progress.fraction, 1.0)
    }

    /// fraction is nil when total is zero (avoid division by zero).
    func testPullProgressFractionNilForZeroTotal() throws {
        let line = #"{"status":"pulling x","total":0,"completed":0}"#
        let progress = try JSONDecoder().decode(PullProgress.self, from: Data(line.utf8))
        XCTAssertNil(progress.fraction)
    }

    // MARK: InstalledModel

    /// Decodes the documented Ollama /api/tags response shape (AI-SPEC §4.3).
    func testInstalledModelDecodesTagsResponse() throws {
        struct TagsResponse: Decodable { let models: [InstalledModel] }

        let json = """
        {
          "models": [
            {
              "name": "qwen2.5:3b",
              "modified_at": "2026-06-01T10:15:30.123456789+10:00",
              "size": 1928429856,
              "digest": "sha256:8eeb52dfb3bb",
              "details": {
                "format": "gguf",
                "family": "qwen2",
                "parameter_size": "3.1B",
                "quantization_level": "Q4_K_M"
              }
            },
            {
              "name": "gemma2:2b",
              "modified_at": "2026-05-20T08:00:00Z",
              "size": 1600000000,
              "digest": "sha256:deadbeef",
              "details": null
            }
          ]
        }
        """

        let response = try JSONDecoder().decode(TagsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.models.count, 2)

        let qwen = response.models[0]
        XCTAssertEqual(qwen.id, "qwen2.5:3b")          // Identifiable via name
        XCTAssertEqual(qwen.name, "qwen2.5:3b")
        XCTAssertEqual(qwen.size, 1_928_429_856)
        XCTAssertEqual(qwen.modified_at, "2026-06-01T10:15:30.123456789+10:00")
        XCTAssertEqual(qwen.digest, "sha256:8eeb52dfb3bb")
        let details = try XCTUnwrap(qwen.details)
        XCTAssertEqual(details.format, "gguf")
        XCTAssertEqual(details.family, "qwen2")
        XCTAssertEqual(details.parameter_size, "3.1B")
        XCTAssertEqual(details.quantization_level, "Q4_K_M")

        XCTAssertNil(response.models[1].details)
    }

    // MARK: DiskSpace

    /// ensureSpace throws .insufficientSpace when free < need × 1.2.
    func testEnsureSpaceThrowsWhenBelowHeadroom() {
        let need: Int64 = 1_000_000_000          // 1 GB
        let available: Int64 = 1_100_000_000     // 1.1 GB < 1.2 GB required

        XCTAssertThrowsError(
            try DiskSpace.ensureSpace(forBytes: need, available: available)
        ) { error in
            XCTAssertEqual(
                error as? OllamaError,
                .insufficientSpace(needed: need, available: available)
            )
        }
    }

    /// ensureSpace passes when free comfortably exceeds need × 1.2.
    func testEnsureSpacePassesWithHeadroom() {
        XCTAssertNoThrow(
            try DiskSpace.ensureSpace(forBytes: 1_000_000_000, available: 1_300_000_000)
        )
    }

    /// The real volume query returns a positive byte count for the home
    /// directory (local filesystem only — no network involved).
    func testAvailableSpaceBytesReturnsPositiveValue() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let bytes = try DiskSpace.availableSpaceBytes(at: home)
        XCTAssertGreaterThan(bytes, 0)
    }
}
