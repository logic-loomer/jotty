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

    /// Outcome of a today-window load. `superseded` means the wrapping task was
    /// cancelled mid-flight (a newer reload owns the published state) — the caller
    /// must not touch any state for it.
    enum TodayOutcome: Equatable {
        /// Authorized and fetched. `allDay` degrades to [] on its own read failure
        /// (the chip row is strictly additive signal; a failure never blocks the
        /// timed section or the drift pass).
        case snapshot(events: [CalendarEvent], allDay: [CalendarEvent])
        /// Access denied/restricted: the caller shows the degraded one-liner.
        case denied
        /// Still notDetermined and prompting was not allowed (WR-06 background
        /// reload): leave the section empty WITHOUT flagging denial, so a later
        /// explicit user action can still ask.
        case unavailable
        /// The timed read threw: degrade to no rows, skip the drift pass.
        case readFailed
        /// Cancelled while awaiting the prompt or a fetch.
        case superseded
    }

    /// Runs the lazy access gate (authorized → fetch; denied → degrade;
    /// notDetermined → request once, only when `promptIfUndetermined`) and, when
    /// granted, fetches the window's timed + all-day events. Checks
    /// `Task.isCancelled` after every suspension so an out-of-order older reload
    /// can never overwrite a newer one's state (the caller bails on `.superseded`).
    func loadToday(promptIfUndetermined: Bool,
                   from start: Date, to end: Date) async -> TodayOutcome {
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
        guard !Task.isCancelled else { return .superseded }
        guard granted else { return .denied }

        let events: [CalendarEvent]
        do {
            events = try await calendar.eventsInRange(start: start, end: end)
            guard !Task.isCancelled else { return .superseded }
        } catch {
            guard !Task.isCancelled else { return .superseded }
            NSLog("[Jotty] calendar read failed: \(error.localizedDescription)")
            return .readFailed
        }

        var allDay: [CalendarEvent] = []
        do {
            allDay = try await calendar.allDayEventsInRange(start: start, end: end)
            guard !Task.isCancelled else { return .superseded }
        } catch {
            guard !Task.isCancelled else { return .superseded }
            allDay = []
        }
        return .snapshot(events: events, allDay: allDay)
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
