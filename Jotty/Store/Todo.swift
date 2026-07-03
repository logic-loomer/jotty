import Foundation

struct Todo: Equatable {
    /// Single authority for task-ID generation (CQ-09).
    ///
    /// The format is REQUIREMENTS-pinned (decision 2026-05-08): `t_<8 hex>` —
    /// "t_" plus the first 8 characters of a UUID string, lowercased. This is
    /// byte-for-byte the expression the capture paths used inline before
    /// centralization; do not change the derivation.
    static func newID() -> String {
        "t_" + String(UUID().uuidString.prefix(8)).lowercased()
    }

    let id: String
    var text: String
    var createdAt: Date
    var done: Bool
    var completedAt: Date?
    var dueDate: Date?
    var rolledTo: Date?      // set on the original line when rolled forward
    var sourceNote: String?  // optional note id this task was extracted from
    var timeBlock: TimeBlock?  // optional time block for the task (Phase 5)
    var calEventID: String?    // linked calendar event identifier (Phase 5)
    var source: String?        // inbox provenance: composite "<sourceID>:<itemID>" (Phase 7)
    var sourceURL: String?     // canonical link to the originating inbox item (Phase 7)

    init(id: String,
         text: String,
         createdAt: Date,
         done: Bool = false,
         completedAt: Date? = nil,
         dueDate: Date? = nil,
         rolledTo: Date? = nil,
         sourceNote: String? = nil,
         timeBlock: TimeBlock? = nil,
         calEventID: String? = nil,
         source: String? = nil,
         sourceURL: String? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.done = done
        self.completedAt = completedAt
        self.dueDate = dueDate
        self.rolledTo = rolledTo
        self.sourceNote = sourceNote
        self.timeBlock = timeBlock
        self.calEventID = calEventID
        self.source = source
        self.sourceURL = sourceURL
    }
}
