import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    /// `launchAtLogin` defaults to the real SMAppService impl and `keybindings`
    /// to the user-writable store; AppDelegate injects the shared runtime
    /// instances in plan 06-05 so the tab and the global hotkey read the same
    /// store. A nil keybindings store (e.g. if seeding ever failed) hides the
    /// Keybindings tab rather than crashing.
    init(configStore: ConfigStore,
         calendar: (any CalendarService)? = nil,
         launchAtLogin: any LaunchAtLoginService = SMAppLaunchAtLoginService(),
         keybindings: KeybindingsStore? = try? KeybindingsStore.loadUser()) {
        let host = NSHostingController(
            rootView: SettingsWindowView(configStore: configStore,
                                         calendar: calendar,
                                         launchAtLogin: launchAtLogin,
                                         keybindings: keybindings))
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
    let launchAtLogin: any LaunchAtLoginService
    let keybindings: KeybindingsStore?

    init(configStore: ConfigStore,
         calendar: (any CalendarService)? = nil,
         launchAtLogin: any LaunchAtLoginService = SMAppLaunchAtLoginService(),
         keybindings: KeybindingsStore? = try? KeybindingsStore.loadUser()) {
        self.configStore = configStore
        self.calendar = calendar
        self.launchAtLogin = launchAtLogin
        self.keybindings = keybindings
    }

    var body: some View {
        TabView {
            GeneralTab(configStore: configStore, launchAtLogin: launchAtLogin)
                .tabItem { Label("General", systemImage: "gearshape") }
            StorageTab(configStore: configStore)
                .tabItem { Label("Storage", systemImage: "folder") }
            AITab(configStore: configStore)
                .tabItem { Label("AI", systemImage: "brain") }
            CalendarTab(configStore: configStore, calendar: calendar)
                .tabItem { Label("Calendar", systemImage: "calendar") }
            IntegrationsTab(configStore: configStore)
                .tabItem { Label("Integrations", systemImage: "tray.and.arrow.down") }
            if let keybindings {
                KeybindingsTab(store: keybindings)
                    .tabItem { Label("Keybindings", systemImage: "keyboard") }
            }
            AdvancedTab(configStore: configStore)
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
    }
}
