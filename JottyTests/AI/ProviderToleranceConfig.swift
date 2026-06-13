// JottyTests/AI/ProviderToleranceConfig.swift
// Per-provider comparator tolerances for the cross-provider eval suite
// (AI-SPEC §7.3). Decodes JottyTests/Resources/cross-provider-tolerances.json
// from the test bundle and exposes a `ProviderTolerance` per provider ID.
//
// The Phase 3 FixtureComparator matching algorithm + stop-word list stay
// intact; only the numeric thresholds (Jaccard floor + title length window)
// vary per provider. `.baseline` reproduces the Phase 3 Apple FM thresholds so
// existing two-arg comparator call sites are byte-for-byte behavior-preserving.

import Foundation

/// Tolerance knobs applied by `FixtureComparator.compareTitle(...:tolerance:)`.
struct ProviderTolerance: Equatable {
    let providerID: String
    /// Minimum Jaccard similarity of content-word sets to accept a title
    /// (baseline 0.6, Phase 3).
    let titleJaccardMin: Double
    /// Acceptable `actual.count / expected.count` window (baseline 0.6...1.6).
    let titleLengthRatio: ClosedRange<Double>
    /// Whether the duration→time-block guardrail (AI-SPEC §6 / G1) should be
    /// applied before scoring this provider's output.
    let applyDurationGuardrail: Bool
}

enum ProviderToleranceConfigError: Error, CustomStringConvertible, Equatable {
    case resourceMissing
    case decodeFailed(String)
    case unknownProvider(String)
    case malformedLengthRatio(provider: String)

    var description: String {
        switch self {
        case .resourceMissing:
            return "cross-provider-tolerances.json not found in the test bundle."
        case .decodeFailed(let detail):
            return "Failed to decode cross-provider-tolerances.json: \(detail)"
        case .unknownProvider(let id):
            return "Unknown provider ID '\(id)'. Known IDs come from the `providers` map in cross-provider-tolerances.json."
        case .malformedLengthRatio(let provider):
            return "Provider '\(provider)' has a malformed title_length_ratio (expected a 2-element [lower, upper] array with lower <= upper)."
        }
    }
}

enum ProviderToleranceConfig {

    // MARK: - Public API

    /// Phase 3 baseline (Apple FM). Used as the default by FixtureComparator so
    /// existing two-arg call sites are unchanged.
    static var baseline: ProviderTolerance {
        ProviderTolerance(
            providerID: "apple-fm",
            titleJaccardMin: 0.6,
            titleLengthRatio: 0.6...1.6,
            applyDurationGuardrail: true
        )
    }

    /// Decodes the test-bundle JSON and returns the tolerance for `providerID`.
    /// Throws a descriptive error (never crashes) when the ID is absent or the
    /// resource is missing/malformed.
    static func tolerance(for providerID: String) throws -> ProviderTolerance {
        let file = try load()
        guard let raw = file.providers[providerID] else {
            throw ProviderToleranceConfigError.unknownProvider(providerID)
        }
        return try raw.tolerance(providerID: providerID)
    }

    // MARK: - JSON shape

    private struct File: Decodable {
        let providers: [String: RawTolerance]
    }

    private struct RawTolerance: Decodable {
        let titleJaccardMin: Double
        let titleLengthRatio: [Double]
        let durationGuardrail: String?

        enum CodingKeys: String, CodingKey {
            case titleJaccardMin = "title_jaccard_min"
            case titleLengthRatio = "title_length_ratio"
            case durationGuardrail = "duration_guardrail"
        }

        func tolerance(providerID: String) throws -> ProviderTolerance {
            guard titleLengthRatio.count == 2,
                  titleLengthRatio[0] <= titleLengthRatio[1] else {
                throw ProviderToleranceConfigError.malformedLengthRatio(provider: providerID)
            }
            return ProviderTolerance(
                providerID: providerID,
                titleJaccardMin: titleJaccardMin,
                titleLengthRatio: titleLengthRatio[0]...titleLengthRatio[1],
                applyDurationGuardrail: durationGuardrail == "applyDurationGuardrail"
            )
        }
    }

    // MARK: - Loading

    private static func load() throws -> File {
        guard let url = Bundle(for: BundleToken.self)
            .url(forResource: "cross-provider-tolerances", withExtension: "json") else {
            throw ProviderToleranceConfigError.resourceMissing
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ProviderToleranceConfigError.decodeFailed(error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(File.self, from: data)
        } catch {
            throw ProviderToleranceConfigError.decodeFailed("\(error)")
        }
    }
}

/// Empty class purely to anchor `Bundle(for:)` to the test bundle.
private final class BundleToken {}
