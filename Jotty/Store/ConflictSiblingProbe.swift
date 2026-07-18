import Foundation

/// One losing `NSFileVersion` from an unresolved iCloud sync conflict (roadmap
/// 3.4 phase 2, Task 6), abstracted behind a protocol so tests can fake conflict
/// content without touching the real `NSFileVersion` API — it has no public
/// initializer, and a losing conflict version only exists for a genuinely
/// sync-conflicted ubiquitous item (two real devices racing a real iCloud
/// container), so it is not reliably fakeable in CI. Mirrors why
/// `UbiquitousStatusProbing` wraps a resource-value lookup instead of exercising
/// real iCloud downloads.
///
/// Not `Sendable`: every conforming instance (real `NSFileVersion` or a test
/// fake) is created, read, and resolved entirely WITHIN the single off-actor
/// `runOffActorWithTimeout` closure `Store.checkForUnresolvedConflicts` runs —
/// it never crosses back out to the caller, so it never needs to cross an
/// isolation boundary.
protocol ConflictVersionMaterializing {
    /// This losing version's raw content, to be copied verbatim into a
    /// `.conflict-<stamp>.md` sidecar. Real `NSFileVersion` reads this via its
    /// own `.url`; the fake in tests hands back fixed bytes.
    func materializedContents() throws -> Data

    /// Marks this version resolved (`isResolved = true` on the real
    /// `NSFileVersion`) so the file provider can clean it up. Called ONLY after
    /// this version's content is safely on disk as a sidecar — never before
    /// (see `Store.checkForUnresolvedConflicts`'s resolution-ordering doc).
    func markResolved() throws
}

/// Injectable conflict-sibling probe seam (roadmap 3.4 phase 2, Task 6): probes
/// `NSURLUbiquitousItemHasUnresolvedConflictsKey` and enumerates
/// `NSFileVersion.unresolvedConflictVersionsOfItem(at:)`. Its own, separate
/// protocol-seam type from `UbiquitousStatusProbing` (Task 5) — a DIFFERENT
/// NSURL resource key answering a DIFFERENT question ("is there an unresolved
/// iCloud sync conflict on this item" vs. "is this item's data materialized
/// locally yet"). `Sendable` so it can cross into `Store`'s off-actor
/// `runOffActorWithTimeout` closure the same way `FileCoordinating` and
/// `UbiquitousStatusProbing` do.
protocol ConflictSiblingProbing: Sendable {
    /// True iff `url` currently has an unresolved iCloud sync conflict.
    func hasUnresolvedConflicts(at url: URL) throws -> Bool

    /// The losing versions for `url` (empty when there are none, even if
    /// `hasUnresolvedConflicts` was true — e.g. a race where iCloud resolved
    /// the conflict between the two calls).
    func unresolvedConflictVersions(at url: URL) throws -> [ConflictVersionMaterializing]
}

/// Production probe: the real `URLResourceValues.ubiquitousItemHasUnresolvedConflicts`
/// lookup plus the real `NSFileVersion.unresolvedConflictVersionsOfItem(at:)`
/// enumeration. A non-ubiquitous or conflict-free file answers `false`/`[]`
/// exactly like a plain local file — `Store` treats a probe failure the same as
/// a `false` answer (see `checkForUnresolvedConflicts`), so this type does not
/// need its own fail-safe fallback.
struct RealConflictSiblingProbe: ConflictSiblingProbing {
    func hasUnresolvedConflicts(at url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.ubiquitousItemHasUnresolvedConflictsKey])
            .ubiquitousItemHasUnresolvedConflicts ?? false
    }

    func unresolvedConflictVersions(at url: URL) throws -> [ConflictVersionMaterializing] {
        NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
    }
}

/// The real `NSFileVersion` wrapper: reads content from its own `.url` and
/// resolves it via its own settable `isResolved`. Plain, un-coordinated reads —
/// an `NSFileVersion`'s `.url` already names a specific, immutable snapshot of
/// the conflicting content (not the live, still-being-written item), so there is
/// no sync-daemon race for `FileCoordinating` to fence against here the way
/// there is for the day file's own read/write path.
extension NSFileVersion: ConflictVersionMaterializing {
    func materializedContents() throws -> Data {
        try Data(contentsOf: url)
    }

    func markResolved() throws {
        isResolved = true
    }
}
