import Foundation
@testable import Jotty

/// Test double for `LaunchAtLoginService` — NEVER touches `SMAppService` or the
/// real login-item registry. Reused by plan 06-04's UI/wiring tests.
final class FakeLaunchAtLoginService: LaunchAtLoginService, @unchecked Sendable {
    /// Status returned by `status()`; set per-test to drive UI mapping.
    var nextStatus: LaunchAtLoginStatus = .notRegistered
    /// Number of times `enable()` / `disable()` were called (idempotency checks).
    private(set) var enableCallCount = 0
    private(set) var disableCallCount = 0
    /// When non-nil, `enable()` / `disable()` throw it (dev-signing failure path).
    var errorToThrow: Error?

    func status() -> LaunchAtLoginStatus { nextStatus }

    func enable() throws {
        enableCallCount += 1
        if let errorToThrow { throw errorToThrow }
        nextStatus = .enabled
    }

    func disable() throws {
        disableCallCount += 1
        if let errorToThrow { throw errorToThrow }
        nextStatus = .notRegistered
    }
}
