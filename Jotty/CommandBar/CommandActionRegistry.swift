import Foundation

/// One palette-runnable settings action: a named `Action` case plus its display
/// metadata (UI-SPEC Copywriting Contract label, SF Symbol glyph).
///
/// The palette (09-04) lists these entries in the Actions section and dispatches
/// `action` through `ActionDispatcher` on Enter — never a parallel switch — so a
/// registry entry without a registered handler is observable, not silently dead
/// (IN-01 contract; coverage tests in CommandActionRegistryTests + the 09-05
/// launch-time dispatch check).
struct CommandAction: Identifiable, Equatable {
    let action: Action
    let label: String     // verb-first Title Case, UI-SPEC Copywriting Contract verbatim
    let symbol: String    // SF Symbol name
    var id: String { action.rawValue }
}

/// The settings-actions registry — the palette's Actions section corpus (SC2).
///
/// Registry order = the palette's Actions-section display order. Destructive
/// items (Reset settings / Reset shortcuts) are EXCLUDED: Enter runs actions
/// with no confirmation (locked decision), so irreversible actions don't belong
/// here (RESEARCH §6).
enum CommandActionRegistry {
    static let all: [CommandAction] = [
        CommandAction(action: .globalToggleCapture,
                      label: "New Capture",
                      symbol: "square.and.pencil"),
        CommandAction(action: .openCalendarCanvas,
                      label: "Open Calendar Canvas",
                      symbol: "calendar.day.timeline.left"),
        CommandAction(action: .openSettingsGeneral,
                      label: "Open Settings — General",
                      symbol: "gearshape"),
        CommandAction(action: .openSettingsStorage,
                      label: "Open Settings — Storage",
                      symbol: "folder"),
        CommandAction(action: .openSettingsAI,
                      label: "Open Settings — AI",
                      symbol: "brain"),
        CommandAction(action: .openSettingsCalendar,
                      label: "Open Settings — Calendar",
                      symbol: "calendar"),
        CommandAction(action: .openSettingsIntegrations,
                      label: "Open Settings — Integrations",
                      symbol: "tray.and.arrow.down"),
        CommandAction(action: .openSettingsKeybindings,
                      label: "Open Settings — Keybindings",
                      symbol: "keyboard"),
        CommandAction(action: .openSettingsAdvanced,
                      label: "Open Settings — Advanced",
                      symbol: "wrench.and.screwdriver"),
        CommandAction(action: .toggleLaunchAtLogin,
                      label: "Toggle Launch at Login",
                      symbol: "power"),
        CommandAction(action: .replayOnboarding,
                      label: "Replay Onboarding",
                      symbol: "sparkles"),
        CommandAction(action: .openTodayFile,
                      label: "Open Today's File",
                      symbol: "doc.text"),
    ]
}
