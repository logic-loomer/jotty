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
    ///   - requestCalendarAccess: routes through the menubar's `requestAccess()` gate —
    ///     the SAME one, so the OS shows a single TCC prompt (anti-pattern avoided).
    init(configStore: ConfigStore,
         launchAtLogin: any LaunchAtLoginService,
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
    let requestCalendarAccess: () async -> Void
    let onGetStarted: () -> Void

    /// The 30-second walkthrough target. The project has no hosted help site yet, so
    /// this points at the GitHub repo README (Claude's discretion per the plan;
    /// documented in the SUMMARY). Swap in one place if a help anchor lands later.
    static let walkthroughURL = URL(string: "https://github.com/awon/jotty#readme")!

    @State private var launchAtLoginOn = false
    @State private var calendarRequested = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // (a) one-line value statement
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Jotty")
                    .font(.system(size: 20, weight: .bold))
                Text("Capture a thought in a keystroke; Jotty turns it into tasks and time blocks, stored as plain markdown you own.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // (c) Launch Jotty at login
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Launch Jotty at login", isOn: $launchAtLoginOn)
                    .onChange(of: launchAtLoginOn) { _, on in
                        // Best-effort, non-fatal (T-6-09): an enable/disable throw is
                        // swallowed so onboarding never crashes on the registration path.
                        if on { try? launchAtLogin.enable() } else { try? launchAtLogin.disable() }
                    }
                Text("Start Jotty automatically when you log in.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // (d) 30-second walkthrough link
            Link("Watch the 30-second walkthrough", destination: Self.walkthroughURL)
                .font(.system(size: 12))

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
            // Reflect the live OS status so the toggle starts in the right position.
            launchAtLoginOn = (launchAtLogin.status() == .enabled)
        }
    }
}
