// Jotty/AI/Ollama/OllamaDownloader.swift
// Chunked/streamed binary download for the Ollama runtime (AI-SPEC §3.1,
// §5.2). Wraps URLSessionDownloadTask so the system writes the body straight
// to a temp file with no per-byte Swift loop: progress comes from a KVO
// observation of Progress.fractionCompleted, and cancellation propagates
// promptly to the underlying task (keeps the §5.2 step-2 Cancel affordance
// responsive for the ~250 MB zip — MAJ-03).

import Foundation

enum OllamaDownloader {

    /// Downloads `source` to a system-managed temp file, reporting fractional
    /// progress on the MainActor. Returns the temp file URL — callers must
    /// move/copy it out before returning, as the OS reclaims it when the task
    /// completes. Throws `OllamaError.downloadFailed` on a non-200 response and
    /// `CancellationError` when the enclosing Task is cancelled.
    static func download(
        from source: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> URL {
        let delegate = ProgressDelegate(progress: progress)
        let session = URLSession(
            configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        // Always invalidate the session so its retain on the delegate is freed.
        defer { session.finishTasksAndInvalidate() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: source) { url, response, error in
                    if let error {
                        let urlError = error as? URLError
                        if urlError?.code == .cancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: OllamaError.downloadFailed(
                                underlying: error.localizedDescription))
                        }
                        return
                    }
                    guard let http = response as? HTTPURLResponse,
                          http.statusCode == 200 else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                        continuation.resume(throwing: OllamaError.downloadFailed(
                            underlying: "HTTP \(status)"))
                        return
                    }
                    guard let url else {
                        continuation.resume(throwing: OllamaError.downloadFailed(
                            underlying: "Download produced no file"))
                        return
                    }
                    // The completion handler's temp file is deleted as soon as
                    // this closure returns, so copy it to a sibling temp path
                    // the caller can move out of.
                    let stable = url.deletingLastPathComponent()
                        .appendingPathComponent("ollama-download-\(UUID().uuidString)")
                    do {
                        try FileManager.default.moveItem(at: url, to: stable)
                        continuation.resume(returning: stable)
                    } catch {
                        continuation.resume(throwing: OllamaError.downloadFailed(
                            underlying: error.localizedDescription))
                    }
                }
                delegate.attach(to: task)
                task.resume()
            }
        } onCancel: {
            delegate.cancel()
        }
    }

    /// URLSession delegate that forwards Progress.fractionCompleted to the
    /// MainActor callback (throttled to whole-percent steps) and owns the
    /// download task for cancellation.
    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate,
                                          @unchecked Sendable {
        private let progress: @MainActor @Sendable (Double) -> Void
        private let lock = NSLock()
        private var task: URLSessionDownloadTask?
        private var lastReported = 0.0

        init(progress: @escaping @MainActor @Sendable (Double) -> Void) {
            self.progress = progress
        }

        func attach(to task: URLSessionDownloadTask) {
            lock.lock(); self.task = task; lock.unlock()
        }

        func cancel() {
            lock.lock(); let t = task; lock.unlock()
            t?.cancel()
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let fraction = min(1.0,
                Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
            lock.lock()
            let shouldReport = fraction - lastReported >= 0.01
            if shouldReport { lastReported = fraction }
            lock.unlock()
            guard shouldReport else { return }
            let cb = progress
            Task { @MainActor in cb(fraction) }
        }

        // The completion-handler download task delivers the file via the
        // completion closure, so this delegate method is unused but required
        // for protocol conformance.
        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {}
    }
}
