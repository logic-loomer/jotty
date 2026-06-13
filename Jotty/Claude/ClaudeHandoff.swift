import Foundation

/// The single seam through which the app (and tests) hand the current task off to
/// Claude — either by opening the Web prompt or by spawning the local `claude`
/// binary in Code mode (plan 06-02 owns the real implementation).
///
/// Mirrors the `CalendarService` seam idiom: a `Sendable` protocol so it can be
/// injected as a dependency under Swift 6, with tests injecting `FakeClaudeHandoff`
/// so the suite never opens a browser, never spawns a process, and never hits the
/// network. The prompt is always passed as a single argv element / URL-encoded
/// query value — never a shell string (see 06-RESEARCH Pattern 3).
protocol ClaudeHandoff: Sendable {
    /// Hands `prompt` to Claude using the configured mode.
    ///
    /// - Returns: `false` when Code mode is selected but the `claude` binary is
    ///   unavailable (caller surfaces a notice); `true` otherwise.
    @discardableResult
    func send(prompt: String) -> Bool

    /// Cheap, synchronous probe for whether the local `claude` binary is present.
    /// Drives the Code-mode availability notice without attempting a spawn.
    func claudeBinaryAvailable() -> Bool
}
