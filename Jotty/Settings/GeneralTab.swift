// Jotty/Settings/GeneralTab.swift
// Settings → General (plan 06-04): launch-at-login toggle + live status + the
// onboarding-replay button.
//
// - "Launch Jotty at login": a Toggle whose onChange registers/unregisters the
//   app via the injected LaunchAtLoginService. Both calls are wrapped in try?
//   and a thrown register()/unregister() (dev-signing, RESEARCH Pitfall 1 /
//   threat T-6-09) surfaces a one-line inline notice — NEVER crashes (D-SC2).
// - A live status line reflecting status() read from the OS each appearance/toggle.
//   On .requiresApproval it shows the "enable in System Settings > Login Items" hint.
// - "Replay welcome screen": clears hasCompletedOnboarding so the first-run
//   onboarding shows again on next launch (D-SC5 replayable).
//
// The Claude default-action picker lives on the AI tab (plan 06-04 Task 2), so
// GeneralTab does not duplicate it.

import SwiftUI

struct GeneralTab: View {
    let configStore: ConfigStore
    /// The launch-at-login seam. Defaults to the real SMAppService impl so the
    /// shipping app works without explicit injection; tests / previews inject
    /// FakeLaunchAtLoginService so the suite never registers a real login item.
    let launchAtLogin: any LaunchAtLoginService

    @State private var launchEnabled: Bool
    @State private var status: LaunchAtLoginStatus
    @State private var toggleFailed = false
    @State private var onboardingReset = false

    init(configStore: ConfigStore,
         launchAtLogin: any LaunchAtLoginService = SMAppLaunchAtLoginService()) {
        self.configStore = configStore
        self.launchAtLogin = launchAtLogin
        let initialStatus = launchAtLogin.status()
        _status = State(initialValue: initialStatus)
        _launchEnabled = State(initialValue: initialStatus == .enabled)
    }

    var body: some View {
        Form {
            Section(header: Text("Startup")) {
                Toggle("Launch Jotty at login", isOn: $launchEnabled)
                    .onChange(of: launchEnabled) { _, newValue in
                        applyLaunchAtLogin(newValue)
                    }

                if let hint = statusHint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if toggleFailed {
                    Text("Couldn't update the login item. Try again, or set it in System Settings > Login Items.")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }

            Section(header: Text("Onboarding")) {
                Button("Replay welcome screen") { replayOnboarding() }
                if onboardingReset {
                    Text("The welcome screen will appear next time you launch Jotty.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 640)
        .onAppear { refreshStatus() }
    }

    /// Human-readable status / approval hint for the current OS state.
    private var statusHint: String? {
        switch status {
        case .enabled:
            return "Jotty will start automatically when you log in."
        case .requiresApproval:
            return "Enable Jotty in System Settings > General > Login Items to finish turning this on."
        case .notRegistered:
            return "Jotty will not start automatically."
        case .notFound:
            return "Login-item registration isn't available for this build."
        }
    }

    private func applyLaunchAtLogin(_ enable: Bool) {
        toggleFailed = false
        do {
            if enable {
                try launchAtLogin.enable()
            } else {
                try launchAtLogin.disable()
            }
        } catch {
            // Dev-signing / OS refusal (T-6-09): surface a notice, never crash.
            toggleFailed = true
        }
        refreshStatus()
    }

    /// Re-reads the live OS status (D-SC2: never trust a cached/persisted value)
    /// and reconciles the toggle to it (e.g. requiresApproval keeps the toggle on
    /// but shows the approval hint; a failed enable flips it back off).
    private func refreshStatus() {
        let live = launchAtLogin.status()
        status = live
        let shouldBeOn = (live == .enabled || live == .requiresApproval)
        if launchEnabled != shouldBeOn {
            launchEnabled = shouldBeOn
        }
    }

    private func replayOnboarding() {
        try? configStore.update { $0.hasCompletedOnboarding = false }
        onboardingReset = true
    }
}
