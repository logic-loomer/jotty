import Foundation

/// Launch-at-login registration state, mirrored from the OS (`SMAppService.mainApp`).
///
/// Read live from the OS every time — never persisted locally — so the UI always
/// reflects the true `SMAppService` status (plan 06-04 owns the real impl).
/// `requiresApproval` means registered-but-the-user-must-approve in
/// System Settings > Login Items; the UI surfaces a hint for that case.
enum LaunchAtLoginStatus: Sendable, Equatable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
}

/// The single seam through which the app (and tests) read and toggle the
/// launch-at-login login item.
///
/// `Sendable` (as `CalendarService` is) so it injects cleanly under Swift 6.
/// Tests inject `FakeLaunchAtLoginService`, so the suite never registers a real
/// login item. The real `SMAppService`-backed implementation lands in plan 06-04;
/// its live behavior (restart-survives-login) is a human-verify item.
protocol LaunchAtLoginService: Sendable {
    /// Cheap, synchronous status read from the OS (does not mutate registration).
    func status() -> LaunchAtLoginStatus
    /// Registers the app as a login item. Idempotent; may throw under dev signing.
    func enable() throws
    /// Unregisters the login item. Idempotent.
    func disable() throws
}
