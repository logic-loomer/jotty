// Jotty/Settings/AdvancedTab.swift
// Settings → Advanced (plan 06-04 Task 2): config reveal + reset + the
// privacy/endpoint summary (D-SC6, REQ-privacy-default).
//
// - "Reveal config.json in Finder" → NSWorkspace.activateFileViewerSelecting
//   (RESEARCH Don't Hand-Roll: native, no Process/`open -R`).
// - "Reset all settings to defaults" → confirm via alert, then write
//   AppConfig.defaultValue. (Reset does NOT touch the Keychain or keybindings —
//   only config.json.)
// - Privacy summary: a one-line posture sentence gated on
//   ProviderFactory.isAppleFM(config) for the LIVE posture, plus the endpoint
//   table reusing ProviderEndpoints so every non-default endpoint URL the app can
//   reach is visible (T-6-11: static non-secret constants only, never key material).
//
// Advanced is its own tab (RESEARCH Open Q3 recommendation), keeping General focused.

import AppKit
import SwiftUI

struct AdvancedTab: View {
    let configStore: ConfigStore

    @State private var resetConfirm = false
    @State private var isAppleFMDefault: Bool
    /// CQ-01: set when a config write fails; drives the shared PersistFailureNotice.
    @State private var persistFailed = false

    init(configStore: ConfigStore) {
        self.configStore = configStore
        _isAppleFMDefault = State(initialValue: ProviderFactory.isAppleFM(configStore.config))
    }

    private static let endpoints: [(provider: String, endpoint: String)] = [
        ("Claude", ProviderEndpoints.claude),
        ("OpenAI", ProviderEndpoints.openai),
        ("Gemini", ProviderEndpoints.gemini),
        ("Ollama (local)", ProviderEndpoints.ollama),
    ]

    var body: some View {
        Form {
            Section(header: Text("Privacy")) {
                Text(privacySummary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(header: Text("Network endpoints")) {
                Text("These are the only endpoints Jotty can reach, and only when you select the matching provider in the AI tab. The default on-device provider makes none of these requests.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Self.endpoints, id: \.provider) { row in
                    HStack(alignment: .top) {
                        Text(row.provider)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 110, alignment: .leading)
                        Text(row.endpoint)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                        Spacer()
                    }
                }
            }

            Section(header: Text("Configuration")) {
                Button("Reveal config.json in Finder") { revealConfig() }
                Button("Reset all settings to defaults") { resetConfirm = true }
                Text("Reset only affects config.json (provider, folder, calendar prefs). API keys and shortcuts are untouched.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                PersistFailureNotice(visible: persistFailed)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 640)
        .onAppear { isAppleFMDefault = ProviderFactory.isAppleFM(configStore.config) }
        .alert("Reset all settings to defaults?", isPresented: $resetConfirm) {
            Button("Reset", role: .destructive) { resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Live posture sentence — on-device default makes zero network requests.
    private var privacySummary: String {
        if isAppleFMDefault {
            return "Default configuration (Apple Foundation Models + local markdown files) makes zero network requests — capture text never leaves your Mac."
        }
        return "A cloud provider is selected, so capture text is sent to that provider's endpoint (listed below) when the AI runs. The default on-device provider makes zero network requests."
    }

    private func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.defaultPath])
    }

    private func resetToDefaults() {
        persist { $0 = AppConfig.defaultValue }
        isAppleFMDefault = ProviderFactory.isAppleFM(configStore.config)
    }

    /// CQ-01 (RESEARCH Pattern 6): wrap config writes in do/catch — success clears
    /// the failure flag, failure sets it. Errors never escape into the view body.
    private func persist(_ mutate: (inout AppConfig) -> Void) {
        do {
            try configStore.update(mutate)
            persistFailed = false
        } catch {
            persistFailed = true
        }
    }
}
