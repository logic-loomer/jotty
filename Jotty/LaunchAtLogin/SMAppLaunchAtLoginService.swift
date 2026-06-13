import Foundation
import ServiceManagement

/// Real `LaunchAtLoginService` backed by `SMAppService.mainApp` (RESEARCH Pattern 2).
///
/// Reads registration status LIVE from the OS every call — never persisted locally
/// (D-SC2) — so the UI always reflects the true `SMAppService` state. `enable()` is
/// idempotent (no-op when already `.enabled`, which avoids the "reregister after
/// registered" foot-gun) and throw-tolerant at the call site: `register()` /
/// `unregister()` are throwing, and under ad-hoc dev signing `register()` may throw
/// or land in `.requiresApproval`/`.notRegistered` (RESEARCH Pitfall 1). Callers
/// (GeneralTab) wrap enable/disable in `try?` + surface a one-line notice; a throw
/// never crashes the app (threat T-6-09).
///
/// This is the ONLY type that touches `ServiceManagement` — tests use
/// `FakeLaunchAtLoginService`, so the suite never registers a real login item.
final class SMAppLaunchAtLoginService: LaunchAtLoginService {

    func status() -> LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled:          return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered:    return .notRegistered
        case .notFound:         return .notFound
        @unknown default:       return .notRegistered
        }
    }

    func enable() throws {
        // Idempotent: registering when already enabled is unnecessary and can
        // surface a spurious error on some OS versions — guard it (RESEARCH Pattern 2).
        guard SMAppService.mainApp.status != .enabled else { return }
        try SMAppService.mainApp.register()
    }

    func disable() throws {
        try SMAppService.mainApp.unregister()
    }
}
