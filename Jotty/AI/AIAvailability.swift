// Jotty/AI/AIAvailability.swift
import Foundation
import FoundationModels

/// UI-facing wrapper over `SystemLanguageModel.default.availability`. Settings
/// and Capture switch on this so they never import FoundationModels directly.
enum AIAvailability: Equatable {
    case available
    case unavailable(reason: String)
    case downloading

    /// Snapshot the current Apple FM availability. Pure read — safe to call
    /// from `@MainActor` for UI display.
    static func current() -> AIAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.modelNotReady):
            // modelNotReady covers both downloading and other transient states.
            // Surface as .downloading so the UI can show a progress indicator.
            return .downloading
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(reason: "Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri.")
        case .unavailable(.deviceNotEligible):
            return .unavailable(reason: "This device does not support Apple Intelligence.")
        case .unavailable(let other):
            return .unavailable(reason: "Model unavailable: \(other).")
        }
    }
}
