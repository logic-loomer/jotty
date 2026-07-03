import Foundation

enum Action: String, Codable, CaseIterable {
    case globalToggleCapture = "global.toggleCapture"
    case captureSubmit       = "capture.submit"
    case captureCancel       = "capture.cancel"
    /// Send-to-Claude shortcut (consumed by the Keybindings tab + handoff).
    /// Its default combo is added to default-keybindings.json in plan 06-02 to
    /// avoid an empty-combo row in the bundled seed.
    case sendToClaude        = "send.toClaude"
    // NOTE (IN-01): the calendar canvas (Phase 8 SC4 / CALX-04) is opened
    // exclusively through the menubar popover item -> AppDelegate's
    // openCalendarCanvas() closure — it has NO Action case. A former
    // `openCalendarCanvas` case was never dispatched, never seeded and never
    // bindable (KeybindingsTab.labels is an explicit list), so it was removed;
    // stored keybindings JSON with unknown keys decodes fine (unknown raw
    // values are dropped). Re-add a case only together with real dispatch
    // wiring (KeybindingsTab.labels row + a handler that routes the combo).
}
