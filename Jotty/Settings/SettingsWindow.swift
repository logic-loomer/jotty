import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(configStore: ConfigStore) {
        let host = NSHostingController(rootView: StorageTab(configStore: configStore))
        let win = NSWindow(contentViewController: host)
        win.title = "Jotty — Settings"
        win.styleMask = [.titled, .closable]
        super.init(window: win)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
