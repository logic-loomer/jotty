import Foundation

enum Action: String, Codable, CaseIterable {
    case globalToggleCapture = "global.toggleCapture"
    case captureSubmit       = "capture.submit"
    case captureCancel       = "capture.cancel"
    /// Send-to-Claude shortcut (consumed by the Keybindings tab + handoff).
    /// Its default combo is added to default-keybindings.json in plan 06-02 to
    /// avoid an empty-combo row in the bundled seed.
    case sendToClaude        = "send.toClaude"
    /// Opens the calendar canvas window (Phase 8 SC4 / CALX-04) — the dispatch
    /// entry point plan 08-05's canvas reaches through. Deliberately carries NO
    /// default combo in the bundled seed (same no-empty-seed approach as
    /// sendToClaude): the canvas is opened via a menubar item; a default
    /// shortcut can be added alongside the window wiring if desired.
    case openCalendarCanvas  = "calendar.openCanvas"
}
