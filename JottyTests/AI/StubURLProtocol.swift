// JottyTests/AI/StubURLProtocol.swift
// Shared HTTP stub for provider tests (plans 04-04, 04-05, 04-06, 04-08, 04-09).
// Records every request (including streamed bodies) and serves queued
// responses FIFO. The last handler repeats once the queue would empty, so a
// "429 on every call" test can queue a single handler.
//
// Usage:
//   StubURLProtocol.reset()                       // in setUp/tearDown
//   StubURLProtocol.responses.append { _ in (200, data, [:]) }
//   let session = StubURLProtocol.makeSession()
//
// Static state is process-global; tests using this stub must not run
// concurrently against each other (XCTest default serial execution is fine).

import Foundation

final class StubURLProtocol: URLProtocol {

    // MARK: Static state

    /// FIFO queue: each handler returns (statusCode, body, headers) for one
    /// request. The last handler repeats if the queue would otherwise empty.
    nonisolated(unsafe) static var responses: [(URLRequest) -> (Int, Data, [String: String])] = []

    /// Every request seen, in arrival order.
    nonisolated(unsafe) static var receivedRequests: [URLRequest] = []

    /// Request bodies, parallel to `receivedRequests`. URLProtocol sees
    /// `httpBodyStream` rather than `httpBody` for URLSession data tasks, so
    /// the stream is drained here and stashed for JSON assertions.
    nonisolated(unsafe) static var receivedBodies: [Data] = []

    static func reset() {
        responses = []
        receivedRequests = []
        receivedBodies = []
    }

    /// URLSession over an ephemeral configuration routed through this stub.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.receivedRequests.append(request)
        Self.receivedBodies.append(Self.drainBody(of: request))

        guard !Self.responses.isEmpty else {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: "StubURLProtocol", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "No stubbed response queued for \(request.url?.absoluteString ?? "<nil>")"]
            ))
            return
        }

        // Dequeue FIFO; keep the last handler so it repeats for subsequent
        // requests (lets "429 on every call" tests queue one handler).
        let handler = Self.responses.count > 1 ? Self.responses.removeFirst() : Self.responses[0]
        let (statusCode, body, headers) = handler(request)

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: headers
              ) else {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: "StubURLProtocol", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not build HTTPURLResponse"]
            ))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    // MARK: Private

    /// URLSession data tasks deliver outgoing bodies as `httpBodyStream`;
    /// read the stream fully into Data (falls back to `httpBody` if set).
    private static func drainBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
