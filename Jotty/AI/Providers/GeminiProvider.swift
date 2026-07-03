// Jotty/AI/Providers/GeminiProvider.swift
// Google Gemini provider (AI-SPEC §1.4). POSTs to the generateContent API
// with structured output: `responseMimeType: "application/json"` +
// `responseSchema` in Gemini's OpenAPI-3.0-flavored Schema dialect
// (uppercase types, nullable optionals) from
// JSONSchemaBuilder.geminiResponseSchema(). The structured payload arrives
// as a JSON STRING in `candidates[0].content.parts[0].text`; safety refusals
// arrive as `finishReason` ∈ {SAFETY, BLOCKED, PROHIBITED_CONTENT}.
//
// SECURITY: the API key travels as a `?key=` URL query param. No thrown
// error message may ever interpolate the request URL — including raw
// URLErrors, whose userInfo carries the failing URL. Every failure path maps
// to AIProviderError with a fixed, URL-free message (AI-SPEC §2).

import Foundation

actor GeminiProvider: AIProvider {

    private let keychain: KeychainAPIKeyStore
    private let model: String
    private let session: URLSession
    private let retry: RetryPolicy

    init(keychain: KeychainAPIKeyStore,
         model: String = "gemini-2.5-flash",
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
            storedKey = try keychain.read(account: "gemini")
        } catch {
            throw AIProviderError.underlying(
                message: "Keychain read failed: \(error)")
        }
        guard let key = storedKey else {
            throw AIProviderError.modelUnavailable(
                reason: "Add a Gemini API key in Settings → AI.")
        }

        let request = try Self.makeRequest(
            key: key, model: model, text: text, now: now, timezone: timezone)

        // G4 — retry via the shared RetryPolicy. Only transport-level
        // transients (429 / 5xx / URLError) throw INSIDE the retried op so
        // they back off and retry; deterministic statuses (401/403/400)
        // return through and are mapped to non-retried errors below (same
        // pattern as ClaudeProvider/OpenAIProvider). Gemini does NOT emit
        // Retry-After (AI-SPEC §8.3), so the default backoff schedule applies
        // and no retryAfterSeconds plumbing is needed.
        let session = self.session
        let (data, statusCode) = try await retry.execute {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError {
                // URL redaction: a raw URLError's userInfo carries the
                // failing URL — which contains the API key. Map to a fixed
                // message; .underlying stays retryable so transient network
                // failures still back off and retry.
                throw AIProviderError.underlying(
                    message: "Network error (URLError \(error.code.rawValue))")
            }
            guard let http = response as? HTTPURLResponse else {
                throw AIProviderError.underlying(message: "Non-HTTP response")
            }
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
        // URLComponents percent-encodes the key in the query item, so
        // arbitrary key strings cannot break the URL.
        guard var components = URLComponents(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        ) else {
            throw AIProviderError.underlying(message: "Could not build Gemini URL")
        }
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        guard let url = components.url else {
            throw AIProviderError.underlying(message: "Could not build Gemini URL")
        }

        let body: [String: Any] = [
            "contents": [[
                "parts": [[
                    "text": ExtractionPrompt.text(now: now, timezone: timezone)
                        + "\n\nUser text:\n" + text
                ]]
            ]],
            "generationConfig": [
                "temperature": 0.0,
                "responseMimeType": "application/json",
                "responseSchema": JSONSchemaBuilder.geminiResponseSchema()
            ]
        ]

        var request = URLRequest(url: url)
        // Bound the wait (CQ-08): a hung cloud connection must not leave
        // capture stuck in "Extracting…" at the URLSession default. Cloud
        // extraction typically completes in 2-15s; 60s bounds a hang without
        // failing slow-but-alive responses. Per-request idiom mirrors
        // OllamaProvider (which keeps 120s for local model cold-load).
        request.timeoutInterval = 60
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: Response parsing

    /// Finish reasons that mean Gemini's safety stack blocked the generation
    /// (AI-SPEC §8.2). All map to .guardrail.
    private static let refusalFinishReasons: Set<String> = [
        "SAFETY", "BLOCKED", "PROHIBITED_CONTENT"
    ]

    /// generateContent success envelope (only the fields we read). Blocked
    /// candidates may omit content/parts entirely, so everything below
    /// `candidates` is optional.
    private struct GenerateContentResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable {
                    let text: String?
                }
                let parts: [Part]?
            }
            let content: Content?
            let finishReason: String?
        }
        let candidates: [Candidate]?
    }

    /// Google error envelope:
    /// `{"error": {"code": 403, "status": "PERMISSION_DENIED", "message": "..."}}`
    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
            let code: Int?
            let status: String?
            let message: String?
        }
        let error: Detail
    }

    private static func parseResponse(
        data: Data, statusCode: Int,
        originalText: String, timezone: TimeZone
    ) throws -> ExtractionResult {
        guard statusCode == 200 else {
            // NOTE: error messages below are fixed strings — never the
            // request URL, which carries the API key in its query.
            if statusCode == 401 || statusCode == 403 {
                throw AIProviderError.modelUnavailable(
                    reason: "Invalid Gemini API key.")
            }
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            if let code = envelope?.error.code, code == 401 || code == 403 {
                throw AIProviderError.modelUnavailable(
                    reason: "Invalid Gemini API key.")
            }
            if statusCode == 400, let detail = envelope?.error {
                let message = detail.message ?? ""
                if message.contains("exceeds the maximum")
                    || (detail.status == "INVALID_ARGUMENT"
                        && message.lowercased().contains("token")) {
                    throw AIProviderError.contextOverflow
                }
            }
            throw AIProviderError.underlying(message: "Gemini HTTP \(statusCode)")
        }

        guard let parsed = try? JSONDecoder().decode(GenerateContentResponse.self, from: data),
              let candidate = parsed.candidates?.first else {
            throw AIProviderError.underlying(
                message: "Provider returned invalid schema")
        }

        // G3 — refusal mapping (AI-SPEC §8.2): safety filters surface as
        // finishReason on the candidate; Gemini supplies no refusal text.
        if let finishReason = candidate.finishReason,
           refusalFinishReasons.contains(finishReason) {
            throw AIProviderError.guardrail(message: nil)
        }

        // A 200 with no text part means the model was blocked or produced
        // nothing usable — treat as guardrail per plan 04-06 step 6.
        guard let text = candidate.content?.parts?.first?.text else {
            throw AIProviderError.guardrail(message: nil)
        }

        // G2 — schema validation: text is a JSON STRING containing the
        // schema-conformant payload. Do NOT attempt to repair on failure.
        guard let result = try? JSONDecoder().decode(
            ExtractionResultAI.self, from: Data(text.utf8))
        else {
            throw AIProviderError.underlying(
                message: "Provider returned invalid schema")
        }

        let tasks = ISOTaskMapper.map(result.tasks, in: timezone)
        return ExtractionResult(tasks: tasks, noteBody: originalText)
    }
}
