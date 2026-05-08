import SwiftUI
import Combine
import Foundation

// MARK: - CaptureState

enum CaptureState: Equatable {
    case input
    case review(tasks: [ExtractedTask], noteBody: String, savedInput: String)
}

// MARK: - ViewModel

@MainActor
final class CaptureViewModel: ObservableObject {
    @Published var text: String = "" {
        didSet { scheduleAutosave() }
    }
    @Published var state: CaptureState = .input
    /// Indices of rows the user has left checked. All rows checked by default on enterReview.
    @Published var acceptedRowIDs: Set<Int> = []
    @Published var isExtracting: Bool = false
    @Published var lastError: AIProviderError?

    private let store: Store
    private let draftURL: URL
    private let provider: any AIProvider
    private let clock: () -> Date
    private var autosaveTask: Task<Void, Never>?
    private var extractionTask: Task<Void, Never>?

    init(store: Store, draftURL: URL,
         provider: any AIProvider,
         clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.draftURL = draftURL
        self.provider = provider
        self.clock = clock

        // Restore draft if present.
        if let restored = try? String(contentsOf: draftURL, encoding: .utf8) {
            self.text = restored
        }
    }

    // MARK: - Manual syntax detection

    private static let manualTaskRegex = /^\s*[-*]\s\[([ xX])\]\s+(.+)$/

    private func hasManualSyntax(_ s: String) -> Bool {
        s.components(separatedBy: "\n").contains { $0.firstMatch(of: Self.manualTaskRegex) != nil }
    }

    // MARK: - Submit

    func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastError = nil

        if hasManualSyntax(trimmed) {
            // Surface manual-path disk errors via lastError. NEVER try?.
            do {
                try submitManual(trimmed)
            } catch {
                lastError = .underlying(message: error.localizedDescription)
                // Stay in input mode so the user can retry; draft autosave intact.
            }
            return
        }

        // AI path
        isExtracting = true
        extractionTask?.cancel()
        let now = clock()
        let tz = TimeZone.current
        extractionTask = Task { [weak self] in
            guard let self else { return }
            let p = self.provider
            do {
                let result = try await p.extractTasks(from: trimmed, now: now, timezone: tz)
                try Task.checkCancellation()
                await MainActor.run {
                    self.isExtracting = false
                    self.enterReview(tasks: result.tasks, noteBody: result.noteBody)
                }
            } catch is CancellationError {
                return
            } catch let e as AIProviderError {
                await MainActor.run {
                    self.isExtracting = false
                    self.lastError = e
                    // Degraded review state: zero tasks, raw capture as note body.
                    self.enterReview(tasks: [], noteBody: trimmed)
                }
            } catch {
                await MainActor.run {
                    self.isExtracting = false
                    self.lastError = .underlying(message: error.localizedDescription)
                    self.enterReview(tasks: [], noteBody: trimmed)
                }
            }
        }
    }

    /// Awaits in-flight extraction; for tests only.
    func submitAndWait() async {
        submit()
        if let t = extractionTask { _ = await t.value }
    }

    // MARK: - Manual path

    private func submitManual(_ input: String) throws {
        let now = clock()
        var noteLines: [String] = []
        var tasks: [Todo] = []
        let taskRegex = /^\s*[-*]\s\[([ xX])\]\s+(.+)$/

        for line in input.components(separatedBy: "\n") {
            if let match = line.firstMatch(of: taskRegex) {
                let done = match.1 != " "
                let title = String(match.2).trimmingCharacters(in: .whitespaces)
                let id = "t_" + String(UUID().uuidString.prefix(8)).lowercased()
                tasks.append(Todo(id: id, text: title, createdAt: now,
                                  done: done,
                                  completedAt: done ? now : nil))
            } else {
                noteLines.append(line)
            }
        }

        let noteBody = noteLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let noteId = noteBody.isEmpty ? nil : "n_" + String(UUID().uuidString.prefix(8)).lowercased()

        try store.appendCapture(noteText: noteBody, noteId: noteId, tasks: tasks, at: now)

        text = ""
        autosaveTask?.cancel()
        try? FileManager.default.removeItem(at: draftURL)
    }

    func cancel() {
        // Draft is already on disk; do nothing else.
    }

    // MARK: - Plan 06: Review state machine

    func enterReview(tasks: [ExtractedTask], noteBody: String) {
        let saved = self.text
        self.state = .review(tasks: tasks, noteBody: noteBody, savedInput: saved)
        self.acceptedRowIDs = Set(tasks.indices)   // all checked by default
    }

    func toggleRow(_ index: Int) {
        if acceptedRowIDs.contains(index) {
            acceptedRowIDs.remove(index)
        } else {
            acceptedRowIDs.insert(index)
        }
    }

    func returnToInput() {
        if case .review(_, _, let saved) = state {
            self.text = saved
        }
        self.state = .input
    }

    func commitFromReview() {
        guard case .review(let tasks, let noteBody, _) = state else { return }
        let now = clock()
        let accepted = acceptedRowIDs.sorted().compactMap { tasks.indices.contains($0) ? tasks[$0] : nil }

        let noteId: String? = noteBody.isEmpty
            ? nil
            : "n_" + String(UUID().uuidString.prefix(8)).lowercased()

        let todos: [Todo] = accepted.map { t in
            Todo(
                id: "t_" + String(UUID().uuidString.prefix(8)).lowercased(),
                text: t.title,
                createdAt: now,
                done: false,
                dueDate: t.dueDate,
                sourceNote: noteId
            )
        }

        do {
            try store.appendCapture(noteText: noteBody, noteId: noteId, tasks: todos, at: now)
        } catch {
            // Keep the user in review with their accepted rows so they can retry.
            lastError = .underlying(message: error.localizedDescription)
            return
        }

        text = ""
        autosaveTask?.cancel()
        try? FileManager.default.removeItem(at: draftURL)   // best-effort cleanup; not user-visible
        state = .input
        acceptedRowIDs = []
    }

    // MARK: - Private

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
