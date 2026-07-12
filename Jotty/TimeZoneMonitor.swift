import Foundation

/// Observes live system-timezone changes and classifies them (roadmap 3.3,
/// design note 2026-07-12; adversarially reviewed same day). The app's
/// Store/model stack pins the timezone at construction (the pinned-calendar
/// discipline — never `autoupdatingCurrent`, which would flip mid-operation);
/// this monitor is the ONE place a zone change enters, so the app can rebuild
/// deliberately instead of split-braining (capture parsing in the new zone
/// while the store serializes in the old one).
///
/// Classification, not action: the monitor reports the zone PAIR and hands it
/// to the AppDelegate, which owns the rebuild. It deliberately does NOT compute
/// an offset delta — a block's re-anchor shift depends on both zones' offsets
/// AT THE BLOCK'S DATE (review F2: Sydney→LA shifts a July block −17h but an
/// October block −18h; Brisbane→Sydney is offset-identical in July yet shifts
/// every post-DST block +1h). Per-block deltas live in
/// `CalendarDrift.partitionForTZShift`; whether to prompt is decided there,
/// never by a single-instant offset comparison.
///
/// The rebuild itself must write ZERO bytes — wall-clock tokens on disk are
/// TZ-agnostic by design, and the rollover over-correction taught us that
/// acting automatically on re-anchored data destroys it. Only an explicit user
/// choice (the one-shot bulk drift prompt) may write.
final class TimeZoneMonitor {
    enum Decision: Equatable {
        /// Spurious notification — same zone identifier. DST transitions never
        /// reach here (they change the offset, not the identifier, and fire no
        /// zone-change notification anyway).
        case none
        /// The system zone identifier changed. ALWAYS rebuild the pinned stack;
        /// prompt iff the partition finds TZ-shift pairs (per-block, downstream).
        case zoneChanged(from: TimeZone, to: TimeZone)
    }

    /// Stored so deinit removes the observer from the center it was ADDED to
    /// (review F1: removing from `.default` leaked observers on any injected
    /// center, and the stale block kept firing captured closures after the
    /// monitor was replaced during a rebuild).
    private let notificationCenter: NotificationCenter
    private var observation: NSObjectProtocol?

    /// All dependencies injected — no singletons — so tests drive the monitor by
    /// posting to a private NotificationCenter with swapped closures.
    ///
    /// `onChange` is delivered on the MAIN queue (`queue: .main` below) — the
    /// AppDelegate rebuild is main-actor work (WR-09 sequencing); callers must
    /// not assume any other thread.
    /// - Parameters:
    ///   - activeTZ: the zone the Store/model stack is currently pinned to.
    ///   - currentTZ: reads the system zone FRESH at notification time
    ///     (`TimeZone.current`; never `autoupdatingCurrent`).
    ///   - onChange: receives every non-`.none` decision.
    init(notificationCenter: NotificationCenter = .default,
         activeTZ: @escaping () -> TimeZone,
         currentTZ: @escaping () -> TimeZone,
         onChange: @escaping (Decision) -> Void) {
        self.notificationCenter = notificationCenter
        observation = notificationCenter.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { _ in
            let decision = Self.decision(active: activeTZ(), current: currentTZ())
            guard decision != .none else { return }
            onChange(decision)
        }
    }

    deinit {
        if let observation {
            notificationCenter.removeObserver(observation)
        }
    }

    /// Pure classification — see `Decision`. Identifier comparison only: offset
    /// math is per-block business (review F2), not the monitor's.
    static func decision(active: TimeZone, current: TimeZone) -> Decision {
        guard active.identifier != current.identifier else { return .none }
        return .zoneChanged(from: active, to: current)
    }
}
