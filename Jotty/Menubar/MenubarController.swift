import AppKit
import SwiftUI

@MainActor
final class MenubarController {
    let statusItem: NSStatusItem
    var onCapture: (() -> Void)?
    var onSettings: (() -> Void)?
    /// Toggles the ⌘K command bar (#2); AppDelegate wires this to its
    /// `toggleCommandBar()` — the SAME entry point the global hotkey uses. The
    /// popover closes first (mirrors `onCapture`) so the transient popover is not
    /// still key when the command-bar panel opens.
    var onCommandBar: (() -> Void)?
    /// Opens the calendar canvas window (Phase 8 SC4 / CALX-04); AppDelegate
    /// wires this to its `openCalendarCanvas()`. The popover item is the ONLY
    /// entry point (no Action case / key combo, IN-01). nil (e.g. in tests)
    /// degrades to a no-op item.
    var onOpenCanvas: (() -> Void)?

    private let popover = NSPopover()
    let listModel: MenubarListModel

    init(store: Store,
         calendar: (any CalendarService)? = nil,
         configStore: ConfigStore? = nil,
         claudeHandoff: (any ClaudeHandoff)? = nil,
         inboxService: InboxService? = nil,
         keybindings: KeybindingsStore? = nil) {
        // Model timezone must match the Store's so leftover partitioning and
        // collapse keys agree with the daily-file midnight boundary. `calendar`
        // (default nil) is threaded through so plan 08 injects the real EventKit
        // service from AppDelegate without further signature churn. `configStore`
        // carries the remembered delete-event preference (SC3). `claudeHandoff`
        // (default nil) is the Send-to-Claude seam (SC1) injected from AppDelegate.
        // `inboxService` (default nil) is the Phase 7 unified-inbox coordinator;
        // when wired, `showPopover()` triggers a lazy, self-guarded refresh (SC3).
        // `keybindings` (default nil) is the SHARED user store so the Send-to-Claude
        // menu item shows the LIVE key equivalent (UX-07).
        self.listModel = MenubarListModel(store: store, timezone: store.timezone,
                                          calendar: calendar, configStore: configStore,
                                          claudeHandoff: claudeHandoff,
                                          inboxService: inboxService,
                                          keybindings: keybindings)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // UX-04: native template SF Symbol status icon (adapts to menubar tint and
        // dark mode) with an accessibility label — replaces the raw emoji title
        // (RESEARCH Pattern 2; leaving both image and title would render both).
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "square.and.pencil",
                                accessibilityDescription: "Jotty")
            image?.isTemplate = true
            button.image = image
            button.title = ""
            button.setAccessibilityLabel("Jotty")
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover.behavior = .transient
        // #11: `animates` is (re)set at show time from the LIVE Reduce Motion signal
        // (see showPopover) so a mid-session accessibility change is honoured.
        popover.animates = true
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    /// Shows the popover, optionally spotlighting one task row (Phase 9 SC3 —
    /// the command bar's Enter-on-today-task seam; the only public entry point).
    /// The highlight is applied AFTER `reload()` + `popover.show`: reload clears
    /// `highlightedTaskID` at entry, so set-then-reload would drop it (ordering
    /// is load-bearing). `highlight(taskID:)` also auto-expands a collapsed
    /// leftovers section so the spotlighted row is actually visible.
    func showPopover(highlighting taskID: String? = nil) {
        listModel.reload()
        // Lazy inbox refresh on open (SC3): self-guarded — fires network ONLY when
        // >=1 source isConfigured, so the default/unconfigured config makes no call.
        Task { await listModel.refreshInbox() }

        let view = MenubarListView(
            model: listModel,
            onCapture: { [weak self] in
                self?.popover.performClose(nil)
                self?.onCapture?()
            },
            onSettings: { [weak self] in
                self?.popover.performClose(nil)
                self?.onSettings?()
            },
            onCommandBar: { [weak self] in
                self?.popover.performClose(nil)
                self?.onCommandBar?()
            },
            onOpenCanvas: { [weak self] in
                self?.popover.performClose(nil)
                self?.onOpenCanvas?()
            }
        )

        popover.contentViewController = NSHostingController(rootView: view)
        guard let button = statusItem.button else { return }
        // #11: honour Reduce Motion for the present/dismiss animation, read live so a
        // mid-session toggle takes effect on the next open.
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // AFTER reload + show (reload clears the id; the view is now live to
        // observe the publish and scroll/fade).
        if let taskID {
            listModel.highlight(taskID: taskID)
        }
    }
}
