// JottyTests/Inbox/GitHubInboxSourceTests.swift
// Hermetic tests for GitHubInboxSource (plan 07-03, SC1). No live network:
// every HTTP exchange goes through StubURLProtocol. No real Keychain prompt:
// the PAT is written to a UUID-suffixed test service and deleted in tearDown,
// so the production "com.jotty.api-keys"/"github" item is never touched.

import XCTest
@testable import Jotty

final class GitHubInboxSourceTests: XCTestCase {

    private var keychain: KeychainAPIKeyStore!
    private var service: String!
    private let patAccount = "github"

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        // UUID-scoped service: a generic-password write/read here never prompts
        // and never collides with the production namespace.
        service = "com.jotty.api-keys.tests.github.\(UUID().uuidString)"
        keychain = KeychainAPIKeyStore(service: service)
    }

    override func tearDown() {
        try? keychain.delete(account: patAccount)
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: Helpers

    /// Builds the source over the stub session + a test-scoped Keychain. When
    /// `withPAT` is true a dummy PAT is seeded so `fetchItems()` proceeds.
    private func makeSource(withPAT: Bool = true) throws -> GitHubInboxSource {
        if withPAT { try keychain.write(account: patAccount, key: "test-pat-not-a-real-token") }
        return GitHubInboxSource(
            session: StubURLProtocol.makeSession(),
            keychain: keychain,
            patAccount: patAccount
        )
    }

    /// One issue/PR object for the `/issues` array body. `isPR` adds the
    /// `pull_request` key; `repo` adds the `repository.full_name` context.
    private func issueObject(
        id: Int, number: Int, title: String, htmlURL: String,
        updatedAt: String, repo: String? = nil, isPR: Bool = false
    ) -> [String: Any] {
        var obj: [String: Any] = [
            "id": id, "number": number, "title": title,
            "html_url": htmlURL, "updated_at": updatedAt
        ]
        if let repo { obj["repository"] = ["full_name": repo] }
        if isPR { obj["pull_request"] = ["url": "https://api.github.com/repos/x/y/pulls/\(number)"] }
        return obj
    }

    private func arrayBody(_ objects: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: objects)
    }

    private func searchBody(_ items: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["total_count": items.count, "items": items])
    }

    /// Queue the two happy-path responses (assigned array, then search envelope)
    /// in the FIFO order `fetchItems()` issues them.
    private func queue(assigned: Data, search: Data) {
        StubURLProtocol.responses.append { _ in (200, assigned, [:]) }
        StubURLProtocol.responses.append { _ in (200, search, [:]) }
    }

    // MARK: Test 1 — mapping (SC1)

    func testFetchMapsAssignedIssuesAndReviewRequestedPRs() async throws {
        let assigned = arrayBody([
            issueObject(id: 101, number: 7, title: "Fix login bug",
                        htmlURL: "https://github.com/org/repo/issues/7",
                        updatedAt: "2026-06-10T09:30:00Z", repo: "org/repo")
        ])
        let search = searchBody([
            issueObject(id: 202, number: 12, title: "Review PR for caching",
                        htmlURL: "https://github.com/org/repo/pull/12",
                        updatedAt: "2026-06-11T14:00:00Z", isPR: true)
        ])
        queue(assigned: assigned, search: search)
        let source = try makeSource()

        let items = try await source.fetchItems()

        XCTAssertEqual(items.count, 2)

        let issue = try XCTUnwrap(items.first { $0.id == "github:101" })
        XCTAssertEqual(issue.sourceID, "github")
        XCTAssertEqual(issue.url, "https://github.com/org/repo/issues/7")
        XCTAssertTrue(issue.title.contains("Fix login bug"))
        XCTAssertTrue(issue.title.contains("org/repo"), "repository.full_name must be in the title")
        // Non-default timestamp parsed from updated_at.
        let expected = ISO8601DateFormatter().date(from: "2026-06-10T09:30:00Z")
        XCTAssertEqual(issue.timestamp, expected)
        XCTAssertNotEqual(issue.timestamp, .distantPast)

        let pr = try XCTUnwrap(items.first { $0.id == "github:202" })
        XCTAssertEqual(pr.url, "https://github.com/org/repo/pull/12")
        XCTAssertEqual(pr.title, "Review PR for caching", "search items carry no repository — title-only")
    }

    // MARK: Test 2 — dedupe across both queries

    func testSameItemInBothQueriesDedupesToOne() async throws {
        // id 303 appears in BOTH the assigned array and the search items.
        let shared = issueObject(id: 303, number: 20, title: "Shared PR",
                                 htmlURL: "https://github.com/org/repo/pull/20",
                                 updatedAt: "2026-06-12T08:00:00Z")
        let assigned = arrayBody([
            issueObject(id: 404, number: 21, title: "Only assigned",
                        htmlURL: "https://github.com/org/repo/issues/21",
                        updatedAt: "2026-06-12T07:00:00Z"),
            shared
        ])
        let search = searchBody([shared])
        queue(assigned: assigned, search: search)
        let source = try makeSource()

        let items = try await source.fetchItems()

        XCTAssertEqual(items.filter { $0.id == "github:303" }.count, 1,
                       "the same composite id from both queries must collapse to one item")
        XCTAssertEqual(items.count, 2, "404 (assigned) + 303 (deduped) = 2")
    }

    // MARK: Test 3 — pull_request key on /issues

    func testAssignedPRAndReviewRequestedPRDoNotDoubleCount() async throws {
        // A PR object (has pull_request) in the assigned array AND the same
        // id in the review-requested search → exactly one item, not two.
        let prShared = issueObject(id: 505, number: 30, title: "Cross-listed PR",
                                   htmlURL: "https://github.com/org/repo/pull/30",
                                   updatedAt: "2026-06-13T10:00:00Z", repo: "org/repo", isPR: true)
        let assigned = arrayBody([prShared])
        let search = searchBody([
            issueObject(id: 505, number: 30, title: "Cross-listed PR",
                        htmlURL: "https://github.com/org/repo/pull/30",
                        updatedAt: "2026-06-13T10:00:00Z")
        ])
        queue(assigned: assigned, search: search)
        let source = try makeSource()

        let items = try await source.fetchItems()

        XCTAssertEqual(items.count, 1, "a PR in both the assigned array and the search must not double-count")
        XCTAssertEqual(items.first?.id, "github:505")
    }

    // MARK: Test 4 — 401 unauthorized

    func testUnauthorizedThrowsUnauthorized() async throws {
        StubURLProtocol.responses.append { _ in (401, Data("{\"message\":\"Bad credentials\"}".utf8), [:]) }
        let source = try makeSource()

        do {
            _ = try await source.fetchItems()
            XCTFail("Expected GitHubInboxError.unauthorized")
        } catch let error as GitHubInboxError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    // MARK: Test 5 — 429 rate limit

    func testRateLimitedThrowsRateLimited() async throws {
        StubURLProtocol.responses.append { _ in
            (429, Data("{\"message\":\"API rate limit exceeded\"}".utf8),
             ["X-RateLimit-Remaining": "0", "X-RateLimit-Resource": "search"])
        }
        let source = try makeSource()

        do {
            _ = try await source.fetchItems()
            XCTFail("Expected GitHubInboxError.rateLimited")
        } catch let error as GitHubInboxError {
            XCTAssertEqual(error, .rateLimited)
        }
    }

    // MARK: Test 6 — outbound headers

    func testRequestsCarryVerifiedHeaders() async throws {
        queue(assigned: arrayBody([]), search: searchBody([]))
        let source = try makeSource()

        _ = try await source.fetchItems()

        XCTAssertEqual(StubURLProtocol.receivedRequests.count, 2, "exactly two GETs: /issues + /search/issues")
        for request in StubURLProtocol.receivedRequests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-pat-not-a-real-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
        }
        let urls = StubURLProtocol.receivedRequests.compactMap { $0.url?.absoluteString }
        XCTAssertTrue(urls.contains { $0.contains("/issues?filter=assigned") }, "assigned-issues GET sent")
        XCTAssertTrue(urls.contains { $0.contains("/search/issues") }, "review-requested search GET sent")
    }

    // MARK: Test 7 — not configured (no PAT → no network)

    func testNotConfiguredThrowsAndMakesNoRequest() async throws {
        let source = try makeSource(withPAT: false)

        do {
            _ = try await source.fetchItems()
            XCTFail("Expected GitHubInboxError.notConfigured")
        } catch let error as GitHubInboxError {
            XCTAssertEqual(error, .notConfigured)
        }
        XCTAssertTrue(StubURLProtocol.receivedRequests.isEmpty,
                      "no network call may be made when the Keychain has no PAT")
        XCTAssertFalse(source.isConfigured)
    }

    // MARK: Test 8 — isConfigured reflects PAT presence

    func testIsConfiguredReflectsPATPresence() throws {
        let configured = try makeSource(withPAT: true)
        XCTAssertTrue(configured.isConfigured)

        try keychain.delete(account: patAccount)
        XCTAssertFalse(configured.isConfigured)
    }
}
