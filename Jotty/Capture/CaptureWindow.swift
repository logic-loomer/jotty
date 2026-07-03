import AppKit
import SwiftUI

@MainActor
final class CaptureWindowController: NSWindowController {
    private let vm: CaptureViewModel

    init(vm: CaptureViewModel) {
        self.vm = vm

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 280),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = CaptureView(
            vm: vm,
            onSubmitInput: { [weak vm] in
                // Just kick off submission. Don't close here — the AI path lands
                // in Review via vm.state, and BOTH commit paths now close the
                // window through vm.dismissRequested -> CaptureView.onChange ->
                // this controller's onDismiss closure (UX-03, plan 07.1-06).
                vm?.submit()
            },
            onDismiss: { [weak win] in
                win?.close()
            }
        )
        win.contentViewController = NSHostingController(rootView: view)
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
