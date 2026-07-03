import CoreGraphics
import Foundation

/// Pure time↔pixel layout math for the calendar canvas (SC4 / CALX-04),
/// mirroring the `CalendarDrift` idiom: an enum of static functions with no
/// I/O, exhaustively unit-testable against value types.
///
/// The canvas is a vertical time-of-day axis: `y(for:)` positions an instant,
/// `height(start:end:)` sizes a block, and `slot(atY:)` inverts a drop y back
/// to a snapped slot Date. It drives BOTH render (event/task → y + height) and
/// drop-slot resolution (drop y → snapped start Date).
///
/// All math operates on absolute `Date` intervals from `dayStart` — never on
/// wall-clock decomposition — so it is timezone-agnostic by construction. On a
/// DST-shifted day the axis still maps linearly over the day's absolute
/// seconds (a 25h/23h day simply renders proportionally); this is intentional
/// and acceptable per RESEARCH §Calendar Canvas View.
enum CanvasLayout {
    /// Default vertical scale: pixels per hour of the day axis.
    static let defaultPixelsPerHour: CGFloat = 60

    /// Default drop-snap granularity in minutes.
    static let defaultSnapMinutes = 15

    /// Default duration (minutes) applied when an unscheduled task is dropped
    /// onto a slot (drag-to-time-block, SC1). The SINGLE source of truth:
    /// `MenubarListModel.defaultDropDuration` derives from this (IN-04).
    static let defaultDropDurationMinutes = 30

    /// Minimum rendered block height in points. `height(start:end:)` never
    /// returns below this, so zero/sub-minute intervals stay visible and
    /// clickable.
    static let minHeight: CGFloat = 16

    /// The y offset (points) of `date` on a canvas whose axis starts at
    /// `dayStart`, at `pixelsPerHour` vertical scale.
    static func y(for date: Date, dayStart: Date, pixelsPerHour: CGFloat) -> CGFloat {
        CGFloat(date.timeIntervalSince(dayStart) / 3600) * pixelsPerHour
    }

    /// The rendered height (points) of a `[start, end]` block, clamped to
    /// `minHeight` so degenerate intervals never collapse below visibility.
    static func height(start: Date, end: Date, pixelsPerHour: CGFloat) -> CGFloat {
        max(minHeight, CGFloat(end.timeIntervalSince(start) / 3600) * pixelsPerHour)
    }

    /// Inverts a canvas y back to a slot `Date`, snapped to the nearest
    /// `snapMinutes` boundary from `dayStart`.
    ///
    /// Exact inverse of `y(for:)` on grid-aligned inputs; off-grid inputs
    /// round to the NEAREST boundary (halfway rounds up).
    static func slot(atY y: CGFloat, dayStart: Date,
                     pixelsPerHour: CGFloat, snapMinutes: Int) -> Date {
        let minutes = Double(y / pixelsPerHour) * 60
        let snapped = (minutes / Double(snapMinutes)).rounded() * Double(snapMinutes)
        return dayStart.addingTimeInterval(snapped * 60)
    }
}
