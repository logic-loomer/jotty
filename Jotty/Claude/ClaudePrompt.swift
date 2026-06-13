import Foundation

/// Pure, value-type builders for the Send-to-Claude handoff (SC1 / D-SC1).
///
/// All three security-critical transforms live here as side-effect-free static
/// functions so they are fully unit-asserted (no browser, no process, no
/// network in the suite):
///   - `wrapped(_:)`     wraps the task text in the prompt template.
///   - `webURL(for:)`    builds the URLComponents-encoded `claude.ai/new?q=` URL
///                       for an already-built prompt (does NOT re-apply the
///                       template — the caller wraps once via `wrapped(_:)`).
///   - `codeArgv(for:)`  returns the single-element argv for Code mode.
///
/// `ClaudePrompt` is an empty enum (uninstantiable namespace) — trivially
/// `Sendable`, no stored state.
enum ClaudePrompt {

    /// Prompt template prefix (D-SC1: "Help me with this task: <text>"). The
    /// builder is pure so the wording can change in one place.
    static let template = "Help me with this task: "

    /// The Web-mode endpoint. Kept as a single constant so it can be swapped if
    /// the `claude.ai/new?q=` web prefill is deprecated (06-RESEARCH Pitfall 5 /
    /// A1 — a Wave-0 human live check). Do NOT change the locked CONTEXT default
    /// here; swap only after the live check confirms the prefill broke.
    static let webEndpoint = "https://claude.ai/new"

    /// Wraps the task text in the prompt template. Surrounding whitespace is
    /// trimmed so a padded task line never yields a bare-template prompt.
    static func wrapped(_ taskText: String) -> String {
        let trimmed = taskText.trimmingCharacters(in: .whitespacesAndNewlines)
        return template + trimmed
    }

    /// Builds the Web-mode URL: `https://claude.ai/new?q=<percent-encoded prompt>`.
    ///
    /// `URLComponents` + `URLQueryItem` percent-encode the value — spaces,
    /// unicode, `&`, and `=` all round-trip through decoding without corrupting
    /// the query string (T-6-05 mitigation; never hand-roll `%` escaping).
    ///
    /// - Parameter prompt: the final prompt string. The template is NOT applied
    ///   here — wrap with `wrapped(_:)` at the call site so the `q=` value is
    ///   exactly what is handed off (matches `codeArgv(for:)` symmetry).
    static func webURL(for prompt: String) -> URL? {
        claudeWebURL(prompt: prompt)
    }

    /// Builds the Web-mode URL for an already-built prompt string. Named to
    /// match the `must_haves` contract (`func claudeWebURL`); `webURL(for:)` is
    /// the task-text-taking convenience that wraps first.
    static func claudeWebURL(prompt: String) -> URL? {
        guard var components = URLComponents(string: webEndpoint) else { return nil }
        components.queryItems = [URLQueryItem(name: "q", value: prompt)]
        return components.url
    }

    /// The Code-mode argv: the prompt as a SINGLE element (T-6-04 mitigation).
    ///
    /// Passing `[prompt]` to `Process.arguments` means the kernel hands the text
    /// to `claude` as one argv slot — no shell, no word-splitting, so `;`,
    /// `$(...)`, backticks, `&&`, and quotes are inert. NEVER build a command
    /// string or route through `/bin/sh -c`.
    ///
    /// - Parameter prompt: the final prompt string. The template is NOT applied
    ///   here — wrap with `wrapped(_:)` at the call site so the single argv
    ///   element is exactly what `claude` receives.
    static func codeArgv(for prompt: String) -> [String] {
        codeArgs(prompt: prompt)
    }

    /// The Code-mode argv for an already-built prompt string — the single-argv
    /// contract (`must_haves`: returns `[prompt]`).
    static func codeArgs(prompt: String) -> [String] {
        [prompt]
    }
}
