// Jotty/AI/ProviderFactory.swift
// The single place that maps a persisted AppConfig.aiProviderID string to a
// constructed `AIProvider` (plan 04-11). AppDelegate calls `make` on every
// capture open so a Settings provider switch takes effect on the NEXT
// extraction without an app restart (ROADMAP Phase 4 success criterion 3).
//
// Construction MUST be cheap and synchronous: no keychain reads, no network.
// Cloud providers receive the shared KeychainAPIKeyStore but defer the G6
// missing-key short-circuit to request time. Unknown / corrupted IDs degrade
// to AppleFMProvider — the on-device default — never crash.

import Foundation

enum ProviderFactory {

    /// Default Ollama model when the user has not picked one (AI-SPEC §1.1).
    static let defaultOllamaModel = "qwen2.5:3b"

    /// Maps `AppConfig.aiProviderID` → concrete provider.
    /// - "apple-fm" → `AppleFMProvider()`
    /// - "ollama"   → `OllamaProvider(model: config.ollamaModel ?? defaultOllamaModel)`
    /// - "claude"   → `ClaudeProvider(keychain:)`
    /// - "openai"   → `OpenAIProvider(keychain:)`
    /// - "gemini"   → `GeminiProvider(keychain:)`
    /// - anything else → `AppleFMProvider()` (defensive default)
    static func make(config: AppConfig,
                     keychain: KeychainAPIKeyStore = KeychainAPIKeyStore()) -> any AIProvider {
        switch config.aiProviderID {
        case "apple-fm":
            return AppleFMProvider()
        case "ollama":
            return OllamaProvider(model: config.ollamaModel ?? defaultOllamaModel)
        case "claude":
            return ClaudeProvider(keychain: keychain)
        case "openai":
            return OpenAIProvider(keychain: keychain)
        case "gemini":
            return GeminiProvider(keychain: keychain)
        default:
            // Corrupted / unknown ID → on-device default, never crash.
            return AppleFMProvider()
        }
    }

    /// True iff the resolved provider for this config is Apple FM (the
    /// "apple-fm" ID and any unknown/empty ID that degrades to it). Drives
    /// the Apple FM prewarm and whether a `fallbackProvider` is needed.
    static func isAppleFM(_ config: AppConfig) -> Bool {
        switch config.aiProviderID {
        case "ollama", "claude", "openai", "gemini":
            return false
        default:
            return true
        }
    }
}
