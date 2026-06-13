// JottyTests/AI/CaptureViewModelFallbackTests.swift
// Plan 04-10 Task 10.3: provider-failure fallback to Apple FM.
//
// ROADMAP Phase 4 SC4: provider failure surfaces an inline toast in the
// Review state with an offer to fall back to Apple FM. Failure enters the
// DEGRADED Review state (established Phase 3 behavior, kept by this plan):
// lastError set, zero AI tasks, raw input preserved in noteBody + savedInput.
// retryWithAppleFM() re-runs the stashed failed input through the injected
// fallback provider.
//
// Reuses MockAIProvider from CaptureViewModelAIPathTests.swift.

import XCTest
@testable import Jotty

@MainActor
final class CaptureViewModelFallbackTests: XCTestCase {
    var folder: URL!
    var draftURL: URL!
    var store: Store!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        draftURL = folder.appendingPathComponent("draft.txt")
        store = Store(folder: folder, timezone: .current)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // Test 1 — failure preserves input: lastError set, user's text intact,
    // degraded Review carries the raw input so nothing is lost.
    func testFailurePreservesInput() async throws {
        let input = "ship the beta to Jamie by Friday"
        let primary = MockAIProvider(
            mode: .throwError(.modelUnavailable(reason: "Invalid Claude API key.")))
        let vm = CaptureViewModel(store: store, draftURL: draftURL,
                                  provider: primary, clock: { Date() })
        vm.text = input
        await vm.submitAndWait()

        XCTAssertEqual(vm.lastError,
                       .modelUnavailable(reason: "Invalid Claude API key."))
        XCTAssertEqual(vm.text, input,
                       "failure must not clear the user's input")
        guard case .review(let tasks, let noteBody, let savedInput) = vm.state else {
            XCTFail("Expected degraded review state, got \(vm.state)"); return
        }
        XCTAssertEqual(tasks.count, 0, "degraded review carries no AI tasks")
        XCTAssertEqual(noteBody, input, "raw input preserved as note body")
        XCTAssertEqual(savedInput, input, "savedInput must restore the input on cancel")
    }

    // Test 2 — fallback succeeds: retryWithAppleFM() re-runs the failed input
    // through the fallback provider; state becomes .review with its task and
    // lastError clears.
    func testFallbackSucceeds() async throws {
        let input = "email Jamie about Q2 plan by Friday"
        let primary = MockAIProvider(
            mode: .throwError(.modelUnavailable(reason: "Invalid Claude API key.")))
        let fallbackTask = ExtractedTask(title: "email Jamie about Q2 plan")
        let fallback = MockAIProvider(
            mode: .succeed(ExtractionResult(tasks: [fallbackTask], noteBody: input)))
        let vm = CaptureViewModel(store: store, draftURL: draftURL,
                                  provider: primary,
                                  fallbackProvider: fallback,
                                  clock: { Date() })
        XCTAssertTrue(vm.fallbackAvailable)

        vm.text = input
        await vm.submitAndWait()
        XCTAssertNotNil(vm.lastError)

        await vm.retryWithAppleFM()

        XCTAssertNil(vm.lastError, "successful fallback must clear the error")
        guard case .review(let tasks, let noteBody, _) = vm.state else {
            XCTFail("Expected review state after fallback, got \(vm.state)"); return
        }
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].title, "email Jamie about Q2 plan")
        XCTAssertEqual(noteBody, input)
        let fallbackCalls = await fallback.callCount
        XCTAssertEqual(fallbackCalls, 1, "fallback provider must run exactly once")
    }

    // Test 3 — fallback also fails: lastError updates to the NEW error and
    // the user's input is still preserved.
    func testFallbackAlsoFails() async throws {
        let input = "remember to call the dentist"
        let primary = MockAIProvider(
            mode: .throwError(.modelUnavailable(reason: "Invalid Claude API key.")))
        let fallback = MockAIProvider(
            mode: .throwError(.modelUnavailable(reason: "Apple Intelligence is off")))
        let vm = CaptureViewModel(store: store, draftURL: draftURL,
                                  provider: primary,
                                  fallbackProvider: fallback,
                                  clock: { Date() })
        vm.text = input
        await vm.submitAndWait()
        XCTAssertEqual(vm.lastError,
                       .modelUnavailable(reason: "Invalid Claude API key."))

        await vm.retryWithAppleFM()

        XCTAssertEqual(vm.lastError,
                       .modelUnavailable(reason: "Apple Intelligence is off"),
                       "lastError must update to the fallback's error")
        XCTAssertEqual(vm.text, input, "input still preserved after double failure")
    }

    // Test 3b — re-entry guard (MIN-04): retryWithAppleFM is a no-op while an
    // extraction is already in flight (isExtracting == true), so a double-tap
    // on "Use Apple FM instead" cannot launch a second overlapping run.
    func testRetryWhileExtractingIsNoOp() async throws {
        let input = "draft the release notes"
        let primary = MockAIProvider(
            mode: .throwError(.modelUnavailable(reason: "Invalid Claude API key.")))
        let fallbackTask = ExtractedTask(title: "draft the release notes")
        let fallback = MockAIProvider(
            mode: .succeed(ExtractionResult(tasks: [fallbackTask], noteBody: input)))
        let vm = CaptureViewModel(store: store, draftURL: draftURL,
                                  provider: primary,
                                  fallbackProvider: fallback,
                                  clock: { Date() })
        vm.text = input
        await vm.submitAndWait()
        XCTAssertNotNil(vm.lastError)

        // Simulate an in-flight extraction: the guard must short-circuit.
        vm.isExtracting = true
        await vm.retryWithAppleFM()

        let fallbackCalls = await fallback.callCount
        XCTAssertEqual(fallbackCalls, 0,
                       "retry must not run the fallback while extracting")
    }

    // Test 4 — no fallback wired (Apple FM already active): retry is a no-op
    // and fallbackAvailable drives the button's visibility.
    func testRetryWithoutFallbackProviderIsNoOp() async throws {
        let primary = MockAIProvider(
            mode: .throwError(.guardrail(message: nil)))
        let vm = CaptureViewModel(store: store, draftURL: draftURL,
                                  provider: primary, clock: { Date() })
        XCTAssertFalse(vm.fallbackAvailable)

        vm.text = "some prose"
        await vm.submitAndWait()
        let errorBefore = vm.lastError
        let stateBefore = vm.state

        await vm.retryWithAppleFM()

        XCTAssertEqual(vm.lastError, errorBefore, "no-op retry must not touch lastError")
        XCTAssertEqual(vm.state, stateBefore, "no-op retry must not change state")
    }
}
