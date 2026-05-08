import Foundation

enum DailyFile {
    static func url(in folder: URL, on date: Date, timezone: TimeZone) -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = timezone
        return folder.appendingPathComponent("\(fmt.string(from: date)).md")
    }
}
