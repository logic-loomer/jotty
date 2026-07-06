// JottyTests/AI/GeminiProviderTests.swift
// URLProtocol-stubbed tests for GeminiProvider (plan 04-06, AI-SPEC §1.4).
// No live network: every HTTP exchange goes through StubURLProtocol.
// API keys come only from KeychainAPIKeyStore (UUID-suffixed test service,
// never the production service namespace).
//
// Gemini-specific security focus: the API key rides in the `x-goog-api-key`
// header (WR-06) — NEVER the `?key=` query form. Test 1 pins the header +
// key-free URL shape; test 11 keeps the leak canary asserting the key value
// NEVER appears in any thrown error message.

import XCTest
@testable import Jotty

final class GeminiProviderTests: XCTestCase {

    private var keychain: KeychainAPIKeyStore!
    private var service: String!
    private let sydney = TimeZone(identifier: "Australia/Sydney")!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        service = "com.jotty.api-keys.tests.gemini.\(UUID().uuidString)"
        keychain = KeychainAPIKeyStore(service: service)
    }

    override func tearDown() {
        try? keychain.delete(account: "gemini")
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: Helpers

    /// Records every nanosecond duration RetryPolicy asks to sleep, so retry
    /// tests never wait real wall-clock time.
    private final class SleepRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _naps: [UInt64] = []
        var naps: [UInt64] { lock.lock(); defer { lock.unlock() }; return _naps }
        func record(_ nanos: UInt64) { lock.lock(); defer { lock.unlock() }; _naps.append(nanos) }
    }

    private func makeProvider(
        withKey: Bool = true,
        key: String = "gm-test-gemini-key",
        recorder: SleepRecorder? = nil
    ) throws -> GeminiProvider {
        if withKey { try keychain.write(account: "gemini", key: key) }
        let sleeper: RetryPolicy.Sleeper = { nanos in recorder?.record(nanos) }
        return GeminiProvider(
            keychain: keychain,
            session: StubURLProtocol.makeSession(),
            retry: RetryPolicy(sleeper: sleeper)
        )
    }

    private func extractError(
        _ provider: GeminiProvider,
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

    /// Every human-readable string embedded in an AIProviderError, for
    /// key-redaction assertions.
    private func embeddedMessage(of error: AIProviderError?) -> String {
        switch error {
        case .modelUnavailable(let reason): return reason
        case .guardrail(let message): return message ?? ""
        case .underlying(let message): return message
        case .contextOverflow, nil: return ""
        }
    }

    /// Canonical generateContent 200 envelope: the structured payload is a
    /// JSON STRING inside candidates[0].content.parts[0].text.
    private func geminiEnvelope(text: String, finishReason: String = "STOP") -> Data {
        let json: [String: Any] = [
            "candidates": [[
                "content": [
                    "role": "model",
                    "parts": [["text": text]]
                ],
                "finishReason": finishReason
            ]]
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    /// Safety-refusal envelope: blocked candidates carry a finishReason but
    /// typically no content/parts at all.
    private func refusalEnvelope(finishReason: String) -> Data {
        let json: [String: Any] = [
            "candidates": [["finishReason": finishReason]]
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

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
        let text = String(
            data: try! JSONSerialization.data(withJSONObject: payload),
            encoding: .utf8)!
        return geminiEnvelope(text: text)
    }

    private func errorEnvelope(code: Int, status: String, message: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "error": ["code": code, "status": status, "message": message]
        ])
    }

    private func requestBodyJSON(at index: Int = 0) throws -> [String: Any] {
        let data = StubURLProtocol.receivedBodies[index]
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertGuardrail(
        finishReason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        StubURLProtocol.reset()
        StubURLProtocol.responses.append { [body = refusalEnvelope(finishReason: finishReason)] _ in
            (200, body, [:])
        }
        let provider = try makeProvider()

        let error = await extractError(provider, file: file, line: line)
        guard case .guardrail = error else {
            return XCTFail("Expected .guardrail for finishReason \(finishReason), got \(String(describing: error))",
                           file: file, line: line)
        }
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

        // Request shape (AI-SPEC §1.4)
        XCTAssertEqual(StubURLProtocol.receivedRequests.count, 1)
        let request = try XCTUnwrap(StubURLProtocol.receivedRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "generativelanguage.googleapis.com")
        XCTAssertEqual(components.path, "/v1beta/models/gemini-2.5-flash:generateContent")
        // WR-06: the key rides in the x-goog-api-key header (the idiom
        // APIKeyValidator.validateGemini pins) — it must NEVER appear in the
        // URL, where every URL-handling layer could log it.
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"),
                       "gm-test-gemini-key",
                       "API key must travel in the x-goog-api-key header")
        XCTAssertNil(components.queryItems,
                     "the request URL must carry no query items at all")
        XCTAssertFalse(url.absoluteString.contains("gm-test-gemini-key"),
                       "API key must never appear anywhere in the URL")

        // Body shape: responseMimeType + responseSchema (uppercase types)
        let json = try requestBodyJSON()
        let genConfig = try XCTUnwrap(json["generationConfig"] as? [String: Any])
        XCTAssertEqual(genConfig["responseMimeType"] as? String, "application/json")
        XCTAssertEqual(genConfig["temperature"] as? Double, 0.0)

        let schema = try XCTUnwrap(genConfig["responseSchema"] as? [String: Any],
                                   "responseSchema must come from JSONSchemaBuilder.geminiResponseSchema()")
        XCTAssertEqual(schema["type"] as? String, "OBJECT", "Gemini schema types are UPPERCASE")
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let tasksSchema = try XCTUnwrap(properties["tasks"] as? [String: Any])
        XCTAssertEqual(tasksSchema["type"] as? String, "ARRAY")
        let items = try XCTUnwrap(tasksSchema["items"] as? [String: Any])
        XCTAssertEqual(items["type"] as? String, "OBJECT")
        let itemProperties = try XCTUnwrap(items["properties"] as? [String: Any])
        XCTAssertEqual((itemProperties["title"] as? [String: Any])?["type"] as? String, "STRING")
        XCTAssertEqual((itemProperties["dueDateISO"] as? [String: Any])?["nullable"] as? Bool, true,
                       "optional fields use nullable: true in the Gemini dialect")
    }

    // MARK: Test 2 — missing keychain entry short-circuits before HTTP

    func testMissingKeychainEntryShortCircuitsWithoutHTTPCall() async throws {
        let provider = try makeProvider(withKey: false)

        let error = await extractError(provider)
        guard case .modelUnavailable(let reason) = error else {
            return XCTFail("Expected .modelUnavailable, got \(String(describing: error))")
        }
        XCTAssertTrue(reason.contains("Settings → AI"), "reason was: \(reason)")
        XCTAssertTrue(StubURLProtocol.receivedRequests.isEmpty,
                      "No HTTP request may be made when the keychain has no gemini entry")
    }

    // MARK: Tests 3-5 — safety finish reasons map to .guardrail

    func testSafetyFinishReasonThrowsGuardrail() async throws {
        try await assertGuardrail(finishReason: "SAFETY")
    }

    func testBlockedFinishReasonThrowsGuardrail() async throws {
        try await assertGuardrail(finishReason: "BLOCKED")
    }

    func testProhibitedContentFinishReasonThrowsGuardrail() async throws {
        try await assertGuardrail(finishReason: "PROHIBITED_CONTENT")
    }

    // MARK: Test 6 — 401/403 (HTTP-level or JSON envelope), no retries

    func testUnauthorizedThrowsModelUnavailableWithoutRetry() async throws {
        // Sub-case A: HTTP-level 401.
        StubURLProtocol.responses.append { [body = errorEnvelope(
            code: 401, status: "UNAUTHENTICATED",
            message: "Request had invalid authentication credentials.")] _ in
            (401, body, [:])
        }
        var provider = try makeProvider()

        var error = await extractError(provider)
        guard case .modelUnavailable(let reasonA) = error else {
            return XCTFail("Expected .modelUnavailable, got \(String(describing: error))")
        }
        XCTAssertTrue(reasonA.contains("Invalid Gemini API key"), "reason was: \(reasonA)")
        XCTAssertEqual(StubURLProtocol.receivedRequests.count, 1,
                       "401 is deterministic (AI-SPEC §8) — must not retry")

        // Sub-case B: HTTP 400 carrying a JSON envelope with error.code 403.
        StubURLProtocol.reset()
        StubURLProtocol.responses.append { [body = errorEnvelope(
            code: 403, status: "PERMISSION_DENIED",
            message: "Method doesn't allow unregistered callers.")] _ in
            (400, body, [:])
        }
        provider = try makeProvider()

        error = await extractError(provider)
        guard case .modelUnavailable(let reasonB) = error else {
            return XCTFail("Expected .modelUnavailable, got \(String(describing: error))")
        }
        XCTAssertTrue(reasonB.contains("Invalid Gemini API key"), "reason was: \(reasonB)")
        XCTAssertEqual(StubURLProtocol.receivedRequests.count, 1,
                       "envelope-level 403 is deterministic — must not retry")
    }

    // MARK: Test 7 — 429 then success (RetryPolicy integration)

    func testRateLimitedOnceThenSuccessRetriesWithDefaultBackoff() async throws {
        let happy = happyPathJSON()
        StubURLProtocol.responses.append { [body = self.errorEnvelope(
            code: 429, status: "RESOURCE_EXHAUSTED", message: "Quota exceeded.")] _ in
            (429, body, [:])
        }
        StubURLProtocol.responses.append { _ in (200, happy, [:]) }

        let recorder = SleepRecorder()
        let provider = try makeProvider(recorder: recorder)

        let result = try await provider.extractTasks(
            from: "email Jamie", now: Date(), timezone: sydney)

        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertEqual(StubURLProtocol.receivedRequests.count, 2)
        // Gemini does NOT emit Retry-After (AI-SPEC §8.3) — the default
        // backoff schedule applies: exactly one nonzero sleep before retry.
        XCTAssertEqual(recorder.naps.count, 1)
        XCTAssertGreaterThan(recorder.naps[0], 0,
                             "default backoff (250ms base ±50% jitter) must be used")
    }

    // MARK: Test 8 — context overflow

    func testInputTokenOverflow400ThrowsContextOverflow() async throws {
        StubURLProtocol.responses.append { [body = self.errorEnvelope(
            code: 400, status: "INVALID_ARGUMENT",
            message: "The input token count (1500000) exceeds the maximum number of tokens allowed (1048576).")] _ in
            (400, body, [:])
        }
        let provider = try makeProvider()

        let error = await extractError(provider)
        XCTAssertEqual(error, .contextOverflow)
        XCTAssertEqual(StubURLProtocol.receivedRequests.count, 1,
                       "contextOverflow is non-retryable")
    }

    // MARK: Test 9 — anchor injection via ExtractionPrompt

    func testPromptContainsNowAnchorAndTimezone() async throws {
        StubURLProtocol.responses.append { [body = happyPathJSON()] _ in (200, body, [:]) }
        let provider = try makeProvider()

        let now = Date(timeIntervalSince1970: 1_781_300_000) // fixed instant
        _ = try await provider.extractTasks(from: "renew domain by Friday", now: now, timezone: sydney)

        let json = try requestBodyJSON()
        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 1)
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        let prompt = try XCTUnwrap(parts.first?["text"] as? String)

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = sydney   // anchor renders in the supplied tz, not UTC
        let expectedISO = isoFormatter.string(from: now)
        XCTAssertTrue(prompt.contains(expectedISO),
                      "prompt must anchor the supplied now (\(expectedISO)) verbatim")
        XCTAssertTrue(prompt.contains("Australia/Sydney"),
                      "prompt must anchor the supplied timezone identifier")
        XCTAssertTrue(prompt.contains("Bare duration NEVER"),
                      "rules block must come from the shared ExtractionPrompt, not a copy")
        XCTAssertTrue(prompt.hasSuffix("\n\nUser text:\nrenew domain by Friday"),
                      "user text is appended after the shared prompt")
    }

    // MARK: Test 10 — text not JSON (model talked instead of emitting schema)

    func testNonJSONTextThrowsUnderlying() async throws {
        StubURLProtocol.responses.append { [body = geminiEnvelope(text: "I refuse")] _ in
            (200, body, [:])
        }
        let provider = try makeProvider()

        let error = await extractError(provider)
        XCTAssertEqual(error, .underlying(message: "Provider returned invalid schema"),
                       "G2: invalid schema must NOT be repaired")
    }

    // MARK: Test 11 — API key never appears in error messages

    func testAPIKeyNeverAppearsInErrorMessages() async throws {
        // Leak canary (kept post-WR-06 as defense in depth): use a
        // known-string key and grep every thrown error's embedded message —
        // no failure path may ever interpolate key material.
        StubURLProtocol.responses.append { _ in (404, Data("not found".utf8), [:]) }
        var provider = try makeProvider(key: "SUPERSECRET")

        var error = await extractError(provider)
        XCTAssertNotNil(error)
        XCTAssertFalse(embeddedMessage(of: error).contains("SUPERSECRET"),
                       "key leaked into error message: \(embeddedMessage(of: error))")

        // Exhausted-retries path (429 on every attempt) must also be clean.
        StubURLProtocol.reset()
        StubURLProtocol.responses.append { [body = self.errorEnvelope(
            code: 429, status: "RESOURCE_EXHAUSTED", message: "Quota exceeded.")] _ in
            (429, body, [:])
        }
        provider = try makeProvider(key: "SUPERSECRET")

        error = await extractError(provider)
        XCTAssertNotNil(error)
        XCTAssertFalse(embeddedMessage(of: error).contains("SUPERSECRET"),
                       "key leaked into retry-exhausted error message: \(embeddedMessage(of: error))")
    }

    // MARK: Test 12 — request timeout is bounded (CQ-08)

    func testRequestTimeoutIntervalIsSixtySeconds() async throws {
        StubURLProtocol.responses.append { [body = happyPathJSON()] _ in (200, body, [:]) }
        let provider = try makeProvider()

        _ = try await provider.extractTasks(from: "email Jamie", now: Date(), timezone: sydney)

        let request = try XCTUnwrap(StubURLProtocol.receivedRequests.first)
        XCTAssertEqual(request.timeoutInterval, 60,
                       "cloud requests must bound hang time at 60s (CQ-08)")
    }
}
