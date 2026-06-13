import Foundation
@testable import Jotty

/// Test double for `ClaudeHandoff` — NEVER opens a browser, spawns `claude`, or
/// hits the network. Records the last prompt so plan 06-02's wiring tests can
/// assert what the app handed off without any real side effect.
final class FakeClaudeHandoff: ClaudeHandoff, @unchecked Sendable {
    /// The most recent prompt passed to `send(prompt:)`, or nil if never called.
    private(set) var lastPrompt: String?
    /// Number of `send(prompt:)` calls.
    private(set) var sendCallCount = 0
    /// Drives `claudeBinaryAvailable()` and the `send` return value (Code-mode
    /// availability). Default `true` = binary present.
    var binaryAvailable = true

    @discardableResult
    func send(prompt: String) -> Bool {
        lastPrompt = prompt
        sendCallCount += 1
        return binaryAvailable
    }

    func claudeBinaryAvailable() -> Bool { binaryAvailable }
}
