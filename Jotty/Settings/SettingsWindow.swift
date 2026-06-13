import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(configStore: ConfigStore, calendar: (any CalendarService)? = nil) {
        let host = NSHostingController(
            rootView: SettingsWindowView(configStore: configStore, calendar: calendar))
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
    let calendar: (any CalendarService)?

    var body: some View {
        TabView {
            StorageTab(configStore: configStore)
                .tabItem { Label("Storage", systemImage: "folder") }
            AITab(configStore: configStore)
                .tabItem { Label("AI", systemImage: "brain") }
            CalendarTab(configStore: configStore, calendar: calendar)
                .tabItem { Label("Calendar", systemImage: "calendar") }
        }
    }
}
