import Foundation

/// Pure builder for the `calshow:` URL that opens Calendar.app at an event's date.
///
/// There is no public per-event deep link on macOS (RESEARCH Pitfall 5), so the best
/// available affordance is `calshow:<timeIntervalSinceReferenceDate>`, which opens Calendar
/// at the given date. This type only builds the URL — opening it (via `NSWorkspace`) is the
/// caller's job (plan 05-06) — so it stays free of AppKit and is unit-testable in isolation.
enum CalendarURL {
    /// Builds `calshow:<start.timeIntervalSinceReferenceDate>` for the given start instant.
    /// Returns `nil` only if URL construction fails (it won't for a finite Date).
    static func show(for start: Date) -> URL? {
        URL(string: "calshow:\(start.timeIntervalSinceReferenceDate)")
    }
}
