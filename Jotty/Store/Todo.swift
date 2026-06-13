import Foundation

struct Todo: Equatable {
    let id: String
    var text: String
    let createdAt: Date
    var done: Bool
    var completedAt: Date?
    var dueDate: Date?
    var rolledTo: Date?      // set on the original line when rolled forward
    var sourceNote: String?  // optional note id this task was extracted from
    var timeBlock: TimeBlock?  // optional time block for the task (Phase 5)
    var calEventID: String?    // linked calendar event identifier (Phase 5)

    init(id: String,
         text: String,
         createdAt: Date,
         done: Bool = false,
         completedAt: Date? = nil,
         dueDate: Date? = nil,
         rolledTo: Date? = nil,
         sourceNote: String? = nil,
         timeBlock: TimeBlock? = nil,
         calEventID: String? = nil) {
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
    }
}
