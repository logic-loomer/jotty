import Foundation

/// App-level Action → handler registry — the dispatch leg review IN-01 said must
/// exist BEFORE any new `Action` case is added (SC4).
///
/// Contract: every palette-selectable settings action is a named `Action` case whose
/// handler is registered here by AppDelegate at launch (09-05). The command palette's
/// Enter-on-settings-action routes ONLY through `dispatch(_:)` (09-04) — never a
/// parallel switch — so a case without a registered handler is observable
/// (`dispatch` returns false / `hasHandler(for:)` is false), not silently dead.
///
@MainActor
final class ActionDispatcher {

    /// Actions routed by the AppDelegate LOCAL key monitor (09-05). Never the global
    /// hotkeys (Carbon-routed) and never the SwiftUI-handled capture/sendToClaude combos.
    static let appLevelActions: Set<Action> = [.openCalendarCanvas, .openTodayFile,
        .openSettingsGeneral, .openSettingsStorage, .openSettingsAI, .openSettingsCalendar,
        .openSettingsIntegrations, .openSettingsKeybindings, .openSettingsAdvanced,
        .toggleLaunchAtLogin, .replayOnboarding]

    /// The single decision point for the AppDelegate LOCAL key monitor (review
    /// WR-01/IN-07): which app-level actions may a keyDown fire, in what order?
    /// - While a `RecorderView` is capturing a combo, NOTHING fires (WR-01): the
    ///   event must reach the recorder even when it matches an existing binding,
    ///   or a bound combo becomes impossible to re-record through the UI.
    /// - Requires ⌘/⌃/⌥ (plain typing and bare-shift keys are NEVER intercepted).
    /// - Restricted to `appLevelActions` (never the Carbon globals, never the
    ///   SwiftUI-handled capture/sendToClaude combos).
    /// - Matches are sorted by rawValue so a user-created conflict dispatches the
    ///   SAME action across launches (IN-07), not whichever Dictionary hash
    ///   order yields first.
    static func appLevelActions(matching pressed: KeyCombo,
                                bindings: [Action: KeyCombo],
                                isRecordingCombo: Bool) -> [Action] {
        guard !isRecordingCombo else { return [] }
        guard !pressed.modifiers.isDisjoint(with: [.cmd, .ctrl, .opt]) else { return [] }
        return bindings
            .filter { $0.value == pressed && appLevelActions.contains($0.key) }
            .map(\.key)
            .sorted { $0.rawValue < $1.rawValue }
    }

    private var handlers: [Action: () -> Void] = [:]

    /// Registers `handler` for `action`. Re-registering REPLACES the previous handler.
    func register(_ action: Action, handler: @escaping () -> Void) {
        handlers[action] = handler
    }

    /// Runs the handler for `action` if one is registered.
    /// - Returns: true when a handler ran; false when none is registered. Never crashes.
    @discardableResult
    func dispatch(_ action: Action) -> Bool {
        guard let handler = handlers[action] else { return false }
        handler()
        return true
    }

    /// Whether `action` currently has a registered handler (coverage reporting —
    /// the "every palette-listed action dispatches" test leans on this).
    func hasHandler(for action: Action) -> Bool {
        handlers[action] != nil
    }
}
