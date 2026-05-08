import SwiftUI
import Combine

@MainActor
final class CaptureViewModel: ObservableObject {
    @Published var text: String = "" {
        didSet { scheduleAutosave() }
    }

    private let store: Store
    private let draftURL: URL
    private let clock: () -> Date
    private var autosaveTask: Task<Void, Never>?

    init(store: Store, draftURL: URL, clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.draftURL = draftURL
        self.clock = clock

        // Restore draft if present.
        if let restored = try? String(contentsOf: draftURL, encoding: .utf8) {
            self.text = restored
        }
    }

    func submit() throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let id = "n_" + String(UUID().uuidString.prefix(8)).lowercased()
        try store.appendNote(text: trimmed, at: clock(), id: id)

        text = ""
        autosaveTask?.cancel()
        try? FileManager.default.removeItem(at: draftURL)
    }

    func cancel() {
        // Draft is already on disk; do nothing else.
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let snapshot = text
        let url = draftURL
        autosaveTask = Task {
            do {
                try await Task.sleep(nanoseconds: 30_000_000)   // 30ms debounce
            } catch {
                return   // cancelled — do not write
            }
            try? snapshot.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
