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
}
