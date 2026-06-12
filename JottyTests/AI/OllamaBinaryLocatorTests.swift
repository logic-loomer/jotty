// JottyTests/AI/OllamaBinaryLocatorTests.swift
// Per-priority resolution table tests for OllamaBinaryLocator (AI-SPEC §3.2).
// File existence is injected as a closure so no test depends on the actual
// machine's Ollama install state.

import XCTest
@testable import Jotty

final class OllamaBinaryLocatorTests: XCTestCase {

    // MARK: - Helpers

    /// Stub fileExists closure: true only for the given absolute paths.
    private func exists(_ paths: Set<String>) -> (URL) -> Bool {
        { url in paths.contains(url.path) }
    }

    // MARK: - Tests

    /// Test 1 — Apple Silicon Homebrew wins.
    func testLocateReturnsSystemHomebrewWhenPresent() {
        let result = OllamaBinaryLocator.locate(
            fileExists: exists(["/opt/homebrew/bin/ollama"]))
        guard case .systemHomebrew(let url) = result else {
            return XCTFail("Expected .systemHomebrew, got \(result)")
        }
        XCTAssertEqual(url.path, "/opt/homebrew/bin/ollama")
    }

    /// Test 2 — Intel Homebrew also maps to .systemHomebrew.
    func testLocateReturnsSystemHomebrewForIntelPath() {
        let result = OllamaBinaryLocator.locate(
            fileExists: exists(["/usr/local/bin/ollama"]))
        guard case .systemHomebrew(let url) = result else {
            return XCTFail("Expected .systemHomebrew, got \(result)")
        }
        XCTAssertEqual(url.path, "/usr/local/bin/ollama")
    }

    /// Test 3 — DMG-style app install in /Applications.
    func testLocateReturnsAppBundleWhenApplicationsInstallPresent() {
        let appPath = "/Applications/Ollama.app/Contents/Resources/ollama"
        let result = OllamaBinaryLocator.locate(fileExists: exists([appPath]))
        guard case .appBundle(let url) = result else {
            return XCTFail("Expected .appBundle, got \(result)")
        }
        XCTAssertEqual(url.path, appPath)
    }

    /// Test 4 — Jotty-managed Application Support fallback.
    func testLocateReturnsJottyManagedWhenOnlySupportPathPresent() {
        let managed = OllamaBinaryLocator.jottyManagedBinary
        let result = OllamaBinaryLocator.locate(fileExists: exists([managed.path]))
        guard case .jottyManaged(let url) = result else {
            return XCTFail("Expected .jottyManaged, got \(result)")
        }
        XCTAssertEqual(url.path, managed.path)
    }

    /// Test 5 — priority: Homebrew beats Jotty-managed (AI-SPEC §3.2 — prefer
    /// the user's existing setup so two daemons never fight over :11434).
    func testLocatePrefersHomebrewOverJottyManaged() {
        let managed = OllamaBinaryLocator.jottyManagedBinary
        let result = OllamaBinaryLocator.locate(
            fileExists: exists(["/opt/homebrew/bin/ollama", managed.path]))
        guard case .systemHomebrew(let url) = result else {
            return XCTFail("Expected .systemHomebrew, got \(result)")
        }
        XCTAssertEqual(url.path, "/opt/homebrew/bin/ollama")
    }

    /// Test 6 — nothing anywhere → .notFound.
    func testLocateReturnsNotFoundWhenNothingExists() {
        let result = OllamaBinaryLocator.locate(fileExists: { _ in false })
        guard case .notFound = result else {
            return XCTFail("Expected .notFound, got \(result)")
        }
    }

    /// Test 7 — requireBinary throws .binaryNotFound when locate finds nothing.
    func testRequireBinaryThrowsBinaryNotFoundWhenNothingExists() {
        XCTAssertThrowsError(
            try OllamaBinaryLocator.requireBinary(fileExists: { _ in false })
        ) { error in
            XCTAssertEqual(error as? OllamaError, .binaryNotFound)
        }
    }

    /// requireBinary returns the located URL when a binary exists.
    func testRequireBinaryReturnsURLWhenBinaryExists() throws {
        let url = try OllamaBinaryLocator.requireBinary(
            fileExists: exists(["/opt/homebrew/bin/ollama"]))
        XCTAssertEqual(url.path, "/opt/homebrew/bin/ollama")
    }
}
