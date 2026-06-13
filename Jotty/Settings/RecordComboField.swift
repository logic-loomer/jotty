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
    /// Called with the freshly-captured combo when the user presses a key.
    let onCapture: (KeyCombo) -> Void

    func makeNSView(context: Context) -> RecorderView {
        RecorderView(current: current, onCapture: onCapture)
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.update(current: current, onCapture: onCapture)
    }
}

/// The AppKit backing view: a focusable button-like surface that captures one
/// keyDown into a KeyCombo. Modifier-only presses are ignored (they have no
/// non-modifier key to bind), and Escape cancels recording without capturing.
final class RecorderView: NSView {
    private var current: KeyCombo?
    private var onCapture: (KeyCombo) -> Void
    private var isRecording = false

    private let label = NSTextField(labelWithString: "")

    init(current: KeyCombo?, onCapture: @escaping (KeyCombo) -> Void) {
        self.current = current
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

    func update(current: KeyCombo?, onCapture: @escaping (KeyCombo) -> Void) {
        self.current = current
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
        current = combo
        onCapture(combo)
        window?.makeFirstResponder(nil)
    }

    // Modifier-only keypresses arrive via flagsChanged; ignore them so a bare ⌘
    // press doesn't try to bind a combo with no base key.
    override func flagsChanged(with event: NSEvent) {}

    private func refreshLabel() {
        label.stringValue = current?.displayString ?? "Not set"
        label.textColor = current == nil ? .secondaryLabelColor : .labelColor
    }
}
