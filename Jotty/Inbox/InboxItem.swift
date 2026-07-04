import Foundation

/// A single actionable item pulled from an external inbox source (GitHub, Gmail, ...).
///
/// This is the only item type that crosses the `InboxSource` seam; a source's raw API
/// payload (an `Octokit` notification, a Gmail message, ...) never leaves the concrete
/// implementation. Being `Sendable` lets it flow freely across Swift 6 isolation
/// boundaries; being `Identifiable` (by `id`) makes it drop straight into SwiftUI lists.
///
/// `id` is the composite `<sourceID>:<itemID>` (e.g. `github:123456`). It is used as BOTH
/// the cross-source dedupe key AND the payload of the `source:` markdown token when an
/// accepted item is written into today's `## Tasks` (RESEARCH Pattern 2, CONTEXT
/// D-architecture). The GitHub item id is a space-free numeric string, so the composite is
/// safe for the space-split meta line.
struct InboxItem: Sendable, Equatable, Identifiable {
    /// Composite `<sourceID>:<itemID>` — the dedupe key and the `source:` token payload.
    let id: String
    /// The owning source's stable id (e.g. `github`); matches `InboxSource.id`.
    let sourceID: String
    /// Human-facing title; becomes the accepted task's text.
    let title: String
    /// Canonical link to the item; written as the `source_url:` token.
    let url: String
    /// The item's last-updated time (from the source's `updated_at`), for sort/recency.
    let timestamp: Date
    /// Verbatim source text, kept as a display fallback when `title` is empty.
    let rawText: String
    /// Calendar-source only: the event's time block, written as the `time:` token on accept.
    /// `nil` for every other source (GitHub, Gmail, ...). `var` with a `= nil` default so the
    /// synthesized memberwise init gains a defaulted trailing param (SE-0242): the GitHub 6-arg
    /// call site stays untouched, while the calendar path can construct with the field set.
    var timeBlock: TimeBlock? = nil
    /// Calendar-source only: the source event's identifier, written as the `cal_event:` token
    /// (a LINK back to the existing event, never a create). `nil` for every other source.
    var calEventID: String? = nil
}
