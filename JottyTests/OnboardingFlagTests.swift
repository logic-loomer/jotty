import XCTest
@testable import Jotty

/// SC5 (first-run onboarding flag) + backward-compat for the two new AppConfig
/// keys. GREEN as of plan 06-01 Task 1 (proves the AppConfig migration); no new
/// app code needed downstream for these assertions.
final class OnboardingFlagTests: XCTestCase {
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

    /// A pre-Phase-6 config.json with ONLY storageFolder must decode, defaulting
    /// the two new keys rather than failing the whole decode (T-6-01).
    func testOldConfigWithOnlyStorageFolderDecodesWithDefaults() throws {
        try FileManager.default.createDirectory(
            at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let folder = "/tmp/JottyLegacy"
        let legacy = #"{ "storageFolder": "file://\#(folder)" }"#.data(using: .utf8)!
        try legacy.write(to: tempURL)

        let store = try ConfigStore(path: tempURL)
        XCTAssertEqual(store.config.storageFolder, URL(string: "file://\(folder)"))
        XCTAssertFalse(store.config.hasCompletedOnboarding)
        XCTAssertEqual(store.config.claudeAction, .web)
    }

    /// Default value carries the documented Phase-6 defaults.
    func testDefaultConfigHasOnboardingFalseAndClaudeWeb() {
        let cfg = AppConfig.defaultValue
        XCTAssertFalse(cfg.hasCompletedOnboarding)
        XCTAssertEqual(cfg.claudeAction, .web)
    }

    /// Completing onboarding flips the flag and persists; a fresh load sees true.
    func testUpdateFlipsOnboardingTrueAndPersists() throws {
        let store = try ConfigStore(path: tempURL)
        XCTAssertFalse(store.config.hasCompletedOnboarding)
        try store.update { $0.hasCompletedOnboarding = true }

        let reloaded = try ConfigStore(path: tempURL)
        XCTAssertTrue(reloaded.config.hasCompletedOnboarding)
    }

    /// Resetting the flag back to false also persists (replay / re-onboard path).
    func testReplaySetsOnboardingBackToFalse() throws {
        let store = try ConfigStore(path: tempURL)
        try store.update { $0.hasCompletedOnboarding = true }
        try store.update { $0.hasCompletedOnboarding = false }

        let reloaded = try ConfigStore(path: tempURL)
        XCTAssertFalse(reloaded.config.hasCompletedOnboarding)
    }
}
