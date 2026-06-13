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

    /// The seam must round-trip every one of the four LaunchAtLoginStatus cases —
    /// the same set SMAppLaunchAtLoginService maps from SMAppService.mainApp.status
    /// (.enabled / .requiresApproval / .notRegistered / .notFound). GeneralTab keys
    /// its toggle + approval hint off these exact cases.
    func testStatusMappingCoversAllFourCases() {
        let fake = FakeLaunchAtLoginService()
        for expected: LaunchAtLoginStatus in [.enabled, .requiresApproval, .notRegistered, .notFound] {
            fake.nextStatus = expected
            XCTAssertEqual(fake.status(), expected)
        }
    }

    /// disable() is throw-tolerant too: a thrown unregister() (dev-signing) must
    /// surface, mirroring enable(), so GeneralTab can show its inline notice.
    func testDisableSurfacesThrownError() throws {
        let fake = FakeLaunchAtLoginService()
        try fake.enable()
        struct Boom: Error {}
        fake.errorToThrow = Boom()
        XCTAssertThrowsError(try fake.disable())
    }
}
