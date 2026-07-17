// Jotty/Calendar/CalendarCoordinator.swift
// The calendar orchestration seam between MenubarListModel and CalendarService,
// extracted from the model (which had grown into a god object owning CRUD, drift,
// prompts, inbox, AND every calendar flow). The coordinator owns the SERVICE-side
// logic — access gating, fetches, update-or-recreate, conflict queries — and
// returns plain values; the model keeps its @Published state, prompts,
// continuations, and every disk write, so its public API is unchanged.
//
// Deliberately value-oriented (no published state, no callbacks): each method is
// directly unit-testable against FakeCalendarService without a model in the loop.

import Foundation

@MainActor
final class CalendarCoordinator {

    private let calendar: any CalendarService

    init(calendar: any CalendarService) {
        self.calendar = calendar
    }

    // MARK: - Today load (the reloadCalendar service leg)
    //
    // Deliberately THREE small calls rather than one combined load, because the
    // model's publish CADENCE between them is behavior (refactor-review WR):
    // `calendarAccessDenied = false` publishes immediately on grant (not after a
    // slow fetch), the today WINDOW is computed after the gate (a TCC prompt can
    // suspend across midnight — the window must be the day the fetch actually
    // runs), and fresh timed events publish before the all-day fetch (a
    // supersede between the two must not discard the timed result).

    /// Outcome of the lazy access gate. `superseded` = the wrapping task was
    /// cancelled while awaiting the prompt (a newer reload owns the published
    /// state) — the caller must not touch any state for it.
    enum AccessOutcome: Equatable {
        case granted
        /// Access denied/restricted: the caller shows the degraded one-liner.
        case denied
        /// Still notDetermined and prompting was not allowed (WR-06 background
        /// reload): leave the section empty WITHOUT flagging denial, so a later
        /// explicit user action can still ask.
        case unavailable
        case superseded
    }

    /// Runs the lazy access gate: authorized → granted; denied → denied;
    /// notDetermined → request once (only when `promptIfUndetermined`).
    func resolveAccess(promptIfUndetermined: Bool) async -> AccessOutcome {
        let granted: Bool
        switch calendar.access() {
        case .authorized:
            granted = true
        case .denied:
            granted = false
        case .notDetermined:
            guard promptIfUndetermined else { return .unavailable }
            granted = await calendar.requestAccess() == .authorized
        }
        // Superseded while awaiting the prompt: checked BEFORE the denied branch so
        // a stale run can never publish a denial the newer run no longer sees.
        guard !Task.isCancelled else { return .superseded }
        return granted ? .granted : .denied
    }

    /// Outcome of one window fetch.
    enum FetchOutcome: Equatable {
        case fetched([CalendarEvent])
        /// The read threw (already logged where warranted).
        case failed
        /// Cancelled mid-fetch: the caller must not touch any state.
        case superseded
    }

    /// The timed-events fetch (service filters all-day + sorts by start, plan 03).
    func fetchTimedEvents(from start: Date, to end: Date) async -> FetchOutcome {
        do {
            let events = try await calendar.eventsInRange(start: start, end: end)
            guard !Task.isCancelled else { return .superseded }
            return .fetched(events)
        } catch {
            guard !Task.isCancelled else { return .superseded }
            NSLog("[Jotty] calendar read failed: \(error.localizedDescription)")
            return .failed
        }
    }

    /// The all-day fetch for the chip row — strictly additive signal, so a read
    /// failure is `.failed` and the caller degrades to no chips without blocking
    /// the timed section or the drift pass.
    func fetchAllDayEvents(from start: Date, to end: Date) async -> FetchOutcome {
        do {
            let events = try await calendar.allDayEventsInRange(start: start, end: end)
            guard !Task.isCancelled else { return .superseded }
            return .fetched(events)
        } catch {
            guard !Task.isCancelled else { return .superseded }
            return .failed
        }
    }

    // MARK: - Update-or-recreate (SC3, shared by editTime and moveToTomorrow)

    /// Outcome of moving a linked event. `recreated` carries the fresh id the
    /// caller must rewrite onto the task line (relink); `failed` has already been
    /// logged and needs no caller action (best-effort, never blocking).
    enum EventUpdateOutcome: Equatable {
        case updated
        case recreated(newID: String)
        case failed
    }

    /// Updates the linked event in place; when it is gone (`.eventNotFound` — the
    /// user deleted it in Calendar, or the id was recycled onto a foreign event the
    /// WR-05 marker guard refuses to touch), recreates it and returns the new id
    /// for the caller's relink write. `context` labels the failure logs so the
    /// editTime and moveToTomorrow paths stay distinguishable in Console.
    func updateOrRecreate(eventID: String, title: String, block: TimeBlock,
                          context: String) async -> EventUpdateOutcome {
        do {
            try await calendar.updateEvent(id: eventID, title: title,
                                           start: block.start, end: block.end)
            return .updated
        } catch CalendarError.eventNotFound {
            do {
                let newID = try await calendar.createEvent(title: title,
                                                           start: block.start,
                                                           end: block.end)
                return .recreated(newID: newID)
            } catch {
                NSLog("[Jotty] \(context) createEvent (recreate) failed: \(error.localizedDescription)")
                return .failed
            }
        } catch {
            NSLog("[Jotty] \(context) updateEvent failed: \(error.localizedDescription)")
            return .failed
        }
    }

    // MARK: - Task-wins per-pair update (roadmap 2.3 "Update event")

    /// Outcome of a single task-wins `updateEvent` push.
    enum UpdateEventOutcome: Equatable {
        case updated
        /// The event is gone from the store — deleted in Calendar, or a foreign/recycled
        /// id the WR-05 `isJottyEvent` marker guard refused to touch. The caller (drift
        /// resolution) surfaces a per-pair skip notice; this does NOT recreate.
        case notFound
        case failed
    }

    /// Pushes ONE drifted pair's own fields onto its linked calendar event. Distinct from
    /// `updateOrRecreate` (editTime/moveToTomorrow): a task-wins confirm must never
    /// recreate on `.eventNotFound` — the drift prompt's sibling "Sync" button already
    /// covers "take the calendar's word for it", so silently recreating here would
    /// multiply events instead of surfacing the miss. `context` labels the failure log.
    func updateEvent(eventID: String, title: String, block: TimeBlock,
                     context: String) async -> UpdateEventOutcome {
        do {
            try await calendar.updateEvent(id: eventID, title: title,
                                           start: block.start, end: block.end)
            return .updated
        } catch CalendarError.eventNotFound {
            return .notFound
        } catch {
            NSLog("[Jotty] \(context) updateEvent failed: \(error.localizedDescription)")
            return .failed
        }
    }

    // MARK: - Conflict gate query (SC5)

    /// The first event overlapping `block`, excluding the task's OWN linked event
    /// when `excludingEventID` is non-nil (a small nudge overlaps the event being
    /// moved — not a conflict). A read failure returns nil — non-fatal, the caller
    /// falls through to the write exactly like the capture pass.
    func firstConflictTitle(overlapping block: TimeBlock,
                            excludingEventID: String?) async -> String? {
        guard let overlap = try? await calendar.overlappingEvents(start: block.start,
                                                                  end: block.end) else {
            return nil
        }
        return overlap.first { excludingEventID == nil || $0.eventKitID != excludingEventID }?
            .title
    }

    // MARK: - Passthrough writes

    /// Creates an event for a just-dropped task (the drop leg's commit).
    func createEvent(title: String, block: TimeBlock) async throws -> String {
        try await calendar.createEvent(title: title, start: block.start, end: block.end)
    }

    /// Best-effort delete: a failure logs but never rolls back the already-completed
    /// markdown delete (T-5-09).
    func deleteEventBestEffort(id: String) async {
        do {
            try await calendar.deleteEvent(id: id)
        } catch {
            NSLog("[Jotty] calendar deleteEvent failed: \(error.localizedDescription)")
        }
    }
}
