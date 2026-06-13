// Jotty/AI/Ollama/OllamaModelManager.swift
// Model management against the local Ollama daemon (AI-SPEC §3.4/§3.5/§4.3):
// streamed /api/pull with MainActor progress fanout, concurrent-pull dedupe,
// cancellation, /api/tags listing, /api/delete, and a disk-space precheck.
//
// Used by the Settings UI (plan 10) only — OllamaProvider (plan 09) never
// pulls; missing models surface as errors there.

import Foundation

actor OllamaModelManager {

    static let shared = OllamaModelManager()

    private let baseURL: URL
    private let session: URLSession
    /// Injectable volume query so the precheck is testable without real
    /// disk state. Live default reads the models volume via DiskSpace.
    private let availableSpace: @Sendable (URL) throws -> Int64
    /// Where Ollama stores weights (AI-SPEC §3.5) — the volume to precheck.
    private let modelsDir: URL

    /// One in-flight pull per model name: the running task plus every
    /// caller's progress callback (fanout for deduped joiners).
    private struct PullJob {
        let task: Task<Void, Error>
        var callbacks: [@MainActor @Sendable (PullProgress) -> Void]
    }
    private var activePulls: [String: PullJob] = [:]

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        session: URLSession = .shared,
        availableSpace: @escaping @Sendable (URL) throws -> Int64 = {
            try DiskSpace.availableSpaceBytes(at: $0)
        },
        modelsDir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ollama/models")
    ) {
        self.baseURL = baseURL
        self.session = session
        self.availableSpace = availableSpace
        self.modelsDir = modelsDir
    }

    // MARK: - Pull (streaming NDJSON)

    /// Pulls a model, streaming progress to `progress` on the MainActor.
    /// Returns when the daemon reports `{"status":"success"}`.
    ///
    /// - De-dupe: a second concurrent call for the same model joins the
    ///   in-flight pull (no fresh /api/pull); its callback receives events
    ///   from registration onward.
    /// - Precheck: when `expectedBytes` is provided (Settings UI knows the
    ///   curated model sizes), the models volume must have at least
    ///   `expectedBytes` × 1.2 free or `.insufficientSpace` is thrown
    ///   before any request is issued.
    func pull(
        model: String,
        expectedBytes: Int64? = nil,
        progress: @escaping @MainActor @Sendable (PullProgress) -> Void
    ) async throws {
        // De-dupe: join the in-flight pull for this model.
        if activePulls[model] != nil {
            activePulls[model]?.callbacks.append(progress)
            guard let job = activePulls[model] else { return }
            try await job.task.value
            return
        }

        // Disk-space precheck before issuing /api/pull (AI-SPEC §3.5).
        if let expectedBytes {
            let have = try availableSpace(modelsDir)
            try DiskSpace.ensureSpace(forBytes: expectedBytes, available: have)
        }

        let task = Task { [weak self] in
            guard let self else { return }
            try await self.runPull(model: model)
        }
        activePulls[model] = PullJob(task: task, callbacks: [progress])
        defer {
            // Clear only our own slot — cancelPull (or a subsequent pull)
            // may already have replaced it.
            if activePulls[model]?.task == task { activePulls[model] = nil }
        }
        try await task.value
    }

    /// Cancels the in-flight pull for `model` (no-op when none). The
    /// URLSession task closes its socket; awaiting callers receive
    /// `CancellationError`. Half-finished layers stay on disk — the daemon
    /// resumes them on the next pull (AI-SPEC §3.4), so no cleanup call.
    func cancelPull(model: String) {
        activePulls[model]?.task.cancel()
        activePulls[model] = nil
    }

    /// Test hook: number of progress callbacks fanned onto the in-flight
    /// pull for `model` (0 when no pull is active).
    func activePullCallbackCount(model: String) -> Int {
        activePulls[model]?.callbacks.count ?? 0
    }

    // MARK: - List / Delete

    func list() async throws -> [InstalledModel] {
        let (data, _) = try await session.data(
            from: baseURL.appendingPathComponent("api/tags"))
        return try JSONDecoder().decode(ListResponse.self, from: data).models
    }

    func delete(model: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/delete"))
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(DeleteBody(model: model))
        let (_, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw OllamaError.deleteFailed
        }
    }

    // MARK: - Private

    private struct PullBody: Encodable {
        let model: String
        let stream: Bool
    }

    private struct DeleteBody: Encodable {
        let model: String
    }

    private struct ListResponse: Decodable {
        let models: [InstalledModel]
    }

    private func runPull(model: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(PullBody(model: model, stream: true))
        req.timeoutInterval = .infinity        // streamed; no idle timeout

        do {
            let (bytes, resp) = try await session.bytes(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw OllamaError.pullFailed(
                    status: (resp as? HTTPURLResponse)?.statusCode ?? -1)
            }

            for try await line in bytes.lines {    // \n framing per NDJSON
                try Task.checkCancellation()
                guard let data = line.data(using: .utf8) else { continue }
                let update = try JSONDecoder().decode(PullProgress.self, from: data)

                // Fan out to every registered caller on the MainActor.
                let callbacks = activePulls[model]?.callbacks ?? []
                await MainActor.run {
                    for callback in callbacks { callback(update) }
                }
                if update.status == "success" { return }
            }
            // Stream ended without a success line: treat as cancellation if
            // we were cancelled, otherwise a failed pull.
            try Task.checkCancellation()
        } catch let error as OllamaError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            if error.code == .cannotConnectToHost {
                // Connection refused — the daemon died (AI-SPEC §3.4 errors).
                throw OllamaError.daemonCrashed(exitCode: -1)
            }
            throw OllamaError.pullFailed(status: -1)
        }
    }
}
