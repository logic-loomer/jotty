import XCTest
@testable import Jotty

/// SC1 (Send-to-Claude) / CQ-03 — the real `SystemClaudeHandoff` web/code branch +
/// safe spawn contract. Every OS effect is an injected closure: the suite NEVER
/// opens a browser, spawns `claude`, or scans the real `$PATH` (T-07.1-05
/// hermeticity). Proves the security-critical argv contract end-to-end — the
/// spawned binary receives `[prompt]` as ONE argv element, never a concatenated
/// shell string routed through `/bin/sh -c`, so shell metacharacters are inert
/// (T-07.1-04 / T-6-04).
///
/// Relocated from `ClaudePromptTests.swift` into this dedicated file in plan
/// 07.1-02 (CQ-03) and extended with $PATH edge cases + a web-branch probe guard.
final class SystemClaudeHandoffTests: XCTestCase {

    // MARK: send — Web mode

    func testWebModeOpensEncodedURLViaInjectedOpener() throws {
        var opened: URL?
        var ran = false
        let handoff = SystemClaudeHandoff(
            open: { opened = $0 },
            runProcess: { _, _ in ran = true },
            locateBinary: {
                XCTFail("Web mode must not probe for the binary")
                return nil
            },
            action: { .web }
        )

        let result = handoff.send(prompt: "Help me with this task: write tests")

        XCTAssertTrue(result)
        XCTAssertFalse(ran, "Web mode must not spawn a process")
        let url = try XCTUnwrap(opened)
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.scheme, "https")
        XCTAssertEqual(comps.host, "claude.ai")
        XCTAssertEqual(comps.path, "/new")
        XCTAssertEqual(comps.queryItems?.first { $0.name == "q" }?.value,
                       "Help me with this task: write tests")
    }

    // MARK: send — Code mode

    func testCodeModeWithNoBinaryReturnsFalseAndDoesNotSpawn() {
        var ran = false
        let handoff = SystemClaudeHandoff(
            open: { _ in XCTFail("Code mode must not open a URL") },
            runProcess: { _, _ in ran = true },
            locateBinary: { nil },                 // no binary
            action: { .code }
        )

        let result = handoff.send(prompt: "anything")

        XCTAssertFalse(result, "Code mode with no binary must return false")
        XCTAssertFalse(ran, "No binary → no spawn")
    }

    func testCodeModeWithBinaryRunsSingleArgvAndReturnsTrue() {
        let bin = URL(fileURLWithPath: "/opt/homebrew/bin/claude")
        var spawnedBin: URL?
        var spawnedArgv: [String]?
        let handoff = SystemClaudeHandoff(
            open: { _ in XCTFail("Code mode must not open a URL") },
            runProcess: { b, argv in spawnedBin = b; spawnedArgv = argv },
            locateBinary: { bin },
            action: { .code }
        )

        // A prompt loaded with shell metacharacters — must pass through literally
        // as ONE argv element (no /bin/sh -c, no word-splitting).
        let dangerous = "do this; rm -rf / && echo $(whoami) `id` \"q\""
        let result = handoff.send(prompt: dangerous)

        XCTAssertTrue(result)
        XCTAssertEqual(spawnedBin, bin)
        XCTAssertEqual(spawnedArgv, [dangerous],
                       "Prompt must be the SINGLE argv element (no shell string)")
    }

    func testCodeModeSpawnThrowDegradesToFalse() {
        struct SpawnError: Error {}
        let handoff = SystemClaudeHandoff(
            open: { _ in },
            runProcess: { _, _ in throw SpawnError() },
            locateBinary: { URL(fileURLWithPath: "/opt/homebrew/bin/claude") },
            action: { .code }
        )
        XCTAssertFalse(handoff.send(prompt: "x"), "A launch throw must degrade to false")
    }

    // MARK: action read LIVE

    func testActionIsReadLivePerSend() {
        var current: ClaudeAction = .web
        var openedCount = 0
        var ranCount = 0
        let handoff = SystemClaudeHandoff(
            open: { _ in openedCount += 1 },
            runProcess: { _, _ in ranCount += 1 },
            locateBinary: { URL(fileURLWithPath: "/opt/homebrew/bin/claude") },
            action: { current }
        )

        XCTAssertTrue(handoff.send(prompt: "a"))   // web
        current = .code
        XCTAssertTrue(handoff.send(prompt: "b"))   // code — picked up live

        XCTAssertEqual(openedCount, 1)
        XCTAssertEqual(ranCount, 1)
    }

    // MARK: claudeBinaryAvailable

    func testBinaryAvailableTracksLocateBinary() {
        let present = SystemClaudeHandoff(
            locateBinary: { URL(fileURLWithPath: "/opt/homebrew/bin/claude") },
            action: { .code }
        )
        XCTAssertTrue(present.claudeBinaryAvailable())

        let absent = SystemClaudeHandoff(locateBinary: { nil }, action: { .code })
        XCTAssertFalse(absent.claudeBinaryAvailable())
    }

    // MARK: locateClaudeBinary — pure probe (candidate paths win over $PATH)

    func testLocateBinaryFindsStubExecutableAtCandidatePath() throws {
        // Point the probe at a real temp executable — proves a candidate-path
        // match without touching the machine's real /opt/homebrew etc.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = dir.appendingPathComponent("claude")
        FileManager.default.createFile(atPath: stub.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let found = SystemClaudeHandoff.locateClaudeBinary(
            candidatePaths: [stub.path],
            pathEnv: nil,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
        )
        XCTAssertEqual(found?.path, stub.path)
    }

    func testLocateBinaryReturnsNilWhenNoCandidateOrPathMatches() {
        let none = SystemClaudeHandoff.locateClaudeBinary(
            candidatePaths: ["/no/such/claude"],
            pathEnv: "/also/missing:/still/nope",
            isExecutable: { _ in false }
        )
        XCTAssertNil(none)
    }

    func testLocateBinaryPrefersCandidatePathOverPathEnv() {
        // Both "match" — the candidate path must win (trusted over $PATH, T-6-06).
        let found = SystemClaudeHandoff.locateClaudeBinary(
            candidatePaths: ["/opt/homebrew/bin/claude"],
            pathEnv: "/usr/bin",
            isExecutable: { _ in true }
        )
        XCTAssertEqual(found?.path, "/opt/homebrew/bin/claude")
    }

    func testLocateBinaryFallsBackToPathEnv() {
        let found = SystemClaudeHandoff.locateClaudeBinary(
            candidatePaths: ["/no/such/claude"],          // miss
            pathEnv: "/usr/bin:/some/dir",
            isExecutable: { $0 == "/some/dir/claude" }    // only the $PATH entry matches
        )
        XCTAssertEqual(found?.path, "/some/dir/claude")
    }

    func testLocateBinaryReturnsNilWithEmptyOrMissingPathEnv() {
        // Once the candidates miss, a nil or empty $PATH cannot produce a match.
        let nilPath = SystemClaudeHandoff.locateClaudeBinary(
            candidatePaths: ["/no/such/claude"],
            pathEnv: nil,
            isExecutable: { _ in false }
        )
        XCTAssertNil(nilPath)

        let emptyPath = SystemClaudeHandoff.locateClaudeBinary(
            candidatePaths: ["/no/such/claude"],
            pathEnv: "",
            isExecutable: { _ in false }
        )
        XCTAssertNil(emptyPath)
    }
}
