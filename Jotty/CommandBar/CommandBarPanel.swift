import AppKit
import SwiftUI

/// Borderless panels return false for `canBecomeKey` by default — the search
/// field could never take the caret. Overriding key (but NEVER main) is the
/// verified Spotlight recipe: the panel types while the front app keeps main
/// status (UI-SPEC §Window Chrome; RESEARCH §Panel construction).
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }    // borderless panels default false
    override var canBecomeMain: Bool { false }  // never steal main from the front app
}

/// Retained controller for the ⌘K command bar panel (CMDB-01, SC1).
///
/// Lifecycle contract (AppDelegate, 09-05):
/// - `show()` recomputes placement on the ACTIVE screen every time (never
///   persists the frame) and orders front WITHOUT `NSApp.activate` (Pitfall 2 —
///   activating would deactivate the user's front app and defeat
///   `.nonactivatingPanel`).
/// - Dismissal: the ONE `didResignKeyNotification` observer installed at init
///   (WR-08 — never per-show) closes on click-outside/focus loss; Esc closes
///   via the view's key monitor calling `close()`; the global hotkey toggles
///   via `isVisible`.
@MainActor
final class CommandBarPanelController {

    private let panel: KeyablePanel
    /// Removed in deinit; assigned once at init (WR-08: block observers are
    /// never auto-removed — a per-show registration would accumulate).
    private nonisolated(unsafe) var resignKeyObserver: NSObjectProtocol?

    var isVisible: Bool { panel.isVisible }

    init(model: CommandBarModel) {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 56),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        self.panel = panel

        // The view is a thin shell over the model; the controller injects ONLY
        // presentation closures (Esc-close + content-height tracking). Weak
        // captures: the view must never retain its controller.
        let view = CommandBarView(
            model: model,
            onClose: { [weak self] in self?.close() },
            onHeightChange: { [weak self] height in self?.updateHeight(height) }
        )
        panel.contentViewController = NSHostingController(rootView: view)

        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { _ in
            // Click-outside + focus loss both land here (locked dismissal set).
            MainActor.assumeIsolated { [weak self] in self?.close() }
        }
    }

    /// Recomputes 640pt-wide placement on the ACTIVE screen — mouse-location
    /// screen with the nil fail-soft chain (CaptureWindow WR-03 idiom) — top
    /// edge at ~28% of the screen's height from the top (Spotlight optical
    /// position), then orders front. NEVER `NSApp.activate` (Pitfall 2).
    func show() {
        let mouseLoc = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            let size = panel.frame.size
            let topLeft = NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.maxY - frame.height * 0.28
            )
            panel.setFrameTopLeftPoint(topLeft)
        }
        // No screen at all (clamshell/display-sleep): show unpositioned, never crash.
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel.orderOut(nil)
    }

    /// Tracks the SwiftUI content's height (results grow/shrink with the query):
    /// resizes the panel to hug the content, keeping the TOP edge anchored so
    /// the bar grows downward like Spotlight. SwiftUI's own height animation
    /// drives this per frame, so the window follows the animated content.
    private func updateHeight(_ height: CGFloat) {
        guard height > 0, abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = height
        frame.origin.y = top - height
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    nonisolated deinit {
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
    }
}
