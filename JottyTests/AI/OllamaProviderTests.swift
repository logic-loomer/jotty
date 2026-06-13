// JottyTests/AI/OllamaProviderTests.swift
// URLProtocol-stubbed tests for OllamaProvider (plan 04-09, AI-SPEC §1.1).
// No live network and no real daemon: every HTTP exchange goes through
// StubURLProtocol; the daemon-down case uses a dedicated protocol that fails
// with URLError(.cannotConnectToHost) like a refused localhost connection.

import XCTest
@testable import Jotty

/// Simulates a daemon that is not running: every request fails at the
/// transport layer with `URLError(.cannotConnectToHost)`. Records requests so
/// tests can assert that `/api/generate` is never attempted.
private final class ConnectionRefusedURLProtocol: URLProtocol {

    nonisolated(unsafe) static var receivedRequests: [URLRequest] = []

    static func reset() { receivedRequests = [] }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConnectionRefusedURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.receivedRequests.append(request)
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }

    override func stopLoading() {}
}

final class OllamaProviderTests: XCTestCase {

    private let sydney = TimeZone(identifier: "Australia/Sydney")!
    private let now = Date(timeIntervalSince1970: 1_781_300_000) // fixed instant

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        ConnectionRefusedURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        ConnectionRefusedURLProtocol.reset()
        super.tearDown()
    }

    // MARK: Helpers

    private func makeProvider(
        model: String = "qwen2.5:3b",
        session: URLSession? = nil
    ) -> OllamaProvider {
        OllamaProvider(model: model, session: session ?? StubURLProtocol.makeSession())
    }

    private func queueVersion(_ version: String) {
        let body = try! JSONSerialization.data(withJSONObject: ["version": version])
        StubURLProtocol.responses.append { _ in (200, body, [:]) }
    }

    /// Canonical `/api/generate` 200 envelope: the structured payload arrives
    /// as a JSON STRING in `response`.
    private func happyGenerateBody(
        title: String = "email Jamie about Q2 plan",
        dueDateISO: String? = "2026-06-19",
        blockStartISO: String? = nil,
        blockEndISO: String? = nil
    ) -> Data {
        let inner: [String: Any] = [
            "tasks": [[
                "title": title,
                "dueDateISO": dueDateISO as Any,
                "blockStartISO": blockStartISO as Any,
                "blockEndISO": blockEndISO as Any
            ]]
        ]
        let innerString = String(
            data: try! JSONSerialization.data(withJSONObject: inner), encoding: .utf8)!
        let envelope: [String: Any] = [
            "model": "qwen2.5:3b",
            "response": innerString,
            "done": true
        ]
        return try! JSONSerialization.data(withJSONObject: envelope)
    }

    private func requestBodyJSON(at index: Int) throws -> [String: Any] {
        let data = StubURLProtocol.receivedBodies[index]
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func extractError(
        _ provider: OllamaProvider,
        text: String = "buy milk tomorrow",
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

    private var sydneyCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = sydney
        return cal
    }

    // MARK: Test 1 — happy path (modern daemon, schema format)

    func testHappyPathWithSchemaFormatModernDaemon() async throws {
        queueVersion("0.5.1")
        StubURLProtocol.responses.append { [body = happyGenerateBody()] _ in (200, body, [:]) }
        let provider = makeProvider()

        let text = "email Jamie about Q2 plan by Friday"
        let result = try await provider.extractTasks(from: text, now: now, timezone: sydney)

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

        // Version probe ran BEFORE /api/generate
        XCTAssertEqual(StubURLProtocol.receivedRequests.count, 2)
        let versionRequest = try XCTUnwrap(StubURLProtocol.receivedRequests.first)
        XCTAssertEqual(versionRequest.url?.path, "/api/version")
        XCTAssertEqual(versionRequest.httpMethod, "GET")

        let generateRequest = try XCTUnwrap(StubURLProtocol.receivedRequests.last)
        XCTAssertEqual(generateRequest.url?.absoluteString,
                       "http://127.0.0.1:11434/api/generate")
        XCTAssertEqual(generateRequest.httpMethod, "POST")

        // Request body shape (AI-SPEC §1.1)
        let json = try requestBodyJSON(at: 1)
        XCTAssertEqual(json["model"] as? String, "qwen2.5:3b")
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertNotNil(json["format"] as? [String: Any],
                        "modern daemon (>= 0.5) must receive the JSON schema dict, not the string \"json\"")
        let options = try XCTUnwrap(json["options"] as? [String: Any])
        XCTAssertEqual(options["temperature"] as? Double, 0.0)

        // Prompt: shared rules + ISO anchor + timezone + user text
        let prompt = try XCTUnwrap(json["prompt"] as? String)
        let expectedISO = ISO8601DateFormatter().string(from: now)
        XCTAssertTrue(prompt.contains(expectedISO),
                      "prompt must anchor the supplied now (\(expectedISO)) verbatim")
        XCTAssertTrue(prompt.contains("Australia/Sydney"),
                      "prompt must anchor the supplied timezone identifier")
        XCTAssertTrue(prompt.contains(text), "user text must be appended to the prompt")
        XCTAssertTrue(prompt.contains("Bare duration NEVER"),
                      "rules block must come from the shared ExtractionPrompt, not a copy")
    }

    // MARK: Test 2 — legacy daemon (< 0.5) falls back to format: "json"

    func testLegacyDaemonFallsBackToJsonFormatString() async throws {
        queueVersion("0.4.9")
        StubURLProtocol.responses.append { [body = happyGenerateBody()] _ in (200, body, [:]) }
        let provider = makeProvider()

        let result = try await provider.extractTasks(
            from: "email Jamie about Q2 plan by Friday", now: now, timezone: sydney)

        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertEqual(result.tasks.first?.title, "email Jamie about Q2 plan")

        let json = try requestBodyJSON(at: 1)
        XCTAssertEqual(json["format"] as? String, "json",
                       "legacy daemon (< 0.5) must receive format: \"json\" as a string")
        XCTAssertNil(json["format"] as? [String: Any])
    }

    // MARK: Test 3 — daemon down maps to .modelUnavailable, no /api/generate

    func testDaemonDownThrowsModelUnavailableWithoutGenerateCall() async throws {
        let provider = makeProvider(session: ConnectionRefusedURLProtocol.makeSession())

        let error = await extractError(provider)
        guard case .modelUnavailable(let reason) = error else {
            return XCTFail("Expected .modelUnavailable, got \(String(describing: error))")
        }
        XCTAssertEqual(reason, "Ollama daemon not running. Start it from Settings → AI.")

        XCTAssertFalse(ConnectionRefusedURLProtocol.receivedRequests.isEmpty,
                       "version probe must be attempted")
        XCTAssertTrue(
            ConnectionRefusedURLProtocol.receivedRequests.allSatisfy {
                $0.url?.path == "/api/version"
            },
            "zero requests to /api/generate when the daemon is down")
    }

    // MARK: Test 4 — Ollama error body maps to .guardrail

    func testErrorBodyThrowsGuardrail() async throws {
        queueVersion("0.5.1")
        let errorBody = try JSONSerialization.data(withJSONObject: [
            "error": "model 'foo:bar' not found, try pulling it first"
        ])
        StubURLProtocol.responses.append { _ in (200, errorBody, [:]) }
        let provider = makeProvider(model: "foo:bar")

        let error = await extractError(provider)
        XCTAssertEqual(
            error,
            .guardrail(message: "model 'foo:bar' not found, try pulling it first"))
    }

    // MARK: Test 5 — schema mismatch maps to .underlying

    func testSchemaMismatchThrowsUnderlying() async throws {
        queueVersion("0.5.1")
        let badBody = try JSONSerialization.data(withJSONObject: [
            "response": "{\"tasks\":\"not an array\"}",
            "done": true
        ])
        StubURLProtocol.responses.append { _ in (200, badBody, [:]) }
        let provider = makeProvider()

        let error = await extractError(provider)
        XCTAssertEqual(error, .underlying(message: "Provider returned invalid schema"),
                       "G2: invalid schema must NOT be repaired")
    }

    // MARK: Test 6 — duration guardrail strips bogus timeBlocks post-extraction

    func testDurationGuardrailStripsBogusTimeBlock() async throws {
        queueVersion("0.5.1")
        // Model wrongly emitted a clock block for a bare duration phrase.
        let body = happyGenerateBody(
            title: "refactor work",
            dueDateISO: nil,
            blockStartISO: "2026-06-14T13:00:00+10:00",
            blockEndISO: "2026-06-14T14:00:00+10:00")
        StubURLProtocol.responses.append { _ in (200, body, [:]) }
        let provider = makeProvider()

        let text = "1-2 hours of refactor work tomorrow"
        let result = try await provider.extractTasks(from: text, now: now, timezone: sydney)

        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertNil(result.tasks.first?.timeBlock,
                     "duration phrase without clock anchor must strip the timeBlock")
        XCTAssertEqual(result.tasks.first?.calendarBlock, false)
        let cal = sydneyCalendar
        let expectedTomorrow = cal.date(
            byAdding: .day, value: 1, to: cal.startOfDay(for: now))
        XCTAssertEqual(result.tasks.first?.dueDate, expectedTomorrow,
                       "'tomorrow' must infer dueDate = tomorrow (Sydney)")
    }
}
