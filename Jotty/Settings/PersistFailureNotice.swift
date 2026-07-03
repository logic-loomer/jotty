// Jotty/Settings/PersistFailureNotice.swift
// Shared inline notice for settings persistence failures (CQ-01, plan 07.1-08).
//
// Every Settings tab wraps its ConfigStore / KeybindingsStore writes in a
// `persist {}`-style do/catch that flips a `persistFailed` flag instead of
// swallowing the error with `try?` (RESEARCH Pattern 6). This view renders the
// shared failure copy when that flag is set — errors never propagate into view
// bodies (Pitfall 11), and the copy is a fixed string only: never interpolate
// error.localizedDescription, file contents, or key material (T-07.1-16).

import SwiftUI

/// Inline red notice shown when a settings write fails to persist.
/// Rendered by each Settings tab, gated on that tab's `persistFailed` flag.
struct PersistFailureNotice: View {
    /// True when the owning tab's most recent persistence attempt failed.
    let visible: Bool

    var body: some View {
        if visible {
            Text("Couldn't save this setting — it may revert on next launch. Check that ~/Library/Application Support/Jotty is writable.")
                .font(.callout)          // A11Y-02: semantic text style, no fixed point size
                .foregroundStyle(.red)
        }
    }
}
