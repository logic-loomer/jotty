import Foundation

/// Static transparency registry of every inbox source the app *plans* to support (SC4).
///
/// Only `github` is built in Phase 7 (`built: true`); the other four are documented
/// extension points (`built: false`) so the Settings privacy/transparency surface can list
/// exactly which third-party endpoints the app talks to — or could be extended to talk to —
/// without anything being hidden. This mirrors the `ProviderEndpoints` idiom (AITab.swift):
/// a flat, audit-friendly list of bare API hosts. Do NOT build the four unbuilt sources here;
/// this enum only declares them.
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

    /// All five planned sources (INBX-01..INBX-05). Order is the transparency-table order.
    static let all: [Entry] = [
        Entry(id: "github", name: "GitHub", endpoint: "https://api.github.com", built: true),
        Entry(id: "gmail", name: "Gmail", endpoint: "https://gmail.googleapis.com", built: false),
        Entry(id: "slack", name: "Slack", endpoint: "https://slack.com/api", built: false),
        Entry(id: "linear", name: "Linear", endpoint: "https://api.linear.app/graphql", built: false),
        Entry(id: "notion", name: "Notion", endpoint: "https://api.notion.com/v1", built: false),
    ]
}
