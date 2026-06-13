// JottyTests/AI/RetryPolicyTests.swift
// Behavioral tests for the shared RetryPolicy actor (AI-SPEC §8.3, G4).
// All delay assertions go through an injected Sleeper that records the
// requested nanoseconds instead of actually sleeping, so the suite never
// waits real wall-clock backoff time. Jitter is asserted as a window
// (base ±50%) rather than stubbing the RNG.

import XCTest
@testable import Jotty

final class RetryPolicyTests: XCTestCase {

    // MARK: - Helpers

    /// Records every nanoseconds value passed to the injected sleeper.
    private actor SleepRecorder {
        private(set) var delays: [UInt64] = []
        func record(_ nanoseconds: UInt64) { delays.append(nanoseconds) }
    }

    /// Counts op invocations so tests can assert total attempt counts.
    private actor AttemptCounter {
        private(set) var count = 0
        @discardableResult
        func next() -> Int {
            count += 1
            return count
        }
    }

    /// Makes a policy whose sleeper records into `recorder` and never sleeps.
    private func makePolicy(recording recorder: SleepRecorder) -> RetryPolicy {
        RetryPolicy(sleeper: { nanoseconds in
            await recorder.record(nanoseconds)
        })
    }

    /// Asserts a jittered delay falls within base ±50% (jitterFactor 0.5).
    private func assertWithinJitterWindow(
        _ nanos: UInt64, baseMs: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let base = Double(baseMs) * 1_000_000
        XCTAssertGreaterThanOrEqual(
            Double(nanos), base * 0.5,
            "delay \(nanos)ns below jitter floor for base \(baseMs)ms",
            file: file, line: line
        )
        XCTAssertLessThanOrEqual(
            Double(nanos), base * 1.5,
            "delay \(nanos)ns above jitter ceiling for base \(baseMs)ms",
            file: file, line: line
        )
    }

    // MARK: - Test 1: success on first try

    func testSuccessOnFirstAttemptNeverSleeps() async throws {
        let recorder = SleepRecorder()
        let counter = AttemptCounter()
        let policy = makePolicy(recording: recorder)

        let result = try await policy.execute { () async throws -> String in
            await counter.next()
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        let attempts = await counter.count
        XCTAssertEqual(attempts, 1)
        let delays = await recorder.delays
        XCTAssertTrue(delays.isEmpty, "sleeper must never be called on first-try success")
    }

    // MARK: - Test 2: retryable error retries up to max

    func testRetriesOnRetryableErrorUpToMax() async throws {
        let recorder = SleepRecorder()
        let counter = AttemptCounter()
        let policy = makePolicy(recording: recorder)

        let result = try await policy.execute { () async throws -> String in
            let attempt = await counter.next()
            if attempt < 3 {
                throw AIProviderError.underlying(message: "transient")
            }
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        let attempts = await counter.count
        XCTAssertEqual(attempts, 3, "expected exactly 3 total attempts")

        let delays = await recorder.delays
        XCTAssertEqual(delays.count, 2, "expected exactly 2 backoff sleeps")
        assertWithinJitterWindow(delays[0], baseMs: 250)
        assertWithinJitterWindow(delays[1], baseMs: 1_000)
    }

    // MARK: - Test 3: exhaustion throws the LAST retryable error

    func testExhaustionThrowsLastRetryableError() async {
        let recorder = SleepRecorder()
        let counter = AttemptCounter()
        let policy = makePolicy(recording: recorder)

        do {
            _ = try await policy.execute { () async throws -> String in
                let attempt = await counter.next()
                throw AIProviderError.underlying(message: "attempt-\(attempt)")
            }
            XCTFail("expected throw after exhaustion")
        } catch let error as AIProviderError {
            XCTAssertEqual(
                error, .underlying(message: "attempt-3"),
                "must rethrow the LAST retryable error, unwrapped"
            )
        } catch {
            XCTFail("expected AIProviderError, got \(error)")
        }

        let attempts = await counter.count
        XCTAssertEqual(attempts, 3)
        let delays = await recorder.delays
        XCTAssertEqual(delays.count, 2)
    }

    // MARK: - Test 4: guardrail short-circuits (non-retryable)

    func testGuardrailShortCircuitsWithoutRetry() async {
        let recorder = SleepRecorder()
        let counter = AttemptCounter()
        let policy = makePolicy(recording: recorder)

        do {
            _ = try await policy.execute { () async throws -> String in
                await counter.next()
                throw AIProviderError.guardrail(message: "x")
            }
            XCTFail("expected throw")
        } catch let error as AIProviderError {
            XCTAssertEqual(error, .guardrail(message: "x"))
        } catch {
            XCTFail("expected AIProviderError, got \(error)")
        }

        let attempts = await counter.count
        XCTAssertEqual(attempts, 1, "non-retryable error must not retry")
        let delays = await recorder.delays
        XCTAssertTrue(delays.isEmpty, "sleeper must never be called for non-retryable error")
    }

    // MARK: - Test 5: contextOverflow short-circuits (non-retryable)

    func testContextOverflowShortCircuitsWithoutRetry() async {
        let recorder = SleepRecorder()
        let counter = AttemptCounter()
        let policy = makePolicy(recording: recorder)

        do {
            _ = try await policy.execute { () async throws -> String in
                await counter.next()
                throw AIProviderError.contextOverflow
            }
            XCTFail("expected throw")
        } catch let error as AIProviderError {
            XCTAssertEqual(error, .contextOverflow)
        } catch {
            XCTFail("expected AIProviderError, got \(error)")
        }

        let attempts = await counter.count
        XCTAssertEqual(attempts, 1)
        let delays = await recorder.delays
        XCTAssertTrue(delays.isEmpty)
    }

    // MARK: - Test 6: non-transient URLError propagates verbatim

    func testNonTransientURLErrorPropagatesVerbatim() async {
        let recorder = SleepRecorder()
        let counter = AttemptCounter()
        let policy = makePolicy(recording: recorder)

        do {
            _ = try await policy.execute { () async throws -> String in
                await counter.next()
                throw URLError(.badURL)
            }
            XCTFail("expected throw")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .badURL, "URLError must propagate unmapped")
        } catch {
            XCTFail("expected URLError, got \(error)")
        }

        let attempts = await counter.count
        XCTAssertEqual(attempts, 1)
        let delays = await recorder.delays
        XCTAssertTrue(delays.isEmpty)
    }

    // MARK: - Test 7: Retry-After overrides the base delay (no jitter)

    func testRetryAfterOverridesBaseDelay() async throws {
        let recorder = SleepRecorder()
        let counter = AttemptCounter()
        let policy = makePolicy(recording: recorder)

        let result = try await policy.execute(
            retryAfterSeconds: { _ in 2.0 }
        ) { () async throws -> String in
            let attempt = await counter.next()
            if attempt < 2 {
                throw AIProviderError.underlying(message: "rate limited")
            }
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        let delays = await recorder.delays
        XCTAssertEqual(delays.count, 1)
        XCTAssertEqual(
            delays[0], 2_000_000_000,
            "server-supplied Retry-After is authoritative — no jitter applied"
        )
    }

    // MARK: - Test 7b: pathological Retry-After is clamped (MIN-07)

    func testRetryAfterIsClampedToMax() async throws {
        let recorder = SleepRecorder()
        let counter = AttemptCounter()
        let policy = makePolicy(recording: recorder)

        // An absurdly large server value must not block the capture for
        // minutes — it is clamped to the 60s ceiling.
        let result = try await policy.execute(
            retryAfterSeconds: { _ in 9_999.0 }
        ) { () async throws -> String in
            let attempt = await counter.next()
            if attempt < 2 {
                throw AIProviderError.underlying(message: "rate limited")
            }
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        let delays = await recorder.delays
        XCTAssertEqual(delays.count, 1)
        XCTAssertEqual(delays[0], 60_000_000_000,
                       "Retry-After must be clamped to a 60s ceiling")
    }

    // MARK: - Test 7c: negative Retry-After clamps to zero (no UInt64 trap)

    func testNegativeRetryAfterClampsToZero() async throws {
        let recorder = SleepRecorder()
        let counter = AttemptCounter()
        let policy = makePolicy(recording: recorder)

        // A negative value would trap on the UInt64 conversion; clamp to 0.
        let result = try await policy.execute(
            retryAfterSeconds: { _ in -5.0 }
        ) { () async throws -> String in
            let attempt = await counter.next()
            if attempt < 2 {
                throw AIProviderError.underlying(message: "rate limited")
            }
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        let delays = await recorder.delays
        XCTAssertEqual(delays.count, 1)
        XCTAssertEqual(delays[0], 0, "negative Retry-After must clamp to zero")
    }

    // MARK: - Test 8: cancellation propagates through the sleep

    func testCancellationPropagatesDuringSleep() async {
        // Real Task.sleep sleeper: on an already-cancelled Task it throws
        // CancellationError immediately, so this test never waits the
        // 250ms backoff.
        let policy = RetryPolicy(sleeper: { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        })

        let task = Task {
            try await policy.execute { () async throws -> String in
                throw AIProviderError.underlying(message: "always fails")
            }
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected throw")
        } catch is CancellationError {
            // expected: Task.sleep threw, execute re-threw
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    // MARK: - Test 9: transient URLError codes retry

    func testTransientURLErrorRetries() async throws {
        let recorder = SleepRecorder()
        let counter = AttemptCounter()
        let policy = makePolicy(recording: recorder)

        let result = try await policy.execute { () async throws -> String in
            let attempt = await counter.next()
            if attempt < 3 {
                throw URLError(.networkConnectionLost)
            }
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        let attempts = await counter.count
        XCTAssertEqual(attempts, 3, "transient URLError must retry like a retryable AIProviderError")
        let delays = await recorder.delays
        XCTAssertEqual(delays.count, 2)
    }

    // MARK: - isRetryable extension table

    func testIsRetryableTable() {
        let cases: [(error: AIProviderError, retryable: Bool)] = [
            (.modelUnavailable(reason: "off"), true),
            (.underlying(message: "boom"), true),
            (.guardrail(message: nil), false),
            (.guardrail(message: "refused"), false),
            (.contextOverflow, false),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(
                error.isRetryable, expected,
                "\(error) expected isRetryable == \(expected)"
            )
        }
    }
}
