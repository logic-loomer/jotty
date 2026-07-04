// JottyTests/Config/ConfigStoreProviderFieldTests.swift
// Plan 04-10 Task 10.1: AppConfig provider fields.
//
// - Backward-compatible decode: Phase 2/3 config.json (storageFolder only)
//   must keep loading, defaulting aiProviderID = "apple-fm", ollamaModel = nil.
// - Round-trip persistence of the new non-secret fields via ConfigStore.update.
// - The keychain-routing invariant at the storage layer: writing an API key
//   through KeychainAPIKeyStore must leave NO key material in config.json.

import XCTest
@testable import Jotty

final class ConfigStoreProviderFieldTests: XCTestCase {
    var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("config.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
        super.tearDown()
    }

    // Test 1 — backward-compatible decode: a config.json written by Phase 2/3
    // (only storageFolder) decodes with defaults; no crash, no reset to defaults.
    func testLegacyConfigDecodesWithProviderDefaults() throws {
        let legacyJSON = """
        {
          "storageFolder" : "file:///tmp/LegacyJotty/"
        }
        """
        try FileManager.default.createDirectory(
            at: tempURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try legacyJSON.data(using: .utf8)!.write(to: tempURL)

        let store = try ConfigStore(path: tempURL)
        XCTAssertEqual(store.config.storageFolder.path, "/tmp/LegacyJotty",
                       "legacy storageFolder must survive (decode must not fall back to defaults)")
        XCTAssertEqual(store.config.aiProviderID, "apple-fm",
                       "missing aiProviderID must default to apple-fm")
        XCTAssertNil(store.config.ollamaModel,
                     "missing ollamaModel must default to nil")
    }

    // Test 2 — round-trip: provider fields persist to disk and reload.
    func testProviderFieldsRoundTrip() throws {
        let store1 = try ConfigStore(path: tempURL)
        try store1.update {
            $0.aiProviderID = "claude"
            $0.ollamaModel = "qwen2.5:3b"
        }

        let store2 = try ConfigStore(path: tempURL)
        XCTAssertEqual(store2.config.aiProviderID, "claude")
        XCTAssertEqual(store2.config.ollamaModel, "qwen2.5:3b")
    }

    // Phase 5 plan 01 — calendar fields round-trip: a config with a chosen
    // calendar identifier and a remembered delete preference persists + reloads.
    func testCalendarFieldsRoundTrip() throws {
        let store1 = try ConfigStore(path: tempURL)
        try store1.update {
            $0.calendarIdentifier = "cal-ABC-123"
            $0.deleteCalendarEventWithTask = true
        }

        let store2 = try ConfigStore(path: tempURL)
        XCTAssertEqual(store2.config.calendarIdentifier, "cal-ABC-123")
        XCTAssertEqual(store2.config.deleteCalendarEventWithTask, true)
    }

    // Phase 5 plan 01 — back-compat: a config.json with ONLY storageFolder
    // (no aiProviderID, no calendar fields) decodes with calendar fields nil.
    func testLegacyConfigHasNilCalendarFields() throws {
        let legacyJSON = """
        {
          "storageFolder" : "file:///tmp/LegacyJotty/"
        }
        """
        try FileManager.default.createDirectory(
            at: tempURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try legacyJSON.data(using: .utf8)!.write(to: tempURL)

        let store = try ConfigStore(path: tempURL)
        XCTAssertNil(store.config.calendarIdentifier,
                     "missing calendarIdentifier must default to nil")
        XCTAssertNil(store.config.deleteCalendarEventWithTask,
                     "missing deleteCalendarEventWithTask must default to nil")
    }

    // Phase 11 plan 03 — SC5 privacy default: a freshly constructed AppConfig has
    // calendarInboxEnabled == false, so the calendar source is gated OFF until the
    // user explicitly opts in (no calendar reads on the default config).
    func testCalendarInboxEnabledDefaultsFalse() throws {
        let cfg = AppConfig(storageFolder: URL(fileURLWithPath: "/tmp/Jotty"))
        XCTAssertFalse(cfg.calendarInboxEnabled,
                       "calendarInboxEnabled must default to false (SC5 privacy default OFF)")
    }

    // Phase 11 plan 03 — round-trip: once the user opts in, the true value persists
    // to disk and reloads.
    func testCalendarInboxEnabledRoundTrip() throws {
        let store1 = try ConfigStore(path: tempURL)
        try store1.update { $0.calendarInboxEnabled = true }

        let store2 = try ConfigStore(path: tempURL)
        XCTAssertTrue(store2.config.calendarInboxEnabled,
                      "calendarInboxEnabled == true must round-trip through config.json")
    }

    // Phase 11 plan 03 — back-compat: a config.json with ONLY storageFolder (written
    // before Phase 11) decodes with calendarInboxEnabled == false rather than failing
    // the whole decode (which would reset the config to defaults). Mirrors the
    // inboxCheckPeriodically missing-key handling.
    func testLegacyConfigHasCalendarInboxDisabled() throws {
        let legacyJSON = """
        {
          "storageFolder" : "file:///tmp/LegacyJotty/"
        }
        """
        try FileManager.default.createDirectory(
            at: tempURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try legacyJSON.data(using: .utf8)!.write(to: tempURL)

        let store = try ConfigStore(path: tempURL)
        XCTAssertEqual(store.config.storageFolder.path, "/tmp/LegacyJotty",
                       "legacy storageFolder must survive (decode must not fall back to defaults)")
        XCTAssertFalse(store.config.calendarInboxEnabled,
                       "missing calendarInboxEnabled must default to false (SC5)")
    }

    // Test 3 — no key material in config: a key saved through
    // KeychainAPIKeyStore must never appear in the raw config.json bytes.
    func testAPIKeyNeverWrittenToConfigJSON() throws {
        let store = try ConfigStore(path: tempURL)
        try store.update { $0.aiProviderID = "claude" }

        let keychain = KeychainAPIKeyStore(service: "com.jotty.api-keys.tests")
        let account = "sentinel-\(UUID().uuidString)"
        defer { try? keychain.delete(account: account) }
        try keychain.write(account: account, key: "sk-SENTINEL-12345")

        // Force one more config save AFTER the key write, then inspect disk.
        try store.update { $0.ollamaModel = "qwen2.5:3b" }

        let rawBytes = try Data(contentsOf: tempURL)
        let raw = String(decoding: rawBytes, as: UTF8.self)
        XCTAssertFalse(raw.contains("SENTINEL"),
                       "config.json must NEVER contain API key material")
        XCTAssertFalse(raw.contains("sk-"),
                       "config.json must NEVER contain anything key-shaped")
    }
}
