// Jotty/AI/Ollama/OllamaError.swift
// Canonical error type for the Ollama runtime lifecycle (AI-SPEC §4.4).
// Covers binary acquisition (download/extract/verify), daemon supervision,
// and model management (pull/delete — used by plan 08's OllamaModelManager).

import Foundation

enum OllamaError: LocalizedError, Equatable {
    case notInstalled
    case downloadFailed(underlying: String)
    case extractFailed
    case signatureInvalid
    case binaryNotFound
    case daemonStartupTimeout
    case daemonCrashed(exitCode: Int32)
    case portInUse(port: Int)
    case insufficientSpace(needed: Int64, available: Int64)
    case modelNotFound(String)
    case pullFailed(status: Int)
    case deleteFailed

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Ollama is not installed. Download it from Settings → AI."
        case .downloadFailed(let underlying):
            return "Couldn't download Ollama: \(underlying)"
        case .extractFailed:
            return "Download failed integrity check while extracting."
        case .signatureInvalid:
            return "Couldn't verify Ollama's code signature. Refusing to launch."
        case .binaryNotFound:
            return "Couldn't find the Ollama binary on this Mac."
        case .daemonStartupTimeout:
            return "Ollama didn't start within 10 seconds. "
                + "See ~/Library/Application Support/Jotty/ollama/daemon.log"
        case .daemonCrashed(let exitCode):
            return "Ollama stopped unexpectedly (exit code \(exitCode))."
        case .portInUse(let port):
            return "Port \(port) is in use by another app."
        case .insufficientSpace(let needed, let available):
            let fmt = ByteCountFormatter()
            return "Not enough disk space: need \(fmt.string(fromByteCount: needed)), "
                + "have \(fmt.string(fromByteCount: available))."
        case .modelNotFound(let name):
            return "No model named \"\(name)\" on ollama.com/library."
        case .pullFailed(let status):
            return "Model download failed (HTTP \(status))."
        case .deleteFailed:
            return "Couldn't delete the model."
        }
    }

    /// Maps an arbitrary error to an OllamaError, preserving OllamaError
    /// values as-is. Used by OllamaInstaller's catch-all error paths.
    init(from error: Error) {
        if let ollama = error as? OllamaError {
            self = ollama
        } else if let urlError = error as? URLError {
            self = .downloadFailed(underlying: urlError.localizedDescription)
        } else {
            // String(describing:) of a Swift error can leak internal type /
            // case detail (and, for some Foundation errors, file paths) into
            // the Settings failure row. Prefer the user-facing localized
            // description (MIN-05).
            self = .downloadFailed(underlying: error.localizedDescription)
        }
    }
}
