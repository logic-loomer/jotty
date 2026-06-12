// Jotty/AI/KeychainAPIKeyStore.swift
// The single seam through which cloud-provider API keys enter or leave the app.
// Per AI-SPEC §1.2 / §1.3 / §1.4 the macOS Keychain is the canonical store for
// Claude / OpenAI / Gemini keys (REQ-privacy-default: never on disk in plaintext).
//
// Account name conventions used by callers (plans 04-06, 10):
//   "claude" — Anthropic API key
//   "openai" — OpenAI API key
//   "gemini" — Google Gemini API key

import Foundation
import Security

enum KeychainAPIKeyStoreError: Error, Equatable {
    case unhandledStatus(OSStatus)
    case stringEncoding
}

/// Thin wrapper around `kSecClassGenericPassword` items, scoped to the Jotty
/// bundle, NOT synced to iCloud. Synchronous — safe to call from the MainActor;
/// generic-password items never trigger Keychain UI prompts for the owning app.
struct KeychainAPIKeyStore: Sendable {

    private let service: String

    init(service: String = "com.jotty.api-keys") {
        self.service = service
    }

    /// Returns nil if no item exists for `account`. Throws on unexpected
    /// OSStatus values (e.g. errSecInteractionNotAllowed in background).
    func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            guard let data = result as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                throw KeychainAPIKeyStoreError.stringEncoding
            }
            return string
        default:
            throw KeychainAPIKeyStoreError.unhandledStatus(status)
        }
    }

    /// Idempotent write. If an item exists for `account`, value is replaced.
    func write(account: String, key: String) throws {
        guard let data = key.data(using: .utf8) else {
            throw KeychainAPIKeyStoreError.stringEncoding
        }

        // Try update first (existing item), fall through to add.
        let query = baseQuery(account: account)
        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            attributesToUpdate as CFDictionary
        )

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery(account: account)
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            addQuery[kSecAttrSynchronizable as String] = kCFBooleanFalse!
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainAPIKeyStoreError.unhandledStatus(addStatus)
            }
        default:
            throw KeychainAPIKeyStoreError.unhandledStatus(updateStatus)
        }
    }

    /// No-op if no item exists for `account` (idempotent).
    func delete(account: String) throws {
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainAPIKeyStoreError.unhandledStatus(status)
        }
    }

    // MARK: - Private

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
