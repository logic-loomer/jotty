import AppKit

struct KeyCombo: Codable, Equatable, Hashable {
    let keyCode: UInt16
    let modifiers: Set<Modifier>

    enum Modifier: String, Codable {
        case cmd, shift, opt, ctrl
    }

    var nsModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.cmd)   { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.opt)   { flags.insert(.option) }
        if modifiers.contains(.ctrl)  { flags.insert(.control) }
        return flags
    }

    /// Inverse of `nsModifierFlags`: NSEvent.modifierFlags → Set<Modifier>.
    /// Non-modifier bits (capsLock, function, numericPad, …) are DROPPED so a
    /// stored ⌘K matches ⌘K typed with Caps Lock on — the AppDelegate local key
    /// monitor (09-05) builds live-event combos through this.
    static func modifiers(from flags: NSEvent.ModifierFlags) -> Set<Modifier> {
        var modifiers: Set<Modifier> = []
        if flags.contains(.command) { modifiers.insert(.cmd) }
        if flags.contains(.shift)   { modifiers.insert(.shift) }
        if flags.contains(.option)  { modifiers.insert(.opt) }
        if flags.contains(.control) { modifiers.insert(.ctrl) }
        return modifiers
    }
}
