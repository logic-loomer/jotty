import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyManager {
    /// Four-char-code signature for our `EventHotKeyID` ('JOTT'), extracted from the inline
    /// magic literal (IN-03) so the value has a name at its single use site.
    private static let signature = OSType(0x4A4F5454)   // 'JOTT'

    /// Stable Carbon hotkey ids. These raw values are baked into registered
    /// `EventHotKeyID`s — a rename must NEVER renumber them.
    enum ID: UInt32 {
        case capture = 1
        case commandBar = 2
    }

    /// id → handler map dispatched by the Carbon callback.
    ///
    /// internal (not private) ON PURPOSE: dispatch-routing tests seed this map
    /// directly and drive `handleHotkey(id:)` without touching Carbon registration,
    /// which is event-loop dependent and stays human-verified (RESEARCH Validation).
    var handlers: [UInt32: () -> Void] = [:]

    private nonisolated(unsafe) var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private nonisolated(unsafe) var eventHandler: EventHandlerRef?

    /// Carbon callback target: routes an event's `EventHotKeyID.id` to ONLY the
    /// matching handler. Unknown ids are a safe no-op (RESEARCH Pitfall 1 — the
    /// old callback ignored the id and fired the single handler for EVERY hotkey).
    func handleHotkey(id: UInt32) {
        handlers[id]?()
    }

    /// Registers (or re-registers) the hotkey for `id`. Re-registering the same id
    /// first unregisters it, so calling this after a rebind swaps the combo live
    /// (Pitfall-4 Settings-close idiom). Returns false on registration failure
    /// (e.g. a duplicate combo — RegisterEventHotKey fails; the KeybindingsTab
    /// conflict warning covers it): logs, never crashes.
    @discardableResult
    func register(id: ID, combo: KeyCombo, handler: @escaping () -> Void) -> Bool {
        unregister(id: id)

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id.rawValue)
        let modifiers = carbonModifiers(for: combo.modifiers)

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            NSLog("[Jotty] RegisterEventHotKey failed (status=\(status)) for keyCode=\(combo.keyCode)")
            return false
        }

        guard installEventHandlerIfNeeded() else {
            UnregisterEventHotKey(ref)
            return false
        }

        hotKeyRefs[id.rawValue] = ref
        handlers[id.rawValue] = handler
        return true
    }

    /// Unregisters the hotkey for `id` and drops its handler. When the last
    /// handler goes away the shared Carbon event handler is removed too (it is
    /// re-installed lazily on the next successful registration).
    func unregister(id: ID) {
        if let ref = hotKeyRefs[id.rawValue] { UnregisterEventHotKey(ref) }
        hotKeyRefs[id.rawValue] = nil
        handlers[id.rawValue] = nil
        if handlers.isEmpty, let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    /// Installs the ONE shared Carbon event handler lazily on the first successful
    /// registration. The callback extracts the event's `EventHotKeyID` via
    /// `GetEventParameter` and dispatches `handleHotkey(id:)` on the main queue —
    /// the id extraction the single-slot design was missing (Pitfall 1).
    private func installEventHandlerIfNeeded() -> Bool {
        guard eventHandler == nil else { return true }

        let context = Unmanaged.passUnretained(self).toOpaque()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, ctx -> OSStatus in
            guard let ctx else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let id = hkID.id
            DispatchQueue.main.async {
                Unmanaged<HotkeyManager>.fromOpaque(ctx).takeUnretainedValue().handleHotkey(id: id)
            }
            return noErr
        }, 1, &spec, context, &eventHandler)
        guard installStatus == noErr else {
            NSLog("[Jotty] InstallEventHandler failed (status=\(installStatus))")
            return false
        }
        return true
    }

    nonisolated deinit {
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        if let handler = eventHandler { RemoveEventHandler(handler) }
    }

    private func carbonModifiers(for set: Set<KeyCombo.Modifier>) -> UInt32 {
        var v: UInt32 = 0
        if set.contains(.cmd)   { v |= UInt32(cmdKey) }
        if set.contains(.shift) { v |= UInt32(shiftKey) }
        if set.contains(.opt)   { v |= UInt32(optionKey) }
        if set.contains(.ctrl)  { v |= UInt32(controlKey) }
        return v
    }
}
