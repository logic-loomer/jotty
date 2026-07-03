import XCTest
@testable import Jotty

/// Phase 8 plan 01 / SC4 (CALX-04): the pure `CanvasLayout` time↔pixel math.
/// y(for:) maps a Date onto the canvas axis, height(start:end:) sizes a block
/// (min-clamped), slot(atY:) inverts a drop y back to a snapped slot Date.
/// All math is on absolute Date intervals — timezone-agnostic by construction.
final class CanvasLayoutTests: XCTestCase {
    // An arbitrary absolute instant; the math must depend only on intervals
    // from dayStart, never on wall-clock decomposition.
    let dayStart = Date(timeIntervalSinceReferenceDate: 700_000_000)

    // MARK: - y(for:)

    func testYAtDayStartIsZero() {
        XCTAssertEqual(CanvasLayout.y(for: dayStart, dayStart: dayStart, pixelsPerHour: 60), 0)
    }

    func testYAtNoonIs720WithPPH60() {
        let noon = dayStart.addingTimeInterval(12 * 3600)
        XCTAssertEqual(CanvasLayout.y(for: noon, dayStart: dayStart, pixelsPerHour: 60), 720)
    }

    func testYAt90MinutesIs90WithPPH60() {
        let t = dayStart.addingTimeInterval(90 * 60)
        XCTAssertEqual(CanvasLayout.y(for: t, dayStart: dayStart, pixelsPerHour: 60), 90)
    }

    // MARK: - height(start:end:)

    func testHeightOneHourIs60WithPPH60() {
        let start = dayStart.addingTimeInterval(9 * 3600)
        let end = start.addingTimeInterval(3600)
        XCTAssertEqual(CanvasLayout.height(start: start, end: end, pixelsPerHour: 60), 60)
    }

    func testHeightThirtyMinutesIs30WithPPH60() {
        let start = dayStart.addingTimeInterval(9 * 3600)
        let end = start.addingTimeInterval(30 * 60)
        XCTAssertEqual(CanvasLayout.height(start: start, end: end, pixelsPerHour: 60), 30)
    }

    func testZeroLengthIntervalClampsToMinHeight() {
        let t = dayStart.addingTimeInterval(9 * 3600)
        XCTAssertEqual(CanvasLayout.height(start: t, end: t, pixelsPerHour: 60),
                       CanvasLayout.minHeight,
                       "a zero-length interval must clamp to the documented minimum")
    }

    func testSubMinuteIntervalClampsToMinHeight() {
        let start = dayStart.addingTimeInterval(9 * 3600)
        let end = start.addingTimeInterval(30) // 30 seconds → 0.5pt raw at pph 60
        let h = CanvasLayout.height(start: start, end: end, pixelsPerHour: 60)
        XCTAssertEqual(h, CanvasLayout.minHeight)
        XCTAssertGreaterThanOrEqual(h, CanvasLayout.minHeight,
                                    "height must never return below the min clamp")
    }

    // MARK: - slot(atY:)

    func testSlotAtY720IsNoon() {
        let slot = CanvasLayout.slot(atY: 720, dayStart: dayStart,
                                     pixelsPerHour: 60, snapMinutes: 15)
        XCTAssertEqual(slot, dayStart.addingTimeInterval(12 * 3600))
    }

    func testOffGridYSnapsToNearest15MinuteSlot() {
        // y=727 at pph 60 → 12:07 wall-offset → nearest 15-min slot is 12:00.
        let slot = CanvasLayout.slot(atY: 727, dayStart: dayStart,
                                     pixelsPerHour: 60, snapMinutes: 15)
        XCTAssertEqual(slot, dayStart.addingTimeInterval(12 * 3600),
                       "12:07 must snap to 12:00 (nearest 15-min boundary)")
        // y=728 → 12:08 → nearest is 12:15.
        let slotUp = CanvasLayout.slot(atY: 728, dayStart: dayStart,
                                       pixelsPerHour: 60, snapMinutes: 15)
        XCTAssertEqual(slotUp, dayStart.addingTimeInterval(12 * 3600 + 15 * 60),
                       "12:08 must snap to 12:15 (nearest 15-min boundary)")
    }

    func testSlotInvertsYExactlyOnGridAlignedInputs() {
        // Every 15-min-aligned instant must survive date → y → slot unchanged.
        for quarter in [0, 1, 4, 37, 48, 95] { // 00:00, 00:15, 01:00, 09:15, 12:00, 23:45
            let date = dayStart.addingTimeInterval(TimeInterval(quarter * 15 * 60))
            let y = CanvasLayout.y(for: date, dayStart: dayStart, pixelsPerHour: 60)
            let slot = CanvasLayout.slot(atY: y, dayStart: dayStart,
                                         pixelsPerHour: 60, snapMinutes: 15)
            XCTAssertEqual(slot, date, "grid-aligned input at quarter \(quarter) must invert exactly")
        }
    }

    // MARK: - timezone agnosticism

    func testMathIsPureIntervalArithmeticRegardlessOfAbsoluteOrigin() {
        // Shifting the whole frame by any offset (e.g. a different timezone's
        // dayStart, or a DST-shifted day) leaves y/height/slot unchanged: the
        // math sees only absolute intervals, never wall-clock components.
        let offsets: [TimeInterval] = [0, 3600, -36000, 86_400 * 200]
        for off in offsets {
            let base = dayStart.addingTimeInterval(off)
            let t = base.addingTimeInterval(10 * 3600 + 30 * 60) // 10.5h in
            XCTAssertEqual(CanvasLayout.y(for: t, dayStart: base, pixelsPerHour: 60),
                           630, "y depends only on the interval from dayStart (offset \(off))")
            XCTAssertEqual(CanvasLayout.height(start: base, end: t, pixelsPerHour: 60),
                           630, "height depends only on the interval (offset \(off))")
            XCTAssertEqual(CanvasLayout.slot(atY: 630, dayStart: base,
                                             pixelsPerHour: 60, snapMinutes: 15),
                           t, "slot depends only on the interval (offset \(off))")
        }
    }
}
