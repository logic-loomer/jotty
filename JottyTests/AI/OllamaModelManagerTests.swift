// JottyTests/AI/OllamaModelManagerTests.swift
// URLProtocol-stubbed tests for OllamaModelManager (plan 04-08, AI-SPEC
// §3.4 + §3.5 + §4.3). No live network, no real ollama binary.
//
// Two stubs:
//   - StubURLProtocol (plan 02): auto-finishing responses — happy path,
//     non-200, list, delete, sequential re-pull.
//   - StreamingStubURLProtocol (this file): holds the connection open so
//     cancellation and concurrent-pull dedupe are deterministic; the test
//     feeds NDJSON lines and finishes the stream explicitly.

import XCTest
@testable import Jotty

// MARK: - Streaming stub

/// URLProtocol that delivers headers + optional initial NDJSON lines, then
/// keeps the connection open until `feed(line:)` / `finish()` are called.
/// Lets tests drive a pull stream one tick at a time.
final class StreamingStubURLProtocol: URLProtocol {

    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var initialLines: [String] = []
    nonisolated(unsafe) private(set) static var receivedRequests: [URLRequest] = []
    nonisolated(unsafe) private static var active: [StreamingStubURLProtocol] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        statusCode = 200
        initialLines = []
        receivedRequests = []
        active = []
    }

    /// Appends one NDJSON line (newline added) to every live connection.
    static func feed(line: String) {
        lock.lock(); let connections = active; lock.unlock()
        for proto in connections {
            proto.client?.urlProtocol(proto, didLoad: Data((line + "\n").utf8))
        }
    }

    /// Completes every live connection.
    static func finish() {
        lock.lock(); let connections = active; active = []; lock.unlock()
        for proto in connections {
            proto.client?.urlProtocolDidFinishLoading(proto)
        }
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamingStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.receivedRequests.append(request)
        let status = Self.statusCode
        let lines = Self.initialLines
        Self.active.append(self)
        Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: status, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/x-ndjson"]
              ) else { return }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for line in lines {
            client?.urlProtocol(self, didLoad: Data((line + "\n").utf8))
        }
    }

    override func stopLoading() {
        Self.lock.lock()
        Self.active.removeAll { $0 === self }
        Self.lock.unlock()
    }
}

// MARK: - Tests

final class OllamaModelManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        StreamingStubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        StreamingStubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: Helpers

    /// Thread-safe recorder for @MainActor progress callbacks.
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [PullProgress] = []
        private var _mainThreadFlags: [Bool] = []

        var events: [PullProgress] {
            lock.lock(); defer { lock.unlock() }; return _events
        }
        var statuses: [String] { events.map(\.status) }
        var count: Int { events.count }
        var allOnMainThread: Bool {
            lock.lock(); defer { lock.unlock() }
            return _mainThreadFlags.allSatisfy { $0 }
        }
        func append(_ progress: PullProgress) {
            lock.lock(); defer { lock.unlock() }
            _events.append(progress)
            _mainThreadFlags.append(Thread.isMainThread)
        }
    }

    private func makeManager(session: URLSession) -> OllamaModelManager {
        OllamaModelManager(session: session)
    }

    /// Polls `condition` every 10 ms until true or timeout (fails the test).
    private func waitUntil(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

    private let fiveLinePull = """
    {"status":"pulling manifest"}
    {"status":"pulling 8eeb52dfb3bb","digest":"sha256:8eeb52dfb3bb","total":1928429856,"completed":241970}
    {"status":"verifying sha256 digest"}
    {"status":"writing manifest"}
    {"status":"success"}
    """

    // MARK: Test 1 — pull happy path

    func testPullStreamsProgressAndCompletes() async throws {
        StubURLProtocol.responses.append { [body = Data(fiveLinePull.utf8)] _ in
            (200, body, ["Content-Type": "application/x-ndjson"])
        }
        let manager = makeManager(session: StubURLProtocol.makeSession())
        let recorder = ProgressRecorder()

        try await manager.pull(model: "qwen2.5:3b") { recorder.append($0) }

        XCTAssertEqual(recorder.statuses, [
            "pulling manifest",
            "pulling 8eeb52dfb3bb",
            "verifying sha256 digest",
            "writing manifest",
            "success",
        ])
        XCTAssertTrue(recorder.allOnMainThread, "progress callback must run on MainActor")

        // Request shape: POST /api/pull with {"model": ..., "stream": true}.
        XCTAssertEqual(StubURLProtocol.receivedRequests.count, 1)
        XCTAssertEqual(StubURLProtocol.receivedRequests[0].httpMethod, "POST")
        XCTAssertEqual(StubURLProtocol.receivedRequests[0].url?.path, "/api/pull")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: StubURLProtocol.receivedBodies[0]) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "qwen2.5:3b")
        XCTAssertEqual(body["stream"] as? Bool, true)
    }

    // MARK: Test 2 — pull non-200

    func testPullNon200ThrowsPullFailed() async throws {
        StubURLProtocol.responses.append { _ in (404, Data(), [:]) }
        let manager = makeManager(session: StubURLProtocol.makeSession())

        do {
            try await manager.pull(model: "nope:1b") { _ in }
            XCTFail("Expected OllamaError.pullFailed")
        } catch let error as OllamaError {
            XCTAssertEqual(error, .pullFailed(status: 404))
        }
    }

    // MARK: Test 3 — pull cancellation

    func testPullCancellationThrowsCancellationError() async throws {
        StreamingStubURLProtocol.initialLines = [#"{"status":"pulling manifest"}"#]
        let manager = makeManager(session: StreamingStubURLProtocol.makeSession())
        let recorder = ProgressRecorder()

        let pullTask = Task {
            try await manager.pull(model: "qwen2.5:3b") { recorder.append($0) }
        }
        // Stream is live once the first callback lands.
        try await waitUntil { recorder.count >= 1 }

        await manager.cancelPull(model: "qwen2.5:3b")

        do {
            try await pullTask.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        // No further callbacks after cancellation, even if data arrives.
        let countAtCancel = recorder.count
        StreamingStubURLProtocol.feed(line: #"{"status":"pulling x","total":10,"completed":5}"#)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(recorder.count, countAtCancel,
                       "progress callback must not fire after cancelPull")
    }

    // MARK: Test 4 — concurrent pull dedupe

    func testConcurrentPullsForSameModelDedupe() async throws {
        StreamingStubURLProtocol.initialLines = [#"{"status":"pulling manifest"}"#]
        let manager = makeManager(session: StreamingStubURLProtocol.makeSession())
        let recorderA = ProgressRecorder()
        let recorderB = ProgressRecorder()

        let taskA = Task {
            try await manager.pull(model: "qwen2.5:3b") { recorderA.append($0) }
        }
        // First pull is in flight once its callback observes the manifest line.
        try await waitUntil { recorderA.count >= 1 }

        let taskB = Task {
            try await manager.pull(model: "qwen2.5:3b") { recorderB.append($0) }
        }
        // Second caller joins the SAME job (fanout registered, no new request).
        try await waitUntil {
            await manager.activePullCallbackCount(model: "qwen2.5:3b") == 2
        }

        StreamingStubURLProtocol.feed(line: #"{"status":"success"}"#)
        try await taskA.value
        try await taskB.value

        XCTAssertEqual(StreamingStubURLProtocol.receivedRequests.count, 1,
                       "second concurrent pull must NOT issue a fresh /api/pull")
        XCTAssertEqual(recorderA.statuses, ["pulling manifest", "success"])
        XCTAssertEqual(recorderB.statuses, ["success"],
                       "joiner receives events from registration onward")
    }

    // MARK: Test 5 — list

    func testListDecodesTagsResponse() async throws {
        let json = """
        {
          "models": [
            {
              "name": "qwen2.5:3b",
              "modified_at": "2026-06-01T10:15:30+10:00",
              "size": 1928429856,
              "digest": "sha256:8eeb52dfb3bb",
              "details": {
                "format": "gguf",
                "family": "qwen2",
                "parameter_size": "3.1B",
                "quantization_level": "Q4_K_M"
              }
            }
          ]
        }
        """
        StubURLProtocol.responses.append { _ in (200, Data(json.utf8), [:]) }
        let manager = makeManager(session: StubURLProtocol.makeSession())

        let models = try await manager.list()

        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].name, "qwen2.5:3b")
        XCTAssertEqual(models[0].size, 1_928_429_856)
        XCTAssertEqual(models[0].details?.family, "qwen2")
        XCTAssertEqual(StubURLProtocol.receivedRequests[0].url?.path, "/api/tags")
    }

    // MARK: Test 6 — delete success

    func testDeleteSucceedsOn200() async throws {
        StubURLProtocol.responses.append { _ in (200, Data(), [:]) }
        let manager = makeManager(session: StubURLProtocol.makeSession())

        try await manager.delete(model: "qwen2.5:3b")

        XCTAssertEqual(StubURLProtocol.receivedRequests.count, 1)
        XCTAssertEqual(StubURLProtocol.receivedRequests[0].httpMethod, "DELETE")
        XCTAssertEqual(StubURLProtocol.receivedRequests[0].url?.path, "/api/delete")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: StubURLProtocol.receivedBodies[0]) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "qwen2.5:3b")
    }

    // MARK: Test 7 — delete failure

    func testDeleteNon200ThrowsDeleteFailed() async throws {
        StubURLProtocol.responses.append { _ in (500, Data(), [:]) }
        let manager = makeManager(session: StubURLProtocol.makeSession())

        do {
            try await manager.delete(model: "qwen2.5:3b")
            XCTFail("Expected OllamaError.deleteFailed")
        } catch let error as OllamaError {
            XCTAssertEqual(error, .deleteFailed)
        }
    }

    // MARK: Test 8 — activePulls slot cleanup

    func testSequentialPullsIssueSeparateRequests() async throws {
        // Single handler repeats (StubURLProtocol keeps the last one), so
        // both pulls complete; a leaked activePulls slot would make the
        // second pull await the finished task instead of issuing a request.
        StubURLProtocol.responses.append { [body = Data(fiveLinePull.utf8)] _ in
            (200, body, ["Content-Type": "application/x-ndjson"])
        }
        let manager = makeManager(session: StubURLProtocol.makeSession())

        try await manager.pull(model: "qwen2.5:3b") { _ in }
        try await manager.pull(model: "qwen2.5:3b") { _ in }

        XCTAssertEqual(StubURLProtocol.receivedRequests.count, 2,
                       "completed pull must clear its activePulls slot")
    }

    // MARK: Test 9 — disk-space precheck

    func testPullBlockedWhenInsufficientDiskSpace() async throws {
        let manager = OllamaModelManager(
            session: StubURLProtocol.makeSession(),
            availableSpace: { _ in 1_000_000_000 }    // 1 GB free
        )

        do {
            // Needs 2 GB × 1.2 = 2.4 GB headroom; only 1 GB available.
            try await manager.pull(model: "qwen2.5:3b", expectedBytes: 2_000_000_000) { _ in }
            XCTFail("Expected OllamaError.insufficientSpace")
        } catch let error as OllamaError {
            XCTAssertEqual(error, .insufficientSpace(
                needed: 2_000_000_000, available: 1_000_000_000))
        }

        XCTAssertTrue(StubURLProtocol.receivedRequests.isEmpty,
                      "precheck failure must block the /api/pull request")
    }
}
