import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menubar: MenubarController!
    private var hotkey: HotkeyManager!
    private var settingsController: SettingsWindowController?
    private var captureController: CaptureWindowController?

    private var configStore: ConfigStore!
    private var keybindings: KeybindingsStore!
    private var store: Store!

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set activation policy BEFORE the app appears, to avoid a Dock-icon flash.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            configStore = try ConfigStore(path: ConfigStore.defaultPath)
            keybindings = try KeybindingsStore.loadDefault()
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
            return
        }

        store = Store(folder: configStore.config.storageFolder, timezone: .current)

        menubar = MenubarController()
        menubar.onCapture = { [weak self] in self?.openCapture() }
        menubar.onSettings = { [weak self] in self?.openSettings() }

        hotkey = HotkeyManager()
        if let combo = keybindings.combo(for: .globalToggleCapture) {
            let success = hotkey.register(combo: combo) { [weak self] in self?.openCapture() }
            if !success {
                NSLog("[Jotty] Global hotkey registration failed — another app may already be using this key combo")
            }
        } else {
            NSLog("[Jotty] No keybinding for .globalToggleCapture; skipping hotkey registration")
        }
    }

    private func openCapture() {
        // Close any prior capture window to prevent stacking on rapid re-presses.
        captureController?.window?.close()

        // Refresh store in case folder changed in settings.
        store = Store(folder: configStore.config.storageFolder, timezone: .current)

        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Jotty")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let draftURL = appSupport.appendingPathComponent("draft.txt")

        let vm = CaptureViewModel(store: store, draftURL: draftURL)
        captureController = CaptureWindowController(vm: vm)
        captureController?.showCenteredOnActiveDisplay()
    }

    private func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(configStore: configStore)
        }
        settingsController?.show()
    }
}
