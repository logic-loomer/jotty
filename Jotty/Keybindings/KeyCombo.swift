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
}
