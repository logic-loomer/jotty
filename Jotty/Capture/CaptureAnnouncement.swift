import Foundation

/// Pure state→VoiceOver-announcement mapping for the capture flow (#7).
///
/// The command bar was the only surface posting `AccessibilityNotification.Announcement`;
/// the capture flow was silent at its most important dynamic moments (extraction failure, a
/// blocking calendar-conflict prompt, a degraded-calendar notice, the "Saved" confirmation,
/// and the input→review switch). This enum captures the announceable slice of
/// `CaptureViewModel` state as an `Equatable` `Snapshot`, and `announcement(from:to:)`
/// maps a transition to the string the view should post — or `nil` when nothing should be
/// announced.
///
/// No I/O, no `Date()`, no SwiftUI: the whole mapping is a pure function so the suite pins
/// every transition deterministically (mirrors the `TaskBadge`/`CalendarDrift` value-type
/// idiom). The view builds a `Snapshot` from the VM and fires this off `.onChange`.
enum CaptureAnnouncement {

    /// The announceable slice of capture state. Deliberately small + `Equatable` so the view
    /// can drive a single `.onChange(of:)` seam instead of one observer per `@Published`.
    struct Snapshot: Equatable {
        /// Whether the flow is on the input editor or the review list (+ its row count).
        enum Phase: Equatable {
            case input
            case review(count: Int)

            var isReview: Bool {
                if case .review = self { return true }
                return false
            }
        }

        let phase: Phase
        /// True when the AI-extraction error channel (`lastError`) is set.
        let hasError: Bool
        /// The overlapping event's title while a blocking conflict prompt is showing; else nil.
        let conflictTitle: String?
        /// The non-blocking degraded-calendar notice, if any.
        let notice: CalendarNotice?
        /// True while the brief "Saved" confirmation is on screen.
        let saved: Bool

        init(phase: Phase,
             hasError: Bool = false,
             conflictTitle: String? = nil,
             notice: CalendarNotice? = nil,
             saved: Bool = false) {
            self.phase = phase
            self.hasError = hasError
            self.conflictTitle = conflictTitle
            self.notice = notice
            self.saved = saved
        }
    }

    /// Maps a snapshot transition to the announcement string, or nil if nothing should be
    /// announced.
    ///
    /// Priority when several fields change in a single transition (highest first):
    /// 1. a conflict prompt just appeared (it blocks the flow — most urgent);
    /// 2. an extraction error just appeared;
    /// 3. a degraded-calendar notice just appeared;
    /// 4. the "Saved" confirmation just appeared;
    /// 5. the flow just entered review (row count).
    ///
    /// Only *rising edges* announce (e.g. `false → true`), so re-emitting the same snapshot,
    /// dismissing a banner, or returning to input is silent.
    static func announcement(from old: Snapshot, to new: Snapshot) -> String? {
        // 1. A blocking conflict prompt just appeared (title changed to non-nil).
        if let title = new.conflictTitle, old.conflictTitle != new.conflictTitle {
            return "Calendar conflict: overlaps \(title). Commit anyway or cancel."
        }

        // 2. Extraction just failed.
        if new.hasError, !old.hasError {
            return "Task extraction failed."
        }

        // 3. A degraded-calendar notice just appeared.
        if let notice = new.notice, old.notice != notice {
            switch notice {
            case .accessDenied:
                return "Calendar access not granted. Task saved without an event."
            case .writeFailed:
                return "Couldn't add the calendar event. Task saved."
            }
        }

        // 4. The "Saved" confirmation just appeared.
        if new.saved, !old.saved {
            return "Saved."
        }

        // 5. The flow just entered review.
        if case .review(let count) = new.phase, !old.phase.isReview {
            switch count {
            case 0:  return "No tasks to review."
            case 1:  return "1 task to review."
            default: return "\(count) tasks to review."
            }
        }

        return nil
    }
}
