import XCTest
@testable import Jotty

/// Phase 9 plan 02 / SC4: the settings-actions registry the palette lists (09-04)
/// and the routing metadata that keeps every case dispatchable (IN-01 contract).
///
/// Structural coverage tests: nothing the palette can select is unrouteable, the
/// local key monitor never double-handles Carbon-routed globals or SwiftUI-handled
/// capture combos, every routed action has a Keybindings tab row, and BOTH global
/// actions refuse bare keys (WR-06).
@MainActor
final class CommandActionRegistryTests: XCTestCase {

    // MARK: - Registry shape

    func testRegistryActionsAndLabelsAreUniqueAndNonEmpty() {
        let all = CommandActionRegistry.all

        let actions = all.map(\.action)
        XCTAssertEqual(Set(actions).count, actions.count,
                       "every registry entry must carry a distinct Action case")

        let labels = all.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count,
                       "labels must be unique — duplicate palette rows are ambiguous")
        XCTAssertFalse(labels.contains(where: \.isEmpty), "labels must be non-empty")

        XCTAssertFalse(all.map(\.symbol).contains(where: \.isEmpty),
                       "every entry needs an SF Symbol name")
    }

    // MARK: - Routing coverage (IN-01: no dispatchable action is unrouteable)

    func testEveryRegistryActionIsCaptureOrAppLevelRouted() {
        for entry in CommandActionRegistry.all {
            XCTAssertTrue(entry.action == .globalToggleCapture
                            || ActionDispatcher.appLevelActions.contains(entry.action),
                          "\(entry.action.rawValue) is palette-listed but routed by " +
                          "neither the capture path nor the app-level monitor")
        }
    }

    func testAppLevelActionsExcludeGlobalsAndSwiftUIHandledCombos() {
        // Globals are Carbon-routed; capture/sendToClaude combos are SwiftUI-handled.
        // The local key monitor must never double-handle any of them.
        let excluded: Set<Action> = [.globalToggleCapture, .globalCommandBar,
                                     .captureSubmit, .captureCancel, .sendToClaude]
        XCTAssertTrue(ActionDispatcher.appLevelActions.isDisjoint(with: excluded),
                      "appLevelActions must contain no Carbon-routed global and no " +
                      "SwiftUI-handled capture/sendToClaude combo")
    }

    // MARK: - Keybindings tab row coverage (IN-01: no case without a tab row)

    func testEveryRoutedActionHasAKeybindingsTabRow() {
        let rowActions = Set(KeybindingsTab.labels.map(\.action))
        for action in ActionDispatcher.appLevelActions {
            XCTAssertTrue(rowActions.contains(action),
                          "\(action.rawValue) has no KeybindingsTab row — the IN-01 " +
                          "contract requires a row for every routed case")
        }
        XCTAssertTrue(rowActions.contains(.globalCommandBar),
                      "the command bar hotkey must be rebindable in the tab (SC4)")
    }

    // MARK: - WR-06: both globals refuse bare keys

    func testBothGlobalActionsRequireModifiers() {
        XCTAssertEqual(KeybindingsTab.requiresModifierActions,
                       [.globalToggleCapture, .globalCommandBar],
                       "BOTH global actions must refuse bare keys (WR-06) — a bare " +
                       "global key would be grabbed system-wide")
    }
}
