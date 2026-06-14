import Foundation

/// The single seam through which the app and tests touch an external inbox source.
///
/// Each concrete source (e.g. `GitHubInboxSource`, plan 07-03) owns its own credential
/// and networking; tests inject `FakeInboxSource`, so the suite never makes a network call.
/// The protocol is `Sendable` so it can be injected as a dependency under Swift 6, mirroring
/// `CalendarService`. NO concrete implementation lives here.
protocol InboxSource: Sendable {
    /// Stable source id (e.g. `github`); the `sourceID` half of every `InboxItem.id` it emits.
    var id: String { get }
    /// Human-facing source name for the UI (e.g. `GitHub`).
    var displayName: String { get }
    /// Bare API host for the SC4 transparency list (e.g. `https://api.github.com`),
    /// mirroring `ProviderEndpoints`. This is a documented-disclosure string, not a live URL.
    var endpointURL: String { get }
    /// True when the source has the credential it needs to fetch (e.g. a PAT is present).
    /// A source that is not configured must NOT make a network call on `fetchItems()`.
    var isConfigured: Bool { get }
    /// Fetches the current inbox items. Throws on transport/credential failure; callers
    /// (InboxService, plan 07-02) fan out tolerantly so one failing source never blocks others.
    func fetchItems() async throws -> [InboxItem]
}
