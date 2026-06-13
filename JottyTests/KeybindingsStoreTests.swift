import XCTest
@testable import Jotty

final class KeybindingsStoreTests: XCTestCase {
    func testLoadsDefaults() throws {
        let json = """
        { "version": 1,
          "bindings": {
            "global.toggleCapture": { "keyCode": 45, "modifiers": ["cmd"] },
            "capture.submit":       { "keyCode": 36, "modifiers": ["cmd"] },
            "capture.cancel":       { "keyCode": 53, "modifiers": [] }
          }
        }
        """.data(using: .utf8)!

        let store = try KeybindingsStore(data: json)

        XCTAssertEqual(store.combo(for: .globalToggleCapture)?.keyCode, 45)
        XCTAssertTrue(store.combo(for: .globalToggleCapture)!.modifiers.contains(.cmd))
        XCTAssertEqual(store.combo(for: .captureSubmit)?.keyCode, 36)
        XCTAssertEqual(store.combo(for: .captureCancel)?.modifiers, [])
    }

    func testMissingActionReturnsNil() throws {
        let json = #"{ "version": 1, "bindings": {} }"#.data(using: .utf8)!
        let store = try KeybindingsStore(data: json)
        XCTAssertNil(store.combo(for: .captureSubmit))
    }

    // MARK: - Mutable + persisted user store (SC3, plan 06-01 Task 2)

    private var userPath: URL!
    private static let defaultSeed = """
    { "version": 1,
      "bindings": {
        "global.toggleCapture": { "keyCode": 45, "modifiers": ["cmd"] },
        "capture.submit":       { "keyCode": 36, "modifiers": ["cmd"] },
        "capture.cancel":       { "keyCode": 53, "modifiers": [] }
      }
    }
    """.data(using: .utf8)!

    override func setUp() {
        super.setUp()
        userPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("keybindings.json")
    }

    override func tearDown() {
        if let userPath { try? FileManager.default.removeItem(at: userPath.deletingLastPathComponent()) }
        super.tearDown()
    }

    func testFirstLoadSeedsFromBundledDefaultAndWritesUserFile() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: userPath.path))
        let store = try KeybindingsStore(path: userPath, defaultData: Self.defaultSeed)
        XCTAssertEqual(store.combo(for: .globalToggleCapture)?.keyCode, 45)
        // The user file was written on first load.
        XCTAssertTrue(FileManager.default.fileExists(atPath: userPath.path))
    }

    func testSetComboPersistsAndSurvivesReload() throws {
        let store = try KeybindingsStore(path: userPath, defaultData: Self.defaultSeed)
        let newCombo = KeyCombo(keyCode: 49, modifiers: [.cmd, .shift])
        try store.setCombo(newCombo, for: .captureSubmit)
        XCTAssertEqual(store.combo(for: .captureSubmit), newCombo)

        // A fresh store at the same path reloads the persisted combo.
        let reloaded = try KeybindingsStore(path: userPath, defaultData: Self.defaultSeed)
        XCTAssertEqual(reloaded.combo(for: .captureSubmit), newCombo)
    }

    func testResetRestoresBundledDefaults() throws {
        let store = try KeybindingsStore(path: userPath, defaultData: Self.defaultSeed)
        try store.setCombo(KeyCombo(keyCode: 99, modifiers: [.ctrl]), for: .captureCancel)
        XCTAssertEqual(store.combo(for: .captureCancel)?.keyCode, 99)

        try store.reset()
        // Bundled default for capture.cancel is keyCode 53, no modifiers.
        XCTAssertEqual(store.combo(for: .captureCancel)?.keyCode, 53)
        XCTAssertEqual(store.combo(for: .captureCancel)?.modifiers, [])
    }

    func testAllBindingsReturnsEverySeededBinding() throws {
        let store = try KeybindingsStore(path: userPath, defaultData: Self.defaultSeed)
        let all = store.allBindings()
        XCTAssertEqual(Set(all.keys), [.globalToggleCapture, .captureSubmit, .captureCancel])
    }

    func testMalformedUserFileReseedsFromDefault() throws {
        try FileManager.default.createDirectory(
            at: userPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{ not valid json".data(using: .utf8)!.write(to: userPath)
        let store = try KeybindingsStore(path: userPath, defaultData: Self.defaultSeed)
        XCTAssertEqual(store.combo(for: .globalToggleCapture)?.keyCode, 45)
    }
}
