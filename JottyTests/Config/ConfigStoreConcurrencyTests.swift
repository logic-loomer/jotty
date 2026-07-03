import XCTest
@testable import Jotty

/// CQ-05: lock-discipline hammer for `ConfigStore` (WR-03). `ConfigStore` is
/// `@unchecked Sendable` with a single NSLock guarding `_config`; this class
/// drives a dense mix of concurrent `update {}` writes and `config` reads
/// through `concurrentPerform` — under a lock-discipline regression this
/// crashes, tears, or trips the Thread Sanitizer.
///
/// Run once locally with TSan when touching ConfigStore's locking:
///   xcodebuild test -scheme Jotty -destination 'platform=macOS' \
///     -enableThreadSanitizer YES -only-testing:JottyTests/ConfigStoreConcurrencyTests
/// (TSan stays out of CI — it roughly doubles suite runtime.)
final class ConfigStoreConcurrencyTests: XCTestCase {
    var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("config.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
        super.tearDown()
    }

    /// 500 concurrent iterations alternating writes (even i) and reads (odd i)
    /// must complete without crash or torn state, and the store must still
    /// round-trip a consistent read afterwards.
    func testConcurrentReadsAndWritesNeverTear() throws {
        let store = try ConfigStore(path: tempURL)

        DispatchQueue.concurrentPerform(iterations: 500) { i in
            if i.isMultiple(of: 2) {
                try? store.update { $0.inboxCheckIntervalMinutes = i }
            } else {
                _ = store.config   // must never crash / tear under TSan
            }
        }

        // The store still round-trips a read: the last-won write is some even
        // iteration index, never a torn/garbage value.
        let final = store.config.inboxCheckIntervalMinutes
        let written = try XCTUnwrap(final, "at least one of the 250 writes must have landed")
        XCTAssertTrue(written.isMultiple(of: 2), "value must be one of the written (even) iterations")
        XCTAssertTrue((0..<500).contains(written), "value must be an actual iteration index")

        // And the persisted bytes decode into the same consistent state on reload.
        let reloaded = try ConfigStore(path: tempURL)
        let persisted = try XCTUnwrap(reloaded.config.inboxCheckIntervalMinutes,
                                      "persisted config must decode with a written interval")
        XCTAssertTrue(persisted.isMultiple(of: 2))
        XCTAssertTrue((0..<500).contains(persisted))
    }
}
