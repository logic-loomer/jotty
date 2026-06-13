import XCTest
@testable import Jotty

/// SC1 (Send-to-Claude): the pure prompt builder + Web URL builder + safe-argv
/// contract. RED in plan 06-01 (the `ClaudePrompt` type does not exist yet);
/// GREEN in plan 06-02 — that plan adds `Jotty/Claude/ClaudePrompt.swift`, then
/// removes the `#if false` guard + the `XCTFail` marker below to activate the
/// real assertions.
///
/// The guarded block is the executable contract 06-02 must satisfy:
///  - wrapped("...") wraps task text as "Help me with this task: <text>"
///  - webURL(...) is https://claude.ai/new?q=<URLComponents-encoded prompt>
///  - spaces, unicode, `&`, `=` are percent-encoded in the query value
///  - argv safety: the prompt is the SINGLE argv element (never a shell string),
///    so `;`, `$()`, backticks, `&&` are inert (no word-splitting / injection)
final class ClaudePromptTests: XCTestCase {

    func testWrapsTaskTextWithTemplate() {
        XCTAssertEqual(ClaudePrompt.wrapped("write tests"),
                       "Help me with this task: write tests")
    }

    func testWebURLIsEncodedClaudeNewQuery() throws {
        let url = try XCTUnwrap(ClaudePrompt.webURL(for: "write tests"))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.scheme, "https")
        XCTAssertEqual(comps.host, "claude.ai")
        XCTAssertEqual(comps.path, "/new")
        let q = try XCTUnwrap(comps.queryItems?.first { $0.name == "q" }?.value)
        XCTAssertEqual(q, "write tests")
    }

    func testWebURLEncodesSpacesUnicodeAmpersandEquals() throws {
        let raw = "a b & c = d 文字"
        let url = try XCTUnwrap(ClaudePrompt.webURL(for: raw))
        let s = url.absoluteString
        // No raw structural characters leak into the encoded query string.
        XCTAssertFalse(s.contains(" "))
        XCTAssertFalse(s.contains("& c"))
        XCTAssertFalse(s.contains("= d"))
        // Round-trips back to the original via URLComponents decoding.
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.queryItems?.first { $0.name == "q" }?.value, raw)
    }

    func testArgvIsSingleElementNotShellString() {
        // Code mode: the prompt must be a single argv element so shell
        // metacharacters are inert (no /bin/sh -c, no string concatenation).
        let dangerous = "do this; rm -rf / && echo $(whoami) `id`"
        let argv = ClaudePrompt.codeArgv(for: dangerous)
        XCTAssertEqual(argv, [dangerous])
    }
}
