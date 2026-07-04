// Jotty/Inbox/InboxRefreshPolicy.swift
// Single source of truth for the opt-in periodic-refresh interval bounds (IN-03).
//
// The 5-minute floor and 15-minute default previously lived independently in
// IntegrationsTab (the Settings stepper) and AppDelegate (the timer scheduler).
// A change to the floor in one place could silently diverge from the other,
// weakening the Pitfall-1 guarantee that the opt-in timer can never poll a
// third-party API more often than the floor. Both call sites now reference
// these constants so the floor is enforced identically wherever it is applied.

import Foundation

/// Bounds for the unified-inbox opt-in periodic refresh (SC3, Pitfall 1).
enum InboxRefreshPolicy {
    /// Minimum opt-in interval in minutes: the periodic timer can never poll a
    /// third-party API more often than this, even if a stale config asks for less.
    static let minIntervalMinutes = 5
    /// Default interval applied when the toggle is first turned on (interval was nil).
    static let defaultIntervalMinutes = 15
    /// Maximum opt-in interval in minutes (24h). Upper ceiling (IN-05): a corrupt or
    /// hand-edited config could otherwise ask for an absurd interval whose `* 60`
    /// seconds conversion overflows Int and traps when scheduling the timer.
    static let maxIntervalMinutes = 1440

    /// Clamps a requested interval (minutes) into `[minIntervalMinutes, maxIntervalMinutes]`.
    /// The floor keeps the timer from polling a third-party API too often (Pitfall 1);
    /// the ceiling keeps the `* 60` seconds conversion in scheduleInboxTimer from
    /// overflowing Int on a corrupt value (IN-05).
    static func flooredMinutes(_ requested: Int) -> Int {
        min(maxIntervalMinutes, max(minIntervalMinutes, requested))
    }
}
