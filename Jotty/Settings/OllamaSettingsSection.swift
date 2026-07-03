// Jotty/Settings/OllamaSettingsSection.swift
// Settings → AI → Ollama: install / daemon / model-management UX driven by
// OllamaInstaller's state machine (AI-SPEC §5.1–§5.4) and OllamaModelManager
// for pull / list / delete. Selecting a model persists the non-secret
// `ollamaModel` field via ConfigStore.

import AppKit
import SwiftUI

struct OllamaSettingsSection: View {
    let configStore: ConfigStore

    @StateObject var installer = OllamaInstaller.shared
    @State private var models: [InstalledModel] = []
    @State private var selectedModel: String?
    /// CQ-01: set when a config write fails; drives the shared PersistFailureNotice.
    @State private var persistFailed = false

    /// Wraps `installer.install()` so the Cancel button can tear the
    /// download down (URLSession bytes loop throws on task cancellation).
    @State private var installTask: Task<Void, Never>?

    // In-flight pull UI state (one visible pull at a time).
    @State private var pullingModel: String?
    @State private var pullFraction: Double?
    @State private var pullStatus: String = ""
    @State private var pullError: String?

    // "Add model…" entry points (§5.2 step 6).
    @State private var advancedModelName: String = ""

    private static let curatedModels = ["qwen2.5:3b", "llama3.2:3b", "phi3.5:3.8b"]
    /// Approximate weights size per curated model — feeds the §3.5
    /// disk-space precheck before /api/pull is issued.
    private static let curatedSizes: [String: Int64] = [
        "qwen2.5:3b": 1_900_000_000,
        "llama3.2:3b": 2_000_000_000,
        "phi3.5:3.8b": 2_200_000_000,
    ]

    var body: some View {
        Section("Ollama") {
            switch installer.state {
            case .checking:
                ProgressView("Checking…")

            case .notInstalled:
                notInstalledRow

            case .downloading(let p):
                downloadingRow(progress: p)

            case .extracting:
                ProgressView("Verifying signature…")

            case .installed(false):
                startDaemonRow

            case .starting:
                ProgressView("Starting Ollama…")

            case .installed(true):
                modelPicker

            case .failed(let err):
                failureRow(err)
            }
        }
        .task {
            selectedModel = configStore.config.ollamaModel
            await installer.bootstrap()
        }
    }

    // MARK: - notInstalled (§5.2 step 1)

    private var notInstalledRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ollama — not installed").font(.body.weight(.medium))
            Text("~250 MB. Runs locally on your Mac.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Download Ollama") {
                installTask = Task { await installer.install() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - downloading (§5.2 step 2)

    private func downloadingRow(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: progress) {
                Text("Downloading Ollama… \(Int(progress * 100))%")
                    .font(.callout)
            }
            Button("Cancel") {
                installTask?.cancel()
                installTask = nil
            }
        }
    }

    // MARK: - installed, daemon off (§5.2 step 4 / §5.3)

    private var startDaemonRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ollama installed. Daemon stopped.")
                .font(.body.weight(.medium))
            installSourceBadge
            Button("Start Ollama") {
                Task { await installer.startDaemon() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// §5.3: never show "Reveal in Finder" for a system install; show the
    /// Homebrew badge instead so the user knows which binary Jotty uses.
    @ViewBuilder
    private var installSourceBadge: some View {
        switch OllamaBinaryLocator.locate() {
        case .jottyManaged:
            Button("Reveal in Finder") {
                let dir = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Jotty/ollama", isDirectory: true)
                NSWorkspace.shared.activateFileViewerSelecting([dir])
            }
            .buttonStyle(.link)
            .font(.subheadline)
        case .systemHomebrew(let url):
            Text("Using Ollama from \(url.path)")
                .font(.subheadline).foregroundStyle(.secondary)
        case .appBundle(let url):
            Text("Using Ollama from \(url.path)")
                .font(.subheadline).foregroundStyle(.secondary)
        case .notFound:
            EmptyView()
        }
    }

    // MARK: - installed, daemon running → model picker (§5.2 step 6–7)

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Daemon ready", systemImage: "circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                Spacer()
                Button("Stop Ollama") { installer.stopDaemon() }
                    .font(.subheadline)
            }

            if models.isEmpty {
                Text("No models installed yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            ForEach(models) { model in
                HStack(spacing: 8) {
                    Button {
                        selectedModel = model.name
                        persist { $0.ollamaModel = model.name }
                    } label: {
                        Image(systemName: selectedModel == model.name
                              ? "largecircle.fill.circle" : "circle")
                    }
                    .buttonStyle(.plain)
                    Text(model.name).font(.system(.callout, design: .monospaced))
                    Text(ByteCountFormatter.string(fromByteCount: model.size,
                                                   countStyle: .file))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete") {
                        Task {
                            try? await OllamaModelManager.shared.delete(model: model.name)
                            if selectedModel == model.name {
                                selectedModel = nil
                                persist { $0.ollamaModel = nil }
                            }
                            await refreshModels()
                        }
                    }
                    .font(.subheadline)
                }
            }

            if let pulling = pullingModel {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: pullFraction ?? 0) {
                        Text("Pulling \(pulling)… \(pullStatus)")
                            .font(.subheadline)
                    }
                    Button("Cancel") {
                        Task { await OllamaModelManager.shared.cancelPull(model: pulling) }
                    }
                    .font(.subheadline)
                }
            } else {
                addModelControls
            }

            if let pullError {
                Text(pullError).font(.subheadline).foregroundStyle(.red)
            }

            PersistFailureNotice(visible: persistFailed)
        }
        .task { await refreshModels() }
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

    private var addModelControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu("Add model…") {
                ForEach(Self.curatedModels, id: \.self) { name in
                    Button(name) { startPull(name) }
                }
            }
            .frame(width: 160)
            HStack(spacing: 8) {
                TextField("Advanced: any ollama.com model tag",
                          text: $advancedModelName)
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
                Button("Pull") {
                    let name = advancedModelName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    startPull(name)
                }
                .disabled(advancedModelName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - failed

    private func failureRow(_ err: OllamaError) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(err.errorDescription ?? "Ollama failed.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
            Button("Retry") {
                Task { await installer.bootstrap() }
            }
        }
    }

    // MARK: - Helpers

    private func startPull(_ name: String) {
        pullingModel = name
        pullFraction = nil
        pullStatus = ""
        pullError = nil
        Task {
            do {
                try await OllamaModelManager.shared.pull(
                    model: name,
                    expectedBytes: Self.curatedSizes[name]
                ) { update in
                    pullStatus = update.status
                    if let fraction = update.fraction { pullFraction = fraction }
                }
                advancedModelName = ""
            } catch is CancellationError {
                // §5.2 step 7: partial layers stay on disk; daemon resumes later.
            } catch let error as OllamaError {
                pullError = error.errorDescription
            } catch {
                pullError = "Model download failed."
            }
            pullingModel = nil
            pullFraction = nil
            await refreshModels()
        }
    }

    @MainActor
    private func refreshModels() async {
        models = (try? await OllamaModelManager.shared.list()) ?? []
    }
}
