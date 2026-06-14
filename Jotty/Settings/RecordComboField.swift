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
    /// Called with the freshly-captured combo when the user presses a key.
    let onCapture: (KeyCombo) -> Void

    func makeNSView(context: Context) -> RecorderView {
        RecorderView(current: current, allowsBareKey: allowsBareKey, onCapture: onCapture)
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.update(current: current, allowsBareKey: allowsBareKey, onCapture: onCapture)
    }
}

/// The AppKit backing view: a focusable button-like surface that captures one
/// keyDown into a KeyCombo. Modifier-only presses are ignored (they have no
/// non-modifier key to bind), and Escape cancels recording without capturing.
final class RecorderView: NSView {
    private var current: KeyCombo?
    private var allowsBareKey: Bool
    private var onCapture: (KeyCombo) -> Void
    private var isRecording = false

    private let label = NSTextField(labelWithString: "")

    init(current: KeyCombo?, allowsBareKey: Bool, onCapture: @escaping (KeyCombo) -> Void) {
        self.current = current
        self.allowsBareKey = allowsBareKey
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

    func update(current: KeyCombo?, allowsBareKey: Bool, onCapture: @escaping (KeyCombo) -> Void) {
        self.current = current
        self.allowsBareKey = allowsBareKey
        self.onCapture = onCapture
        if !isRecording { refreshLabel() }
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        label.stringValue = "Recording…"
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        return true
    }

    override func resignFirstResponder() -> Bool {
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

        // WR-06: reject a combo that is unsafe/unusable for this action (e.g. a
        // modifier-less key for the GLOBAL hotkey, which would be grabbed system-wide).
        // Beep and keep recording so the user can press a valid combo instead of silently
        // persisting a dangerous one.
        guard RecorderView.isAcceptable(combo, allowsBareKey: allowsBareKey) else {
            NSSound.beep()
            return
        }

        current = combo
        onCapture(combo)
        window?.makeFirstResponder(nil)
    }

    /// Pure validity check (WR-06), exposed (internal) for unit tests. A captured combo is
    /// rejected when it has NO modifier and bare keys are not allowed for this action
    /// (the global hotkey case). Bare keys are fine for app-scoped actions (e.g. Esc to
    /// cancel), so `allowsBareKey == true` accepts everything the recorder can build.
    static func isAcceptable(_ combo: KeyCombo, allowsBareKey: Bool) -> Bool {
        if combo.modifiers.isEmpty && !allowsBareKey { return false }
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
