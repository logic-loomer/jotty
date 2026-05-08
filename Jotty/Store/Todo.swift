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

    init(id: String,
         text: String,
         createdAt: Date,
         done: Bool = false,
         completedAt: Date? = nil,
         dueDate: Date? = nil,
         rolledTo: Date? = nil,
         sourceNote: String? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.done = done
        self.completedAt = completedAt
        self.dueDate = dueDate
        self.rolledTo = rolledTo
        self.sourceNote = sourceNote
    }
}
