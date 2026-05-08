import Foundation

struct ExtractedTask: Equatable {
    let title: String
    let dueDate: Date?
    let timeBlock: TimeBlock?
    let calendarBlock: Bool

    init(
        title: String,
        dueDate: Date? = nil,
        timeBlock: TimeBlock? = nil,
        calendarBlock: Bool = false
    ) {
        self.title = title
        self.dueDate = dueDate
        self.timeBlock = timeBlock
        self.calendarBlock = calendarBlock
    }
}
