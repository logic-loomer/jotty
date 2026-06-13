import Foundation

/// Pure builder for the `calshow:` URL that opens Calendar.app at an event's date.
///
/// There is no public per-event deep link on macOS (RESEARCH Pitfall 5), so the best
/// available affordance is `calshow:<timeIntervalSinceReferenceDate>`, which opens Calendar
/// at the given date. This type only builds the URL; opening it (via `NSWorkspace`) is the
/// caller's job (plan 05-06), so it stays free of AppKit and is unit-testable in isolation.
enum CalendarURL {
    /// Builds `calshow:<start.timeIntervalSinceReferenceDate>` for the given start instant.
    /// Returns `nil` for a non-finite Date (NaN/inf from a corrupted parse would otherwise
    /// interpolate "nan"/"inf" into the URL, IN-03) or if URL construction fails.
    static func show(for start: Date) -> URL? {
        let interval = start.timeIntervalSinceReferenceDate
        guard interval.isFinite else { return nil }
        return URL(string: "calshow:\(interval)")
    }
}
