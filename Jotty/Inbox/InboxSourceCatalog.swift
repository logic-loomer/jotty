import Foundation

/// Static transparency registry of every inbox source the app *plans* to support (SC4).
///
/// `github` (network) and the on-device `calendar` source are built (`built: true`); the other
/// four network sources are documented extension points (`built: false`) so the Settings
/// privacy/transparency surface can list exactly which endpoints the app talks to — or could be
/// extended to talk to — without anything being hidden. `calendar` reads local EventKit and
/// talks to no network host, so its endpoint is an honest on-device disclosure string, not a URL.
/// This mirrors the `ProviderEndpoints` idiom (AITab.swift): a flat, audit-friendly list. Do NOT
/// build the four unbuilt sources here; this enum only declares them.
enum InboxSourceCatalog {
    /// One planned source's transparency record.
    struct Entry: Equatable {
        /// Stable source id; matches `InboxSource.id` for built sources.
        let id: String
        /// Human-facing name for the transparency table.
        let name: String
        /// Bare API host the source talks to (disclosure only).
        let endpoint: String
        /// True when a concrete `InboxSource` exists for this entry in the shipped app.
        let built: Bool
    }

    /// The six planned sources: the five network sources (INBX-01..INBX-05) plus the on-device
    /// `calendar` source (EventKit, no network host). Order is the transparency-table order.
    static let all: [Entry] = [
        Entry(id: "github", name: "GitHub", endpoint: "https://api.github.com", built: true),
        Entry(id: "calendar", name: "Calendar", endpoint: "On-device (EventKit, no network)", built: true),
        Entry(id: "gmail", name: "Gmail", endpoint: "https://gmail.googleapis.com", built: false),
        Entry(id: "slack", name: "Slack", endpoint: "https://slack.com/api", built: false),
        Entry(id: "linear", name: "Linear", endpoint: "https://api.linear.app/graphql", built: false),
        Entry(id: "notion", name: "Notion", endpoint: "https://api.notion.com/v1", built: false),
    ]
}
