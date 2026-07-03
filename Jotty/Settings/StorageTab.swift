// Jotty/Settings/StorageTab.swift
// Settings → Storage (UX-09, plan 07.1-08): the daily-files folder picker,
// aligned to the grouped-Form 560x640 idiom every other tab uses.
//
// - Folder picks are validated with FileManager.isWritableFile BEFORE
//   persisting: a non-writable folder is rejected with an inline red notice
//   and the stored folder is left untouched (no test-write-then-delete dance).
// - Persistence goes through the CQ-01 persist{} wrapper so a failed config
//   write surfaces via the shared PersistFailureNotice instead of silently
//   reverting on next launch.

import SwiftUI

struct StorageTab: View {
    let configStore: ConfigStore
    @State private var folder: URL
    /// CQ-01: set when a config write fails; drives the shared PersistFailureNotice.
    @State private var persistFailed = false
    /// UX-09: set when the picked folder is not writable; drives the inline notice.
    @State private var folderNotWritable = false

    init(configStore: ConfigStore) {
        self.configStore = configStore
        _folder = State(initialValue: configStore.config.storageFolder)
    }

    var body: some View {
        Form {
            Section(header: Text("Daily files")) {
                HStack {
                    Text("Folder")
                    Spacer()
                    Text(folder.path)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Choose…") { pickFolder() }
                }

                if folderNotWritable {
                    Text("Jotty can't write to that folder — choose another.")
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                Text("Jotty keeps one markdown file per day in this folder.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                PersistFailureNotice(visible: persistFailed)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 640)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            // UX-09: validate BEFORE persisting — a non-writable pick is rejected
            // outright and the stored folder stays as it was.
            guard FileManager.default.isWritableFile(atPath: url.path) else {
                folderNotWritable = true
                return
            }
            folderNotWritable = false
            persist { $0.storageFolder = url }
            folder = url
        }
    }

    /// CQ-01 (RESEARCH Pattern 6): wrap config writes in do/catch — success clears
    /// the failure flag, failure sets it. Errors never escape into the view body.
    private func persist(_ mutate: (inout AppConfig) -> Void) {
        do {
            try configStore.update(mutate)
            persistFailed = false
        } catch {
            persistFailed = true
        }
    }
}
