import AppKit
import SwiftUI

@MainActor
final class MenubarController {
    let statusItem: NSStatusItem
    var onCapture: (() -> Void)?
    var onSettings: (() -> Void)?

    private let popover = NSPopover()
    let listModel: MenubarListModel

    init(store: Store) {
        // Model timezone must match the Store's so leftover partitioning and
        // collapse keys agree with the daily-file midnight boundary.
        self.listModel = MenubarListModel(store: store, timezone: store.timezone)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "📝"
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

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
