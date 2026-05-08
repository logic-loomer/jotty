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

    // MARK: - Phase 2: manual regex parse (KEEP — AI fallback path, plan 08 adds AI on top)

    func submit() throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let now = clock()
        var noteLines: [String] = []
        var tasks: [Todo] = []
        // Allow optional leading whitespace and `* ` as alternate bullet, so
        // copy-pasted markdown still parses as tasks.
        let taskRegex = /^\s*[-*]\s\[([ xX])\]\s+(.+)$/

        for line in trimmed.components(separatedBy: "\n") {
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

        try store.appendCapture(noteText: noteBody, noteId: noteId,
                                tasks: tasks, at: now)

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

    /// TEMP for plan 06 smoke — prints accepted tasks to console. Plan 08 wires real commit via Store.
    func commitFromReview() {
        if case .review(let tasks, let noteBody, _) = state {
            let accepted = acceptedRowIDs.sorted().compactMap { tasks.indices.contains($0) ? tasks[$0] : nil }
            NSLog("[Jotty][03-06 smoke] commit \(accepted.count) tasks; noteBody=\(noteBody.prefix(50))")
            self.text = ""
            self.state = .input
            autosaveTask?.cancel()
            try? FileManager.default.removeItem(at: draftURL)
        }
    }

    // MARK: - Plan 06: Dev stub (plan 08 deletes this method)

    /// Injects fake ExtractedTasks and transitions to review. Only used behind JOTTY_FORCE_REVIEW=1.
    func devForceReviewWithStubTasks() {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: clock())!
        let startOfBlock = cal.date(bySettingHour: 13, minute: 0, second: 0, of: clock())!
        let endOfBlock = cal.date(bySettingHour: 14, minute: 30, second: 0, of: clock())!
        let stub: [ExtractedTask] = [
            ExtractedTask(title: "email Jamie re Q2 plan"),
            ExtractedTask(title: "laptop setup",
                          timeBlock: TimeBlock(start: startOfBlock, end: endOfBlock),
                          calendarBlock: true),
            ExtractedTask(title: "domain renewal", dueDate: tomorrow),
        ]
        enterReview(tasks: stub, noteBody: text)
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
