import SwiftUI

struct StorageTab: View {
    let configStore: ConfigStore
    @State private var folder: URL
    /// CQ-01: set when a config write fails; drives the shared PersistFailureNotice.
    @State private var persistFailed = false

    init(configStore: ConfigStore) {
        self.configStore = configStore
        _folder = State(initialValue: configStore.config.storageFolder)
    }

    var body: some View {
        Form {
            HStack {
                Text("Daily files folder:")
                Text(folder.path).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") { pickFolder() }
            }
            PersistFailureNotice(visible: persistFailed)
        }
        .padding(20)
        .frame(width: 520, height: 120)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
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
