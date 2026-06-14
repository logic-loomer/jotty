import XCTest
@testable import Jotty

final class ConfigStoreTests: XCTestCase {
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

    func testFirstLoadReturnsDefaults() throws {
        let store = try ConfigStore(path: tempURL)
        let expectedDefault = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Jotty")
        XCTAssertEqual(store.config.storageFolder, expectedDefault)
    }

    func testSaveAndReloadPersists() throws {
        let store1 = try ConfigStore(path: tempURL)
        let custom = URL(fileURLWithPath: "/tmp/CustomJotty")
        try store1.update { $0.storageFolder = custom }

        let store2 = try ConfigStore(path: tempURL)
        XCTAssertEqual(store2.config.storageFolder, custom)
    }

    // MARK: - Phase 7 inbox opt-in keys (SC3 — default OFF, backward-compatible)

    /// SC3: the periodic-check opt-in defaults OFF and the interval defaults to nil
    /// (off) on a brand-new config — no background polling on the default config.
    func testInboxPeriodicCheckDefaultsOff() throws {
        let store = try ConfigStore(path: tempURL)
        XCTAssertFalse(store.config.inboxCheckPeriodically)
        XCTAssertNil(store.config.inboxCheckIntervalMinutes)
    }

    /// Backward compat: a config.json written WITHOUT the Phase 7 keys (e.g. a
    /// pre-Phase-7 file) must decode successfully with `inboxCheckPeriodically == false`
    /// via decodeIfPresent — a missing key must NOT fail the whole decode (which would
    /// silently reset the user's entire config to defaults).
    func testInboxKeysAbsentDecodesWithDefaultsNotResettingConfig() throws {
        // A minimal config.json carrying only a non-default storageFolder and NONE of
        // the Phase 7 keys (mirrors a file written by an older build).
        let json = """
        {
          "storageFolder": "file:///tmp/BackCompatJotty/",
          "aiProviderID": "apple-fm",
          "claudeAction": "web",
          "hasCompletedOnboarding": true
        }
        """
        try FileManager.default.createDirectory(
            at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.data(using: .utf8)!.write(to: tempURL)

        let store = try ConfigStore(path: tempURL)
        // The rest of the config survived (not reset to defaults)…
        XCTAssertEqual(store.config.storageFolder.path, "/tmp/BackCompatJotty")
        XCTAssertTrue(store.config.hasCompletedOnboarding)
        // …and the missing Phase 7 keys defaulted off.
        XCTAssertFalse(store.config.inboxCheckPeriodically)
        XCTAssertNil(store.config.inboxCheckIntervalMinutes)
    }

    /// The opt-in toggle persists and reloads true (SC3 user enables periodic checks).
    func testInboxPeriodicCheckPersistsAndReloads() throws {
        let store1 = try ConfigStore(path: tempURL)
        try store1.update {
            $0.inboxCheckPeriodically = true
            $0.inboxCheckIntervalMinutes = 15
        }

        let store2 = try ConfigStore(path: tempURL)
        XCTAssertTrue(store2.config.inboxCheckPeriodically)
        XCTAssertEqual(store2.config.inboxCheckIntervalMinutes, 15)
    }

    // MARK: - WR-03: Sendable + concurrent read/write safety

    /// ConfigStore is `Sendable` (its config read + every update are lock-guarded), so it
    /// can be captured into the off-main Claude-handoff seam and read concurrently with a
    /// Settings-tab `update {}` without tearing. This drives many concurrent readers
    /// against repeated writers: each read must observe a CONSISTENT (never half-written)
    /// AppConfig — under the data race the `@unchecked` previously masked this would trip
    /// TSan / produce a torn value. (Run with the Thread Sanitizer to harden further.)
    func testConcurrentReadsAndWritesDoNotTear() throws {
        let store = try ConfigStore(path: tempURL)
        // Two valid, distinct states; every read must see one of them whole, never a mix.
        let web: ClaudeAction = .web
        let code: ClaudeAction = .code
        try store.update { $0.claudeAction = web; $0.aiProviderID = "apple-fm" }

        let iterations = 2_000
        let group = DispatchGroup()

        // Writers flip between two fully-consistent states.
        for i in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                for n in 0..<iterations {
                    let toCode = (n % 2 == 0)
                    try? store.update {
                        $0.claudeAction = toCode ? code : web
                        $0.aiProviderID = toCode ? "claude" : "apple-fm"
                    }
                    _ = i
                }
                group.leave()
            }
        }

        // Readers assert the two fields are always mutually consistent (the invariant a
        // torn read would break): claudeAction==.code iff aiProviderID=="claude".
        for _ in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                for _ in 0..<iterations {
                    let snapshot = store.config
                    let codeMode = (snapshot.claudeAction == code)
                    let claudeProvider = (snapshot.aiProviderID == "claude")
                    XCTAssertEqual(codeMode, claudeProvider,
                                   "read must observe a whole, consistent AppConfig (no tear)")
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 30), .success, "no deadlock under contention")
    }
}
