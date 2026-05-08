import SwiftUI

struct StorageTab: View {
    let configStore: ConfigStore
    @State private var folder: URL

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
            try? configStore.update { $0.storageFolder = url }
            folder = url
        }
    }
}
