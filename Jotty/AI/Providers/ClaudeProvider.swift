// Jotty/AI/Providers/ClaudeProvider.swift
// Anthropic Claude provider (AI-SPEC §1.2). POSTs to the Messages API with
// the tool-use forced-output pattern: a single `emit_tasks` tool whose
// input_schema is the shared ExtractionResultAI schema, forced via
// `tool_choice: {type: "tool", name: "emit_tasks"}`. The structured payload
// comes back at `content[].input` of the tool_use block.
//
// Every failure path maps to AIProviderError — no Anthropic-private error
// type ever escapes this actor (AI-SPEC §2).

import Foundation

actor ClaudeProvider: AIProvider {

    private let keychain: KeychainAPIKeyStore
    private let model: String
    private let session: URLSession
    private let retry: RetryPolicy

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    init(keychain: KeychainAPIKeyStore,
         model: String = "claude-haiku-4-5",
         session: URLSession = .shared,
         retry: RetryPolicy = RetryPolicy()) {
        self.keychain = keychain
        self.model = model
        self.session = session
        self.retry = retry
    }

    // MARK: AIProvider

    func extractTasks(
        from text: String,
        now: Date,
        timezone: TimeZone
    ) async throws -> ExtractionResult {
        // G6 — API-key presence: short-circuit BEFORE any HTTP call.
        let storedKey: String?
        do {
            storedKey = try keychain.read(account: "claude")
        } catch {
            throw AIProviderError.underlying(
                message: "Keychain read failed: \(error)")
        }
        guard let key = storedKey else {
            throw AIProviderError.modelUnavailable(
                reason: "Add a Claude API key in Settings → AI.")
        }

        let request = try Self.makeRequest(
            key: key, model: model, text: text, now: now, timezone: timezone)

        // G4 — retry via the shared RetryPolicy. Only transport-level
        // transients (429 / 5xx / URLError) throw INSIDE the retried op so
        // they back off and retry; deterministic statuses (401/403/400)
        // return through and are mapped to non-retried errors below —
        // .modelUnavailable is retryable by taxonomy, but an invalid API key
        // never heals on retry (AI-SPEC §8: auth errors are deterministic).
        let retryAfter = RetryAfterBox()
        let session = self.session
        let (data, statusCode) = try await retry.execute(
            retryAfterSeconds: { _ in retryAfter.value }
        ) {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError {
                // No Anthropic/URLSession-private error escapes this actor
                // (file header contract): remap a raw URLError to a fixed,
                // detail-free message. .underlying stays retryable so transient
                // network failures still back off and retry (mirrors Gemini).
                throw AIProviderError.underlying(
                    message: "Network error (URLError \(error.code.rawValue))")
            }
            guard let http = response as? HTTPURLResponse else {
                throw AIProviderError.underlying(message: "Non-HTTP response")
            }
            // Stash Retry-After (Anthropic emits it on 429) for the
            // retryAfterSeconds closure above — server value is authoritative.
            retryAfter.value = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap(Double.init)
            if http.statusCode == 429 || (500...599).contains(http.statusCode) {
                throw AIProviderError.modelUnavailable(
                    reason: "Rate limited; try again in a moment.")
            }
            return (data, http.statusCode)
        }

        return try Self.parseResponse(
            data: data, statusCode: statusCode,
            originalText: text, timezone: timezone)
    }

    // MARK: Request building

    private static func makeRequest(
        key: String, model: String, text: String,
        now: Date, timezone: TimeZone
    ) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "tools": [[
                "name": "emit_tasks",
                "description": "Emit extracted tasks and note body.",
                "input_schema": JSONSchemaBuilder.anthropicToolInput()
            ]],
            "tool_choice": ["type": "tool", "name": "emit_tasks"],
            "messages": [[
                "role": "user",
                "content": ExtractionPrompt.text(now: now, timezone: timezone)
                    + "\n\nUser text:\n" + text
            ]]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: Response parsing

    /// Anthropic error envelope:
    /// `{"type": "error", "error": {"type": "...", "message": "..."}}`
    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
            let type: String
            let message: String
        }
        let type: String
        let error: Detail
    }

    private static func parseResponse(
        data: Data, statusCode: Int,
        originalText: String, timezone: TimeZone
    ) throws -> ExtractionResult {
        switch statusCode {
        case 200:
            break
        case 401, 403:
            throw AIProviderError.modelUnavailable(
                reason: "Invalid Claude API key.")
        case 400:
            if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
               envelope.error.type == "invalid_request_error",
               envelope.error.message.localizedCaseInsensitiveContains("context") {
                throw AIProviderError.contextOverflow
            }
            throw AIProviderError.underlying(message: "Claude HTTP 400")
        default:
            throw AIProviderError.underlying(message: "Claude HTTP \(statusCode)")
        }

        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AIProviderError.underlying(
                message: "Provider returned invalid schema")
        }

        // G3 — refusal mapping (AI-SPEC §8.2): explicit refusal stop_reason,
        // or the model talked instead of calling the forced tool.
        if (root["stop_reason"] as? String) == "refusal" {
            throw AIProviderError.guardrail(message: nil)
        }
        let content = root["content"] as? [[String: Any]] ?? []
        guard let toolUse = content.first(where: { ($0["type"] as? String) == "tool_use" }) else {
            throw AIProviderError.guardrail(message: nil)
        }

        // G2 — schema validation: decode tool input as ExtractionResultAI.
        // Do NOT attempt to repair on failure.
        guard let input = toolUse["input"],
              JSONSerialization.isValidJSONObject(input),
              let inputData = try? JSONSerialization.data(withJSONObject: input),
              let parsed = try? JSONDecoder().decode(ExtractionResultAI.self, from: inputData)
        else {
            throw AIProviderError.underlying(
                message: "Provider returned invalid schema")
        }

        let tasks = ISOTaskMapper.map(parsed.tasks, in: timezone)
        return ExtractionResult(tasks: tasks, noteBody: originalText)
    }
}

/// Carries the most recent Retry-After header value from inside the retried
/// op (a `@Sendable` closure) out to RetryPolicy's `retryAfterSeconds`
/// callback. Accesses are sequential — RetryPolicy runs attempts one at a
/// time — but the lock keeps the type honest under Sendable checking.
private final class RetryAfterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Double?

    var value: Double? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
