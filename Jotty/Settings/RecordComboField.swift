// Jotty/Settings/RecordComboField.swift
// A record-a-combo control for the Keybindings tab (plan 06-04 Task 2).
//
// An NSViewRepresentable wrapping an NSView that overrides keyDown to build a
// KeyCombo from event.keyCode + event.modifierFlags (RESEARCH Code Examples).
// Lives in the real Settings NSWindow — focus there is well-behaved, unlike the
// menubar NSPopover (RESEARCH Pitfall 2). On click the view becomes first
// responder ("Recording…"); the next key press captures the combo and calls
// onCapture, after which it resigns first responder.
//
// KeyCombo.displayString gives the human-readable label (⌘⇧N) shown both here and
// in the KeybindingsTab row.

import AppKit
import SwiftUI

struct RecordComboField: NSViewRepresentable {
    /// The combo currently bound to this action (for the resting label).
    let current: KeyCombo?
    /// Whether a bare (modifier-less) key may be bound for this action (WR-06). False for
    /// the GLOBAL `globalToggleCapture`: a modifier-less global hotkey would be grabbed
    /// system-wide by `HotkeyManager.register`, hijacking that key everywhere. App-scoped
    /// actions (submit/cancel/sendToClaude) may keep bare keys (e.g. Esc to cancel).
    var allowsBareKey: Bool = true
    /// Whether this action's combo must include ⌘/⌃/⌥ (Phase 9 review WR-02). True for
    /// the APP-LEVEL actions the AppDelegate local key monitor routes: the monitor only
    /// fires on a command-like modifier, so recording a bare or ⇧-only combo would
    /// persist a displayed-but-permanently-dead binding. Mirrors the monitor's guard
    /// (`ActionDispatcher.appLevelActions(matching:...)`).
    var requiresCommandLikeModifier: Bool = false
    /// Called with the freshly-captured combo when the user presses a key.
    let onCapture: (KeyCombo) -> Void

    func makeNSView(context: Context) -> RecorderView {
        RecorderView(current: current, allowsBareKey: allowsBareKey,
                     requiresCommandLikeModifier: requiresCommandLikeModifier,
                     onCapture: onCapture)
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.update(current: current, allowsBareKey: allowsBareKey,
                    requiresCommandLikeModifier: requiresCommandLikeModifier,
                    onCapture: onCapture)
    }
}

/// The AppKit backing view: a focusable button-like surface that captures one
/// keyDown into a KeyCombo. Modifier-only presses are ignored (they have no
/// non-modifier key to bind), and Escape cancels recording without capturing.
final class RecorderView: NSView {
    private var current: KeyCombo?
    private var allowsBareKey: Bool
    private var requiresCommandLikeModifier: Bool
    private var onCapture: (KeyCombo) -> Void
    private var isRecording = false

    /// App-wide "a combo is being recorded" signal (review WR-01): non-zero while
    /// ANY RecorderView is first responder. The AppDelegate local key monitor
    /// checks `isRecordingActive` and suppresses dispatch, so a combo already
    /// bound to an app-level action can still be re-recorded — dispatching
    /// mid-recording would fire the action AND swallow the keyDown the recorder
    /// needs (a settings deep-link could even switch the tab away).
    private(set) static var activeRecorderCount = 0
    static var isRecordingActive: Bool { activeRecorderCount > 0 }

    private let label = NSTextField(labelWithString: "")

    init(current: KeyCombo?, allowsBareKey: Bool,
         requiresCommandLikeModifier: Bool = false,
         onCapture: @escaping (KeyCombo) -> Void) {
        self.current = current
        self.allowsBareKey = allowsBareKey
        self.requiresCommandLikeModifier = requiresCommandLikeModifier
        self.onCapture = onCapture
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        label.alignment = .center
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refreshLabel()
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(current: KeyCombo?, allowsBareKey: Bool,
                requiresCommandLikeModifier: Bool = false,
                onCapture: @escaping (KeyCombo) -> Void) {
        self.current = current
        self.allowsBareKey = allowsBareKey
        self.requiresCommandLikeModifier = requiresCommandLikeModifier
        self.onCapture = onCapture
        if !isRecording { refreshLabel() }
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        if !isRecording { Self.activeRecorderCount += 1 }   // WR-01 signal on
        isRecording = true
        label.stringValue = "Recording…"
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        return true
    }

    override func resignFirstResponder() -> Bool {
        // WR-01 signal off — guarded so a spurious resign can never underflow.
        if isRecording { Self.activeRecorderCount = max(0, Self.activeRecorderCount - 1) }
        isRecording = false
        layer?.borderColor = NSColor.separatorColor.cgColor
        refreshLabel()
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }

        // Escape (keyCode 53) with no modifiers cancels recording.
        if event.keyCode == 53 && !event.modifierFlags.contains(.command) {
            window?.makeFirstResponder(nil)
            return
        }

        var mods: Set<KeyCombo.Modifier> = []
        if event.modifierFlags.contains(.command) { mods.insert(.cmd) }
        if event.modifierFlags.contains(.shift)   { mods.insert(.shift) }
        if event.modifierFlags.contains(.option)  { mods.insert(.opt) }
        if event.modifierFlags.contains(.control) { mods.insert(.ctrl) }

        let combo = KeyCombo(keyCode: event.keyCode, modifiers: mods)

        // WR-06/WR-02: reject a combo that is unsafe/unusable for this action (a
        // modifier-less key for the GLOBAL hotkey, which would be grabbed system-wide;
        // a bare/⇧-only combo for an APP-LEVEL action, which the local monitor would
        // never fire). Beep and keep recording so the user can press a valid combo
        // instead of silently persisting a dangerous or dead one.
        guard RecorderView.isAcceptable(combo, allowsBareKey: allowsBareKey,
                                        requiresCommandLikeModifier: requiresCommandLikeModifier)
        else {
            NSSound.beep()
            return
        }

        current = combo
        onCapture(combo)
        window?.makeFirstResponder(nil)
    }

    /// Pure validity check (WR-06 + review WR-02), exposed (internal) for unit tests.
    /// A captured combo is rejected when:
    /// - it has NO modifier and bare keys are not allowed for this action (the global
    ///   hotkey case — a modifier-less global would be grabbed system-wide), or
    /// - the action requires a command-like modifier (⌘/⌃/⌥) and the combo has none
    ///   (WR-02: the app-level local monitor only fires on ⌘/⌃/⌥, so a bare or ⇧-only
    ///   combo would record as a displayed-but-permanently-dead binding).
    /// Bare keys stay fine for app-scoped capture actions (e.g. Esc to cancel).
    static func isAcceptable(_ combo: KeyCombo, allowsBareKey: Bool,
                             requiresCommandLikeModifier: Bool = false) -> Bool {
        if combo.modifiers.isEmpty && !allowsBareKey { return false }
        if requiresCommandLikeModifier
            && combo.modifiers.isDisjoint(with: [.cmd, .ctrl, .opt]) { return false }
        return true
    }

    // Modifier-only keypresses arrive via flagsChanged; ignore them so a bare ⌘
    // press doesn't try to bind a combo with no base key.
    override func flagsChanged(with event: NSEvent) {}

    private func refreshLabel() {
        label.stringValue = current?.displayString ?? "Not set"
        label.textColor = current == nil ? .secondaryLabelColor : .labelColor
    }
}
