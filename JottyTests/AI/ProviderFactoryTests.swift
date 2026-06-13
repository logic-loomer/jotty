// JottyTests/AI/ProviderFactoryTests.swift
// ID-mapping tests for ProviderFactory (plan 04-11). The factory is the single
// place that maps AppConfig.aiProviderID → concrete AIProvider. Construction
// must be cheap and synchronous — no keychain reads, no network — so these
// tests only type-check the returned instance (and the Ollama model seam).

import XCTest
@testable import Jotty

final class ProviderFactoryTests: XCTestCase {

    private var keychain: KeychainAPIKeyStore!

    override func setUp() {
        super.setUp()
        // UUID-suffixed service so factory tests can never touch the
        // production keychain namespace (same hygiene as provider tests).
        keychain = KeychainAPIKeyStore(
            service: "com.jotty.api-keys.tests.factory.\(UUID().uuidString)")
    }

    override func tearDown() {
        keychain = nil
        super.tearDown()
    }

    private func config(id: String, ollamaModel: String? = nil) -> AppConfig {
        AppConfig(
            storageFolder: FileManager.default.temporaryDirectory,
            aiProviderID: id,
            ollamaModel: ollamaModel)
    }

    // MARK: - ID → type mapping

    func testAppleFMIDReturnsAppleFMProvider() {
        let provider = ProviderFactory.make(config: config(id: "apple-fm"),
                                            keychain: keychain)
        XCTAssertTrue(provider is AppleFMProvider)
    }

    func testOllamaIDWithNilModelDefaultsToQwen() {
        let provider = ProviderFactory.make(config: config(id: "ollama"),
                                            keychain: keychain)
        guard let ollama = provider as? OllamaProvider else {
            return XCTFail("Expected OllamaProvider, got \(type(of: provider))")
        }
        XCTAssertEqual(ollama.model, "qwen2.5:3b")
    }

    func testOllamaIDWithExplicitModelWins() {
        let provider = ProviderFactory.make(
            config: config(id: "ollama", ollamaModel: "llama3.2:3b"),
            keychain: keychain)
        guard let ollama = provider as? OllamaProvider else {
            return XCTFail("Expected OllamaProvider, got \(type(of: provider))")
        }
        XCTAssertEqual(ollama.model, "llama3.2:3b")
    }

    func testCloudIDsReturnRespectiveProviders() {
        XCTAssertTrue(
            ProviderFactory.make(config: config(id: "claude"),
                                 keychain: keychain) is ClaudeProvider)
        XCTAssertTrue(
            ProviderFactory.make(config: config(id: "openai"),
                                 keychain: keychain) is OpenAIProvider)
        XCTAssertTrue(
            ProviderFactory.make(config: config(id: "gemini"),
                                 keychain: keychain) is GeminiProvider)
    }

    func testUnknownIDFallsBackToAppleFM() {
        let provider = ProviderFactory.make(config: config(id: "garbage"),
                                            keychain: keychain)
        XCTAssertTrue(provider is AppleFMProvider)
    }

    func testEmptyIDFallsBackToAppleFM() {
        let provider = ProviderFactory.make(config: config(id: ""),
                                            keychain: keychain)
        XCTAssertTrue(provider is AppleFMProvider)
    }

    // MARK: - isAppleFM

    func testIsAppleFMTrueOnlyForAppleFMAndUnknownIDs() {
        XCTAssertTrue(ProviderFactory.isAppleFM(config(id: "apple-fm")))
        XCTAssertTrue(ProviderFactory.isAppleFM(config(id: "garbage")))
        XCTAssertTrue(ProviderFactory.isAppleFM(config(id: "")))

        XCTAssertFalse(ProviderFactory.isAppleFM(config(id: "ollama")))
        XCTAssertFalse(ProviderFactory.isAppleFM(config(id: "claude")))
        XCTAssertFalse(ProviderFactory.isAppleFM(config(id: "openai")))
        XCTAssertFalse(ProviderFactory.isAppleFM(config(id: "gemini")))
    }
}
