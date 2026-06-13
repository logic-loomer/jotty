// Jotty/Keybindings/KeyComboDisplay.swift
// Human-readable rendering of a KeyCombo for the Keybindings tab + record-combo
// control (plan 06-04). Pure formatting, no AppKit event handling — maps the
// modifier set to glyphs (⌃⌥⇧⌘, ordered the macOS-standard way) and the keyCode
// to its key name. Unknown keyCodes fall back to "key <n>" so a recorded combo
// always shows *something* rather than an empty label.

import Foundation

extension KeyCombo {
    /// e.g. "⌘⇧N", "⌃⌥Space", "⎋".
    var displayString: String {
        modifierGlyphs + KeyCombo.keyName(for: keyCode)
    }

    /// Modifier glyphs in the canonical macOS order (Control, Option, Shift, Command).
    private var modifierGlyphs: String {
        var s = ""
        if modifiers.contains(.ctrl)  { s += "⌃" }
        if modifiers.contains(.opt)   { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.cmd)   { s += "⌘" }
        return s
    }

    /// Maps a virtual key code (kVK_*) to a printable key name. Covers the keys
    /// the app actually binds plus the common alphanumerics a user might record.
    static func keyName(for keyCode: UInt16) -> String {
        if let name = specialKeys[keyCode] { return name }
        if let name = letterKeys[keyCode] { return name }
        if let name = numberKeys[keyCode] { return name }
        return "key \(keyCode)"
    }

    private static let specialKeys: [UInt16: String] = [
        36: "↩",        // Return
        48: "⇥",        // Tab
        49: "Space",
        51: "⌫",        // Delete
        53: "⎋",        // Escape
        76: "⌤",        // Enter (keypad)
        117: "⌦",       // Forward Delete
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4",
        96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    private static let letterKeys: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
        12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z",
    ]

    private static let numberKeys: [UInt16: String] = [
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4",
        23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
    ]
}
