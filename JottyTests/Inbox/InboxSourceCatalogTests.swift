import XCTest
@testable import Jotty

/// SC4 transparency guard: the catalog must enumerate exactly the six planned sources with stable
/// ids and the correct `built` flags (github + the on-device calendar source are shipped; the four
/// remaining network sources are documented extension points). The endpoint invariant is carved out
/// by trust type: the five NETWORK sources must disclose a non-empty http(s) URL, while the
/// on-device `calendar` source must disclose a non-empty, non-http string (it reaches no host), so
/// the Settings transparency table can never silently hide or misdeclare a source.
final class InboxSourceCatalogTests: XCTestCase {

    func testCatalogListsExactlySixSources() {
        XCTAssertEqual(InboxSourceCatalog.all.count, 6,
                       "SC4 transparency table must list all 6 planned sources (5 network + on-device calendar)")
    }

    func testCatalogIDsAreTheSixPlannedSources() {
        let ids = Set(InboxSourceCatalog.all.map(\.id))
        XCTAssertEqual(ids, ["github", "gmail", "slack", "linear", "notion", "calendar"])
    }

    func testOnlyGitHubAndCalendarAreBuilt() {
        let built = InboxSourceCatalog.all.filter(\.built).map(\.id)
        XCTAssertEqual(built, ["github", "calendar"],
                       "github and the on-device calendar source are built; the four network sources are documented extension points")
        for entry in InboxSourceCatalog.all where entry.id != "github" && entry.id != "calendar" {
            XCTAssertFalse(entry.built, "\(entry.id) must be built:false")
        }
    }

    func testNetworkEndpointsAreHTTPAndCalendarIsANonHTTPDisclosure() throws {
        // Every source discloses a non-empty endpoint string.
        for entry in InboxSourceCatalog.all {
            XCTAssertFalse(entry.endpoint.isEmpty, "\(entry.id) endpoint must be non-empty")
        }
        // The five network sources must disclose an http(s) host.
        for entry in InboxSourceCatalog.all where entry.id != "calendar" {
            XCTAssertTrue(entry.endpoint.hasPrefix("https://") || entry.endpoint.hasPrefix("http://"),
                          "\(entry.id) endpoint must be an http(s) URL: \(entry.endpoint)")
        }
        // The on-device calendar source reaches no host: an honest non-http disclosure, not a URL.
        let calendar = try XCTUnwrap(InboxSourceCatalog.all.first { $0.id == "calendar" },
                                     "catalog must contain the calendar source")
        XCTAssertFalse(calendar.endpoint.isEmpty, "calendar endpoint must be a non-empty disclosure")
        XCTAssertFalse(calendar.endpoint.hasPrefix("http"),
                       "calendar is on-device: its endpoint must NOT be an http(s) URL: \(calendar.endpoint)")
    }
}
