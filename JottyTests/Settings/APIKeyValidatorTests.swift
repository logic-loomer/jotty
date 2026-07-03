// JottyTests/Settings/APIKeyValidatorTests.swift
// UX-12 (plan 07.1-10): StubURLProtocol tests for APIKeyValidator.
// No live network: every probe goes through StubURLProtocol. Pins the
// three-state status mapping, the per-vendor request shape (endpoint + auth
// header name), the 15s probe timeout, and the host-only unreachable payload.

import XCTest
@testable import Jotty

final class APIKeyValidatorTests: XCTestCase {

    private var validator: APIKeyValidator!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        validator = APIKeyValidator(session: StubURLProtocol.makeSession())
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: Helpers

    private func stub(status: Int) {
        StubURLProtocol.responses.append { _ in (status, Data("{}".utf8), [:]) }
    }

    private func recordedRequest(
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> URLRequest {
        XCTAssertEqual(StubURLProtocol.receivedRequests.count, 1,
                       "a probe must make exactly one lightweight call",
                       file: file, line: line)
        return try XCTUnwrap(StubURLProtocol.receivedRequests.first, file: file, line: line)
    }

    // MARK: Status mapping — valid / rejected / unreachable

    func testHTTP200MapsToValid() async {
        stub(status: 200)
        let result = await validator.validateAnthropic(key: "sk-ant-test")
        XCTAssertEqual(result, .valid)
    }

    func testHTTP401MapsToRejected() async {
        stub(status: 401)
        let result = await validator.validateOpenAI(key: "sk-oa-test")
        XCTAssertEqual(result, .rejected)
    }

    func testHTTP403MapsToRejected() async {
        stub(status: 403)
        let result = await validator.validateGitHubPAT(key: "ghp_test")
        XCTAssertEqual(result, .rejected)
    }

    /// Endpoint live-verified 2026-07-03: Gemini answers an invalid key with
    /// HTTP 400 (INVALID_ARGUMENT / API_KEY_INVALID), not 401/403 — a rejected
    /// Gemini key must NOT read as "unreachable".
    func testGeminiHTTP400MapsToRejected() async {
        stub(status: 400)
        let result = await validator.validateGemini(key: "AIza-test")
        XCTAssertEqual(result, .rejected)
    }

    /// 400 stays out of the rejected set for vendors whose auth failures are
    /// real 401/403s — only Gemini widens the mapping.
    func testOpenAIHTTP400MapsToUnreachableNotRejected() async {
        stub(status: 400)
        let result = await validator.validateOpenAI(key: "sk-oa-test")
        XCTAssertEqual(result, .unreachable(host: "api.openai.com"))
    }

    func testServerErrorMapsToUnreachableWithHostOnly() async {
        stub(status: 500)
        let result = await validator.validateAnthropic(key: "sk-ant-test")
        XCTAssertEqual(result, .unreachable(host: "api.anthropic.com"))
    }

    /// StubURLProtocol fails the load when no response is queued — that
    /// surfaces as a thrown transport error, i.e. the URLError path.
    func testTransportErrorMapsToUnreachableWithHostOnly() async {
        let result = await validator.validateGemini(key: "AIza-test")
        XCTAssertEqual(result, .unreachable(host: "generativelanguage.googleapis.com"))
    }

    /// The unreachable payload is the bare host — no scheme, path, query, or key.
    func testUnreachablePayloadCarriesHostOnly() async {
        stub(status: 503)
        let result = await validator.validateGitHubPAT(key: "ghp_secret")
        guard case .unreachable(let host) = result else {
            return XCTFail("expected .unreachable, got \(result)")
        }
        XCTAssertEqual(host, "api.github.com")
        XCTAssertFalse(host.contains("/"), "host must carry no path")
        XCTAssertFalse(host.contains("ghp_secret"), "host must never carry the key")
    }

    // MARK: Request shape per vendor (Pattern 11 endpoint table)

    func testAnthropicRequestShape() async throws {
        stub(status: 200)
        _ = await validator.validateAnthropic(key: "sk-ant-test")

        let request = try recordedRequest()
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                     "Anthropic auth is x-api-key, not Bearer")
        XCTAssertEqual(request.timeoutInterval, 15, "probe must fail fast (T-07.1-22)")
    }

    func testOpenAIRequestShape() async throws {
        stub(status: 200)
        _ = await validator.validateOpenAI(key: "sk-oa-test")

        let request = try recordedRequest()
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-oa-test")
        XCTAssertEqual(request.timeoutInterval, 15, "probe must fail fast (T-07.1-22)")
    }

    func testGeminiRequestShape() async throws {
        stub(status: 200)
        _ = await validator.validateGemini(key: "AIza-test")

        let request = try recordedRequest()
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "AIza-test")
        XCTAssertNil(request.url?.query(),
                     "the key goes in the header — never the ?key= query form")
        XCTAssertEqual(request.timeoutInterval, 15, "probe must fail fast (T-07.1-22)")
    }

    func testGitHubPATRequestShape() async throws {
        stub(status: 200)
        _ = await validator.validateGitHubPAT(key: "ghp_test")

        let request = try recordedRequest()
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/rate_limit")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ghp_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
        XCTAssertEqual(request.timeoutInterval, 15, "probe must fail fast (T-07.1-22)")
    }

    /// The key never leaks into any probe URL, for any vendor.
    func testKeyNeverAppearsInAnyProbeURL() async throws {
        let key = "leak-canary-key"
        for vendor: APIKeyValidator.Vendor in [.anthropic, .openai, .gemini, .githubPAT] {
            StubURLProtocol.reset()
            stub(status: 200)
            _ = await validator.validate(vendor, key: key)
            let request = try recordedRequest()
            let url = try XCTUnwrap(request.url?.absoluteString)
            XCTAssertFalse(url.contains(key), "key leaked into URL for \(vendor): \(url)")
        }
    }

    // MARK: Vendor dispatch

    func testValidateDispatchesToMatchingVendorEndpoint() async throws {
        stub(status: 200)
        _ = await validator.validate(.openai, key: "sk-oa-test")
        let request = try recordedRequest()
        XCTAssertEqual(request.url?.host(), "api.openai.com")
    }
}
