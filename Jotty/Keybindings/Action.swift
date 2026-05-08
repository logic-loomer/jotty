import Foundation

enum Action: String, Codable, CaseIterable {
    case globalToggleCapture = "global.toggleCapture"
    case captureSubmit       = "capture.submit"
    case captureCancel       = "capture.cancel"
}
