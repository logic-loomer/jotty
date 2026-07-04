import XCTest
@testable import Jotty

/// #7: the pure state→announcement mapping. Each transition returns the right VoiceOver
/// string; non-events (steady state, dismissals, return-to-input) return nil.
final class CaptureAnnouncementTests: XCTestCase {
    typealias Snapshot = CaptureAnnouncement.Snapshot

    private func announce(_ old: Snapshot, _ new: Snapshot) -> String? {
        CaptureAnnouncement.announcement(from: old, to: new)
    }

    // MARK: - Input → review

    func testEntersReviewAnnouncesPluralCount() {
        let old = Snapshot(phase: .input)
        let new = Snapshot(phase: .review(count: 3))
        XCTAssertEqual(announce(old, new), "3 tasks to review.")
    }

    func testEntersReviewAnnouncesSingular() {
        let new = Snapshot(phase: .review(count: 1))
        XCTAssertEqual(announce(Snapshot(phase: .input), new), "1 task to review.")
    }

    func testEntersReviewWithZeroTasks() {
        let new = Snapshot(phase: .review(count: 0))
        XCTAssertEqual(announce(Snapshot(phase: .input), new), "No tasks to review.")
    }

    func testStayingInReviewDoesNotReannounce() {
        let a = Snapshot(phase: .review(count: 2))
        let b = Snapshot(phase: .review(count: 2))
        XCTAssertNil(announce(a, b))
    }

    func testReturningToInputIsSilent() {
        let old = Snapshot(phase: .review(count: 2))
        let new = Snapshot(phase: .input)
        XCTAssertNil(announce(old, new))
    }

    // MARK: - Extraction error

    func testExtractionErrorAnnounced() {
        let old = Snapshot(phase: .input)
        let new = Snapshot(phase: .review(count: 1), hasError: true)
        XCTAssertEqual(announce(old, new), "Task extraction failed.")
    }

    func testErrorTakesPriorityOverReviewEntry() {
        // Degraded path: enterReview + lastError set in the same transition. Error wins.
        let old = Snapshot(phase: .input, hasError: false)
        let new = Snapshot(phase: .review(count: 2), hasError: true)
        XCTAssertEqual(announce(old, new), "Task extraction failed.")
    }

    func testDismissingErrorIsSilent() {
        let old = Snapshot(phase: .review(count: 1), hasError: true)
        let new = Snapshot(phase: .review(count: 1), hasError: false)
        XCTAssertNil(announce(old, new))
    }

    // MARK: - Conflict prompt

    func testConflictPromptAnnounced() {
        let old = Snapshot(phase: .input, saved: true)
        let new = Snapshot(phase: .input, conflictTitle: "Team sync", saved: true)
        XCTAssertEqual(announce(old, new),
                       "Calendar conflict: overlaps Team sync. Commit anyway or cancel.")
    }

    func testConflictTakesPriorityOverSaved() {
        // Both saved and conflict rising in one transition — conflict is more urgent.
        let old = Snapshot(phase: .input, conflictTitle: nil, saved: false)
        let new = Snapshot(phase: .input, conflictTitle: "Lunch", saved: true)
        XCTAssertEqual(announce(old, new),
                       "Calendar conflict: overlaps Lunch. Commit anyway or cancel.")
    }

    func testConflictResolvedIsSilent() {
        let old = Snapshot(phase: .input, conflictTitle: "Lunch")
        let new = Snapshot(phase: .input, conflictTitle: nil)
        XCTAssertNil(announce(old, new))
    }

    // MARK: - Degraded-calendar notice

    func testAccessDeniedNoticeAnnounced() {
        let old = Snapshot(phase: .input, saved: true)
        let new = Snapshot(phase: .input, notice: .accessDenied, saved: true)
        XCTAssertEqual(announce(old, new),
                       "Calendar access not granted. Task saved without an event.")
    }

    func testWriteFailedNoticeAnnounced() {
        let old = Snapshot(phase: .input, saved: true)
        let new = Snapshot(phase: .input, notice: .writeFailed(message: "boom"), saved: true)
        XCTAssertEqual(announce(old, new), "Couldn't add the calendar event. Task saved.")
    }

    func testDismissingNoticeIsSilent() {
        let old = Snapshot(phase: .input, notice: .accessDenied)
        let new = Snapshot(phase: .input, notice: nil)
        XCTAssertNil(announce(old, new))
    }

    // MARK: - Saved confirmation

    func testSavedAnnounced() {
        let old = Snapshot(phase: .review(count: 2))
        let new = Snapshot(phase: .input, saved: true)
        XCTAssertEqual(announce(old, new), "Saved.")
    }

    func testSavedRisesOnlyOnce() {
        let a = Snapshot(phase: .input, saved: true)
        let b = Snapshot(phase: .input, saved: true)
        XCTAssertNil(announce(a, b))
    }

    // MARK: - Nothing changed

    func testIdenticalSnapshotIsSilent() {
        let s = Snapshot(phase: .input)
        XCTAssertNil(announce(s, s))
    }
}
