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
    /// IN-03: single source of truth — shared with AppDelegate's timer scheduler.
    private static let minIntervalMinutes = InboxRefreshPolicy.minIntervalMinutes
    /// Default interval applied when the toggle is first turned on (interval was nil).
    private static let defaultIntervalMinutes = InboxRefreshPolicy.defaultIntervalMinutes

    @State private var checkPeriodically: Bool
    @State private var intervalMinutes: Int
    /// Phase 11 SC5: the calendar-inbox opt-in, seeded from config and persisted on
    /// change. OFF by default so the CalendarInboxSource stays gated (zero reads).
    @State private var suggestCalendarEvents: Bool
    /// CQ-01: set when a config write fails; drives the shared PersistFailureNotice.
    @State private var persistFailed = false

    init(configStore: ConfigStore) {
        self.configStore = configStore
        let cfg = configStore.config
        _checkPeriodically = State(initialValue: cfg.inboxCheckPeriodically)
        _intervalMinutes = State(
            initialValue: max(Self.minIntervalMinutes,
                              cfg.inboxCheckIntervalMinutes ?? Self.defaultIntervalMinutes))
        _suggestCalendarEvents = State(initialValue: cfg.calendarInboxEnabled)
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
                            persist {
                                $0.inboxCheckPeriodically = on
                                // Seed an interval on first enable so the timer has a value.
                                if on, $0.inboxCheckIntervalMinutes == nil {
                                    $0.inboxCheckIntervalMinutes = intervalMinutes
                                }
                            }
                        }
                    Text("Off by default — suggestions refresh when you open the menubar. Turn this on to also check on a timer.")
                        .font(.subheadline).foregroundStyle(.secondary)

                    if checkPeriodically {
                        Stepper(value: $intervalMinutes,
                                in: Self.minIntervalMinutes...120,
                                step: 5) {
                            Text("Every \(intervalMinutes) min")
                                .font(.callout)
                        }
                        .onChange(of: intervalMinutes) { _, mins in
                            let floored = max(Self.minIntervalMinutes, mins)
                            persist { $0.inboxCheckIntervalMinutes = floored }
                        }
                        Text("Minimum 5 minutes.")
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    PersistFailureNotice(visible: persistFailed)
                }
            }

            // (b2) Calendar suggestions — opt-in (default OFF, SC5 privacy default):
            // on-device EventKit reads only, never prompts at launch.
            Section(header: Text("Calendar")) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Suggest today's calendar events", isOn: $suggestCalendarEvents)
                        .onChange(of: suggestCalendarEvents) { _, on in
                            persist { $0.calendarInboxEnabled = on }
                        }
                    Text("Off by default. Reads today's timed events on-device (EventKit, no network) and never prompts at launch — turn this on to surface them as suggestions in the menubar.")
                        .font(.subheadline).foregroundStyle(.secondary)

                    PersistFailureNotice(visible: persistFailed)
                }
            }

            // (c) Transparency table — every planned source + its endpoint (SC4).
            Section(header: Text("All integrations")) {
                Text("Every source Jotty can reach. Only built sources make any network call, and only after you configure them.")
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(InboxSourceCatalog.all, id: \.id) { entry in
                    IntegrationRow(entry: entry)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 640)
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

// MARK: - GitHub PAT row

/// UX-12: per-field probe state for the inline Test result. `done` renders one
/// of three distinct outcomes; the state clears whenever the field text changes
/// so a result always describes exactly the text it probed.
private enum KeyTestState: Equatable {
    case idle
    case testing
    case done(APIKeyValidator.ValidationResult)
}

/// GitHub Personal Access Token entry. Save/Remove route through
/// KeychainAPIKeyStore (account "github") ONLY — the saved PAT is never read
/// back into the UI and never reaches any on-disk preference/settings file
/// (T-7-10). Mirrors AITab's CloudProviderKeyRow idiom (SecureField, draft
/// cleared after save, UX-12 Test probe).
private struct GitHubTokenRow: View {
    /// Keychain account under which the PAT is stored; matches GitHubInboxSource's
    /// `patAccount` default so a token saved here is read by the source.
    private static let account = "github"

    @State private var draftToken: String = ""
    @State private var tokenSaved: Bool = false
    @State private var saveFailed: Bool = false
    /// UX-07 / T-07.1-15: gate the destructive Keychain delete behind confirmation.
    @State private var confirmRemove: Bool = false
    /// UX-12: inline result of the last explicit PAT probe.
    @State private var testState: KeyTestState = .idle

    private let keyStore = KeychainAPIKeyStore()
    private let validator = APIKeyValidator()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Personal access token").font(.body.weight(.medium))
                Spacer()
                if tokenSaved {
                    Label("Token saved", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }
            }
            Text("Needs read access to issues and pull requests. Surfaces your assigned issues and review-requested PRs as suggestions.")
                .font(.subheadline).foregroundStyle(.secondary)
            Text(InboxSourceCatalog.all.first { $0.id == "github" }?.endpoint
                 ?? "https://api.github.com")
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                SecureField("ghp_… / github_pat_…", text: $draftToken)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .onChange(of: draftToken) { _, _ in
                        // UX-12: a probe result describes the exact text it
                        // tested — clear it the moment the field changes.
                        // (Mutates only testState, never draftToken — no
                        // onChange re-entrancy.)
                        if testState != .idle { testState = .idle }
                    }
                Button("Test") { runTokenTest() }
                    .disabled(draftToken.trimmingCharacters(in: .whitespaces).isEmpty
                              || testState == .testing)
                    .help("Paste the token to test it — saved tokens are never read back into the app.")
                Button("Save") { saveToken() }
                    .disabled(draftToken.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Remove") { confirmRemove = true }
                    .disabled(!tokenSaved)
                    .confirmationDialog("Remove GitHub token?",
                                        isPresented: $confirmRemove,
                                        titleVisibility: .visible) {
                        Button("Remove", role: .destructive) { removeToken() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("GitHub inbox suggestions stop until you save a new token.")
                    }
            }
            // UX-12: inline probe outcome. Copy shows status or bare host —
            // never the token value (T-07.1-19).
            switch testState {
            case .idle:
                EmptyView()
            case .testing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Testing token…")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            case .done(.valid):
                Label("Key works", systemImage: "checkmark.circle.fill")
                    .font(.subheadline).foregroundStyle(.green)
            case .done(.rejected):
                Label("Key rejected", systemImage: "xmark.circle.fill")
                    .font(.subheadline).foregroundStyle(.red)
            case .done(.unreachable(let host)):
                Label("Couldn't reach \(host)", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline).foregroundStyle(.orange)
            }
            if saveFailed {
                Text("Couldn't update the Keychain. Try again.")
                    .font(.subheadline).foregroundStyle(.red)
            }
        }
        .onAppear { refreshSavedStatus() }
    }

    /// UX-12: probes the PAT currently in the field. Explicit user action ONLY
    /// (T-07.1-20) — never fires on save, appear, or text change. The saved PAT
    /// is never read back (invariant), so Test requires a non-empty field.
    private func runTokenTest() {
        let token = draftToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        testState = .testing
        Task {
            let result = await validator.validate(.githubPAT, key: token)
            // Apply only if the field still holds the text that was probed;
            // otherwise the result is stale (user edited or saved mid-flight).
            if draftToken.trimmingCharacters(in: .whitespacesAndNewlines) == token {
                testState = .done(result)
            } else {
                testState = .idle
            }
        }
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
                Text(entry.name).font(.body.weight(.medium))
                builtBadge
                Spacer()
            }
            Text(entry.endpoint)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    private var builtBadge: some View {
        Text(entry.built ? "Built" : "Planned")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((entry.built ? Color.green : Color.secondary).opacity(0.15),
                        in: Capsule())
            .foregroundStyle(entry.built ? Color.green : Color.secondary)
    }
}
