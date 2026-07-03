import AppKit
import SwiftUI

@MainActor
final class MenubarController {
    let statusItem: NSStatusItem
    var onCapture: (() -> Void)?
    var onSettings: (() -> Void)?

    private let popover = NSPopover()
    let listModel: MenubarListModel

    init(store: Store,
         calendar: (any CalendarService)? = nil,
         configStore: ConfigStore? = nil,
         claudeHandoff: (any ClaudeHandoff)? = nil,
         inboxService: InboxService? = nil) {
        // Model timezone must match the Store's so leftover partitioning and
        // collapse keys agree with the daily-file midnight boundary. `calendar`
        // (default nil) is threaded through so plan 08 injects the real EventKit
        // service from AppDelegate without further signature churn. `configStore`
        // carries the remembered delete-event preference (SC3). `claudeHandoff`
        // (default nil) is the Send-to-Claude seam (SC1) injected from AppDelegate.
        // `inboxService` (default nil) is the Phase 7 unified-inbox coordinator;
        // when wired, `showPopover()` triggers a lazy, self-guarded refresh (SC3).
        self.listModel = MenubarListModel(store: store, timezone: store.timezone,
                                          calendar: calendar, configStore: configStore,
                                          claudeHandoff: claudeHandoff,
                                          inboxService: inboxService)

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
        popover.animates = true
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
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
            }
        )

        popover.contentViewController = NSHostingController(rootView: view)
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}
