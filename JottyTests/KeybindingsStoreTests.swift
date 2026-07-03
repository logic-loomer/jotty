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

    // MARK: - Phase 9: one-shot sendToClaude ⌘K → ⌘⇧K migration (09-02 Task 3)

    /// The Phase-9 seed shape: sendToClaude moved to ⌘⇧K, global.commandBar ⌘K added.
    /// Mirrors Jotty/Resources/default-keybindings.json — injected so seed and
    /// migration are tested against the SAME source the store decodes.
    private static let phase9Seed = """
    { "version": 1,
      "bindings": {
        "global.toggleCapture": { "keyCode": 45, "modifiers": ["cmd"] },
        "capture.submit":       { "keyCode": 36, "modifiers": ["cmd"] },
        "capture.cancel":       { "keyCode": 53, "modifiers": [] },
        "send.toClaude":        { "keyCode": 40, "modifiers": ["cmd", "shift"] },
        "global.commandBar":    { "keyCode": 40, "modifiers": ["cmd"] }
      }
    }
    """.data(using: .utf8)!

    private static let legacyCmdK = KeyCombo(keyCode: 40, modifiers: [.cmd])
    private static let cmdShiftK  = KeyCombo(keyCode: 40, modifiers: [.cmd, .shift])

    private func writeUserFile(_ json: String) throws {
        try FileManager.default.createDirectory(
            at: userPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.data(using: .utf8)!.write(to: userPath)
    }

    func testLegacyConstantPinsTheOldDefault() {
        XCTAssertEqual(KeybindingsStore.legacySendToClaudeDefault, Self.legacyCmdK,
                       "the NAMED legacy constant must stay ⌘K (keyCode 40, [cmd]) forever — " +
                       "it identifies pre-Phase-9 uncustomized files")
    }

    func testPreP9FileWithDefaultCmdKMigratesOnceAndBackfillsCommandBar() throws {
        // Pre-Phase-9 file: no global.commandBar key, sendToClaude still the old ⌘K default.
        try writeUserFile("""
        { "version": 1,
          "bindings": {
            "global.toggleCapture": { "keyCode": 45, "modifiers": ["cmd"] },
            "capture.submit":       { "keyCode": 36, "modifiers": ["cmd"] },
            "capture.cancel":       { "keyCode": 53, "modifiers": [] },
            "send.toClaude":        { "keyCode": 40, "modifiers": ["cmd"] }
          }
        }
        """)

        let store = try KeybindingsStore(path: userPath, defaultData: Self.phase9Seed)

        XCTAssertEqual(store.combo(for: .sendToClaude), Self.cmdShiftK,
                       "uncustomized sendToClaude migrates ⌘K → ⌘⇧K (from the SEED)")
        XCTAssertEqual(store.combo(for: .globalCommandBar), Self.legacyCmdK,
                       "global.commandBar backfills ⌘K (WR-02)")

        // Persisted: a fresh store at the same path sees the migrated state.
        let reloaded = try KeybindingsStore(path: userPath, defaultData: Self.phase9Seed)
        XCTAssertEqual(reloaded.combo(for: .sendToClaude), Self.cmdShiftK)
        XCTAssertEqual(reloaded.combo(for: .globalCommandBar), Self.legacyCmdK)
    }

    func testPreP9FileWithCustomizedSendToClaudeIsNeverTouched() throws {
        // User customized sendToClaude to ⌘J (keyCode 38) before Phase 9.
        try writeUserFile("""
        { "version": 1,
          "bindings": {
            "global.toggleCapture": { "keyCode": 45, "modifiers": ["cmd"] },
            "capture.submit":       { "keyCode": 36, "modifiers": ["cmd"] },
            "capture.cancel":       { "keyCode": 53, "modifiers": [] },
            "send.toClaude":        { "keyCode": 38, "modifiers": ["cmd"] }
          }
        }
        """)

        let store = try KeybindingsStore(path: userPath, defaultData: Self.phase9Seed)

        XCTAssertEqual(store.combo(for: .sendToClaude),
                       KeyCombo(keyCode: 38, modifiers: [.cmd]),
                       "a customized sendToClaude is kept verbatim")
        XCTAssertEqual(store.combo(for: .globalCommandBar), Self.legacyCmdK,
                       "global.commandBar still backfills ⌘K")
    }

    func testPostP9FileWithManuallyResetCmdKIsNotReMigrated() throws {
        // Post-Phase-9 file: global.commandBar present. The user then deliberately
        // set sendToClaude BACK to ⌘K. The commandBar-key presence is the already-ran
        // sentinel, so the rewrite can never re-fire — the conflict warning covers
        // the ⌘K clash (locked fallback).
        try writeUserFile("""
        { "version": 1,
          "bindings": {
            "global.toggleCapture": { "keyCode": 45, "modifiers": ["cmd"] },
            "capture.submit":       { "keyCode": 36, "modifiers": ["cmd"] },
            "capture.cancel":       { "keyCode": 53, "modifiers": [] },
            "send.toClaude":        { "keyCode": 40, "modifiers": ["cmd"] },
            "global.commandBar":    { "keyCode": 40, "modifiers": ["cmd"] }
          }
        }
        """)

        let store = try KeybindingsStore(path: userPath, defaultData: Self.phase9Seed)

        XCTAssertEqual(store.combo(for: .sendToClaude), Self.legacyCmdK,
                       "post-P9 manual ⌘K stays ⌘K — the migration never re-fires")
        XCTAssertEqual(store.combo(for: .globalCommandBar), Self.legacyCmdK)
    }

    func testFreshInstallSeedsNewDefaultsInOnePass() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: userPath.path))

        let store = try KeybindingsStore(path: userPath, defaultData: Self.phase9Seed)

        XCTAssertEqual(store.combo(for: .sendToClaude), Self.cmdShiftK)
        XCTAssertEqual(store.combo(for: .globalCommandBar), Self.legacyCmdK)
        XCTAssertTrue(FileManager.default.fileExists(atPath: userPath.path),
                      "seeded user file written on first load")
    }

    func testCorruptFileReseedsWithNewDefaults() throws {
        try writeUserFile("{ not valid json")

        let store = try KeybindingsStore(path: userPath, defaultData: Self.phase9Seed)

        XCTAssertEqual(store.combo(for: .sendToClaude), Self.cmdShiftK,
                       "existing corrupt-file tolerance reseeds with the NEW defaults")
        XCTAssertEqual(store.combo(for: .globalCommandBar), Self.legacyCmdK)
    }
}
