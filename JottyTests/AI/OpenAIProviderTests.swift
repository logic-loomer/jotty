// JottyTests/AI/OpenAIProviderTests.swift
// URLProtocol-stubbed tests for OpenAIProvider (plan 04-05, AI-SPEC §1.3).
// No live network: every HTTP exchange goes through StubURLProtocol.
// API keys come only from KeychainAPIKeyStore (UUID-suffixed test service,
// never the production service namespace).

import XCTest
@testable import Jotty

final class OpenAIProviderTests: XCTestCase {

    private var keychain: KeychainAPIKeyStore!
    private var service: String!
    private let sydney = TimeZone(identifier: "Australia/Sydney")!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        service = "com.jotty.api-keys.tests.openai.\(UUID().uuidString)"
        keychain = KeychainAPIKeyStore(service: service)
    }

    override func tearDown() {
        try? keychain.delete(account: "openai")
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
    ) throws -> OpenAIProvider {
        if withKey { try keychain.write(account: "openai", key: "sk-test-openai-key") }
        let sleeper: RetryPolicy.Sleeper = { nanos in recorder?.record(nanos) }
        return OpenAIProvider(
            keychain: keychain,
            session: StubURLProtocol.makeSession(),
            retry: RetryPolicy(sleeper: sleeper)
        )
    }

    private func extractError(
        _ provider: OpenAIProvider,
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

    /// Canonical Chat Completions 200: strict mode delivers the structured
    /// payload as a JSON STRING inside choices[0].message.content.
    private func happyPathJSON(
        title: String = "email Jamie about Q2 plan",
        dueDateISO: String = "2026-06-19"
    ) -> Data {
        let payload: [String: Any] = [
            "tasks": [[
                "title": title,
                "dueDateISO": dueDateISO,
                "blockStartISO": NSNull(),
                "blockEndISO": NSNull()
            ]]
        ]
        let content = String(
            data: try! JSONSerialization.data(withJSONObject: payload),
            encoding: .utf8)!
        return chatCompletionJSON(content: content)
    }

    /// A Chat Completions envelope with arbitrary content / refusal values.
    private func chatCompletionJSON(content: Any, refusal: Any = NSNull()) -> Data {
        let json: [String: Any] = [
            "id": "chatcmpl-01ABC",
            "object": "chat.completion",
            "model": "gpt-4o-mini",
            "choices": [[
                "index": 0,
                "message": [
                    "role": "assistant",
                    "content": content,
                    "refusal": refusal
                ],
                "finish_reason": "stop"
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

        // Request shape (AI-SPEC §1.3)
        XCTAssertEqual(StubURLProtocol.receivedRequests.count, 1)
        let request = try XCTUnwrap(StubURLProtocol.receivedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-openai-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let json = try requestBodyJSON()
        XCTAssertEqual(json["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(json["temperature"] as? Double, 0.0)
        let responseFormat = try XCTUnwrap(json["response_format"] as? [String: Any])
        XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
        let jsonSchema = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
        XCTAssertEqual(jsonSchema["name"] as? String, "ExtractionResult")
        XCTAssertEqual(jsonSchema["strict"] as? Bool, true)
        XCTAssertNotNil(jsonSchema["schema"], "schema must come from JSONSchemaBuilder.openAIStrict()")
        // Strict-mode invariant: additionalProperties false at the top level.
        let schema = try XCTUnwrap(jsonSchema["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
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
                      "No HTTP request may be made when the keychain has no openai entry")
    }

    // MARK: Test 3 — refusal via choices[0].message.refusal

    func testRefusalThrowsGuardrailWithProviderMessage() async throws {
        let body = chatCompletionJSON(content: NSNull(), refusal: "I can't help with that.")
        StubURLProtocol.responses.append { _ in (200, body, [:]) }
        let provider = try makeProvider()

        let error = await extractError(provider)
        XCTAssertEqual(error, .guardrail(message: "I can't help with that."))
    }

    // MARK: Test 4 — 401 unauthorised, no retries

    func testUnauthorizedThrowsModelUnavailableWithoutRetry() async throws {
        let errorBody = try JSONSerialization.data(withJSONObject: [
            "error": [
                "message": "Incorrect API key provided",
                "type": "invalid_request_error",
                "code": "invalid_api_key"
            ]
        ])
        StubURLProtocol.responses.append { _ in (401, errorBody, [:]) }
        let provider = try makeProvider()

        let error = await extractError(provider)
        guard case .modelUnavailable(let reason) = error else {
            return XCTFail("Expected .modelUnavailable, got \(String(describing: error))")
        }
        XCTAssertTrue(reason.contains("Invalid OpenAI API key"), "reason was: \(reason)")
        XCTAssertEqual(StubURLProtocol.receivedRequests.count, 1,
                       "401 is deterministic (AI-SPEC §8) — must not retry")
    }

    // MARK: Test 5 — 429 then success (RetryPolicy integration)

    func testRateLimitedOnceThenSuccessHonorsRetryAfter() async throws {
        let happy = happyPathJSON()
        StubURLProtocol.responses.append { _ in
            (429, Data("{\"error\":{\"message\":\"Rate limit reached\",\"type\":\"rate_limit_error\"}}".utf8),
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

    // MARK: Test 6 — context overflow

    func testContextLengthExceeded400ThrowsContextOverflow() async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "error": [
                "message": "This model's maximum context length is 128000 tokens.",
                "type": "invalid_request_error",
                "code": "context_length_exceeded"
            ]
        ])
        StubURLProtocol.responses.append { _ in (400, body, [:]) }
        let provider = try makeProvider()

        let error = await extractError(provider)
        XCTAssertEqual(error, .contextOverflow)
        XCTAssertEqual(StubURLProtocol.receivedRequests.count, 1,
                       "contextOverflow is non-retryable")
    }

    // MARK: Test 7 — content not parseable as ExtractionResultAI

    func testSchemaInvalidContentThrowsUnderlying() async throws {
        let body = chatCompletionJSON(content: "{\"foo\": \"bar\"}") // missing "tasks"
        StubURLProtocol.responses.append { _ in (200, body, [:]) }
        let provider = try makeProvider()

        let error = await extractError(provider)
        XCTAssertEqual(error, .underlying(message: "Provider returned invalid schema"),
                       "G2: invalid schema must NOT be repaired")
    }

    // MARK: Test 8 — anchor injection via ExtractionPrompt (system message)

    func testSystemMessageContainsNowAnchorAndTimezone() async throws {
        StubURLProtocol.responses.append { [body = happyPathJSON()] _ in (200, body, [:]) }
        let provider = try makeProvider()

        let now = Date(timeIntervalSince1970: 1_781_300_000) // fixed instant
        _ = try await provider.extractTasks(from: "renew domain by Friday", now: now, timezone: sydney)

        let json = try requestBodyJSON()
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)

        XCTAssertEqual(messages.first?["role"] as? String, "system")
        let system = try XCTUnwrap(messages.first?["content"] as? String)
        let expectedISO = ISO8601DateFormatter().string(from: now)
        XCTAssertTrue(system.contains(expectedISO),
                      "system prompt must anchor the supplied now (\(expectedISO)) verbatim")
        XCTAssertTrue(system.contains("Australia/Sydney"),
                      "system prompt must anchor the supplied timezone identifier")
        XCTAssertTrue(system.contains("Bare duration NEVER"),
                      "rules block must come from the shared ExtractionPrompt, not a copy")

        XCTAssertEqual(messages.last?["role"] as? String, "user")
        XCTAssertEqual(messages.last?["content"] as? String, "renew domain by Friday",
                       "user text travels as its own user-role message")
    }

    // MARK: Test 9 — empty content + no refusal (defensive)

    func testNilContentAndNilRefusalThrowsUnderlying() async throws {
        let body = chatCompletionJSON(content: NSNull(), refusal: NSNull())
        StubURLProtocol.responses.append { _ in (200, body, [:]) }
        let provider = try makeProvider()

        let error = await extractError(provider)
        XCTAssertEqual(error, .underlying(message: "Provider returned invalid schema"))
    }

    // MARK: Test 10 — request timeout is bounded (CQ-08)

    func testRequestTimeoutIntervalIsSixtySeconds() async throws {
        StubURLProtocol.responses.append { [body = happyPathJSON()] _ in (200, body, [:]) }
        let provider = try makeProvider()

        _ = try await provider.extractTasks(from: "email Jamie", now: Date(), timezone: sydney)

        let request = try XCTUnwrap(StubURLProtocol.receivedRequests.first)
        XCTAssertEqual(request.timeoutInterval, 60,
                       "cloud requests must bound hang time at 60s (CQ-08)")
    }
}
