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

    /// Context caps for the two handoff modes (#1). Web/URL mode is capped HARD so
    /// the `claude.ai/new?q=` prefill stays well under browser/query-string limits;
    /// Code/argv mode allows a fuller context (a single argv slot has no practical
    /// size limit — the text still can't inject, it's one element).
    static let webContextCap = 500
    static let codeContextCap = 4000

    /// Context-taking builder (#1): wraps the task text AND appends the source
    /// note's body plus sibling-task titles so the handoff carries the surrounding
    /// context, not just the bare title.
    ///
    /// SECURITY: this only grows the PROMPT TEXT — the single-argv construction
    /// (`codeArgv`) and the URLComponents percent-encoding (`webURL`) downstream are
    /// untouched, so metacharacters remain inert. The context is additionally
    /// FLATTENED (every whitespace/newline run → a single space) so a multi-line
    /// note body stays one contained region and cannot inject a fake template line.
    ///
    /// The core `wrapped(taskText)` prefix is NEVER truncated; only the appended
    /// context is hard-capped at `maxContextLength`. Nil/empty body + empty siblings
    /// degrade to exactly `wrapped(taskText)`.
    static func wrapped(taskText: String,
                        sourceNoteBody: String?,
                        siblingTitles: [String] = [],
                        maxContextLength: Int) -> String {
        let base = wrapped(taskText)
        var parts: [String] = []
        if let body = flattenContext(sourceNoteBody), !body.isEmpty {
            parts.append("Context from my note: \"\(body)\"")
        }
        let siblings = siblingTitles
            .compactMap { flattenContext($0) }
            .filter { !$0.isEmpty }
        if !siblings.isEmpty {
            parts.append("Related tasks in the same note: " + siblings.joined(separator: "; "))
        }
        guard !parts.isEmpty else { return base }
        var context = " " + parts.joined(separator: " ")
        if context.count > maxContextLength {
            context = String(context.prefix(maxContextLength))
        }
        return base + context
    }

    /// Collapses every whitespace/newline run to a single space and trims — so
    /// note-body context can never carry a raw newline (or a fake structural line)
    /// into the prompt. Returns nil for nil input; "" for whitespace-only input.
    private static func flattenContext(_ s: String?) -> String? {
        guard let s else { return nil }
        return s.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
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
