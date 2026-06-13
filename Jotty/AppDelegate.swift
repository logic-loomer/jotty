import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menubar: MenubarController!
    private var hotkey: HotkeyManager!
    private var settingsController: SettingsWindowController?
    private var captureController: CaptureWindowController?

    private var configStore: ConfigStore!
    /// The user-writable keybindings store, SHARED with the Settings → Keybindings tab
    /// so a rebind there is the same store the global hotkey re-reads (Pitfall 4).
    private var keybindings: KeybindingsStore!
    private var store: Store!
    /// The single, app-lifetime launch-at-login service, SHARED with the Settings →
    /// General toggle and the onboarding toggle so all three reflect/mutate one OS state.
    private var launchAtLogin: (any LaunchAtLoginService)!
    /// The Send-to-Claude handoff seam (SC1), injected into the menubar. Reads
    /// `AppConfig.claudeAction` LIVE per send so an AI-tab Web/Code switch needs no
    /// restart (mirrors the calendar/provider live-read idiom).
    private var claudeHandoff: (any ClaudeHandoff)!
    /// Retained so onboarding is presented exactly once and not deallocated mid-flow.
    private var onboardingController: OnboardingWindowController?
    /// Apple FM is constructed once at launch (session reuse is the Phase 3
    /// behavior to preserve) and kept for prewarm + as the cloud/Ollama
    /// fallback provider. The ACTIVE provider is resolved per-capture in
    /// `openCapture()` via ProviderFactory so a Settings switch needs no restart.
    private var appleFM: AppleFMProvider!
    /// The single, app-lifetime calendar service. Constructed once at launch
    /// (one long-lived event store lives inside it) and injected into the
    /// capture-commit path, the menubar read/lifecycle/drift hooks, and the
    /// Settings → Calendar picker. Its `calendarID` closure reads
    /// AppConfig.calendarIdentifier LIVE, so a Settings change takes effect with
    /// no re-wiring. Construction does NOT request access (CONTEXT: lazy on the
    /// first calendar action — the access gate fires inside the read/commit paths).
    private var calendar: EventKitCalendarService!

    private var midnightTimer: Timer?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set activation policy BEFORE the app appears, to avoid a Dock-icon flash.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            configStore = try ConfigStore(path: ConfigStore.defaultPath)
            // User-writable store (seeds from the bundled default on first load).
            // SHARED with the Settings → Keybindings tab so a rebind there re-registers
            // the global hotkey here (Pitfall 4); capture-window-local shortcuts read
            // from this same user store, not the bundled default.
            keybindings = try KeybindingsStore.loadUser()
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
            return
        }

        store = Store(folder: configStore.config.storageFolder, timezone: .current)
        appleFM = AppleFMProvider()
        launchAtLogin = SMAppLaunchAtLoginService()
        // Live-read the action so an AI-tab Web/Code switch takes effect on the next
        // handoff without re-injecting the service (mirrors the calendar id closure).
        claudeHandoff = SystemClaudeHandoff(action: { [weak configStore] in
            configStore?.config.claudeAction ?? .web
        })

        // One calendar service for the whole app. The closure reads the chosen
        // calendar id live from config (not captured), and constructing the
        // service does NOT prompt for access — the lazy gate inside the read/
        // commit paths requests full access only on the first calendar action.
        calendar = EventKitCalendarService(
            calendarID: { [weak configStore] in configStore?.config.calendarIdentifier })

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

        // Inject the real calendar service into the menubar: the read section
        // (SC2), the SC3 lifecycle, and the SC4 drift-on-open hook all ride the
        // model's reloadCalendar(), which fires from reload() (popover open /
        // window close / midnight) whenever a service is wired (plan 06/07).
        menubar = MenubarController(store: store, calendar: calendar,
                                    configStore: configStore, claudeHandoff: claudeHandoff)
        menubar.onCapture = { [weak self] in self?.openCapture() }
        menubar.onSettings = { [weak self] in self?.openSettings() }

        scheduleMidnightRollover(rolloverState: rolloverState)

        hotkey = HotkeyManager()
        registerGlobalHotkey()

        // First-launch onboarding (D-SC5): present the single welcome screen once,
        // after all services are built so its Grant-Calendar routes through the SAME
        // calendar.requestAccess() gate the menubar uses and its launch-at-login toggle
        // shares the app-lifetime service. Skipping never blocks the app.
        if !configStore.config.hasCompletedOnboarding {
            presentOnboarding()
        }
    }

    /// (Re)registers the global capture hotkey from the CURRENT user keybinding for
    /// `.globalToggleCapture`. `HotkeyManager.register` unregisters any prior hotkey
    /// first, so calling this after a rebind swaps the combo live (Pitfall 4 — no
    /// stale hotkey lingers). A nil binding or a registration failure logs, never crashes.
    private func registerGlobalHotkey() {
        guard let combo = keybindings.combo(for: .globalToggleCapture) else {
            hotkey.unregister()
            NSLog("[Jotty] No keybinding for .globalToggleCapture; skipping hotkey registration")
            return
        }
        let success = hotkey.register(combo: combo) { [weak self] in self?.openCapture() }
        if !success {
            NSLog("[Jotty] Global hotkey registration failed — another app may already be using this key combo")
        }
    }

    /// Presents the single-screen onboarding window once. The Grant-Calendar closure
    /// routes through the SAME menubar `requestAccess()` gate (no parallel TCC prompt,
    /// T-6-12) and the shared `launchAtLogin` service backs the toggle.
    private func presentOnboarding() {
        let controller = OnboardingWindowController(
            configStore: configStore,
            launchAtLogin: launchAtLogin,
            requestCalendarAccess: { [weak self] in
                // The SAME gate the menubar uses (promptIfUndetermined defaults true),
                // so the OS shows a single TCC prompt.
                await self?.menubar.listModel.reloadCalendar()
            })
        onboardingController = controller
        controller.present()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Drift-on-open (SC4): when Jotty comes to the foreground, refresh the
        // menubar calendar section so the open-time drift check runs on today+
        // future linked tasks (CONTEXT). Best-effort and off the main path —
        // reloadCalendar() is a no-op when no service is wired and degrades
        // silently on denied access, so it never blocks activation. The menubar
        // may not exist yet during the very first activation at launch (guard).
        guard let menubar else { return }
        // WR-06: foreground activation refreshes the section but must NOT prompt for access
        // when the grant is still notDetermined — otherwise every activation re-issues the
        // TCC dialog. The one-time prompt is driven by explicit user actions (popover open).
        Task { await menubar.listModel.reloadCalendar(promptIfUndetermined: false) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop a Jotty-spawned Ollama daemon so it never outlives the app.
        // stopDaemon() is @MainActor + synchronous-with-timeout (SIGTERM, 5s
        // grace, SIGKILL — plan 04-07) and a NO-OP when Jotty never spawned a
        // daemon (a Homebrew-managed `ollama serve` is not Jotty's to kill).
        OllamaInstaller.shared.stopDaemon()
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

        // Resolve the active provider HERE, on every capture open — this is
        // what makes ROADMAP Phase 4 SC3 true: a Settings switch takes effect
        // on the next extraction with no app restart. When the active provider
        // is not Apple FM, hand the CaptureViewModel an AppleFMProvider as
        // `fallbackProvider` so the plan-10 provider-failure toast can offer a
        // one-tap on-device fallback.
        let usingAppleFM = ProviderFactory.isAppleFM(configStore.config)
        let provider: any AIProvider = usingAppleFM
            ? appleFM
            : ProviderFactory.make(config: configStore.config)
        let fallback: (any AIProvider)? = usingAppleFM ? nil : appleFM

        let vm = CaptureViewModel(store: store, draftURL: draftURL,
                                  provider: provider,
                                  fallbackProvider: fallback,
                                  calendar: calendar)
        let controller = CaptureWindowController(vm: vm)
        captureController = controller
        controller.showCenteredOnActiveDisplay()

        // Prewarm Apple FM model load so first extraction is fast (AI-SPEC §3.5).
        // Only pay the FM model-load cost when Apple FM is the active provider;
        // a cloud/Ollama capture would not benefit from a warm on-device model.
        if usingAppleFM {
            Task { [weak self] in
                guard let self else { return }
                await self.appleFM.prewarm()
            }
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
            // Inject the SHARED runtime services: the live calendar (Calendar tab
            // picker), the app-lifetime launch-at-login service (General toggle), and
            // the SAME user keybindings store the global hotkey reads (Keybindings tab),
            // so a rebind there mutates the store this delegate re-registers from.
            let controller = SettingsWindowController(configStore: configStore,
                                                      calendar: calendar,
                                                      launchAtLogin: launchAtLogin,
                                                      keybindings: keybindings)
            settingsController = controller
            // Pitfall 4: when the Settings window closes, re-register the global hotkey
            // from the (possibly rebound) user store so a globalToggleCapture change
            // takes effect live — no app restart.
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: controller.window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.registerGlobalHotkey() }
            }
        }
        settingsController?.show()
    }
}
