import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyManager {
    private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) var eventHandler: EventHandlerRef?
    private var handler: (() -> Void)?

    func register(combo: KeyCombo, _ handler: @escaping () -> Void) {
        unregister()
        self.handler = handler

        let hotKeyID = EventHotKeyID(signature: OSType(0x4A4F5454), id: 1)   // 'JOTT'
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
        guard status == noErr, let ref else { return }
        hotKeyRef = ref

        let context = Unmanaged.passUnretained(self).toOpaque()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx -> OSStatus in
            guard let ctx else { return noErr }
            DispatchQueue.main.async {
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(ctx).takeUnretainedValue()
                mgr.handler?()
            }
            return noErr
        }, 1, &spec, context, &eventHandler)
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let handler = eventHandler { RemoveEventHandler(handler) }
        hotKeyRef = nil
        eventHandler = nil
    }

    nonisolated deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
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
