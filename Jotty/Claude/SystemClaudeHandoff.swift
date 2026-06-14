import Foundation
import AppKit

/// Real `ClaudeHandoff` (06-02): Web mode opens the encoded `claude.ai/new?q=`
/// URL via `NSWorkspace`; Code mode spawns the local `claude` binary via
/// `Process`, passing the prompt as a SINGLE argv element (never a shell string).
///
/// Every OS effect is behind an injected closure with a real default, so the
/// unit suite drives this type WITHOUT opening a browser, spawning a process, or
/// hitting `$PATH`:
///   - `open`         opens the Web URL          (default `NSWorkspace.shared.open`)
///   - `runProcess`   spawns the `claude` binary (default a `Process` with
///                    `executableURL = bin`, `arguments = codeArgs(prompt)`)
///   - `locateBinary` probes for the `claude` binary (default candidate paths + $PATH)
///   - `action`       reads the active `ClaudeAction` LIVE (default config-backed)
///
/// `final class` whose stored closures are immutable `let`s; it carries no
/// mutable shared state, so it conforms to the `Sendable` `ClaudeHandoff` seam
/// via `@unchecked Sendable` (mirrors the repo's `FakeClaudeHandoff`). The
/// `@unchecked` lets injected test closures capture local mutable state without
/// `@Sendable` capture errors, while the real OS effects are fire-and-forget.
///
/// WR-03: the masked data race the reviewer flagged was the PRODUCTION `action`
/// closure capturing a then-non-Sendable, non-isolated `ConfigStore` and reading
/// `config` off the main actor concurrently with a Settings-tab `update {}` write.
/// `ConfigStore` is now a genuinely `Sendable`, lock-guarded type, so that
/// concurrent read/write is serialized and can never tear — the `@unchecked` here
/// no longer hides a real race, it only relaxes the (unrelated) test-closure
/// capture rules. The argv-only Code-mode contract (T-6-04) is unchanged.
final class SystemClaudeHandoff: ClaudeHandoff, @unchecked Sendable {

    /// Opens a Web-mode URL. Default routes to `NSWorkspace.shared.open`.
    private let open: (URL) -> Void
    /// Spawns the `claude` binary with the given argv. Throwing so a launch
    /// failure degrades to `false` (caller surfaces a notice). Default builds a
    /// `Process` with `executableURL = bin` and `arguments = argv` — NEVER
    /// `/bin/sh -c`, NEVER a concatenated command string (T-6-04 / 06-RESEARCH
    /// Pattern 3 + Security Domain).
    private let runProcess: (_ bin: URL, _ argv: [String]) throws -> Void
    /// Locates the `claude` binary, or nil when none is found. Default probes the
    /// explicit trusted candidate paths first, then `$PATH` (06-RESEARCH Pattern
    /// 4 / T-6-06 — prefer trusted paths over `$PATH`).
    private let locateBinary: () -> URL?
    /// Reads the active handoff mode LIVE — never a cached snapshot, so a
    /// Settings change takes effect on the next `send`.
    private let action: () -> ClaudeAction

    init(open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
         runProcess: @escaping (_ bin: URL, _ argv: [String]) throws -> Void
            = SystemClaudeHandoff.defaultRunProcess,
         locateBinary: @escaping () -> URL? = SystemClaudeHandoff.defaultLocateBinary,
         action: @escaping () -> ClaudeAction) {
        self.open = open
        self.runProcess = runProcess
        self.locateBinary = locateBinary
        self.action = action
    }

    /// Hands `prompt` to Claude using the live-read mode.
    ///
    /// - Web mode: builds the encoded URL and routes to `open`. Returns `true`.
    /// - Code mode: returns `false` when no binary is found; otherwise builds the
    ///   single-element argv `[prompt]` and runs it, returning `true` (a launch
    ///   throw degrades to `false`).
    ///
    /// `prompt` is the FINAL handoff string. Wrap the raw task text via
    /// `ClaudePrompt.wrapped(_:)` at the call site (menubar/AI tab) before calling.
    @discardableResult
    func send(prompt: String) -> Bool {
        switch action() {
        case .web:
            guard let url = ClaudePrompt.claudeWebURL(prompt: prompt) else { return false }
            open(url)
            return true
        case .code:
            guard let bin = locateBinary() else { return false }   // no binary → caller shows notice
            do {
                try runProcess(bin, ClaudePrompt.codeArgs(prompt: prompt))
                return true
            } catch {
                return false
            }
        }
    }

    /// Cheap probe for the local `claude` binary (drives the Code-mode notice).
    func claudeBinaryAvailable() -> Bool { locateBinary() != nil }

    // MARK: - Real defaults (never exercised by the unit suite — closures injected there)

    /// Default `Process` spawn: the prompt argv is passed as `Process.arguments`,
    /// so the kernel hands it to `claude` as a single argv slot. No shell, no
    /// word-splitting, no injection surface (T-6-04). Mirrors the in-repo
    /// safe-argv idiom (`Quarantine.strip`, `OllamaInstaller`).
    static let defaultRunProcess: @Sendable (_ bin: URL, _ argv: [String]) throws -> Void = { bin, argv in
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = argv        // ← argv element(s), NEVER "claude \(prompt)" or /bin/sh -c
        try proc.run()
    }

    /// Default binary probe: explicit trusted candidate paths first, then `$PATH`
    /// (06-RESEARCH Pattern 4 / T-6-06). Only an `isExecutableFile` match counts.
    static let defaultLocateBinary: @Sendable () -> URL? = {
        locateClaudeBinary(
            candidatePaths: [
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
                (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/claude"),
            ],
            pathEnv: ProcessInfo.processInfo.environment["PATH"],
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }

    /// Pure, injectable probe logic — explicit candidate paths win over `$PATH`,
    /// only executable matches return. Exposed (internal) so a test can point it
    /// at a temp executable without touching the real filesystem candidates.
    static func locateClaudeBinary(
        candidatePaths: [String],
        pathEnv: String?,
        isExecutable: (String) -> Bool
    ) -> URL? {
        for path in candidatePaths where isExecutable(path) {
            return URL(fileURLWithPath: path)
        }
        guard let pathEnv, !pathEnv.isEmpty else { return nil }
        for dir in pathEnv.split(separator: ":") {
            let candidate = "\(dir)/claude"
            if isExecutable(candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }
}
