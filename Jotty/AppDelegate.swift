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
    private var aiProvider: AppleFMProvider!

    private var midnightTimer: Timer?

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
        aiProvider = AppleFMProvider()

        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Jotty")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let rolloverState = appSupport.appendingPathComponent("last-rollover.txt")

        do {
            let svc = RolloverService(store: store, statePath: rolloverState, timezone: .current)
            try svc.run(now: Date())
        } catch {
            NSLog("[Jotty] Rollover failed: \(error.localizedDescription)")
        }

        menubar = MenubarController(store: store)
        menubar.onCapture = { [weak self] in self?.openCapture() }
        menubar.onSettings = { [weak self] in self?.openSettings() }

        scheduleMidnightRollover(rolloverState: rolloverState)

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

    private func scheduleMidnightRollover(rolloverState: URL) {
        midnightTimer?.invalidate()
        let cal = Calendar.current
        let nextMidnight = cal.nextDate(
            after: Date(),
            matching: DateComponents(hour: 0, minute: 0, second: 5),
            matchingPolicy: .nextTime
        )!
        let interval = nextMidnight.timeIntervalSinceNow
        midnightTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            let svc = RolloverService(store: self.store, statePath: rolloverState, timezone: .current)
            try? svc.run(now: Date())
            self.menubar.listModel.reload()
            self.scheduleMidnightRollover(rolloverState: rolloverState)
        }
    }

    private func openCapture() {
        // Close any prior capture window to prevent stacking on rapid re-presses.
        captureController?.window?.close()

        // Refresh store in case folder changed in settings.
        store = Store(folder: configStore.config.storageFolder, timezone: .current)

        // Reload list now so any config-folder change is reflected before the popover opens.
        menubar.listModel.reload()

        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Jotty")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let draftURL = appSupport.appendingPathComponent("draft.txt")

        let vm = CaptureViewModel(store: store, draftURL: draftURL, provider: aiProvider)
        let controller = CaptureWindowController(vm: vm)
        captureController = controller
        controller.showCenteredOnActiveDisplay()

        // Prewarm Apple FM model load so first extraction is fast (AI-SPEC §3.5).
        Task { [weak self] in
            guard let self else { return }
            await self.aiProvider.prewarm()
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window,
            queue: .main
        ) { [weak self] _ in
            self?.menubar.listModel.reload()
        }
    }

    private func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(configStore: configStore)
        }
        settingsController?.show()
    }
}
