import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menubar: MenubarController!
    private var hotkey: HotkeyManager!
    private var settingsController: SettingsWindowController?
    private var captureController: CaptureWindowController?
    /// The calendar canvas window (Phase 8 SC4 / CALX-04). Created lazily on
    /// the first menubar "Calendar canvas" item tap and retained (mirror of
    /// the Settings controller idiom) so repeated opens re-show one window.
    private var canvasController: CalendarCanvasWindowController?
    /// The ⌘K command bar (Phase 9 CMDB-01). Created lazily on the first
    /// toggle and retained (canvas idiom) so repeated opens re-show one panel.
    private var commandBarController: CommandBarPanelController?
    private var commandBarModel: CommandBarModel?
    /// App-level Action → handler registry (SC4). Built after services; every
    /// CommandActionRegistry action gets a handler + a launch coverage check
    /// (the phase-level IN-01 closure).
    private var dispatcher: ActionDispatcher!
    /// Local key-down monitor routing recorded app-level combos through the
    /// dispatcher (SC4's non-global leg). Installed ONCE at launch; retained
    /// for the app's lifetime (removing it would disable palette keybindings).
    private var localKeyMonitor: Any?

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
    /// The single, app-lifetime unified-inbox coordinator (Phase 7). Constructed once
    /// with the shipped `GitHubInboxSource` and the persisted dedupe `InboxStateStore`,
    /// injected into the menubar. `refresh()` self-guards on a configured source, so the
    /// default config makes no network call (SC3). nil only if the state store fails to
    /// open (degrades to no Suggested section rather than crashing the app).
    private var inboxService: InboxService?

    private var midnightTimer: Timer?
    /// Dedupe-state path (last-rollover.txt) for the midnight rollover, promoted to a
    /// property so `applicationDidBecomeActive` can run the wake catch-up (CQ-07). nil
    /// when Application Support could not be resolved at launch (CQ-06: rollover disabled).
    private var rolloverStatePath: URL?
    /// Opt-in periodic inbox refresh timer (SC3). nil unless `inboxCheckPeriodically`
    /// is on; rescheduled when Settings closes so a toggle/interval change takes effect.
    private var inboxTimer: Timer?

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

        // CQ-06: urls(for:in:) returning an empty array is pathological but possible —
        // fail soft (rollover disabled) instead of crashing the whole launch.
        if let appSupportBase = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let appSupport = appSupportBase.appendingPathComponent("Jotty")
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            rolloverStatePath = appSupport.appendingPathComponent("last-rollover.txt")
        } else {
            NSLog("[Jotty] Application Support unavailable; rollover disabled")
        }

        runRolloverCatchUp()

        // Construct the unified-inbox coordinator (Phase 7): the one shipped
        // GitHubInboxSource (reads its PAT from the Keychain at fetch time) over the
        // shared URLSession, plus the persisted dedupe state. `refresh()` self-guards
        // on a configured source, so with no PAT the menubar open makes no network
        // call (SC3). A state-store open failure degrades to no Suggested section.
        if let inboxState = try? InboxStateStore() {
            inboxService = InboxService(
                sources: [
                    GitHubInboxSource(session: .shared,
                                      keychain: KeychainAPIKeyStore(),
                                      patAccount: "github"),
                    // Phase 11: the calendar source rides the SAME app-lifetime
                    // EventKitCalendarService (L101). `enabled` reads the toggle LIVE
                    // (mirrors the claudeAction/calendarID closures) so a Settings flip
                    // takes effect on the next refresh with no re-wiring; OFF by default
                    // ⇒ isConfigured false ⇒ zero calendar reads (SC5). `linkedEventIDs`
                    // reads today's tasks' cal_event ids FRESH from the Store each call so
                    // the SC4 dedup filter uses current state (never a stale snapshot).
                    CalendarInboxSource(
                        calendar: calendar,
                        enabled: { [weak configStore] in
                            configStore?.config.calendarInboxEnabled ?? false
                        },
                        // @MainActor closure: this live per-fetch Store read runs ON the
                        // main actor, so it never races main-actor writes (accept/reload);
                        // awaiting it hops off-actor fetchItems to main (WR-01).
                        linkedEventIDs: { [weak store] instant in
                            guard let store else { return [] }
                            return Set((try? store.readDoc(on: instant))?
                                .tasks.compactMap(\.calEventID) ?? [])
                        },
                        now: Date.init,
                        timezone: .current)
                ],
                state: inboxState)
        } else {
            NSLog("[Jotty] inbox state store unavailable; Suggested section disabled")
            inboxService = nil
        }

        // Inject the real calendar service into the menubar: the read section
        // (SC2), the SC3 lifecycle, and the SC4 drift-on-open hook all ride the
        // model's reloadCalendar(), which fires from reload() (popover open /
        // window close / midnight) whenever a service is wired (plan 06/07). The
        // inbox service drives the Suggested section + lazy refresh-on-open (Phase 7).
        menubar = MenubarController(store: store, calendar: calendar,
                                    configStore: configStore, claudeHandoff: claudeHandoff,
                                    inboxService: inboxService,
                                    // The SAME user store the Keybindings tab mutates, so
                                    // the Send-to-Claude key equivalent stays live (UX-07).
                                    keybindings: keybindings)
        menubar.onCapture = { [weak self] in self?.openCapture() }
        menubar.onSettings = { [weak self] in self?.openSettings() }
        // #2: the popover's "Search…" affordance opens the SAME ⌘K command bar the
        // global hotkey toggles — one entry point, no divergent open path.
        menubar.onCommandBar = { [weak self] in self?.toggleCommandBar() }
        // Phase 8 SC4: the popover's "Calendar canvas" item — the canvas's
        // only entry point (menubar-item-only, IN-01) — routes here.
        menubar.onOpenCanvas = { [weak self] in self?.openCalendarCanvas() }

        scheduleMidnightRollover()
        // Opt-in periodic inbox refresh (SC3): OFF by default, so this is a no-op
        // unless the user enabled "Check periodically" in Settings → Integrations.
        scheduleInboxTimer()

        // App-level dispatch (SC4): one handler per registry action, then the
        // launch-time coverage check, then the local combo monitor — built
        // after services/menubar so every handler closes over live seams.
        dispatcher = ActionDispatcher()
        registerDispatcherHandlers()
        runDispatchCoverageCheck()
        installLocalKeyMonitor()

        hotkey = HotkeyManager()
        registerGlobalHotkeys()

        // First-launch onboarding (D-SC5): present the single welcome screen once,
        // after all services are built so its Grant-Calendar routes through the SAME
        // calendar.requestAccess() gate the menubar uses and its launch-at-login toggle
        // shares the app-lifetime service. Skipping never blocks the app.
        if !configStore.config.hasCompletedOnboarding {
            presentOnboarding()
        }
    }

    /// (Re)registers BOTH global hotkeys from the CURRENT user keybindings:
    /// `.globalToggleCapture` → openCapture (⌘N) and `.globalCommandBar` →
    /// toggleCommandBar (⌘K), each on its own Carbon id (multi-id dispatch,
    /// Pitfall 1). `HotkeyManager.register` unregisters the same id first, so
    /// calling this after a rebind swaps combos live (Pitfall 4 — the Settings
    /// willClose observer gives ⌘K live rebind for free). If the user binds
    /// both globals to ONE combo, the second RegisterEventHotKey fails and
    /// logs; the KeybindingsTab conflict warning covers it (locked fallback).
    private func registerGlobalHotkeys() {
        registerGlobalHotkey(id: .capture, action: .globalToggleCapture) { [weak self] in
            self?.openCapture()
        }
        registerGlobalHotkey(id: .commandBar, action: .globalCommandBar) { [weak self] in
            self?.toggleCommandBar()
        }
    }

    /// One id's registration leg: a nil binding unregisters the id + logs; a
    /// registration failure logs, never crashes.
    private func registerGlobalHotkey(id: HotkeyManager.ID, action: Action,
                                      handler: @escaping () -> Void) {
        guard let combo = keybindings.combo(for: action) else {
            hotkey.unregister(id: id)
            NSLog("[Jotty] No keybinding for \(action.rawValue); skipping hotkey registration")
            return
        }
        if !hotkey.register(id: id, combo: combo, handler: handler) {
            NSLog("[Jotty] Global hotkey registration failed for \(action.rawValue) — another app may already be using this key combo")
        }
    }

    /// Presents the single-screen onboarding window once. The Grant-Calendar closure
    /// routes through the SAME menubar `requestAccess()` gate (no parallel TCC prompt,
    /// T-6-12) and the shared `launchAtLogin` service backs the toggle.
    private func presentOnboarding() {
        let controller = OnboardingWindowController(
            configStore: configStore,
            launchAtLogin: launchAtLogin,
            // The SAME user store the global hotkey registers from, so the
            // onboarding hotkey line names the LIVE capture combo (UX-02).
            keybindings: keybindings,
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

        // CQ-07 wake catch-up: a Mac asleep across midnight misses its one-shot timer.
        // Re-run the rollover (idempotent — RolloverService self-dedupes via
        // last-rollover.txt, so a same-day re-run is a no-op), reload the list so any
        // moved tasks are reflected (mirrors the timer path), and re-arm the midnight
        // timer so the next fire is scheduled relative to NOW, not the pre-sleep clock.
        // WR-02: the reload's calendar refresh must honor the same no-prompt rule as
        // the reloadCalendar call above — foreground activation is not an explicit
        // calendar action, so it must never re-issue the TCC dialog.
        runRolloverCatchUp()
        menubar.listModel.reload(promptIfUndetermined: false)
        scheduleMidnightRollover()
    }

    /// Runs the rollover once for "now". Safe to call repeatedly — RolloverService
    /// self-dedupes via last-rollover.txt, so a second run on the same day is a no-op
    /// (the CQ-07 wake catch-up relies on this idempotency). A no-op when Application
    /// Support was unavailable at launch (rolloverStatePath == nil, CQ-06).
    private func runRolloverCatchUp() {
        guard let rolloverStatePath else { return }
        do {
            let svc = RolloverService(store: store, statePath: rolloverStatePath, timezone: .current)
            try svc.run(now: Date())
        } catch {
            NSLog("[Jotty] Rollover failed: \(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop a Jotty-spawned Ollama daemon so it never outlives the app.
        // stopDaemon() is @MainActor + synchronous-with-timeout (SIGTERM, 5s
        // grace, SIGKILL — plan 04-07) and a NO-OP when Jotty never spawned a
        // daemon (a Homebrew-managed `ollama serve` is not Jotty's to kill).
        OllamaInstaller.shared.stopDaemon()
    }

    /// (Re)schedules the one-shot midnight rollover timer, invalidating any prior timer
    /// first so repeated activations (CQ-07 wake re-arm) never accumulate timers. A
    /// no-op when rollover is disabled (rolloverStatePath == nil, CQ-06).
    private func scheduleMidnightRollover() {
        midnightTimer?.invalidate()
        midnightTimer = nil
        guard rolloverStatePath != nil else { return }
        let cal = Calendar.current
        // CQ-07: nil is effectively unreachable for a daily 00:00:05 match, but a nil
        // must skip scheduling — never crash on a force-unwrap.
        guard let nextMidnight = cal.nextDate(
            after: Date(),
            matching: DateComponents(hour: 0, minute: 0, second: 5),
            matchingPolicy: .nextTime
        ) else {
            NSLog("[Jotty] could not compute next midnight; rollover timer not scheduled")
            return
        }
        let interval = nextMidnight.timeIntervalSinceNow
        midnightTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.runRolloverCatchUp()
            // WR-02: an unattended timer fire must never pop the system calendar
            // prompt at 00:00:05 while access is still notDetermined.
            self.menubar.listModel.reload(promptIfUndetermined: false)
            self.scheduleMidnightRollover()
        }
    }

    /// (Re)schedules the opt-in periodic inbox refresh (SC3). A no-op (timer cleared)
    /// unless `inboxCheckPeriodically` is on AND an interval is set; the interval is
    /// floored at 5 minutes (Pitfall 1) so the timer can never poll a third-party API
    /// more often. Each tick calls the SAME self-guarded `refreshInbox()` the menubar
    /// open uses, so an unconfigured source still makes no network call. Called at
    /// launch and when Settings closes so a toggle/interval change takes effect live.
    private func scheduleInboxTimer() {
        inboxTimer?.invalidate()
        inboxTimer = nil
        let cfg = configStore.config
        guard cfg.inboxCheckPeriodically, let mins = cfg.inboxCheckIntervalMinutes else { return }
        // IN-03: floor via the shared InboxRefreshPolicy so this never diverges from
        // the Settings stepper's minimum (Pitfall 1).
        let interval = TimeInterval(InboxRefreshPolicy.flooredMinutes(mins) * 60)
        inboxTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.menubar.listModel.refreshInbox() }
        }
    }

    /// Registers one handler per `CommandActionRegistry` action (SC4 — the
    /// dispatch leg IN-01 required). Every handler resolves live state at
    /// DISPATCH time (config folder, login status), never at registration.
    private func registerDispatcherHandlers() {
        dispatcher.register(.globalToggleCapture) { [weak self] in self?.openCapture() }
        dispatcher.register(.openCalendarCanvas) { [weak self] in self?.openCalendarCanvas() }
        dispatcher.register(.openSettingsGeneral) { [weak self] in self?.openSettings(tab: .general) }
        dispatcher.register(.openSettingsStorage) { [weak self] in self?.openSettings(tab: .storage) }
        dispatcher.register(.openSettingsAI) { [weak self] in self?.openSettings(tab: .ai) }
        dispatcher.register(.openSettingsCalendar) { [weak self] in self?.openSettings(tab: .calendar) }
        dispatcher.register(.openSettingsIntegrations) { [weak self] in self?.openSettings(tab: .integrations) }
        dispatcher.register(.openSettingsKeybindings) { [weak self] in self?.openSettings(tab: .keybindings) }
        dispatcher.register(.openSettingsAdvanced) { [weak self] in self?.openSettings(tab: .advanced) }
        dispatcher.register(.toggleLaunchAtLogin) { [weak self] in self?.toggleLaunchAtLogin() }
        dispatcher.register(.replayOnboarding) { [weak self] in self?.replayOnboarding() }
        dispatcher.register(.openTodayFile) { [weak self] in self?.openTodayFile() }
    }

    /// Launch-time dispatch coverage check (phase-level IN-01 closure): every
    /// palette-listed action MUST have a registered handler. A gap logs in
    /// release and asserts in debug — an unwired action is a wiring bug, and
    /// `dispatch` returning false keeps it a no-op rather than a crash.
    private func runDispatchCoverageCheck() {
        for entry in CommandActionRegistry.all where !dispatcher.hasHandler(for: entry.action) {
            NSLog("[Jotty] COVERAGE FAILURE: no dispatcher handler registered for \(entry.action.rawValue)")
            assertionFailure("Unwired palette action: \(entry.action.rawValue)")
        }
    }

    /// Installs the ONE local key-down monitor routing recorded app-level
    /// combos through the dispatcher (SC4's non-global leg). The match rules —
    /// requires ⌘/⌃/⌥, restricted to `ActionDispatcher.appLevelActions`,
    /// deterministic order under a conflict (IN-07), and NEVER while a
    /// RecorderView is capturing a combo (WR-01) — live in the unit-tested
    /// `ActionDispatcher.appLevelActions(matching:bindings:isRecordingCombo:)`.
    /// The event is swallowed ONLY when a dispatch actually handled it.
    private func installLocalKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let pressed = KeyCombo(keyCode: event.keyCode,
                                   modifiers: KeyCombo.modifiers(from: event.modifierFlags))
            for action in ActionDispatcher.appLevelActions(
                matching: pressed,
                bindings: self.keybindings.allBindings(),
                isRecordingCombo: RecorderView.isRecordingActive) {
                if self.dispatcher.dispatch(action) { return nil }
            }
            return event
        }
    }

    /// Toggles the ⌘K command bar (CMDB-01): visible → close; else lazily
    /// build the retained controller+model (canvas idiom), rebuild the per-open
    /// corpus, and show. The toggle lives ONLY here — the view has no local ⌘K
    /// equivalent (Pitfall 10); Carbon hotkeys fire even while our panel is key.
    private func toggleCommandBar() {
        if let controller = commandBarController, controller.isVisible {
            controller.close()
            return
        }
        if commandBarModel == nil || commandBarController == nil {
            let model = CommandBarModel(list: menubar.listModel, dispatcher: dispatcher)
            let controller = CommandBarPanelController(model: model)
            model.onRequestClose = { [weak controller] in controller?.close() }
            // Pitfall 8: close the panel FIRST, then open the popover one
            // runloop later — the transient popover must not open while the
            // panel is still key (it would close as the panel resigns).
            model.onOpenMenubar = { [weak self] taskID in
                self?.commandBarController?.close()
                DispatchQueue.main.async {
                    self?.menubar.showPopover(highlighting: taskID)
                }
            }
            commandBarModel = model
            commandBarController = controller
        }
        commandBarModel?.prepareForOpen()
        commandBarController?.show()
    }

    /// Palette "Toggle Launch at Login": flip the LIVE OS status (never a
    /// cached value — D-SC2). enabled/requiresApproval count as on → disable;
    /// otherwise enable. A throw logs; the General tab reconciles from live
    /// status on its next open, so no state can go stale.
    private func toggleLaunchAtLogin() {
        let status = launchAtLogin.status()
        do {
            if status == .enabled || status == .requiresApproval {
                try launchAtLogin.disable()
            } else {
                try launchAtLogin.enable()
            }
        } catch {
            NSLog("[Jotty] toggle launch at login failed: \(error.localizedDescription)")
        }
    }

    /// Palette "Replay Onboarding": clear the completed flag via the ConfigStore
    /// write idiom (mirror GeneralTab.replayOnboarding), then present. A persist
    /// failure logs and still presents — replaying is harmless.
    private func replayOnboarding() {
        do {
            try configStore.update { $0.hasCompletedOnboarding = false }
        } catch {
            NSLog("[Jotty] replay onboarding: config write failed: \(error.localizedDescription)")
        }
        presentOnboarding()
    }

    /// Palette "Open Today's File": build the Store at DISPATCH time (a
    /// Settings folder change must take effect live — Pitfall 9) and open
    /// today's file in the default editor (MenubarListView open-day-file idiom).
    private func openTodayFile() {
        let store = Store(folder: configStore.config.storageFolder, timezone: .current)
        // #12: create today's file first so the action isn't a silent no-op before
        // the day's first capture. Fall back to the plain URL if the scaffold write
        // fails (e.g. unwritable folder) — same behavior as before the fix.
        let url = (try? store.ensureDayFile(on: Date()))
            ?? DailyFile.url(in: store.folder, on: Date(), timezone: store.timezone)
        NSWorkspace.shared.open(url)
    }

    private func openCapture() {
        // Close any prior capture window to prevent stacking on rapid re-presses.
        captureController?.window?.close()

        // Refresh store in case folder changed in settings.
        store = Store(folder: configStore.config.storageFolder, timezone: .current)

        // WR-09: hand the menubar model the SAME refreshed store (its own reference is
        // otherwise captured at launch and Store.folder is immutable) and reload, so the
        // list/rollover/toggle paths follow a Settings → Storage folder change instead of
        // operating on the old folder for the rest of the session.
        menubar.listModel.replaceStore(store)

        // CQ-06: fail soft — without Application Support there is nowhere to persist
        // the draft, so skip opening capture rather than crashing on a force-unwrap.
        guard let appSupportBase = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            NSLog("[Jotty] Application Support unavailable; capture disabled")
            return
        }
        let appSupport = appSupportBase.appendingPathComponent("Jotty")
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

        // WR-08: block-based observers are never auto-removed — NotificationCenter
        // retains each block for the life of the app, so a per-open registration
        // accumulated unboundedly. Capture the token and remove it when it fires
        // (the window closes exactly once). `nonisolated(unsafe)` is sound: the
        // token is assigned once here, before the window can possibly close, and
        // only read inside the one-shot handler.
        nonisolated(unsafe) var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window,
            queue: .main
        ) { [weak self, weak vm] _ in
            if let token { NotificationCenter.default.removeObserver(token) }
            MainActor.assumeIsolated {
                // CQ-02: the capture window is going away — resolve any pending
                // calendar-conflict prompt to cancel (safe default) so the suspended
                // calendar pass finishes and the task stays uncommitted. Covers both
                // close legs: user-close with the prompt showing, and the post-commit
                // close where a conflict is raised after the window is already gone
                // (teardown flags the VM so a later conflict auto-cancels).
                vm?.teardown()
                self?.menubar.listModel.reload()
            }
        }
    }

    /// Opens the calendar canvas window (Phase 8 SC4 / CALX-04) — reached
    /// exclusively from the menubar popover's "Calendar canvas" item (no
    /// Action case / key combo, IN-01). The window wraps the SHARED menubar
    /// list model, so the canvas reads the same store + calendar seam as the
    /// dropdown and a drop's trailing reload refreshes both surfaces.
    /// OPTIONAL surface: the dropdown stays the default.
    ///
    /// Calendar access stays LAZY (T-8-12 / Phase 5 decision): constructing the
    /// window never prompts; the `reload()` below is an explicit user action,
    /// so it keeps `promptIfUndetermined: true` — the one-time TCC prompt fires
    /// on the FIRST canvas open (if still undetermined), never at launch.
    private func openCalendarCanvas() {
        if canvasController == nil {
            canvasController = CalendarCanvasWindowController(list: menubar.listModel)
        }
        menubar.listModel.reload()
        canvasController?.show()
    }

    /// Opens Settings, optionally deep-linked to `tab` (palette "Open Settings
    /// — X" actions route here through the SettingsTabSelection seam). The
    /// default nil keeps the menubar gear item's behavior unchanged (last tab).
    private func openSettings(tab: SettingsTab? = nil) {
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
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.registerGlobalHotkeys()
                    // A Settings → Integrations toggle/interval change takes effect live.
                    self.scheduleInboxTimer()
                    // WR-09: a Settings → Storage folder change takes effect live too —
                    // rebuild the delegate's store (rollover uses it) and swap it into
                    // the menubar model, whose own Store is otherwise fixed at launch.
                    self.store = Store(folder: self.configStore.config.storageFolder,
                                       timezone: .current)
                    self.menubar.listModel.replaceStore(self.store)
                }
            }
        }
        settingsController?.show(tab: tab)
    }
}
