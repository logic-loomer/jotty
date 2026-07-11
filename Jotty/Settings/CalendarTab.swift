// Jotty/Settings/CalendarTab.swift
// Settings → Calendar (plan 05-08): the default-calendar picker + delete preference.
//
// Mirrors AITab's Form/Section idiom. Two controls:
//   1. "Default calendar" — a Picker of writableCalendars() (loaded async via the
//      injected CalendarService), writing AppConfig.calendarIdentifier. A "System
//      default" entry (tag nil) leaves the service to fall back to
//      defaultCalendarForNewEvents (plan 03 targetCalendar). When no service is
//      injected, or access is not yet granted, the picker is disabled with a hint.
//   2. "When deleting a task" — a Picker mapping the three-state
//      AppConfig.deleteCalendarEventWithTask (nil = ask each time / true = always
//      delete / false = keep), writing back via configStore.update.
//
// Reads writableCalendars() through the CalendarService seam only — NO EventKit
// here (T-5-03: EventKit stays confined to EventKitCalendarService + the mapper).

import AppKit
import SwiftUI

struct CalendarTab: View {
    let configStore: ConfigStore
    /// The injected calendar service (the real EventKitCalendarService at runtime;
    /// nil only in previews / when not yet wired). Used to list writable calendars.
    let calendar: (any CalendarService)?

    /// nil tag = "System default" (service falls back to defaultCalendarForNewEvents).
    @State private var selectedCalendarID: String?
    @State private var deletePreference: DeletePreference
    @State private var writableCalendars: [(id: String, title: String)] = []
    @State private var didLoadCalendars = false
    /// CQ-01: set when a config write fails; drives the shared PersistFailureNotice.
    @State private var persistFailed = false
    /// Mirror of the OS calendar grant, so the tab can recover IN PLACE: previously it
    /// never prompted and `didLoadCalendars` latched, so granting access while Settings
    /// was open left the picker empty until the window was reopened.
    @State private var access: CalendarAccess = .notDetermined

    /// The three-state delete preference, mapped to/from the optional Bool config field.
    private enum DeletePreference: Hashable {
        case ask          // nil  — prompt once each time
        case always       // true — always delete the linked event
        case keep         // false — keep the event

        init(_ stored: Bool?) {
            switch stored {
            case .some(true): self = .always
            case .some(false): self = .keep
            case .none: self = .ask
            }
        }

        var stored: Bool? {
            switch self {
            case .ask: return nil
            case .always: return true
            case .keep: return false
            }
        }
    }

    init(configStore: ConfigStore, calendar: (any CalendarService)?) {
        self.configStore = configStore
        self.calendar = calendar
        _selectedCalendarID = State(initialValue: configStore.config.calendarIdentifier)
        _deletePreference = State(initialValue: DeletePreference(configStore.config.deleteCalendarEventWithTask))
    }

    /// Persists a calendar selection, guarding against a SwiftUI Picker auto-reset (WR-07).
    ///
    /// When `writableCalendars` loads and the stored id is no longer in the list (the chosen
    /// calendar was removed from the account), the Picker has no matching tag and SwiftUI can
    /// silently reset `selectedCalendarID` to `nil` ("System default"), firing `.onChange`
    /// and overwriting the user's stored preference with `nil` — a silent loss the user never
    /// confirmed. We only persist when:
    ///   - the calendar list has finished loading (no write during the async load), AND
    ///   - the new value actually differs from what is already stored, AND
    ///   - it is NOT the missing-calendar auto-reset case (new value `nil` while a real
    ///     stored id is simply absent from the freshly-loaded list — keep the stored id).
    private func persistSelectedCalendar(_ newValue: String?) {
        guard didLoadCalendars else { return }
        let stored = configStore.config.calendarIdentifier
        guard newValue != stored else { return }

        if newValue == nil, let stored, !stored.isEmpty,
           !writableCalendars.contains(where: { $0.id == stored }) {
            // Auto-reset to "System default" because the stored calendar isn't in the loaded
            // list. Keep the stored id rather than coercing to nil; restore the binding.
            selectedCalendarID = stored
            return
        }

        persist { $0.calendarIdentifier = newValue }
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

    var body: some View {
        Form {
            Section(header: Text("Target calendar")) {
                Picker("Default calendar", selection: $selectedCalendarID) {
                    Text("System default").tag(String?.none)
                    ForEach(writableCalendars, id: \.id) { cal in
                        Text(cal.title).tag(String?.some(cal.id))
                    }
                }
                .pickerStyle(.menu)
                .disabled(calendar == nil || access != .authorized
                          || (didLoadCalendars && writableCalendars.isEmpty))
                .onChange(of: selectedCalendarID) { _, newValue in
                    persistSelectedCalendar(newValue)
                }

                if calendar == nil {
                    Text("Calendar service unavailable.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else if access == .notDetermined {
                    // Recover in place: ask right here instead of pointing at a future
                    // "first calendar action" and a Settings reopen.
                    Button("Grant Calendar Access") { requestAccessAndReload() }
                    Text("Jotty needs calendar access to list your calendars and create events.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else if access == .denied {
                    Button("Open System Settings") { openPrivacySettings() }
                    Text("Calendar access is off. Enable it for Jotty under Privacy & Security → Calendars.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else if didLoadCalendars && writableCalendars.isEmpty {
                    Text("No writable calendars found in your account.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("New time-blocked tasks create events on this calendar.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }

            Section(header: Text("Deleting a task")) {
                Picker("When deleting a task", selection: $deletePreference) {
                    Text("Ask each time").tag(DeletePreference.ask)
                    Text("Always delete the event").tag(DeletePreference.always)
                    Text("Keep the event").tag(DeletePreference.keep)
                }
                .pickerStyle(.inline)
                .onChange(of: deletePreference) { _, newValue in
                    persist { $0.deleteCalendarEventWithTask = newValue.stored }
                }

                Text("Controls whether deleting a linked task also removes its calendar event.")
                    .font(.subheadline).foregroundStyle(.secondary)

                PersistFailureNotice(visible: persistFailed)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 640)
        .task {
            // Load writable calendars through the seam. writableCalendars() is async
            // (and @MainActor on the real impl); the [(id, title)] tuple is Sendable so
            // the await hop crosses the actor boundary cleanly. Best-effort: if no service
            // is wired the picker stays on "System default" and is disabled.
            guard let calendar else { return }
            access = calendar.access()
            guard access == .authorized, !didLoadCalendars else { return }
            writableCalendars = await calendar.writableCalendars()
            didLoadCalendars = true
        }
    }

    /// The in-place grant path: run the SAME lazy `requestAccess()` gate the menubar
    /// uses (one shared TCC prompt), then — on a grant — load the calendars the latch
    /// previously left empty until the window was reopened.
    private func requestAccessAndReload() {
        guard let calendar else { return }
        Task {
            access = await calendar.requestAccess()
            guard access == .authorized else { return }
            writableCalendars = await calendar.writableCalendars()
            didLoadCalendars = true
        }
    }

    /// Deep-link to Privacy & Security → Calendars for the denied → re-enable path
    /// (an app cannot re-prompt once the user has answered; System Settings is the
    /// only recovery).
    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}
