import XCTest
@testable import Jotty

/// SC4 transparency guard: the catalog must enumerate exactly the five planned sources with
/// stable ids, the correct `built` flags (only github shipped in Phase 7), and a non-empty
/// http(s) endpoint per entry, so the Settings transparency table can never silently hide or
/// misdeclare a source.
final class InboxSourceCatalogTests: XCTestCase {

    func testCatalogListsExactlyFiveSources() {
        XCTAssertEqual(InboxSourceCatalog.all.count, 5,
                       "SC4 transparency table must list all 5 planned sources")
    }

    func testCatalogIDsAreTheFivePlannedSources() {
        let ids = Set(InboxSourceCatalog.all.map(\.id))
        XCTAssertEqual(ids, ["github", "gmail", "slack", "linear", "notion"])
    }

    func testOnlyGitHubIsBuilt() {
        let built = InboxSourceCatalog.all.filter(\.built).map(\.id)
        XCTAssertEqual(built, ["github"],
                       "only github is built in Phase 7; the other four are documented extension points")
        for entry in InboxSourceCatalog.all where entry.id != "github" {
            XCTAssertFalse(entry.built, "\(entry.id) must be built:false")
        }
    }

    func testEveryEndpointIsANonEmptyHTTPURL() {
        for entry in InboxSourceCatalog.all {
            XCTAssertFalse(entry.endpoint.isEmpty, "\(entry.id) endpoint must be non-empty")
            XCTAssertTrue(entry.endpoint.hasPrefix("https://") || entry.endpoint.hasPrefix("http://"),
                          "\(entry.id) endpoint must be an http(s) URL: \(entry.endpoint)")
        }
    }
}
