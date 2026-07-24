import Foundation
import OSLog
import Security

// =============================================================================
// MobileSSHKeyStore — Keychain store for SSH tunnel private-key material (iOS).
//
// The tunnel's SSH password and key passphrase reuse the shared
// `KeychainManager` (`.sshPassword` / `.sshKeyPassphrase`), but the private-key
// PEM has no matching `FfiCredentialKind`, so it lives in its own
// generic-password item here, keyed by the SSH endpoint's `user@host:port`.
//
// Key material belongs in the Keychain — never a plaintext file at rest — so
// the resolver only ever materializes it to a short-lived, file-protected temp
// file at connect time (see SSHTunnelResolverMobile.swift).
// =============================================================================
enum MobileSSHKeyStore {
    private static let service = "com.mc-ssh.tunnel-ssh-key"
    /// Passphrases for identity keys live here rather than in `KeychainManager`
    /// so they share the key's `AfterFirstUnlock` accessibility. The shared
    /// manager stores secrets `WhenUnlocked`, which would make the passphrase
    /// unreadable during a locked-device background connect while the key
    /// itself still loaded — an encrypted key silently opened as unencrypted.
    private static let passphraseService = "com.mc-ssh.tunnel-ssh-key-passphrase"
    private static let logger = Logger(subsystem: "com.mc-ssh", category: "mobile-ssh-key-store")

    private static func baseQuery(account: String, service: String = service) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Store (or replace) the private key PEM for an SSH endpoint account.
    @discardableResult
    static func save(pem: String, account: String) -> Bool {
        guard let data = pem.data(using: .utf8) else { return false }
        // Replace-by-delete keeps the item single-valued; ignore not-found.
        SecItemDelete(baseQuery(account: account) as CFDictionary)

        var add = baseQuery(account: account)
        add[kSecValueData as String] = data
        // Device-only: an SSH private key must never leave the device via
        // iCloud Keychain. Readable after first unlock so a foregrounded
        // connect works without re-auth.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("SSH key keychain add failed: \(status, privacy: .public)")
            return false
        }
        return true
    }

    /// Load the stored PEM for an account, or nil if none is saved.
    static func load(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether a key is stored for the account — for the edit form to show
    /// "key saved" without reading the secret back.
    static func has(account: String) -> Bool {
        SecItemCopyMatching(baseQuery(account: account) as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Key passphrase (identity keys)

    @discardableResult
    static func savePassphrase(_ passphrase: String, account: String) -> Bool {
        guard let data = passphrase.data(using: .utf8) else { return false }
        SecItemDelete(baseQuery(account: account, service: passphraseService) as CFDictionary)

        var add = baseQuery(account: account, service: passphraseService)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("SSH key passphrase keychain add failed: \(status, privacy: .public)")
            return false
        }
        return true
    }

    static func loadPassphrase(account: String) -> String? {
        var query = baseQuery(account: account, service: passphraseService)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func deletePassphrase(account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account, service: passphraseService) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
