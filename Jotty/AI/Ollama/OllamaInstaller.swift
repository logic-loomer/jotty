// Jotty/AI/Ollama/OllamaInstaller.swift
// The Ollama runtime supervisor — the ONLY place in Jotty that downloads the
// Ollama binary or spawns `ollama serve` (AI-SPEC §3 + §4). UI (plan 10)
// observes the @Published state; OllamaProvider (plan 09) reads
// `OllamaInstaller.shared.state.isDaemonRunning` before issuing requests.
//
// All side effects (locate, version probe, download, unzip, quarantine strip,
// codesign verify, daemon spawn, sleep) flow through OllamaInstallerDeps so
// the state machine is fully testable without touching the network or
// spawning processes.

import Foundation

// MARK: - State machine (AI-SPEC §4.1)

enum OllamaInstallerState: Equatable {
    case checking                       // initial probe
    case notInstalled                   // no binary anywhere
    case downloading(progress: Double)  // 0.0…1.0
    case extracting                     // unzip + codesign verify
    case installed(daemonRunning: Bool) // binary present
    case starting                       // proc spawned, awaiting /api/version
    case failed(OllamaError)

    var isDaemonRunning: Bool {
        if case .installed(true) = self { return true }
        return false
    }
}

// MARK: - Daemon process handle

/// Minimal seam over `Process` so tests never spawn a real daemon.
protocol ProcessHandle: AnyObject {
    var isRunning: Bool { get }
    func terminate()
}

/// Production wrapper around the spawned `ollama serve` Process.
/// `terminate()` sends SIGTERM and schedules a SIGKILL escalation after a
/// 5-second grace period (AI-SPEC §3.3 stop sequence).
final class OllamaDaemonProcess: ProcessHandle, @unchecked Sendable {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate() // SIGTERM
        let proc = process
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            // Still alive after the 5s grace window → SIGKILL.
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
    }
}

// MARK: - Dependency seam

/// Injectable collaborators for OllamaInstaller. `live` wires the real
/// implementations; tests build a stub per scenario.
struct OllamaInstallerDeps: Sendable {
    /// ~/Library/Application Support/Jotty/ollama (or a temp dir in tests).
    var supportDir: URL
    var locate: @Sendable () -> OllamaBinaryLocation
    var isDaemonRunning: @Sendable () async -> Bool
    var latestRelease: @Sendable () async throws -> GitHubReleases.Asset
    /// (source, destination tmp file, progress 0…1) → final zip URL.
    var download: @Sendable (
        URL, URL, @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> URL
    /// (zip, destination directory)
    var extractZip: @Sendable (URL, URL) throws -> Void
    var stripQuarantine: @Sendable (URL) throws -> Void
    /// (bundle, required Team ID)
    var verifyCodesign: @Sendable (URL, String?) throws -> Void
    /// (binary, log file) → handle on the spawned `ollama serve`.
    var launchDaemon: @Sendable (URL, URL) throws -> any ProcessHandle
    /// Nanosecond sleep — injected so the readiness loop is testable.
    var sleep: @Sendable (UInt64) async throws -> Void
}

// MARK: - Installer

@MainActor
final class OllamaInstaller: ObservableObject {

    static let shared = OllamaInstaller(deps: .live)

    /// Expected Developer ID Team ID for codesign pinning (AI-SPEC §3.1).
    /// Verified against Ollama v0.30.8 on 2026-06-13: `Ollama.app` is signed by
    /// "Developer ID Application: Infra Technologies, Inc (3MU9H2V9Y9)"
    /// (bundle id com.electron.ollama). The AI-SPEC's provisional `Y3CTD9V6X3`
    /// was wrong — see plan 04-13 SUMMARY for the codesign evidence.
    static let expectedOllamaTeamID: String? = "3MU9H2V9Y9"

    @Published private(set) var state: OllamaInstallerState = .checking

    private let deps: OllamaInstallerDeps
    private var daemon: (any ProcessHandle)?

    init(deps: OllamaInstallerDeps) {
        self.deps = deps
    }

    // MARK: Public

    /// Probe locate() + /api/version and settle into the right resting state.
    func bootstrap() async {
        state = .checking
        if case .notFound = deps.locate() {
            state = .notInstalled
        } else {
            let running = await deps.isDaemonRunning()
            state = .installed(daemonRunning: running)
        }
    }

    /// Download the latest release zip, extract, strip quarantine, verify
    /// codesign. Never called when locate() found an existing install — the
    /// UI only offers Download from `.notInstalled`.
    func install() async {
        let supportDir = deps.supportDir
        let bundleURL = supportDir.appendingPathComponent("Ollama.app")
        let tmpURL = supportDir.appendingPathComponent("download.tmp")
        do {
            try FileManager.default.createDirectory(
                at: supportDir, withIntermediateDirectories: true)

            // 1. Resolve latest release asset.
            let asset = try await deps.latestRelease()

            // 2. Streaming download with progress.
            state = .downloading(progress: 0)
            let zipURL = try await deps.download(asset.url, tmpURL) {
                [weak self] fraction in
                self?.state = .downloading(progress: fraction)
            }

            // 3. Extract.
            state = .extracting
            try deps.extractZip(zipURL, supportDir)
            try? FileManager.default.removeItem(at: zipURL)

            // 4. Strip quarantine, then verify signature. Verification
            //    failure is fatal: delete the bundle, never launch.
            try deps.stripQuarantine(bundleURL)
            try deps.verifyCodesign(bundleURL, Self.expectedOllamaTeamID)

            state = .installed(daemonRunning: false)
        } catch {
            try? FileManager.default.removeItem(at: bundleURL)
            try? FileManager.default.removeItem(at: tmpURL)
            state = .failed(OllamaError(from: error))
        }
    }

    /// Spawn `ollama serve` and poll /api/version for up to 10s
    /// (40 × 250ms). Times out into `.failed(.daemonStartupTimeout)`.
    func startDaemon() async {
        guard case .installed(false) = state else { return }
        guard let binary = deps.locate().binaryURL else {
            state = .failed(.binaryNotFound)
            return
        }
        state = .starting
        do {
            let logURL = deps.supportDir.appendingPathComponent("daemon.log")
            let proc = try deps.launchDaemon(binary, logURL)
            self.daemon = proc

            for _ in 0..<40 {
                if await deps.isDaemonRunning() {
                    state = .installed(daemonRunning: true)
                    return
                }
                try? await deps.sleep(250_000_000)
            }
            proc.terminate()
            self.daemon = nil
            state = .failed(.daemonStartupTimeout)
        } catch {
            self.daemon = nil
            state = .failed(OllamaError(from: error))
        }
    }

    /// SIGTERM the daemon (the production handle escalates to SIGKILL after
    /// a 5s grace period — see OllamaDaemonProcess). Wired to
    /// applicationWillTerminate in plan 11 so no `ollama serve` outlives Jotty.
    func stopDaemon() {
        guard let proc = daemon else { return }
        proc.terminate()
        daemon = nil
        state = .installed(daemonRunning: false)
    }

    /// Stop + start, e.g. after the daemon stops responding (AI-SPEC §6 #7).
    func restartDaemon() async {
        stopDaemon()
        await startDaemon()
    }
}

// MARK: - Live dependencies

extension OllamaInstallerDeps {

    /// Production wiring (AI-SPEC §3).
    static var live: OllamaInstallerDeps {
        OllamaInstallerDeps(
            supportDir: FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Jotty/ollama", isDirectory: true),
            locate: { OllamaBinaryLocator.locate() },
            isDaemonRunning: { await liveIsDaemonRunning() },
            latestRelease: { try await GitHubReleases.latestMacAsset() },
            download: { source, tmpURL, progress in
                try await liveDownload(from: source, to: tmpURL, progress: progress)
            },
            extractZip: { zip, dir in
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                proc.arguments = ["-o", "-q", zip.path, "-d", dir.path]
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                try proc.run()
                proc.waitUntilExit()
                guard proc.terminationStatus == 0 else {
                    throw OllamaError.extractFailed
                }
            },
            stripQuarantine: { try Quarantine.strip(at: $0) },
            verifyCodesign: { try CodesignVerifier.verify(bundle: $0, requiredTeamID: $1) },
            launchDaemon: { binary, logURL in
                try liveLaunchDaemon(binary: binary, logURL: logURL)
            },
            sleep: { try await Task.sleep(nanoseconds: $0) })
    }

    /// GET http://127.0.0.1:11434/api/version with a 1s timeout (§3.3).
    private static func liveIsDaemonRunning() async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/version")!)
        req.timeoutInterval = 1.0
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Streaming download: write to `download.tmp`, report progress against
    /// Content-Length, rename to a stable name on success (§3.1 layout).
    private static func liveDownload(
        from source: URL,
        to tmpURL: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> URL {
        let (bytes, resp) = try await URLSession.shared.bytes(from: source)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw OllamaError.downloadFailed(underlying: "HTTP \(status)")
        }
        let expected = http.expectedContentLength

        let fm = FileManager.default
        try? fm.removeItem(at: tmpURL)
        fm.createFile(atPath: tmpURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmpURL)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        var received: Int64 = 0
        var lastReported = 0.0
        for try await byte in bytes {
            buffer.append(byte)
            received += 1
            if buffer.count >= 1 << 16 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                if expected > 0 {
                    let fraction = min(1.0, Double(received) / Double(expected))
                    // Throttle MainActor hops to whole-percent steps.
                    if fraction - lastReported >= 0.01 {
                        lastReported = fraction
                        await progress(fraction)
                    }
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        await progress(1.0)

        let finalURL = tmpURL.deletingLastPathComponent()
            .appendingPathComponent("Ollama-darwin.zip")
        try? fm.removeItem(at: finalURL)
        try fm.moveItem(at: tmpURL, to: finalURL)
        return finalURL
    }

    /// Spawn `ollama serve` bound to 127.0.0.1:11434, stdout+stderr appended
    /// to daemon.log (§3.3 start sequence).
    private static func liveLaunchDaemon(binary: URL, logURL: URL) throws -> any ProcessHandle {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: logURL)
        logHandle.seekToEndOfFile()

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["serve"]
        proc.environment = ProcessInfo.processInfo.environment.merging(
            ["OLLAMA_HOST": "127.0.0.1:11434"],
            uniquingKeysWith: { _, new in new })
        proc.standardOutput = logHandle
        proc.standardError = logHandle
        try proc.run() // throws if path bad / quarantined
        return OllamaDaemonProcess(process: proc)
    }
}
