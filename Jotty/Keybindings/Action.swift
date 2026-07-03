import Foundation

enum Action: String, Codable, CaseIterable {
    case globalToggleCapture = "global.toggleCapture"
    case captureSubmit       = "capture.submit"
    case captureCancel       = "capture.cancel"
    /// Send-to-Claude shortcut (consumed by the Keybindings tab + handoff).
    /// Its default combo is added to default-keybindings.json in plan 06-02 to
    /// avoid an empty-combo row in the bundled seed. Phase 9 migrates its
    /// default ⌘K → ⌘⇧K (one-shot, KeybindingsStore) to free ⌘K for the bar.
    case sendToClaude        = "send.toClaude"

    // NOTE (IN-01, standing rule): every Action case ships in the SAME phase as
    // (a) a real dispatch leg — an ActionDispatcher handler registered by
    // AppDelegate — and (b) a KeybindingsTab.labels row. A former dead
    // `openCalendarCanvas` case was removed for violating this; it is
    // legitimately re-added below because ActionDispatcher exists (09-01),
    // routing metadata + tab rows land with the cases here (09-02), and
    // AppDelegate registers a handler per case in 09-05 (with a launch-time
    // dispatch coverage check closing the loop). Stored keybindings JSON with
    // unknown keys still decodes fine (unknown raw values are dropped).

    // Phase 9 (command bar). Raw values are persisted JSON keys — never rename.

    /// Global hotkey toggling the ⌘K command bar (Carbon-routed, like
    /// `.globalToggleCapture` — never the local app-level monitor).
    case globalCommandBar    = "global.commandBar"

    // App-level actions routed by the AppDelegate local key monitor
    // (`ActionDispatcher.appLevelActions`) and runnable from the palette.
    case openCalendarCanvas       = "open.calendarCanvas"
    case openTodayFile            = "open.todayFile"
    case openSettingsGeneral      = "settings.general"
    case openSettingsStorage      = "settings.storage"
    case openSettingsAI           = "settings.ai"
    case openSettingsCalendar     = "settings.calendar"
    case openSettingsIntegrations = "settings.integrations"
    case openSettingsKeybindings  = "settings.keybindings"
    case openSettingsAdvanced     = "settings.advanced"
    case toggleLaunchAtLogin      = "app.toggleLaunchAtLogin"
    case replayOnboarding         = "app.replayOnboarding"
}
