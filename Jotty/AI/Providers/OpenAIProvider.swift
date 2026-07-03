// Jotty/AI/Providers/OpenAIProvider.swift
// OpenAI provider (AI-SPEC §1.3). POSTs to the Chat Completions API with
// Structured Outputs strict mode: `response_format.json_schema.strict: true`
// over the shared schema from JSONSchemaBuilder.openAIStrict(). Strict mode
// delivers the structured payload as a JSON STRING in
// `choices[0].message.content`; refusals arrive at
// `choices[0].message.refusal` instead.
//
// Every failure path maps to AIProviderError — no OpenAI-private error type
// ever escapes this actor (AI-SPEC §2).

import Foundation

actor OpenAIProvider: AIProvider {

    private let keychain: KeychainAPIKeyStore
    private let model: String
    private let session: URLSession
    private let retry: RetryPolicy

    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    init(keychain: KeychainAPIKeyStore,
         model: String = "gpt-4o-mini",
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
            storedKey = try keychain.read(account: "openai")
        } catch {
            throw AIProviderError.underlying(
                message: "Keychain read failed: \(error)")
        }
        guard let key = storedKey else {
            throw AIProviderError.modelUnavailable(
                reason: "Add an OpenAI API key in Settings → AI.")
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
                // No OpenAI/URLSession-private error escapes this actor (file
                // header contract): remap a raw URLError to a fixed,
                // detail-free message. .underlying stays retryable so transient
                // network failures still back off and retry (mirrors Gemini).
                throw AIProviderError.underlying(
                    message: "Network error (URLError \(error.code.rawValue))")
            }
            guard let http = response as? HTTPURLResponse else {
                throw AIProviderError.underlying(message: "Non-HTTP response")
            }
            // Stash Retry-After (OpenAI emits it on 429) for the
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
            "messages": [
                ["role": "system",
                 "content": ExtractionPrompt.text(now: now, timezone: timezone)],
                ["role": "user", "content": text]
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "ExtractionResult",
                    "strict": true,
                    "schema": JSONSchemaBuilder.openAIStrict()
                ]
            ],
            "temperature": 0.0
        ]

        var request = URLRequest(url: endpoint)
        // Bound the wait (CQ-08): a hung cloud connection must not leave
        // capture stuck in "Extracting…" at the URLSession default. Cloud
        // extraction typically completes in 2-15s; 60s bounds a hang without
        // failing slow-but-alive responses. Per-request idiom mirrors
        // OllamaProvider (which keeps 120s for local model cold-load).
        request.timeoutInterval = 60
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: Response parsing

    /// Chat Completions success envelope (only the fields we read).
    private struct ChatCompletion: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
                let refusal: String?
            }
            let message: Message
        }
        let choices: [Choice]
    }

    /// OpenAI error envelope:
    /// `{"error": {"message": "...", "type": "...", "code": "..."}}`
    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
            let message: String?
            let type: String?
            let code: String?
        }
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
                reason: "Invalid OpenAI API key.")
        case 400:
            if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
               envelope.error.code == "context_length_exceeded" {
                throw AIProviderError.contextOverflow
            }
            throw AIProviderError.underlying(message: "OpenAI HTTP 400")
        default:
            throw AIProviderError.underlying(message: "OpenAI HTTP \(statusCode)")
        }

        guard let parsed = try? JSONDecoder().decode(ChatCompletion.self, from: data),
              let message = parsed.choices.first?.message else {
            throw AIProviderError.underlying(
                message: "Provider returned invalid schema")
        }

        // G3 — refusal mapping (AI-SPEC §8.2): strict mode reports refusals
        // at message.refusal with content nil.
        if let refusal = message.refusal {
            throw AIProviderError.guardrail(message: refusal)
        }

        // G2 — schema validation: content is a JSON STRING containing the
        // schema-conformant payload. Do NOT attempt to repair on failure.
        guard let content = message.content,
              let result = try? JSONDecoder().decode(
                  ExtractionResultAI.self, from: Data(content.utf8))
        else {
            throw AIProviderError.underlying(
                message: "Provider returned invalid schema")
        }

        let tasks = ISOTaskMapper.map(result.tasks, in: timezone)
        return ExtractionResult(tasks: tasks, noteBody: originalText)
    }
}
