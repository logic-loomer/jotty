// JottyTests/AI/ClaudeProviderTests.swift
// URLProtocol-stubbed tests for ClaudeProvider (plan 04-04, AI-SPEC §1.2).
// No live network: every HTTP exchange goes through StubURLProtocol.
// API keys come only from KeychainAPIKeyStore (UUID-suffixed test service,
// never the production service namespace).

import XCTest
@testable import Jotty

final class ClaudeProviderTests: XCTestCase {

    private var keychain: KeychainAPIKeyStore!
    private var service: String!
    private let sydney = TimeZone(identifier: "Australia/Sydney")!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        service = "com.jotty.api-keys.tests.claude.\(UUID().uuidString)"
        keychain = KeychainAPIKeyStore(service: service)
    }

    override func tearDown() {
        try? keychain.delete(account: "claude")
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: Helpers

    /// Records every nanosecond duration RetryPolicy asks to sleep, so retry
    /// tests never wait real wall-clock time and can assert Retry-After honor.
    private final class SleepRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _naps: [UInt64] = []
        var naps: [UInt64] { lock.lock(); defer { lock.unlock() }; return _naps }
        func record(_ nanos: UInt64) { lock.lock(); defer { lock.unlock() }; _naps.append(nanos) }
    }

    private func makeProvider(
        withKey: Bool = true,
        recorder: SleepRecorder? = nil
    ) throws -> ClaudeProvider {
        if withKey { try keychain.write(account: "claude", key: "sk-test-claude-key") }
        let sleeper: RetryPolicy.Sleeper = { nanos in recorder?.record(nanos) }
        return ClaudeProvider(
            keychain: keychain,
            session: StubURLProtocol.makeSession(),
            retry: RetryPolicy(sleeper: sleeper)
        )
    }

    private func extractError(
        _ provider: ClaudeProvider,
        text: String = "buy milk tomorrow",
        now: Date = Date(),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> AIProviderError? {
        do {
            _ = try await provider.extractTasks(from: text, now: now, timezone: sydney)
            XCTFail("Expected AIProviderError, got success", file: file, line: line)
            return nil
        } catch let error as AIProviderError {
            return error
        } catch {
            XCTFail("Expected AIProviderError, got \(error)", file: file, line: line)
            return nil
        }
    }

    /// Canonical Anthropic Messages 200 with one tool_use content block.
    private func happyPathJSON(
        title: String = "email Jamie about Q2 plan",
        dueDateISO: String = "2026-06-19"
    ) -> Data {
        let json: [String: Any] = [
            "id": "msg_01ABC",
            "type": "message",
            "role": "assistant",
            "model": "claude-haiku-4-5",
            "stop_reason": "tool_use",
            "content": [[
                "type": "tool_use",
                "id": "toolu_01XYZ",
                "name": "emit_tasks",
                "input": [
                    "tasks": [[
                        "title": title,
                        "dueDateISO": dueDateISO,
                        "blockStartISO": NSNull(),
                        "blockEndISO": NSNull()
                    ]]
                ]
            ]]
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func requestBodyJSON(at index: Int = 0) throws -> [String: Any] {
        let data = StubURLProtocol.receivedBodies[index]
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Test 1 — happy path

    func testHappyPathReturnsExtractedTasks() async throws {
        let body = happyPathJSON()
        StubURLProtocol.responses.append { _ in (200, body, [:]) }
        let provider = try makeProvider()

        let text = "email Jamie about Q2 plan by Friday"
        let result = try await provider.extractTasks(from: text, now: Date(), timezone: sydney)

        // Parsed result
        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertEqual(result.tasks.first?.title, "email Jamie about Q2 plan")
        XCTAssertEqual(result.noteBody, text)

        let dayFmt = DateFormatter()
        dayFmt.calendar = Calendar(identifier: .gregorian)
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.timeZone = sydney
        dayFmt.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(result.tasks.first?.dueDate, dayFmt.date(from: "2026-06-19"))
        XCTAssertNil(result.tasks.first?.timeBlock)

        // Request shape (AI-SPEC §1.2)
        XCTAssertEqual(StubURLProtocol.receivedRequests.count, 1)
        let request = try XCTUnwrap(StubURLProtocol.receivedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test-claude-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/json")

        let json = try requestBodyJSON()
        XCTAssertEqual(json["model"] as? String, "claude-haiku-4-5")
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["name"] as? String, "emit_tasks")
        XCTAssertNotNil(tools.first?["input_schema"], "input_schema must come from JSONSchemaBuilder")
        let toolChoice = try XCTUnwrap(json["tool_choice"] as? [String: Any])
        XCTAssertEqual(toolChoice["type"] as? String, "tool")
        XCTAssertEqual(toolChoice["name"] as? String, "emit_tasks")
    }

    // MARK: Test 2 — missing keychain entry short-circuits before HTTP

    func testMissingKeychainEntryShortCircuitsWithoutHTTPCall() async throws {
        // Fresh keychain service; deliberately NO key written.
        let provider = try makeProvider(withKey: false)

        let error = await extractError(provider)
        guard case .modelUnavailable(let reason) = error else {
            return XCTFail("Expected .modelUnavailable, got \(String(describing: error))")
        }
        XCTAssertTrue(reason.contains("Settings → AI"), "reason was: \(reason)")
        XCTAssertTrue(StubURLProtocol.receivedRequests.isEmpty,
                      "No HTTP request may be made when the keychain has no claude entry")
    }

    // MARK: Test 3 — 401 unauthorised, no retries

    func testUnauthorizedThrowsModelUnavailableWithoutRetry() async throws {
        let errorBody = try JSONSerialization.data(withJSONObject: [
            "type": "error",
            "error": ["type": "authentication_error", "message": "invalid x-api-key"]
        ])
        StubURLProtocol.responses.append { _ in (401, errorBody, [:]) }
        let provider = try makeProvider()

        let error = await extractError(provider)
        guard case .modelUnavailable(let reason) = error else {
            return XCTFail("Expected .modelUnavailable, got \(String(describing: error))")
        }
        XCTAssertTrue(reason.contains("Invalid Claude API key"), "reason was: \(reason)")
        XCTAssertEqual(StubURLProtocol.receivedRequests.count, 1,
                       "401 is deterministic (AI-SPEC §8) — must not retry")
    }

    // MARK: Test 4 — 429 then success (RetryPolicy integration)

    func testRateLimitedOnceThenSuccessHonorsRetryAfter() async throws {
        let happy = happyPathJSON()
        StubURLProtocol.responses.append { _ in
            (429, Data("{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow down\"}}".utf8),
             ["retry-after": "0"])
        }
        StubURLProtocol.responses.append { _ in (200, happy, [:]) }

        let recorder = SleepRecorder()
        let provider = try makeProvider(recorder: recorder)

        let result = try await provider.extractTasks(
            from: "email Jamie", now: Date(), timezone: sydney)

        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertEqual(StubURLProtocol.receivedRequests.count, 2)
        // Retry-After: 0 is authoritative — the single backoff sleep is exactly 0ns.
        XCTAssertEqual(recorder.naps, [0],
                       "Retry-After header value must be honored verbatim")
    }

    // MARK: Test 5 — 429 exhausted after 3 total attempts

    func testRateLimitedOnEveryCallExhaustsAfterThreeAttempts() async throws {
        StubURLProtocol.responses.append { _ in
            (429, Data("{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow down\"}}".utf8), [:])
        }
        let provider = try makeProvider(recorder: SleepRecorder())

        let error = await extractError(provider)
        guard case .modelUnavailable(let reason) = error else {
            return XCTFail("Expected .modelUnavailable, got \(String(describing: error))")
        }
        XCTAssertTrue(reason.contains("Rate limited"), "reason was: \(reason)")
        XCTAssertEqual(StubURLProtocol.receivedRequests.count, 3,
                       "RetryPolicy default = 3 total attempts")
    }

    // MARK: Test 6 — refusal via stop_reason

    func testRefusalStopReasonThrowsGuardrail() async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "id": "msg_01",
            "type": "message",
            "stop_reason": "refusal",
            "content": []
        ])
        StubURLProtocol.responses.append { _ in (200, body, [:]) }
        let provider = try makeProvider()

        let error = await extractError(provider)
        XCTAssertEqual(error, .guardrail(message: nil))
    }

    // MARK: Test 7 — refusal via missing tool_use block

    func testMissingToolUseBlockThrowsGuardrail() async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "id": "msg_01",
            "type": "message",
            "stop_reason": "tool_use",
            "content": [["type": "text", "text": "I would rather chat about this."]]
        ])
        StubURLProtocol.responses.append { _ in (200, body, [:]) }
        let provider = try makeProvider()

        let error = await extractError(provider)
        XCTAssertEqual(error, .guardrail(message: nil))
    }

    // MARK: Test 8 — context overflow

    func testContextOverflow400ThrowsContextOverflow() async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "type": "error",
            "error": [
                "type": "invalid_request_error",
                "message": "prompt is too long: 250000 tokens > 200000 maximum context window"
            ]
        ])
        StubURLProtocol.responses.append { _ in (400, body, [:]) }
        let provider = try makeProvider()

        let error = await extractError(provider)
        XCTAssertEqual(error, .contextOverflow)
        XCTAssertEqual(StubURLProtocol.receivedRequests.count, 1,
                       "contextOverflow is non-retryable")
    }

    // MARK: Test 9 — schema-invalid tool_use input

    func testSchemaInvalidToolInputThrowsUnderlying() async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "id": "msg_01",
            "type": "message",
            "stop_reason": "tool_use",
            "content": [[
                "type": "tool_use",
                "id": "toolu_01",
                "name": "emit_tasks",
                "input": ["items": ["not", "the", "schema"]]  // missing "tasks"
            ]]
        ])
        StubURLProtocol.responses.append { _ in (200, body, [:]) }
        let provider = try makeProvider()

        let error = await extractError(provider)
        XCTAssertEqual(error, .underlying(message: "Provider returned invalid schema"),
                       "G2: invalid schema must NOT be repaired")
    }

    // MARK: Test 10 — anchor injection via ExtractionPrompt

    func testRequestBodyContainsNowAnchorAndTimezone() async throws {
        StubURLProtocol.responses.append { [body = happyPathJSON()] _ in (200, body, [:]) }
        let provider = try makeProvider()

        let now = Date(timeIntervalSince1970: 1_781_300_000) // fixed instant
        _ = try await provider.extractTasks(from: "renew domain by Friday", now: now, timezone: sydney)

        let json = try requestBodyJSON()
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        let content = try XCTUnwrap(messages.first?["content"] as? String)

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = sydney   // anchor renders in the supplied tz, not UTC
        let expectedISO = isoFormatter.string(from: now)
        XCTAssertTrue(content.contains(expectedISO),
                      "prompt must anchor the supplied now (\(expectedISO)) verbatim")
        XCTAssertTrue(content.contains("Australia/Sydney"),
                      "prompt must anchor the supplied timezone identifier")
        XCTAssertTrue(content.contains("renew domain by Friday"),
                      "user text must be appended to the prompt")
        XCTAssertTrue(content.contains("Bare duration NEVER"),
                      "rules block must come from the shared ExtractionPrompt, not a copy")
    }

    // MARK: Test 11 — request timeout is bounded (CQ-08)

    func testRequestTimeoutIntervalIsSixtySeconds() async throws {
        StubURLProtocol.responses.append { [body = happyPathJSON()] _ in (200, body, [:]) }
        let provider = try makeProvider()

        _ = try await provider.extractTasks(from: "email Jamie", now: Date(), timezone: sydney)

        let request = try XCTUnwrap(StubURLProtocol.receivedRequests.first)
        XCTAssertEqual(request.timeoutInterval, 60,
                       "cloud requests must bound hang time at 60s (CQ-08)")
    }
}
