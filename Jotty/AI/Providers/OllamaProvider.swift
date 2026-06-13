// Jotty/AI/Providers/OllamaProvider.swift
// Ollama provider (AI-SPEC §1.1). POSTs to the local daemon's /api/generate
// with structured output via the `format` parameter: the OpenAI-strict JSON
// schema for daemons >= 0.5, falling back to `format: "json"` mode for older
// daemons (detected via /api/version).
//
// Critical separation (AI-SPEC §3.9): this provider does NOT spawn or
// supervise the daemon — that is OllamaInstaller's job (plan 04-07). If the
// daemon is unreachable, it throws `.modelUnavailable` with actionable copy
// pointing the user at Settings. It holds NO state about model download or
// install — only the model name + base URL.
//
// No RetryPolicy here: the local daemon is fast and deterministic; AI-SPEC
// §8.3 retry semantics are explicitly cloud-only.
//
// Every failure path maps to AIProviderError — no Ollama-private error type
// ever escapes this actor (AI-SPEC §2).

import Foundation

actor OllamaProvider: AIProvider {

    private let model: String
    private let baseURL: URL
    private let session: URLSession

    init(model: String,
         baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
         session: URLSession = .shared) {
        self.model = model
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: AIProvider

    func extractTasks(
        from text: String,
        now: Date,
        timezone: TimeZone
    ) async throws -> ExtractionResult {
        // Version probe doubles as the daemon-up check. Daemon down maps to
        // .modelUnavailable (NOT .underlying) so the UI shows actionable copy.
        guard let version = await daemonVersion() else {
            throw AIProviderError.modelUnavailable(
                reason: "Ollama daemon not running. Start it from Settings → AI.")
        }

        let useSchema = Self.supportsSchemaFormat(version)
        let body: [String: Any] = [
            "model": model,
            "prompt": ExtractionPrompt.text(now: now, timezone: timezone)
                + "\n\nUser text:\n" + text,
            "stream": false,
            "format": useSchema ? JSONSchemaBuilder.openAIStrict() as Any
                                : "json" as Any,
            "options": ["temperature": 0.0, "num_predict": 512]
        ]

        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        do {
            let (received, response) = try await session.data(for: request)
            guard response is HTTPURLResponse else {
                throw AIProviderError.underlying(message: "Non-HTTP response")
            }
            data = received
        } catch let error as AIProviderError {
            throw error
        } catch {
            throw AIProviderError.underlying(message: error.localizedDescription)
        }

        guard let envelope = try? JSONDecoder().decode(GenerateEnvelope.self, from: data) else {
            throw AIProviderError.underlying(message: "Provider returned invalid schema")
        }

        // Ollama reports failures (missing model, OOM, …) as a JSON error
        // body — mapped to .guardrail per AI-SPEC §8.2.
        if let message = envelope.error {
            throw AIProviderError.guardrail(message: message)
        }

        // The structured payload arrives as a JSON STRING in `response`
        // (both schema mode and legacy json mode). G2 — do NOT repair on
        // decode failure.
        guard let responseString = envelope.response,
              let result = try? JSONDecoder().decode(
                  ExtractionResultAI.self, from: Data(responseString.utf8))
        else {
            throw AIProviderError.underlying(message: "Provider returned invalid schema")
        }

        let rawTasks = ISOTaskMapper.map(result.tasks, in: timezone)
        // Duration guardrail (AI-SPEC §6) — shared post-process with Apple FM.
        let tasks = DurationGuardrail.apply(rawTasks, against: text, now: now, timezone: timezone)
        return ExtractionResult(tasks: tasks, noteBody: text)
    }

    // MARK: Daemon probe

    /// GET /api/version. Returns nil when the daemon is unreachable (connection
    /// refused / timeout / non-200 / undecodable body) — callers treat nil as
    /// "daemon down".
    private func daemonVersion() async -> String? {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/version"))
        request.httpMethod = "GET"
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            struct VersionEnvelope: Decodable { let version: String }
            return (try? JSONDecoder().decode(VersionEnvelope.self, from: data))?.version
        } catch {
            return nil
        }
    }

    /// Structured `format` (JSON schema dict) requires daemon >= 0.5.0;
    /// older daemons only understand `format: "json"`. Compares major.minor
    /// as ints; unparseable versions assume modern.
    private static func supportsSchemaFormat(_ version: String) -> Bool {
        let parts = version.split(separator: ".").map { component in
            Int(component.prefix { $0.isNumber }) ?? 0
        }
        guard parts.count >= 2 else { return true }
        let (major, minor) = (parts[0], parts[1])
        return major > 0 || minor >= 5
    }

    // MARK: Response envelope

    /// /api/generate non-streaming envelope (only the fields we read).
    /// `{"response": String, "done": Bool, "error"?: String}`
    private struct GenerateEnvelope: Decodable {
        let response: String?
        let done: Bool?
        let error: String?
    }
}
