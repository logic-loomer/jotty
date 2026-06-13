import Foundation

enum Action: String, Codable, CaseIterable {
    case globalToggleCapture = "global.toggleCapture"
    case captureSubmit       = "capture.submit"
    case captureCancel       = "capture.cancel"
    /// Send-to-Claude shortcut (consumed by the Keybindings tab + handoff).
    /// Its default combo is added to default-keybindings.json in plan 06-02 to
    /// avoid an empty-combo row in the bundled seed.
    case sendToClaude        = "send.toClaude"
}
