// Jotty/Settings/IntegrationsTab.swift
// Settings → Integrations: the unified-inbox control + transparency surface (Phase 7).
//
// - GitHub Personal Access Token entry routed EXCLUSIVELY through
//   KeychainAPIKeyStore (account "github") — the only place the secret is ever
//   stored. It never reaches any on-disk preference/settings file; the draft is
//   cleared after save and the value is never read back into the UI
//   (T-7-10, REQ-privacy-default).
// - "Check periodically" opt-in toggle (default OFF, SC3 privacy default): no
//   background polling on the default config; refresh runs on menubar open.
//   The interval is gated on the toggle and floored at 5 minutes (Pitfall 1).
// - "All integrations" transparency table: every planned source from
//   InboxSourceCatalog with a Built/Planned badge and its bare endpoint host
//   (SC4) — the same disclosure idiom as AITab's cloud-endpoint rows.

import SwiftUI

struct IntegrationsTab: View {
    let configStore: ConfigStore

    /// The minimum opt-in interval (Pitfall 1): the periodic timer can never poll
    /// a third-party API more often than this, even if a stale config asks for less.
    private static let minIntervalMinutes = 5
    /// Default interval applied when the toggle is first turned on (interval was nil).
    private static let defaultIntervalMinutes = 15

    @State private var checkPeriodically: Bool
    @State private var intervalMinutes: Int

    init(configStore: ConfigStore) {
        self.configStore = configStore
        let cfg = configStore.config
        _checkPeriodically = State(initialValue: cfg.inboxCheckPeriodically)
        _intervalMinutes = State(
            initialValue: max(Self.minIntervalMinutes,
                              cfg.inboxCheckIntervalMinutes ?? Self.defaultIntervalMinutes))
    }

    var body: some View {
        Form {
            // (a) GitHub PAT entry — Keychain-routed, draft-cleared, never read back.
            Section(header: Text("GitHub")) {
                GitHubTokenRow()
            }

            // (b) Refresh policy — opt-in periodic toggle (default OFF), gated interval.
            Section(header: Text("Refresh")) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Check periodically", isOn: $checkPeriodically)
                        .onChange(of: checkPeriodically) { _, on in
                            try? configStore.update {
                                $0.inboxCheckPeriodically = on
                                // Seed an interval on first enable so the timer has a value.
                                if on, $0.inboxCheckIntervalMinutes == nil {
                                    $0.inboxCheckIntervalMinutes = intervalMinutes
                                }
                            }
                        }
                    Text("Off by default — suggestions refresh when you open the menubar. Turn this on to also check on a timer.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)

                    if checkPeriodically {
                        Stepper(value: $intervalMinutes,
                                in: Self.minIntervalMinutes...120,
                                step: 5) {
                            Text("Every \(intervalMinutes) min")
                                .font(.system(size: 12))
                        }
                        .onChange(of: intervalMinutes) { _, mins in
                            let floored = max(Self.minIntervalMinutes, mins)
                            try? configStore.update { $0.inboxCheckIntervalMinutes = floored }
                        }
                        Text("Minimum 5 minutes.")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // (c) Transparency table — every planned source + its endpoint (SC4).
            Section(header: Text("All integrations")) {
                Text("Every source Jotty can reach. Only built sources make any network call, and only after you configure them.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(InboxSourceCatalog.all, id: \.id) { entry in
                    IntegrationRow(entry: entry)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 640)
    }
}

// MARK: - GitHub PAT row

/// GitHub Personal Access Token entry. Save/Remove route through
/// KeychainAPIKeyStore (account "github") ONLY — the saved PAT is never read
/// back into the UI and never reaches any on-disk preference/settings file
/// (T-7-10). Mirrors AITab's CloudProviderKeyRow idiom (SecureField, draft
/// cleared after save).
private struct GitHubTokenRow: View {
    /// Keychain account under which the PAT is stored; matches GitHubInboxSource's
    /// `patAccount` default so a token saved here is read by the source.
    private static let account = "github"

    @State private var draftToken: String = ""
    @State private var tokenSaved: Bool = false
    @State private var saveFailed: Bool = false

    private let keyStore = KeychainAPIKeyStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Personal access token").font(.system(size: 13, weight: .medium))
                Spacer()
                if tokenSaved {
                    Label("Token saved", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
            }
            Text("Needs read access to issues and pull requests. Surfaces your assigned issues and review-requested PRs as suggestions.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(InboxSourceCatalog.all.first { $0.id == "github" }?.endpoint
                 ?? "https://api.github.com")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                SecureField("ghp_… / github_pat_…", text: $draftToken)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button("Save") { saveToken() }
                    .disabled(draftToken.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Remove") { removeToken() }
                    .disabled(!tokenSaved)
            }
            if saveFailed {
                Text("Couldn't update the Keychain. Try again.")
                    .font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .onAppear { refreshSavedStatus() }
    }

    private func saveToken() {
        let token = draftToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        do {
            try keyStore.write(account: Self.account, key: token)
            draftToken = ""        // never retain or display the PAT after save
            saveFailed = false
            tokenSaved = true
        } catch {
            saveFailed = true
        }
    }

    private func removeToken() {
        do {
            try keyStore.delete(account: Self.account)
            saveFailed = false
            tokenSaved = false
        } catch {
            saveFailed = true
        }
    }

    private func refreshSavedStatus() {
        // read() only checks presence — the value is discarded immediately.
        tokenSaved = ((try? keyStore.read(account: Self.account)) ?? nil) != nil
    }
}

// MARK: - Transparency row

/// One row of the "All integrations" table: the source name, a Built/Planned
/// badge from `entry.built`, and the bare endpoint host (SC4 disclosure).
private struct IntegrationRow: View {
    let entry: InboxSourceCatalog.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.name).font(.system(size: 13, weight: .medium))
                builtBadge
                Spacer()
            }
            Text(entry.endpoint)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    private var builtBadge: some View {
        Text(entry.built ? "Built" : "Planned")
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((entry.built ? Color.green : Color.secondary).opacity(0.15),
                        in: Capsule())
            .foregroundStyle(entry.built ? Color.green : Color.secondary)
    }
}
