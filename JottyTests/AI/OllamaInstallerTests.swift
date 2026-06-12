// JottyTests/AI/OllamaInstallerTests.swift
// State-machine transition tests for OllamaInstaller (AI-SPEC §4.1 / §4.2).
// All collaborators (locator, version probe, downloader, unzip, codesign,
// daemon launcher, sleep) are injected via OllamaInstallerDeps so no test
// spawns `ollama serve`, touches the network, or waits wall-clock time.

import XCTest
import Combine
@testable import Jotty

@MainActor
final class OllamaInstallerTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OllamaInstallerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        cancellables.removeAll()
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Test doubles

    /// Scripted boolean sequence for the /api/version probe.
    private final class ProbeScript: @unchecked Sendable {
        private var results: [Bool]
        private let fallback: Bool
        private(set) var calls = 0
        init(_ results: [Bool], fallback: Bool = false) {
            self.results = results
            self.fallback = fallback
        }
        func next() -> Bool {
            calls += 1
            return results.isEmpty ? fallback : results.removeFirst()
        }
    }

    /// Counts invocations (e.g. of the injected sleep).
    private final class CallCounter: @unchecked Sendable {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    private final class MockProcessHandle: ProcessHandle, @unchecked Sendable {
        var isRunning = true
        private(set) var terminateCount = 0
        func terminate() {
            terminateCount += 1
            isRunning = false
        }
    }

    // MARK: - Helpers

    private func makeDeps(
        locate: @escaping @Sendable () -> OllamaBinaryLocation = { .notFound },
        isDaemonRunning: @escaping @Sendable () async -> Bool = { false },
        latestRelease: @escaping @Sendable () async throws -> GitHubReleases.Asset = {
            GitHubReleases.Asset(
                url: URL(string: "https://example.com/Ollama-darwin.zip")!,
                name: "Ollama-darwin.zip", size: 100)
        },
        download: @escaping @Sendable (
            URL, URL, @escaping @MainActor @Sendable (Double) -> Void
        ) async throws -> URL = { _, dest, _ in dest },
        extractZip: @escaping @Sendable (URL, URL) throws -> Void = { _, _ in },
        stripQuarantine: @escaping @Sendable (URL) throws -> Void = { _ in },
        verifyCodesign: @escaping @Sendable (URL, String?) throws -> Void = { _, _ in },
        launchDaemon: (@Sendable (URL, URL) throws -> any ProcessHandle)? = nil,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { _ in }
    ) -> OllamaInstallerDeps {
        OllamaInstallerDeps(
            supportDir: tempDir,
            locate: locate,
            isDaemonRunning: isDaemonRunning,
            latestRelease: latestRelease,
            download: download,
            extractZip: extractZip,
            stripQuarantine: stripQuarantine,
            verifyCodesign: verifyCodesign,
            launchDaemon: launchDaemon ?? { _, _ in MockProcessHandle() },
            sleep: sleep)
    }

    /// Records every state transition after the initial sink replay.
    private func recordStates(of installer: OllamaInstaller) -> NSMutableArray {
        let log = NSMutableArray()
        installer.$state
            .dropFirst()
            .sink { log.add($0) }
            .store(in: &cancellables)
        return log
    }

    private func states(_ log: NSMutableArray) -> [OllamaInstallerState] {
        log.compactMap { $0 as? OllamaInstallerState }
    }

    private let homebrewBinary = URL(fileURLWithPath: "/opt/homebrew/bin/ollama")

    // MARK: - bootstrap()

    /// Test 1 — no binary anywhere: checking → notInstalled.
    func testBootstrapWithNoBinaryGoesToNotInstalled() async {
        let installer = OllamaInstaller(deps: makeDeps(locate: { .notFound }))
        let log = recordStates(of: installer)

        await installer.bootstrap()

        XCTAssertEqual(states(log), [.checking, .notInstalled])
    }

    /// Test 2 — binary present + daemon already up: checking → installed(true).
    func testBootstrapWithRunningDaemonGoesToInstalledRunning() async {
        let binary = homebrewBinary
        let installer = OllamaInstaller(deps: makeDeps(
            locate: { .systemHomebrew(binary) },
            isDaemonRunning: { true }))
        let log = recordStates(of: installer)

        await installer.bootstrap()

        XCTAssertEqual(states(log), [.checking, .installed(daemonRunning: true)])
        XCTAssertTrue(installer.state.isDaemonRunning)
    }

    /// Test 3 — binary present + daemon down: checking → installed(false).
    func testBootstrapWithBinaryButNoDaemonGoesToInstalledNotRunning() async {
        let binary = homebrewBinary
        let installer = OllamaInstaller(deps: makeDeps(
            locate: { .systemHomebrew(binary) },
            isDaemonRunning: { false }))
        let log = recordStates(of: installer)

        await installer.bootstrap()

        XCTAssertEqual(states(log), [.checking, .installed(daemonRunning: false)])
        XCTAssertFalse(installer.state.isDaemonRunning)
    }

    // MARK: - install()

    /// Test 4 — success path walks the full download → extract → installed arc.
    func testInstallSuccessPathTransitionsThroughDownloadAndExtract() async {
        let installer = OllamaInstaller(deps: makeDeps(
            locate: { .notFound },
            download: { _, dest, progress in
                await progress(0.5)
                await progress(1.0)
                return dest
            }))
        let log = recordStates(of: installer)

        await installer.bootstrap()
        await installer.install()

        XCTAssertEqual(states(log), [
            .checking,
            .notInstalled,
            .downloading(progress: 0),
            .downloading(progress: 0.5),
            .downloading(progress: 1.0),
            .extracting,
            .installed(daemonRunning: false),
        ])
    }

    /// Test 5 — codesign failure lands in failed(.signatureInvalid) and the
    /// extracted bundle is removed (never launch an unverified binary).
    func testInstallCodesignFailureCleansUpExtractedBundle() async throws {
        let supportDir: URL = tempDir
        let bundleURL = supportDir.appendingPathComponent("Ollama.app")
        let installer = OllamaInstaller(deps: makeDeps(
            locate: { .notFound },
            download: { _, dest, progress in
                await progress(1.0)
                return dest
            },
            extractZip: { _, dir in
                try FileManager.default.createDirectory(
                    at: dir.appendingPathComponent("Ollama.app"),
                    withIntermediateDirectories: true)
            },
            verifyCodesign: { _, _ in throw OllamaError.signatureInvalid }))
        let log = recordStates(of: installer)

        await installer.bootstrap()
        await installer.install()

        XCTAssertEqual(states(log), [
            .checking,
            .notInstalled,
            .downloading(progress: 0),
            .downloading(progress: 1.0),
            .extracting,
            .failed(.signatureInvalid),
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.path),
                       "Extracted bundle must be removed when codesign fails")
    }

    // MARK: - startDaemon()

    /// Test 6 — readiness loop polls until the probe flips true:
    /// installed(false) → starting → installed(true).
    func testStartDaemonPollsReadinessThenInstalledRunning() async {
        let binary = homebrewBinary
        // Call 1: bootstrap probe (false). Calls 2-3: poll loop (false twice).
        // Call 4: poll loop success.
        let probe = ProbeScript([false, false, false, true])
        let sleeps = CallCounter()
        let mock = MockProcessHandle()
        let installer = OllamaInstaller(deps: makeDeps(
            locate: { .systemHomebrew(binary) },
            isDaemonRunning: { probe.next() },
            launchDaemon: { _, _ in mock },
            sleep: { _ in sleeps.increment() }))
        let log = recordStates(of: installer)

        await installer.bootstrap()
        await installer.startDaemon()

        XCTAssertEqual(states(log), [
            .checking,
            .installed(daemonRunning: false),
            .starting,
            .installed(daemonRunning: true),
        ])
        XCTAssertEqual(sleeps.count, 2, "Loop must sleep between failed probes")
        XCTAssertEqual(mock.terminateCount, 0)
    }

    /// Test 7 — probe never flips: after 40 attempts the daemon is terminated
    /// and state is failed(.daemonStartupTimeout).
    func testStartDaemonTimesOutAfterFortyAttemptsAndTerminatesDaemon() async {
        let binary = homebrewBinary
        let probe = ProbeScript([], fallback: false)
        let sleeps = CallCounter()
        let mock = MockProcessHandle()
        let installer = OllamaInstaller(deps: makeDeps(
            locate: { .systemHomebrew(binary) },
            isDaemonRunning: { probe.next() },
            launchDaemon: { _, _ in mock },
            sleep: { _ in sleeps.increment() }))
        let log = recordStates(of: installer)

        await installer.bootstrap()
        await installer.startDaemon()

        XCTAssertEqual(states(log), [
            .checking,
            .installed(daemonRunning: false),
            .starting,
            .failed(.daemonStartupTimeout),
        ])
        // 1 bootstrap probe + 40 poll probes
        XCTAssertEqual(probe.calls, 41)
        XCTAssertEqual(mock.terminateCount, 1,
                       "Spawned daemon must be terminated on timeout")
    }

    // MARK: - stopDaemon()

    /// Test 8 — stopDaemon: installed(true) → installed(false), terminate()
    /// called exactly once on the daemon handle.
    func testStopDaemonTerminatesProcessAndReturnsToInstalledNotRunning() async {
        let binary = homebrewBinary
        // bootstrap probe false → installed(false); first poll true.
        let probe = ProbeScript([false, true])
        let mock = MockProcessHandle()
        let installer = OllamaInstaller(deps: makeDeps(
            locate: { .systemHomebrew(binary) },
            isDaemonRunning: { probe.next() },
            launchDaemon: { _, _ in mock }))
        let log = recordStates(of: installer)

        await installer.bootstrap()
        await installer.startDaemon()
        installer.stopDaemon()

        XCTAssertEqual(states(log), [
            .checking,
            .installed(daemonRunning: false),
            .starting,
            .installed(daemonRunning: true),
            .installed(daemonRunning: false),
        ])
        XCTAssertEqual(mock.terminateCount, 1)
    }

    /// stopDaemon with no daemon handle is a no-op (no state churn).
    func testStopDaemonWithoutRunningDaemonIsNoOp() async {
        let installer = OllamaInstaller(deps: makeDeps(locate: { .notFound }))
        let log = recordStates(of: installer)

        await installer.bootstrap()
        installer.stopDaemon()

        XCTAssertEqual(states(log), [.checking, .notInstalled])
    }
}
