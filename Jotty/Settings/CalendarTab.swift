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
                .disabled(calendar == nil || (didLoadCalendars && writableCalendars.isEmpty))
                .onChange(of: selectedCalendarID) { _, newValue in
                    try? configStore.update { $0.calendarIdentifier = newValue }
                }

                if calendar == nil {
                    Text("Calendar service unavailable.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else if didLoadCalendars && writableCalendars.isEmpty {
                    Text("No writable calendars yet — grant calendar access (Jotty asks on the first calendar action), then reopen Settings.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("New time-blocked tasks create events on this calendar.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
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
                    try? configStore.update { $0.deleteCalendarEventWithTask = newValue.stored }
                }

                Text("Controls whether deleting a linked task also removes its calendar event.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 640)
        .task {
            // Load writable calendars through the seam. writableCalendars() is async
            // (and @MainActor on the real impl); the [(id, title)] tuple is Sendable so
            // the await hop crosses the actor boundary cleanly. Best-effort: if no service
            // is wired the picker stays on "System default" and is disabled.
            guard let calendar, !didLoadCalendars else { return }
            writableCalendars = await calendar.writableCalendars()
            didLoadCalendars = true
        }
    }
}
