import XCTest
@testable import Jotty

/// SC2 (Launch at Login): the `LaunchAtLoginService` seam contract, driven
/// through `FakeLaunchAtLoginService`. The real `SMAppService` impl is human-verify
/// (restart-survives-login); wired in plan 06-04. This asserts the protocol
/// contract + idempotency + throw-tolerance, never registering a real login item.
///
/// real SMAppService impl is human-verify; fake here
final class LaunchAtLoginTests: XCTestCase {

    func testStatusReflectsConfiguredState() {
        let fake = FakeLaunchAtLoginService()
        fake.nextStatus = .requiresApproval
        XCTAssertEqual(fake.status(), .requiresApproval)
        fake.nextStatus = .enabled
        XCTAssertEqual(fake.status(), .enabled)
    }

    func testEnableSetsEnabledStatus() throws {
        let fake = FakeLaunchAtLoginService()
        try fake.enable()
        XCTAssertEqual(fake.status(), .enabled)
        XCTAssertEqual(fake.enableCallCount, 1)
    }

    func testEnableIsIdempotent() throws {
        let fake = FakeLaunchAtLoginService()
        try fake.enable()
        try fake.enable()
        XCTAssertEqual(fake.status(), .enabled)
        XCTAssertEqual(fake.enableCallCount, 2)
    }

    func testDisableSetsNotRegistered() throws {
        let fake = FakeLaunchAtLoginService()
        try fake.enable()
        try fake.disable()
        XCTAssertEqual(fake.status(), .notRegistered)
        XCTAssertEqual(fake.disableCallCount, 1)
    }

    /// register()/disable() can throw under dev signing — the contract must
    /// surface the error, not swallow it.
    func testEnableSurfacesThrownError() {
        let fake = FakeLaunchAtLoginService()
        struct Boom: Error {}
        fake.errorToThrow = Boom()
        XCTAssertThrowsError(try fake.enable())
    }
}
