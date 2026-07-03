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
/// NOTE: the `appLevelActions` routing set for the local key-down monitor is added
/// in plan 09-02 WITH the new Action cases it names (Pitfall 6: enum cases and
/// their routing metadata land together).
@MainActor
final class ActionDispatcher {

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
