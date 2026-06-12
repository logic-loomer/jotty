// JottyTests/AI/KeychainAPIKeyStoreTests.swift
// Round-trip, overwrite, delete, missing-account, unicode, idempotent-delete
// coverage for KeychainAPIKeyStore. Each test uses a UUID-prefixed account so
// parallel runs do not collide, and cleans up via defer so no Keychain residue
// survives the test run.

import XCTest
@testable import Jotty

final class KeychainAPIKeyStoreTests: XCTestCase {

    private let store = KeychainAPIKeyStore(service: "com.jotty.api-keys.tests")

    private func uniqueAccount(_ label: String) -> String {
        "\(label)-\(UUID().uuidString)"
    }

    // Test 1 — round-trip: write then read returns the exact value.
    func testRoundTrip() throws {
        let account = uniqueAccount("test-roundtrip")
        defer { try? store.delete(account: account) }

        try store.write(account: account, key: "sk-abc123")
        XCTAssertEqual(try store.read(account: account), "sk-abc123")
    }

    // Test 2 — overwrite: second write replaces the first (SecItemUpdate path).
    func testOverwriteReplacesPreviousValue() throws {
        let account = uniqueAccount("test-overwrite")
        defer { try? store.delete(account: account) }

        try store.write(account: account, key: "sk-first")
        try store.write(account: account, key: "sk-second")
        XCTAssertEqual(try store.read(account: account), "sk-second")
    }

    // Test 3 — delete: after delete, read returns nil.
    func testDeleteRemovesItem() throws {
        let account = uniqueAccount("test-delete")
        defer { try? store.delete(account: account) }

        try store.write(account: account, key: "sk-to-delete")
        try store.delete(account: account)
        XCTAssertNil(try store.read(account: account))
    }

    // Test 4 — missing account: read returns nil, does NOT throw.
    func testReadMissingAccountReturnsNil() throws {
        let account = "nonexistent-\(UUID().uuidString)"
        XCTAssertNil(try store.read(account: account))
    }

    // Test 5 — unicode preserved: non-ASCII key survives the round-trip intact.
    func testUnicodeKeyPreserved() throws {
        let account = uniqueAccount("test-unicode")
        defer { try? store.delete(account: account) }

        let key = "sk-✓-π"
        try store.write(account: account, key: key)
        XCTAssertEqual(try store.read(account: account), key)
    }

    // Test 6 — delete is idempotent: deleting an unknown account does not throw.
    func testDeleteUnknownAccountDoesNotThrow() {
        let account = "never-written-\(UUID().uuidString)"
        XCTAssertNoThrow(try store.delete(account: account))
    }
}
