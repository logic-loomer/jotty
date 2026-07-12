import Foundation

/// Observes live system-timezone changes and classifies them (roadmap 3.3,
/// design note 2026-07-12). The app's Store/model stack pins the timezone at
/// construction (the pinned-calendar discipline — never `autoupdatingCurrent`,
/// which would flip mid-operation); this monitor is the ONE place a zone change
/// enters, so the app can rebuild deliberately instead of split-braining
/// (capture parsing in the new zone while the store serializes in the old one).
///
/// Classification, not action: the monitor decides what KIND of change happened
/// and hands the decision to the AppDelegate, which owns the rebuild. The
/// rebuild itself must write ZERO bytes — wall-clock tokens on disk are
/// TZ-agnostic by design, and the rollover over-correction taught us that
/// acting automatically on re-anchored data destroys it. Only an explicit user
/// choice (the one-shot bulk drift prompt) may write.
final class TimeZoneMonitor {
    enum Decision: Equatable {
        /// Spurious notification — same zone identifier. DST transitions land
        /// here by construction (they change the offset, not the identifier,
        /// and fire no zone-change notification anyway).
        case none
        /// Identifier changed but the current offset is identical
        /// (Melbourne → Sydney): rebuild the pinned stack silently — no
        /// instant moved, so no prompt.
        case silentRebuild
        /// The offset moved (real travel): rebuild AND surface the one-shot
        /// bulk drift prompt. `offsetDelta` = new − old in seconds at the
        /// moment of change — the value `CalendarDrift.partitionForTZShift`
        /// uses to tell TZ-shift drift from genuine user drift.
        case rebuildAndPrompt(offsetDelta: TimeInterval)
    }

    private var observation: NSObjectProtocol?

    /// All dependencies injected — no singletons — so tests drive the monitor by
    /// posting to a private NotificationCenter with swapped closures.
    /// - Parameters:
    ///   - activeTZ: the zone the Store/model stack is currently pinned to.
    ///   - currentTZ: reads the system zone FRESH at notification time
    ///     (`TimeZone.current`; never `autoupdatingCurrent`).
    ///   - now: injected clock (offset comparison is instant-dependent).
    ///   - onChange: receives every non-`.none` decision.
    init(notificationCenter: NotificationCenter = .default,
         activeTZ: @escaping () -> TimeZone,
         currentTZ: @escaping () -> TimeZone,
         now: @escaping () -> Date = Date.init,
         onChange: @escaping (Decision) -> Void) {
        observation = notificationCenter.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { _ in
            let decision = Self.decision(active: activeTZ(), current: currentTZ(), at: now())
            guard decision != .none else { return }
            onChange(decision)
        }
    }

    deinit {
        if let observation {
            NotificationCenter.default.removeObserver(observation)
        }
    }

    /// Pure classification — see `Decision` for the three outcomes.
    static func decision(active: TimeZone, current: TimeZone, at now: Date) -> Decision {
        guard active.identifier != current.identifier else { return .none }
        let delta = TimeInterval(current.secondsFromGMT(for: now) - active.secondsFromGMT(for: now))
        return delta == 0 ? .silentRebuild : .rebuildAndPrompt(offsetDelta: delta)
    }
}
