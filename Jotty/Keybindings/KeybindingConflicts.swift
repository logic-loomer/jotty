import Foundation

/// A single keybinding conflict: one `combo` that two or more `actions` share.
///
/// Pure value type, AppKit-free, so it's trivially `Sendable` and unit-testable
/// without touching the OS. `actions` is always sorted by `rawValue` for stable,
/// deterministic comparison in tests and UI.
struct KeybindingConflict: Equatable {
    let combo: KeyCombo
    let actions: [Action]
}

/// Detects every combo bound to more than one action.
///
/// Pure function (no disk, no AppKit): groups the bindings by combo and returns
/// one `KeybindingConflict` per combo shared by 2+ actions, with the offending
/// actions sorted by `rawValue`. Returns `[]` when every combo is distinct.
func conflicts(in bindings: [Action: KeyCombo]) -> [KeybindingConflict] {
    var byCombo: [KeyCombo: [Action]] = [:]
    for (action, combo) in bindings {
        byCombo[combo, default: []].append(action)
    }
    return byCombo
        .filter { $0.value.count > 1 }
        .map { KeybindingConflict(combo: $0.key,
                                  actions: $0.value.sorted { $0.rawValue < $1.rawValue }) }
}
