// Jotty/Inbox/GitHubInboxSource.swift
// The one shipped concrete InboxSource (SC1, plan 07-03): GitHub via a
// Personal Access Token. Fetches assigned issues and review-requested PRs,
// decodes the GitHub REST JSON with Codable, and maps both queries into
// deduped InboxItems behind the InboxSource seam.
//
// Query choice (RESEARCH A1): assigned issues (`/issues?filter=assigned`)
// + review-requested PRs (`/search/issues ... review-requested:@me`). Either
// subset satisfies SC1; both give the fuller "what needs me" inbox.
//
// Secret hygiene (T-7-06): the PAT is read from KeychainAPIKeyStore at call
// time only. It is held in a local and placed straight into the Authorization
// header — never logged, never written to any on-disk store.
//
// Network (T-7-07): the base host is HTTPS-only (`https://api.github.com`);
// URLSession enforces ATS. The verified `X-GitHub-Api-Version` header is sent
// on every request.

import Foundation

/// Typed errors surfaced by `GitHubInboxSource.fetchItems()`. `InboxService`'s
/// tolerant fan-out (plan 07-02) catches these via `try?`, so a thrown error
/// degrades to "no items from this source this refresh" rather than a crash.
enum GitHubInboxError: Error, Equatable {
    /// No PAT in the Keychain — `fetchItems()` must not hit the network.
    case notConfigured
    /// HTTP 401: bad/expired PAT. Surface in Integrations; do not retry (T-7-08).
    case unauthorized
    /// HTTP 403/429 that is a primary rate limit (`X-RateLimit-Remaining: 0`) OR a
    /// secondary/abuse limit (`Retry-After` present, no `Remaining: 0`). Do not retry
    /// until reset/Retry-After (RESEARCH Pitfall 1, WR-04); the service swallows it.
    case rateLimited
    /// Any other non-2xx status from GitHub.
    case httpStatus(Int)
    /// A non-HTTP `URLResponse` came back (should never happen over HTTPS).
    case nonHTTPResponse
}

/// GitHub inbox source: assigned issues + review-requested PRs → `InboxItem`s.
///
/// Conforms to `InboxSource`; `id` matches the `github` catalog entry
/// (`InboxSourceCatalog`, built: true). All collaborators (`URLSession`,
/// `KeychainAPIKeyStore`, PAT account) are injectable so the suite drives it
/// hermetically through `StubURLProtocol` with a test-scoped Keychain.
struct GitHubInboxSource: InboxSource {

    // MARK: InboxSource identity (matches InboxSourceCatalog `github`)

    let id = "github"
    let displayName = "GitHub"
    let endpointURL = "https://api.github.com"

    // MARK: Injected collaborators

    private let session: URLSession
    private let keychain: KeychainAPIKeyStore
    private let patAccount: String

    /// - Parameters:
    ///   - session: HTTP transport; tests inject `StubURLProtocol.makeSession()`.
    ///   - keychain: PAT store; tests inject a UUID-scoped test service.
    ///   - patAccount: Keychain account under which the PAT is stored.
    init(session: URLSession = .shared,
         keychain: KeychainAPIKeyStore = KeychainAPIKeyStore(),
         patAccount: String = "github") {
        self.session = session
        self.keychain = keychain
        self.patAccount = patAccount
    }

    // MARK: Configuration

    /// True iff the Keychain holds a PAT under `patAccount`. A throwing read is
    /// treated as not-configured so a transient Keychain error never crashes
    /// the privacy gate; `fetchItems()` re-reads and throws on a genuine miss.
    var isConfigured: Bool {
        ((try? keychain.read(account: patAccount)) ?? nil) != nil
    }

    // MARK: Endpoints

    private static let assignedIssuesURL = URL(
        string: "https://api.github.com/issues?filter=assigned&state=open&per_page=50")!
    private static let reviewRequestedURL = URL(
        string: "https://api.github.com/search/issues?q=is:open+is:pr+review-requested:@me&per_page=50")!

    /// A fresh ISO8601 parser with `Z` zone (RFC3339), matching GitHub
    /// `updated_at` and the `MarkdownDoc` `created:`/`done:` parse idiom.
    /// Built per call (like `MarkdownDoc`) because `ISO8601DateFormatter` is
    /// not `Sendable` — a shared static would break Swift 6 concurrency safety.
    private static func makeISO8601() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    // MARK: Fetch

    /// Issues TWO GETs (assigned issues + review-requested PRs), decodes each,
    /// maps both into `InboxItem`s, and dedupes by the composite `github:<id>`
    /// (Pitfall 2: the same PR can appear in both queries). Throws a typed
    /// `GitHubInboxError` on a missing PAT or any non-2xx status.
    func fetchItems() async throws -> [InboxItem] {
        // Read the PAT from the Keychain at call time only (T-7-06). A read
        // error or a missing entry means not-configured — no network.
        let pat: String
        do {
            guard let stored = try keychain.read(account: patAccount) else {
                throw GitHubInboxError.notConfigured
            }
            pat = stored
        } catch let error as GitHubInboxError {
            throw error
        } catch {
            throw GitHubInboxError.notConfigured
        }

        // Endpoint 1: assigned issues (array body; mixes issues + PRs).
        let assigned: [GitHubIssue] = try await fetch(
            [GitHubIssue].self, from: Self.assignedIssuesURL, pat: pat)
        // Endpoint 2: review-requested PRs (search envelope).
        let search: GitHubSearchResponse = try await fetch(
            GitHubSearchResponse.self, from: Self.reviewRequestedURL, pat: pat)

        // Merge + dedupe by composite id. Insertion order preserved so the
        // assigned-issues items lead; the first occurrence of an id wins
        // (Pitfall 2 — the duplicate PR in /search collapses into the same row).
        var seen = Set<String>()
        var items: [InboxItem] = []
        for issue in assigned + search.items {
            let item = map(issue)
            if seen.insert(item.id).inserted {
                items.append(item)
            }
        }
        return items
    }

    // MARK: Request / decode

    /// Builds a GitHub request with the verified headers and decodes the typed
    /// body, mapping HTTP status to a `GitHubInboxError` (mirrors ClaudeProvider's
    /// Bearer + JSONDecoder idiom).
    private func fetch<T: Decodable>(
        _ type: T.Type, from url: URL, pat: String
    ) async throws -> T {
        let request = Self.makeRequest(url, pat: pat)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            // Never let the raw PAT-bearing URLError detail escape; map to a
            // detail-free transport status the service can swallow.
            throw GitHubInboxError.httpStatus(urlError.code.rawValue)
        }

        guard let http = response as? HTTPURLResponse else {
            throw GitHubInboxError.nonHTTPResponse
        }

        switch http.statusCode {
        case 200...299:
            break
        case 401:
            throw GitHubInboxError.unauthorized
        case 403, 429:
            // Rate limited iff the primary bucket is exhausted
            // (`X-RateLimit-Remaining` trimmed == "0", RESEARCH Pitfall 1) OR GitHub
            // signalled a secondary/abuse limit, which omits `X-RateLimit-Remaining: 0`
            // and instead carries a `Retry-After` header (WR-04). Either signal maps to
            // the typed `rateLimited` Integrations surfaces; anything else is a generic
            // forbidden. The header is trimmed so a stray " 0" is not mis-classified.
            let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining")?
                .trimmingCharacters(in: .whitespaces)
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")?
                .trimmingCharacters(in: .whitespaces)
            if remaining == "0" || (retryAfter?.isEmpty == false) {
                throw GitHubInboxError.rateLimited
            }
            throw GitHubInboxError.httpStatus(http.statusCode)
        default:
            throw GitHubInboxError.httpStatus(http.statusCode)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }

    /// Verified GitHub headers (RESEARCH "GitHub request"): Bearer PAT,
    /// `application/vnd.github+json`, pinned `X-GitHub-Api-Version`.
    private static func makeRequest(_ url: URL, pat: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    // MARK: Mapping

    /// Maps one decoded GitHub issue/PR into an `InboxItem`. The id is the
    /// composite `github:<id>` (stable numeric id → space-free dedupe key and
    /// `source:` token payload). Repository context, when present (issues only),
    /// is prefixed to the title for display.
    private func map(_ issue: GitHubIssue) -> InboxItem {
        let timestamp = Self.makeISO8601().date(from: issue.updatedAt) ?? .distantPast
        let title: String
        if let repo = issue.repository?.fullName, !repo.isEmpty {
            title = "\(repo) #\(issue.number) — \(issue.title)"
        } else {
            title = issue.title
        }
        return InboxItem(
            id: "\(id):\(issue.id)",
            sourceID: id,
            title: title,
            url: issue.htmlURL,
            timestamp: timestamp,
            rawText: issue.title
        )
    }
}

// MARK: - Codable response types
// Verified live against GitHub REST 2026-06-14 (RESEARCH). Explicit CodingKeys
// (matching the ClaudeProvider idiom) rather than `.convertFromSnakeCase`, so
// the field mapping is auditable in one place.

/// One issue or PR from `/issues` or `/search/issues`. `repository` is present only
/// on `/issues`. (The `pull_request` field marks PR-ness but no runtime behavior reads
/// it — dedupe is by id and `map` does not branch on PR vs issue — so it is not decoded;
/// IN-04. Re-add a `PRStub`/`pull_request` key here when a PR-specific glyph/filter lands.)
struct GitHubIssue: Decodable {
    let id: Int
    let number: Int
    let title: String
    let htmlURL: String
    let updatedAt: String
    let repository: Repo?

    struct Repo: Decodable {
        let fullName: String
        enum CodingKeys: String, CodingKey { case fullName = "full_name" }
    }

    enum CodingKeys: String, CodingKey {
        case id, number, title, repository
        case htmlURL = "html_url"
        case updatedAt = "updated_at"
    }
}

/// Search API envelope for `/search/issues`.
struct GitHubSearchResponse: Decodable {
    let totalCount: Int
    let items: [GitHubIssue]

    enum CodingKeys: String, CodingKey {
        case items
        case totalCount = "total_count"
    }
}
