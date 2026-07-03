import AppKit
import SwiftUI

/// Identifies each Settings tab so "Open Settings → X" is a runnable deep link
/// (Phase 9 SC4: the command palette dispatches per-tab settings actions).
enum SettingsTab: String, Hashable, CaseIterable {
    case general, storage, ai, calendar, integrations, keybindings, advanced
}

/// Shared selection state for the Settings TabView. Owned by the (cached)
/// `SettingsWindowController` — the controller is created once and reused
/// (AppDelegate caches it), so deep links must mutate this shared published
/// object rather than pass an init parameter into the view struct.
@MainActor
final class SettingsTabSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
}

@MainActor
final class SettingsWindowController: NSWindowController {
    /// Shared tab-selection seam: mutated by `show(tab:)` for palette deep links,
    /// observed by `SettingsWindowView`'s TabView selection binding.
    let tabSelection = SettingsTabSelection()

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
                                         keybindings: keybindings,
                                         tabSelection: tabSelection))
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

    /// Deep-links to `tab` (when non-nil) and shows the window. Because this
    /// controller is cached across opens, setting the shared published selection
    /// BEFORE `show()` re-selects the tab on every subsequent open too.
    func show(tab: SettingsTab?) {
        if let tab { tabSelection.tab = tab }
        show()
    }
}

struct SettingsWindowView: View {
    let configStore: ConfigStore
    let calendar: (any CalendarService)?
    let launchAtLogin: any LaunchAtLoginService
    let keybindings: KeybindingsStore?
    @ObservedObject var tabSelection: SettingsTabSelection

    init(configStore: ConfigStore,
         calendar: (any CalendarService)? = nil,
         launchAtLogin: any LaunchAtLoginService = SMAppLaunchAtLoginService(),
         keybindings: KeybindingsStore? = try? KeybindingsStore.loadUser(),
         tabSelection: SettingsTabSelection = SettingsTabSelection()) {
        self.configStore = configStore
        self.calendar = calendar
        self.launchAtLogin = launchAtLogin
        self.keybindings = keybindings
        self.tabSelection = tabSelection
    }

    var body: some View {
        TabView(selection: $tabSelection.tab) {
            GeneralTab(configStore: configStore, launchAtLogin: launchAtLogin)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            StorageTab(configStore: configStore)
                .tabItem { Label("Storage", systemImage: "folder") }
                .tag(SettingsTab.storage)
            AITab(configStore: configStore)
                .tabItem { Label("AI", systemImage: "brain") }
                .tag(SettingsTab.ai)
            CalendarTab(configStore: configStore, calendar: calendar)
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(SettingsTab.calendar)
            IntegrationsTab(configStore: configStore)
                .tabItem { Label("Integrations", systemImage: "tray.and.arrow.down") }
                .tag(SettingsTab.integrations)
            if let keybindings {
                KeybindingsTab(store: keybindings)
                    .tabItem { Label("Keybindings", systemImage: "keyboard") }
                    .tag(SettingsTab.keybindings)
            }
            AdvancedTab(configStore: configStore)
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
                .tag(SettingsTab.advanced)
        }
    }
}
