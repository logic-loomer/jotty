import AppKit
import SwiftUI

/// First-launch onboarding (D-SC5): a SINGLE welcome screen (NOT a wizard) shown once
/// when `AppConfig.hasCompletedOnboarding` is false, and replayable from Settings →
/// General. Hosts a SwiftUI view in a small NSWindow.
///
/// The screen never blocks the app: every action is optional, permissions stay lazy,
/// and "Get started" simply flips `hasCompletedOnboarding` true and closes. The
/// "Grant Calendar access" button routes through the SAME `requestAccess()` gate the
/// menubar uses (injected closure) so there is no parallel TCC prompt (T-6-12).
@MainActor
final class OnboardingWindowController: NSWindowController {
    /// - Parameters:
    ///   - configStore: flips `hasCompletedOnboarding` on "Get started".
    ///   - launchAtLogin: the SHARED launch-at-login service (same instance the
    ///     Settings → General toggle uses); enable is best-effort (try?), never fatal.
    ///   - keybindings: the SHARED user keybindings store (same instance the global
    ///     hotkey registers from), so the hotkey line names the LIVE capture combo —
    ///     correct even if the user rebound it before first launch (UX-02).
    ///   - requestCalendarAccess: routes through the menubar's `requestAccess()` gate —
    ///     the SAME one, so the OS shows a single TCC prompt (anti-pattern avoided).
    init(configStore: ConfigStore,
         launchAtLogin: any LaunchAtLoginService,
         keybindings: KeybindingsStore,
         requestCalendarAccess: @escaping () async -> Void) {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        win.title = "Welcome to Jotty"
        win.isReleasedWhenClosed = false
        super.init(window: win)

        let view = OnboardingView(
            configStore: configStore,
            launchAtLogin: launchAtLogin,
            keybindings: keybindings,
            requestCalendarAccess: requestCalendarAccess,
            onGetStarted: { [weak self] in self?.finish() })
        win.contentViewController = NSHostingController(rootView: view)
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        window?.performClose(nil)
    }
}

/// The single welcome screen (D-SC5): value statement, Grant-Calendar, Launch-at-login
/// toggle, 30-second walkthrough link, and a Get-started dismiss. All elements are
/// optional — skipping never blocks the app (permissions stay lazy).
struct OnboardingView: View {
    let configStore: ConfigStore
    let launchAtLogin: any LaunchAtLoginService
    /// The SHARED user keybindings store; the hotkey line below reads the LIVE
    /// `.globalToggleCapture` combo from it (UX-02) — never a hardcoded literal.
    let keybindings: KeybindingsStore
    let requestCalendarAccess: () async -> Void
    let onGetStarted: () -> Void

    /// The 30-second walkthrough target. The project has no hosted help site yet, so
    /// this points at the GitHub repo README (Claude's discretion per the plan;
    /// documented in the SUMMARY). Swap in one place if a help anchor lands later.
    static let walkthroughURL = URL(string: "https://github.com/awon/jotty#readme")!

    @State private var launchAtLoginOn = false
    @State private var calendarRequested = false
    /// Re-entrancy guard (WR-07, mirrors GeneralTab WR-05): true while the onChange handler
    /// reconciles `launchAtLoginOn` to the live OS status after an enable/disable attempt,
    /// so the programmatic reassignment does not re-enter the handler and re-toggle.
    @State private var isReconciling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // (a) one-line value statement
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Jotty")
                    .font(.title.weight(.bold))
                Text("Capture a thought in a keystroke; Jotty turns it into tasks and time blocks, stored as plain markdown you own.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // UX-02: name the ONE keystroke that matters, read LIVE from the shared
            // keybindings store (never a hardcoded literal) — automatically correct
            // even if the user rebound the combo before first launch.
            if let combo = keybindings.combo(for: .globalToggleCapture) {
                HStack(spacing: 10) {
                    Text(combo.displayString)
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(NSColor.controlBackgroundColor)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(NSColor.separatorColor)))
                    Text("opens capture from anywhere")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // (b) Grant Calendar access — routes through the SAME requestAccess() gate.
            VStack(alignment: .leading, spacing: 6) {
                Button(calendarRequested ? "Calendar access requested" : "Grant Calendar access") {
                    calendarRequested = true
                    Task { await requestCalendarAccess() }
                }
                .disabled(calendarRequested)
                Text("Optional — lets Jotty show today’s events alongside your tasks. You can grant this later.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // (c) Launch Jotty at login
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Launch Jotty at login", isOn: $launchAtLoginOn)
                    .onChange(of: launchAtLoginOn) { _, on in
                        // Skip programmatic reconciles so the status reconcile below does not
                        // re-enter and re-toggle (WR-07, mirrors GeneralTab WR-05).
                        guard !isReconciling else { return }
                        // Best-effort, non-fatal (T-6-09): an enable/disable throw must NOT
                        // crash onboarding — but it also must NOT leave a false-positive ON
                        // (WR-07). Attempt the change, then reconcile the toggle to the REAL
                        // OS status so a failed enable visibly flips back off.
                        do {
                            if on { try launchAtLogin.enable() } else { try launchAtLogin.disable() }
                        } catch {
                            // Swallowed for crash-safety; the reconcile below reflects reality.
                        }
                        let live = launchAtLogin.status()
                        let shouldBeOn = (live == .enabled || live == .requiresApproval)
                        if launchAtLoginOn != shouldBeOn {
                            isReconciling = true
                            launchAtLoginOn = shouldBeOn
                            isReconciling = false
                        }
                    }
                Text("Start Jotty automatically when you log in.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // (d) 30-second walkthrough link
            Link("Watch the 30-second walkthrough", destination: Self.walkthroughURL)
                .font(.callout)

            Spacer()

            // (e) Get started — flips the once-only flag and dismisses.
            HStack {
                Spacer()
                Button("Get started") {
                    try? configStore.update { $0.hasCompletedOnboarding = true }
                    onGetStarted()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420, height: 420)
        .onAppear {
            // Reflect the live OS status so the toggle starts in the right position
            // (requiresApproval counts as on — registered, pending user approval), matching
            // GeneralTab and the WR-07 reconcile below.
            let live = launchAtLogin.status()
            isReconciling = true
            launchAtLoginOn = (live == .enabled || live == .requiresApproval)
            isReconciling = false
        }
    }
}
