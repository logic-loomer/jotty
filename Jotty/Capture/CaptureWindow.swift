import AppKit
import SwiftUI

@MainActor
final class CaptureWindowController: NSWindowController {
    private let vm: CaptureViewModel

    init(vm: CaptureViewModel) {
        self.vm = vm
        let view = CaptureView(
            vm: vm,
            onSubmit: { [weak vm] in
                guard let vm else { return }
                do { try vm.submit() } catch { NSSound.beep() }
                NSApp.keyWindow?.close()
            },
            onCancel: {
                NSApp.keyWindow?.close()
            }
        )
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: win)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showCenteredOnActiveDisplay() {
        guard let win = window else { return }
        let mouseLoc = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) })
                    ?? NSScreen.main!
        let frame = screen.visibleFrame
        let size = win.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        )
        win.setFrameOrigin(origin)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        win.makeKeyAndOrderFront(nil)
    }
}
