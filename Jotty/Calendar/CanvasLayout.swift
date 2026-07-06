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

    /// Assigns each `[start,end]` interval a `(column, columnCount)` so overlapping
    /// blocks render SIDE-BY-SIDE instead of stacking on top of each other (#2).
    ///
    /// Intervals are grouped into clusters — maximal runs that chain-overlap — and
    /// within a cluster each interval greedily takes the first column whose previous
    /// occupant has already ended. `columnCount` is the cluster's peak concurrency
    /// (its column total), shared by every member so a cluster renders as equal-width
    /// columns. A non-overlapping interval is its own cluster → `(0, 1)` (full width).
    ///
    /// Overlap is STRICT: intervals that merely touch (`a.end == b.start`) do NOT
    /// overlap and can share a column — matching the app's `CalendarEventMapper`
    /// overlap semantics (touching intervals are not conflicts).
    ///
    /// Pure and order-preserving: results are returned in the SAME order as `intervals`
    /// (internally sorted by start, then end, for the greedy pass), so a caller can
    /// `zip` them straight back onto its blocks.
    static func columns(for intervals: [(start: Date, end: Date)])
        -> [(column: Int, columnCount: Int)] {
        let n = intervals.count
        guard n > 0 else { return [] }

        // Visit in start-then-end order; map results back to original indices.
        let order = (0..<n).sorted {
            intervals[$0].start != intervals[$1].start
                ? intervals[$0].start < intervals[$1].start
                : intervals[$0].end < intervals[$1].end
        }

        var result = Array(repeating: (column: 0, columnCount: 1), count: n)
        var clusterMembers: [Int] = []   // original indices in the open cluster
        var columnEnds: [Date] = []       // last end assigned to each column
        var clusterEnd: Date?             // max end seen in the open cluster

        func closeCluster() {
            let count = max(1, columnEnds.count)
            for idx in clusterMembers { result[idx].columnCount = count }
            clusterMembers.removeAll(keepingCapacity: true)
            columnEnds.removeAll(keepingCapacity: true)
            clusterEnd = nil
        }

        for idx in order {
            let interval = intervals[idx]
            // A gap from the whole cluster (start >= max end) closes it (strict:
            // start == clusterEnd is a touch, not an overlap → new cluster).
            if let end = clusterEnd, interval.start >= end { closeCluster() }

            // First column free at this start (previous occupant ended at/before it).
            if let free = columnEnds.firstIndex(where: { $0 <= interval.start }) {
                columnEnds[free] = interval.end
                result[idx].column = free
            } else {
                result[idx].column = columnEnds.count
                columnEnds.append(interval.end)
            }
            clusterMembers.append(idx)
            clusterEnd = max(clusterEnd ?? interval.end, interval.end)
        }
        closeCluster()
        return result
    }
}
