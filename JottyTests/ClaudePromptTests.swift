import XCTest
@testable import Jotty

/// SC1 (Send-to-Claude): the pure prompt builder + Web URL builder + safe-argv
/// contract. RED in plan 06-01 (the `ClaudePrompt` type does not exist yet);
/// GREEN in plan 06-02 — that plan adds `Jotty/Claude/ClaudePrompt.swift`, then
/// removes the `#if false` guard + the `XCTFail` marker below to activate the
/// real assertions.
///
/// The guarded block is the executable contract 06-02 must satisfy:
///  - wrapped("...") wraps task text as "Help me with this task: <text>"
///  - webURL(...) is https://claude.ai/new?q=<URLComponents-encoded prompt>
///  - spaces, unicode, `&`, `=` are percent-encoded in the query value
///  - argv safety: the prompt is the SINGLE argv element (never a shell string),
///    so `;`, `$()`, backticks, `&&` are inert (no word-splitting / injection)
final class ClaudePromptTests: XCTestCase {

    func testWrapsTaskTextWithTemplate() {
        XCTAssertEqual(ClaudePrompt.wrapped("write tests"),
                       "Help me with this task: write tests")
    }

    func testWebURLIsEncodedClaudeNewQuery() throws {
        let url = try XCTUnwrap(ClaudePrompt.webURL(for: "write tests"))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.scheme, "https")
        XCTAssertEqual(comps.host, "claude.ai")
        XCTAssertEqual(comps.path, "/new")
        let q = try XCTUnwrap(comps.queryItems?.first { $0.name == "q" }?.value)
        XCTAssertEqual(q, "write tests")
    }

    func testWebURLEncodesSpacesUnicodeAmpersandEquals() throws {
        let raw = "a b & c = d 文字"
        let url = try XCTUnwrap(ClaudePrompt.webURL(for: raw))
        let s = url.absoluteString
        // No raw structural characters leak into the encoded query string.
        XCTAssertFalse(s.contains(" "))
        XCTAssertFalse(s.contains("& c"))
        XCTAssertFalse(s.contains("= d"))
        // Round-trips back to the original via URLComponents decoding.
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.queryItems?.first { $0.name == "q" }?.value, raw)
    }

    func testArgvIsSingleElementNotShellString() {
        // Code mode: the prompt must be a single argv element so shell
        // metacharacters are inert (no /bin/sh -c, no string concatenation).
        let dangerous = "do this; rm -rf / && echo $(whoami) `id`"
        let argv = ClaudePrompt.codeArgv(for: dangerous)
        XCTAssertEqual(argv, [dangerous])
    }
}

/// SC1 (Send-to-Claude) — the real `SystemClaudeHandoff` web/code branch + safe
/// Process spawn. Every OS effect is an injected closure: the suite NEVER opens a
/// browser, spawns `claude`, or scans `$PATH`. Proves the security-critical argv
/// contract end-to-end (the spawned process receives `[prompt]` as one element,
/// even for shell-metacharacter-laden prompts).
final class SystemClaudeHandoffTests: XCTestCase {

    // MARK: send — Web mode

    func testWebModeOpensEncodedURLViaInjectedOpener() throws {
        var opened: URL?
        var ran = false
        let handoff = SystemClaudeHandoff(
            open: { opened = $0 },
            runProcess: { _, _ in ran = true },
            locateBinary: { nil },
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
}
