import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(configStore: ConfigStore) {
        let host = NSHostingController(rootView: SettingsWindowView(configStore: configStore))
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

struct SettingsWindowView: View {
    let configStore: ConfigStore

    var body: some View {
        TabView {
            StorageTab(configStore: configStore)
                .tabItem { Label("Storage", systemImage: "folder") }
            AITab()
                .tabItem { Label("AI", systemImage: "brain") }
        }
    }
}
