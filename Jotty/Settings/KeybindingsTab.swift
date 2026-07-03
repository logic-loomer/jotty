// Jotty/Settings/KeybindingsTab.swift
// Settings → Keybindings (plan 06-04 Task 2): rebind every Action via a
// record-combo control, warn on conflicts inline, and reset to defaults (D-SC3).
//
// Lists every Action.allCases with a human label + its current combo + a
// RecordComboField to rebind (setCombo on capture, persisted by the store).
// Conflicts are computed reactively from store.allBindings() via conflicts(in:)
// and shown as an inline warning row PER conflict (combo + the conflicting action
// labels) so the user sees the clash before leaving the tab. "Reset to defaults"
// calls store.reset().
//
// NOTE: a change to globalToggleCapture must trigger HotkeyManager re-register —
// that wiring is plan 06-05 (RESEARCH Pitfall 4). This tab only persists the new
// combo via the store; the global hotkey re-registration is out of scope here.

import SwiftUI

struct KeybindingsTab: View {
    let store: KeybindingsStore

    /// Local mirror of the store's bindings so the view re-renders on each rebind
    /// / reset (KeybindingsStore is a reference type with no Combine publisher).
    @State private var bindings: [Action: KeyCombo]
    @State private var resetConfirm = false
    /// CQ-01: set when a keybindings write fails; drives the shared PersistFailureNotice.
    @State private var persistFailed = false

    init(store: KeybindingsStore) {
        self.store = store
        _bindings = State(initialValue: store.allBindings())
    }

    /// Display order + human labels for the bound actions. Internal (not private)
    /// so CommandActionRegistryTests can assert the IN-01 row-coverage contract:
    /// every routed action has a row here.
    static let labels: [(action: Action, label: String)] = [
        (.globalToggleCapture,      "Open capture window"),
        (.globalCommandBar,         "Open command bar"),
        (.captureSubmit,            "Submit capture"),
        (.captureCancel,            "Cancel capture"),
        (.sendToClaude,             "Send to Claude"),
        (.openCalendarCanvas,       "Open calendar canvas"),
        (.openTodayFile,            "Open today's file"),
        (.openSettingsGeneral,      "Open Settings — General"),
        (.openSettingsStorage,      "Open Settings — Storage"),
        (.openSettingsAI,           "Open Settings — AI"),
        (.openSettingsCalendar,     "Open Settings — Calendar"),
        (.openSettingsIntegrations, "Open Settings — Integrations"),
        (.openSettingsKeybindings,  "Open Settings — Keybindings"),
        (.openSettingsAdvanced,     "Open Settings — Advanced"),
        (.toggleLaunchAtLogin,      "Toggle launch at login"),
        (.replayOnboarding,         "Replay onboarding"),
    ]

    /// WR-06: GLOBAL hotkeys must require a modifier — a bare key would be
    /// grabbed system-wide and hijack that key everywhere. BOTH globals qualify.
    static let requiresModifierActions: Set<Action> = [.globalToggleCapture, .globalCommandBar]

    /// Phase 9 review WR-02: APP-LEVEL actions fire through the AppDelegate local
    /// monitor, which requires ⌘/⌃/⌥ — so the recorder must enforce the same rule
    /// or a bare/⇧-only combo records as a permanently dead binding. The SAME set
    /// the monitor routes, so the two rules can never drift apart.
    static let requiresCommandModifierActions: Set<Action> = ActionDispatcher.appLevelActions

    private var currentConflicts: [KeybindingConflict] {
        conflicts(in: bindings)
    }

    var body: some View {
        Form {
            Section(header: Text("Shortcuts")) {
                ForEach(Self.labels, id: \.action) { entry in
                    HStack {
                        Text(entry.label)
                        Spacer()
                        RecordComboField(
                            current: bindings[entry.action],
                            allowsBareKey: !Self.requiresModifierActions.contains(entry.action),
                            requiresCommandLikeModifier:
                                Self.requiresCommandModifierActions.contains(entry.action)
                        ) { combo in
                            rebind(entry.action, to: combo)
                        }
                        .frame(width: 120, height: 24)
                    }
                }
            }

            if !currentConflicts.isEmpty {
                Section(header: Text("Conflicts")) {
                    ForEach(currentConflicts, id: \.combo) { conflict in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text("\(conflict.combo.displayString) is bound to \(conflictActionLabels(conflict)). Each shortcut should be unique.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Button("Reset to defaults") { resetConfirm = true }
                Text("Click a shortcut, then press a new key combination to rebind it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                PersistFailureNotice(visible: persistFailed)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 640)
        .alert("Reset all shortcuts to their defaults?", isPresented: $resetConfirm) {
            Button("Reset", role: .destructive) { resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func conflictActionLabels(_ conflict: KeybindingConflict) -> String {
        let names = conflict.actions.map { action in
            Self.labels.first { $0.action == action }?.label ?? action.rawValue
        }
        return names.joined(separator: " and ")
    }

    // CQ-01 (RESEARCH Pattern 6): KeybindingsStore writes get the same do/catch +
    // flag idiom as ConfigStore persists — errors never escape into the view body.

    private func rebind(_ action: Action, to combo: KeyCombo) {
        do {
            try store.setCombo(combo, for: action)
            persistFailed = false
        } catch {
            persistFailed = true
        }
        bindings = store.allBindings()
    }

    private func resetToDefaults() {
        do {
            try store.reset()
            persistFailed = false
        } catch {
            persistFailed = true
        }
        bindings = store.allBindings()
    }
}
