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
    /// Apple FM fallback for the failure toast (ROADMAP Phase 4 SC4).
    /// nil when the active provider already IS Apple FM — the "Use Apple FM
    /// instead" button hides via `fallbackAvailable`. Production call site
    /// passes an AppleFMProvider in plan 11.
    private let fallbackProvider: (any AIProvider)?
    private let clock: () -> Date
    private var autosaveTask: Task<Void, Never>?
    private var extractionTask: Task<Void, Never>?

    /// The prose that was in-flight when the provider threw, stashed so
    /// retryWithAppleFM() can re-run the SAME input through the fallback.
    private var lastFailedInput: String?
    private var lastFailedManualTasks: [ExtractedTask] = []

    /// True iff a fallback provider is wired — drives the toast button.
    var fallbackAvailable: Bool { fallbackProvider != nil }

    init(store: Store, draftURL: URL,
         provider: any AIProvider,
         fallbackProvider: (any AIProvider)? = nil,
         clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.draftURL = draftURL
        self.provider = provider
        self.fallbackProvider = fallbackProvider
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

        // Per-line routing: extract manual `- [ ] ` lines as ExtractedTask
        // directly (bypass AI); send the remaining prose to the AI provider.
        // The Review state then shows manual + AI tasks combined.
        var manualTasks: [ExtractedTask] = []
        var remainingLines: [String] = []
        for line in trimmed.components(separatedBy: "\n") {
            if let match = line.firstMatch(of: Self.manualTaskRegex) {
                let title = String(match.2).trimmingCharacters(in: .whitespaces)
                manualTasks.append(ExtractedTask(title: title))
            } else {
                remainingLines.append(line)
            }
        }
        let remainingText = remainingLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Pure-manual capture (no prose to extract from): commit directly,
        // skipping the Review state. Fast path for typed checklists.
        if !manualTasks.isEmpty && remainingText.isEmpty {
            do {
                try submitManual(trimmed)
            } catch {
                lastError = .underlying(message: error.localizedDescription)
            }
            return
        }

        // Mixed or pure-prose capture: send remaining text to AI, combine
        // any manual tasks into the Review state.
        isExtracting = true
        extractionTask?.cancel()
        let now = clock()
        let tz = TimeZone.current
        let manualTasksCopy = manualTasks
        let remainingTextCopy = remainingText
        extractionTask = Task { [weak self] in
            guard let self else { return }
            let p = self.provider
            do {
                let aiResult = remainingTextCopy.isEmpty
                    ? ExtractionResult(tasks: [], noteBody: "")
                    : try await p.extractTasks(from: remainingTextCopy, now: now, timezone: tz)
                try Task.checkCancellation()
                await MainActor.run {
                    self.isExtracting = false
                    self.lastError = nil   // success — clear any stale error from a prior attempt
                    self.enterReview(tasks: manualTasksCopy + aiResult.tasks,
                                     noteBody: aiResult.noteBody)
                }
            } catch is CancellationError {
                return
            } catch let e as AIProviderError {
                await MainActor.run {
                    self.isExtracting = false
                    self.lastError = e
                    // Stash the failed input so retryWithAppleFM can re-run it.
                    self.lastFailedInput = remainingTextCopy
                    self.lastFailedManualTasks = manualTasksCopy
                    // Degraded review: keep manual tasks, raw remaining text as note body.
                    self.enterReview(tasks: manualTasksCopy, noteBody: remainingTextCopy)
                }
            } catch {
                await MainActor.run {
                    self.isExtracting = false
                    self.lastError = .underlying(message: error.localizedDescription)
                    self.lastFailedInput = remainingTextCopy
                    self.lastFailedManualTasks = manualTasksCopy
                    self.enterReview(tasks: manualTasksCopy, noteBody: remainingTextCopy)
                }
            }
        }
    }

    /// Awaits in-flight extraction; for tests only.
    func submitAndWait() async {
        submit()
        if let t = extractionTask { _ = await t.value }
    }

    // MARK: - Apple FM fallback (plan 04-10, ROADMAP Phase 4 SC4)

    /// Re-runs the last failed input through the injected fallback provider
    /// (Apple FM in production). On success the Review state rebuilds with
    /// the fallback's tasks and `lastError` clears; on failure `lastError`
    /// updates to the new error and nothing else changes. No-op when no
    /// fallback is wired or nothing has failed.
    func retryWithAppleFM() async {
        // Re-entry guard (MIN-04): a double-tap on "Use Apple FM instead" must
        // not launch two overlapping extractions that both mutate
        // isExtracting/state. No fallback wired or nothing failed → no-op.
        guard !isExtracting,
              let fallback = fallbackProvider,
              let failedInput = lastFailedInput else { return }

        isExtracting = true
        let now = clock()
        let tz = TimeZone.current
        do {
            let result = failedInput.isEmpty
                ? ExtractionResult(tasks: [], noteBody: "")
                : try await fallback.extractTasks(from: failedInput, now: now, timezone: tz)
            isExtracting = false
            lastError = nil
            enterReview(tasks: lastFailedManualTasks + result.tasks,
                        noteBody: result.noteBody)
            lastFailedInput = nil
            lastFailedManualTasks = []
        } catch let e as AIProviderError {
            isExtracting = false
            lastError = e
        } catch {
            isExtracting = false
            lastError = .underlying(message: error.localizedDescription)
        }
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
