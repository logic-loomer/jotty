// Jotty/Settings/AITab.swift
// Settings → AI: the full provider control surface (plan 04-10).
//
// - Grouped provider picker (On-device / Cloud) per AI-SPEC §9.1.
// - Per-cloud-provider API-key entry routed EXCLUSIVELY through
//   KeychainAPIKeyStore. Keys never touch config.json or any preference
//   store on disk (REQ-privacy-default).
// - Endpoint transparency (ROADMAP Phase 4 SC5): every cloud endpoint URL the
//   app can hit is visible here before the user enables that provider.

import SwiftUI

// MARK: - Endpoint constants (single source for Settings display)

enum ProviderEndpoints {
    static let claude = "https://api.anthropic.com/v1/messages"
    static let openai = "https://api.openai.com/v1/chat/completions"
    // IN-06: display the bare host instead of a `<model>` template artifact — the host is
    // what matters for the privacy/endpoint transparency surface, and the real per-call URL
    // (with the configured model) is built by GeminiProvider, not read from this constant.
    static let gemini = "https://generativelanguage.googleapis.com"
    static let ollama = "http://127.0.0.1:11434"
}

// MARK: - AITab

struct AITab: View {
    let configStore: ConfigStore

    @State private var availability: AIAvailability = .unavailable(reason: "checking…")
    @State private var selectedProvider: String
    @State private var claudeAction: ClaudeAction

    init(configStore: ConfigStore) {
        self.configStore = configStore
        _selectedProvider = State(initialValue: configStore.config.aiProviderID)
        _claudeAction = State(initialValue: configStore.config.claudeAction)
    }

    var body: some View {
        Form {
            Section(header: Text("Provider")) {
                Picker("AI provider", selection: $selectedProvider) {
                    Section("On-device") {
                        Text("Apple Foundation Models").tag("apple-fm")
                        Text("Ollama").tag("ollama")
                    }
                    Section("Cloud") {
                        Text("Claude").tag("claude")
                        Text("OpenAI").tag("openai")
                        Text("Gemini").tag("gemini")
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedProvider) { _, newValue in
                    try? configStore.update { $0.aiProviderID = newValue }
                }
            }

            Section(header: Text("Send to Claude")) {
                // Mode chosen here drives AppConfig.claudeAction, read live by the
                // SystemClaudeHandoff on the next Send-to-Claude (D-SC1).
                Picker("Claude action", selection: $claudeAction) {
                    Text("Open in Claude (Web)").tag(ClaudeAction.web)
                    Text("Run in Claude Code").tag(ClaudeAction.code)
                }
                .pickerStyle(.inline)
                .onChange(of: claudeAction) { _, newValue in
                    try? configStore.update { $0.claudeAction = newValue }
                }
                Text("\"Send to Claude\" opens the selected task in claude.ai, or hands it to the local Claude Code CLI.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section(header: Text("On-device")) {
                // Apple FM row: posture badge + availability pill.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Apple Foundation Models").font(.system(size: 13, weight: .medium))
                        PostureBadge(onDevice: true)
                        Spacer()
                        HStack(spacing: 6) {
                            Circle().fill(pillColor).frame(width: 9, height: 9)
                            Text(pillText).font(.system(size: 12))
                        }
                    }
                    Text("Capture text never leaves your Mac.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Runs entirely on this Mac — no endpoint.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if case .unavailable(let reason) = availability {
                        Text(reason).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Ollama row: posture badge + local endpoint + runtime section.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Ollama").font(.system(size: 13, weight: .medium))
                        PostureBadge(onDevice: true)
                    }
                    Text("Capture text never leaves your Mac. Inference happens locally via Ollama.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(ProviderEndpoints.ollama)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            // Ollama runtime management (install / daemon / models) — AI-SPEC §5.
            OllamaSettingsSection(configStore: configStore)

            Section(header: Text("Cloud")) {
                CloudProviderKeyRow(
                    title: "Claude",
                    account: "claude",
                    vendorCopy: "Capture text is sent to Anthropic.",
                    endpoint: ProviderEndpoints.claude)
                Divider()
                CloudProviderKeyRow(
                    title: "OpenAI",
                    account: "openai",
                    vendorCopy: "Capture text is sent to OpenAI.",
                    endpoint: ProviderEndpoints.openai)
                Divider()
                CloudProviderKeyRow(
                    title: "Gemini",
                    account: "gemini",
                    vendorCopy: "Capture text is sent to Google.",
                    endpoint: ProviderEndpoints.gemini)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 640)
        .onAppear { availability = AIAvailability.current() }
    }

    private var pillColor: Color {
        switch availability {
        case .available: return .green
        case .downloading: return .yellow
        case .unavailable: return .red
        }
    }

    private var pillText: String {
        switch availability {
        case .available: return "Available"
        case .downloading: return "Downloading…"
        case .unavailable: return "Unavailable"
        }
    }
}

// MARK: - Posture badge (AI-SPEC §9.1)

struct PostureBadge: View {
    let onDevice: Bool

    var body: some View {
        Label(onDevice ? "On-device" : "Cloud",
              systemImage: onDevice ? "lock.fill" : "cloud.fill")
            .font(.system(size: 10, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((onDevice ? Color.green : Color.blue).opacity(0.15),
                        in: Capsule())
            .foregroundStyle(onDevice ? Color.green : Color.blue)
    }
}

// MARK: - Cloud key row

/// One cloud provider's row: posture badge, vendor copy, literal endpoint URL,
/// and SecureField key entry. Save/Remove route through KeychainAPIKeyStore
/// ONLY — the saved key value is never read back into the UI.
private struct CloudProviderKeyRow: View {
    let title: String
    let account: String
    let vendorCopy: String
    let endpoint: String

    @State private var draftKey: String = ""
    @State private var keySaved: Bool = false
    @State private var saveFailed: Bool = false

    private let keyStore = KeychainAPIKeyStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .medium))
                PostureBadge(onDevice: false)
                Spacer()
                if keySaved {
                    Label("Key saved", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
            }
            Text(vendorCopy)
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(endpoint)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                SecureField("API key", text: $draftKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button("Save") { saveKey() }
                    .disabled(draftKey.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Remove") { removeKey() }
                    .disabled(!keySaved)
            }
            if saveFailed {
                Text("Couldn't update the Keychain. Try again.")
                    .font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .onAppear { refreshSavedStatus() }
    }

    private func saveKey() {
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try keyStore.write(account: account, key: key)
            draftKey = ""        // never retain or display the key after save
            saveFailed = false
            keySaved = true
        } catch {
            saveFailed = true
        }
    }

    private func removeKey() {
        do {
            try keyStore.delete(account: account)
            saveFailed = false
            keySaved = false
        } catch {
            saveFailed = true
        }
    }

    private func refreshSavedStatus() {
        // read() only checks presence — the value is discarded immediately.
        keySaved = ((try? keyStore.read(account: account)) ?? nil) != nil
    }
}
