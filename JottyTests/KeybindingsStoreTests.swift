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

    // MARK: - WR-01: reset() restores the INJECTED seed, not Bundle.main

    /// A seed that DIFFERS from the real bundle file (globalToggleCapture is keyCode 49
    /// here, not 45). reset() must restore THIS injected seed — proving it reuses the
    /// retained seed and is not coupled to global Bundle.main state.
    private static let divergentSeed = """
    { "version": 1,
      "bindings": {
        "global.toggleCapture": { "keyCode": 49, "modifiers": ["cmd", "shift"] },
        "capture.submit":       { "keyCode": 36, "modifiers": ["cmd"] },
        "capture.cancel":       { "keyCode": 53, "modifiers": [] }
      }
    }
    """.data(using: .utf8)!

    func testResetRestoresInjectedSeedNotBundle() throws {
        let store = try KeybindingsStore(path: userPath, defaultData: Self.divergentSeed)
        try store.setCombo(KeyCombo(keyCode: 0, modifiers: [.ctrl]), for: .globalToggleCapture)
        XCTAssertEqual(store.combo(for: .globalToggleCapture)?.keyCode, 0)

        try store.reset()

        // Restores the injected divergent seed (49 + cmd,shift), NOT the bundle's 45/cmd.
        XCTAssertEqual(store.combo(for: .globalToggleCapture)?.keyCode, 49)
        XCTAssertEqual(store.combo(for: .globalToggleCapture)?.modifiers, [.cmd, .shift])

        // Survives a reload (persisted from the injected seed).
        let reloaded = try KeybindingsStore(path: userPath, defaultData: Self.divergentSeed)
        XCTAssertEqual(reloaded.combo(for: .globalToggleCapture)?.keyCode, 49)
    }

    // MARK: - WR-02: forward-compat backfill of newly-added actions

    /// A pre-upgrade user file that has only the three original actions. After upgrading,
    /// the default seed gains `send.toClaude`. Load must backfill the new action with its
    /// default combo (not leave it nil / "Not set") while KEEPING the user's custom binds.
    func testPartialUserFileBackfillsNewActionsFromDefault() throws {
        try FileManager.default.createDirectory(
            at: userPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Pre-upgrade file: user customized capture.submit, no send.toClaude key at all.
        let preUpgrade = """
        { "version": 1,
          "bindings": {
            "global.toggleCapture": { "keyCode": 45, "modifiers": ["cmd"] },
            "capture.submit":       { "keyCode": 49, "modifiers": ["cmd", "shift"] },
            "capture.cancel":       { "keyCode": 53, "modifiers": [] }
          }
        }
        """.data(using: .utf8)!
        try preUpgrade.write(to: userPath)

        // Upgraded default seed includes send.toClaude (cmd-K, keyCode 40).
        let upgradedSeed = """
        { "version": 1,
          "bindings": {
            "global.toggleCapture": { "keyCode": 45, "modifiers": ["cmd"] },
            "capture.submit":       { "keyCode": 36, "modifiers": ["cmd"] },
            "capture.cancel":       { "keyCode": 53, "modifiers": [] },
            "send.toClaude":        { "keyCode": 40, "modifiers": ["cmd"] }
          }
        }
        """.data(using: .utf8)!

        let store = try KeybindingsStore(path: userPath, defaultData: upgradedSeed)

        // New action backfilled with its default combo.
        XCTAssertEqual(store.combo(for: .sendToClaude)?.keyCode, 40)
        XCTAssertTrue(store.combo(for: .sendToClaude)!.modifiers.contains(.cmd))
        // User's custom bind is preserved (NOT overwritten by the default).
        XCTAssertEqual(store.combo(for: .captureSubmit)?.keyCode, 49)
        XCTAssertEqual(store.combo(for: .captureSubmit)?.modifiers, [.cmd, .shift])

        // Backfill was persisted: a fresh store at the same path now has all four.
        let reloaded = try KeybindingsStore(path: userPath, defaultData: upgradedSeed)
        XCTAssertEqual(Set(reloaded.allBindings().keys),
                       [.globalToggleCapture, .captureSubmit, .captureCancel, .sendToClaude])
        XCTAssertEqual(reloaded.combo(for: .captureSubmit)?.keyCode, 49,
                       "persisted backfill keeps the user's custom bind")
    }
}
