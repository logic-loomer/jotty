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

    /// Clamps a requested interval (minutes) to never go below the floor.
    static func flooredMinutes(_ requested: Int) -> Int {
        max(minIntervalMinutes, requested)
    }
}
