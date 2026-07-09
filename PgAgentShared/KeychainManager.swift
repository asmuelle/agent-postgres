#if os(macOS)
import AppKit
#endif
import Foundation
import OSLog
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif
import Security

/// Wraps the keychain access for Swift.
/// - On macOS: Uses `rshell_keychain_*` from the uniffi bindings (macOS Keychain via Rust core).
/// - On iOS: Uses native iOS Security framework.
/// - Synchronizable (iCloud Keychain) items use the native Security framework
///   on BOTH platforms — the Rust core has no synchronizable concept.
@MainActor
class KeychainManager {
    static let shared = KeychainManager()
    private let logger = Logger(subsystem: "com.mc-ssh", category: "keychain")

    private init() {}

    var isAvailable: Bool {
        #if os(macOS)
        return rshellKeychainIsSupported()
        #else
        return true
        #endif
    }

    // MARK: - Save

    @discardableResult
    func savePassword(kind: FfiCredentialKind, account: String, secret: String) -> Bool {
        #if os(macOS)
        let result = rshellKeychainSave(kind: kind, account: account, secret: secret)
        if !result.success {
            logger.error("keychain save failed: \(result.error ?? "?", privacy: .public)")
        }
        return result.success
        #else
        guard let data = secret.data(using: .utf8) else { return false }
        let query = baseQuery(kind: kind, account: account)
        let update: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            return false
        }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        return status == errSecSuccess
        #endif
    }

    // MARK: - Load

    /// Load a secret, preferring the device-local store, falling back to the
    /// synchronizable (iCloud Keychain) store — so connect flows work no
    /// matter which store the password lives in.
    func loadPassword(kind: FfiCredentialKind, account: String) -> String? {
        loadLocalPassword(kind: kind, account: account)
            ?? loadSynchronizablePassword(kind: kind, account: account)
    }

    private func loadLocalPassword(kind: FfiCredentialKind, account: String) -> String? {
        #if os(macOS)
        let result = rshellKeychainLoad(kind: kind, account: account)
        if !result.success {
            logger.error("keychain load failed: \(result.error ?? "?", privacy: .public)")
            return nil
        }
        return result.value
        #else
        var query = baseQuery(kind: kind, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #endif
    }

    // MARK: - Delete

    /// Delete a secret from BOTH stores (device-local and synchronizable) so
    /// profile deletion never strands a synced copy.
    @discardableResult
    func deletePassword(kind: FfiCredentialKind, account: String) -> Bool {
        let localOk = deleteLocalPassword(kind: kind, account: account)
        let syncOk = deleteSynchronizablePassword(kind: kind, account: account)
        return localOk && syncOk
    }

    @discardableResult
    private func deleteLocalPassword(kind: FfiCredentialKind, account: String) -> Bool {
        #if os(macOS)
        let result = rshellKeychainDelete(kind: kind, account: account)
        if !result.success {
            logger.error("keychain delete failed: \(result.error ?? "?", privacy: .public)")
        }
        return result.success
        #else
        let status = SecItemDelete(baseQuery(kind: kind, account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
        #endif
    }

    // MARK: - List

    func listAccounts(kind: FfiCredentialKind) -> [String] {
        #if os(macOS)
        return rshellKeychainList(kind: kind)
        #else
        return []
        #endif
    }

    func hasPassword(kind: FfiCredentialKind, account: String) -> Bool {
        if hasSynchronizablePassword(kind: kind, account: account) { return true }
        #if os(macOS)
        return listAccounts(kind: kind).contains(account)
        #else
        var query = baseQuery(kind: kind, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
        #endif
    }

    #if os(iOS)
    private func baseQuery(kind: FfiCredentialKind, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.pgagent.mobile.\(kind.rawValue)",
            kSecAttrAccount as String: account
        ]
    }
    #endif

    // MARK: - Synchronizable variant (iCloud Keychain, opt-in per profile)
    //
    // Tradeoff, deliberately accepted and surfaced in the UI footnote:
    // synchronizable items CANNOT use a ThisDeviceOnly protection class, so
    // these are stored kSecAttrAccessibleWhenUnlocked instead of the
    // WhenUnlockedThisDeviceOnly default used for local items. In exchange
    // the secret follows the user's devices through iCloud Keychain
    // (end-to-end encrypted by Apple) — which is the entire point of the
    // per-connection "Sync password" opt-in. Items sync between devices
    // that share the keychain access group (same app on iPhone/iPad; the
    // Mac build needs a shared access group once it ships with a
    // provisioning profile).

    /// Save, choosing the store. `synchronizable: true` also removes any
    /// device-local copy (and vice versa) so exactly one store holds the
    /// secret — this is what makes toggling the option a migration.
    @discardableResult
    func savePassword(
        kind: FfiCredentialKind, account: String, secret: String, synchronizable: Bool
    ) -> Bool {
        if synchronizable {
            let saved = saveSynchronizablePassword(kind: kind, account: account, secret: secret)
            if saved { deleteLocalPassword(kind: kind, account: account) }
            return saved
        } else {
            let saved = savePassword(kind: kind, account: account, secret: secret)
            if saved { deleteSynchronizablePassword(kind: kind, account: account) }
            return saved
        }
    }

    /// Persist (or clear) a Postgres profile's password for `account`,
    /// honouring the editor's "save to keychain" + "sync via iCloud" toggles.
    /// Shared by both platforms' connection editors so this three-way branch
    /// (write / migrate-in-place / delete) can't drift between them.
    func persistPostgresPassword(
        account: String,
        password: String,
        saveToKeychain: Bool,
        synchronizable: Bool
    ) {
        if saveToKeychain && !password.isEmpty {
            savePassword(kind: .postgresPassword, account: account, secret: password, synchronizable: synchronizable)
        } else if saveToKeychain {
            // No new password entered — migrate whatever already exists.
            setPasswordSynchronizable(kind: .postgresPassword, account: account, synchronizable: synchronizable)
        } else {
            deletePassword(kind: .postgresPassword, account: account)
        }
    }

    /// Migrate an existing secret between stores without knowing its value
    /// (used when the toggle flips but the password field wasn't re-entered).
    /// Duplicates are resolved by deleting the source copy after a
    /// successful write to the destination.
    @discardableResult
    func setPasswordSynchronizable(
        kind: FfiCredentialKind, account: String, synchronizable: Bool
    ) -> Bool {
        if synchronizable {
            if let secret = loadLocalPassword(kind: kind, account: account) {
                return savePassword(kind: kind, account: account, secret: secret, synchronizable: true)
            }
            // Nothing local — already migrated (or never saved).
            return loadSynchronizablePassword(kind: kind, account: account) != nil
        } else {
            if let secret = loadSynchronizablePassword(kind: kind, account: account) {
                return savePassword(kind: kind, account: account, secret: secret, synchronizable: false)
            }
            return loadLocalPassword(kind: kind, account: account) != nil
        }
    }

    func hasSynchronizablePassword(kind: FfiCredentialKind, account: String) -> Bool {
        loadSynchronizablePassword(kind: kind, account: account) != nil
    }

    @discardableResult
    private func saveSynchronizablePassword(
        kind: FfiCredentialKind, account: String, secret: String
    ) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }
        let query = synchronizableQuery(kind: kind, account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            logger.error("synchronizable keychain update failed: \(updateStatus, privacy: .public)")
            return false
        }
        var attributes = query
        attributes[kSecValueData as String] = data
        // WhenUnlocked (not ThisDeviceOnly) — see the tradeoff note above.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("synchronizable keychain add failed: \(status, privacy: .public)")
        }
        return status == errSecSuccess
    }

    private func loadSynchronizablePassword(kind: FfiCredentialKind, account: String) -> String? {
        var query = synchronizableQuery(kind: kind, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private func deleteSynchronizablePassword(kind: FfiCredentialKind, account: String) -> Bool {
        let status = SecItemDelete(synchronizableQuery(kind: kind, account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Same service string on every platform so items rendezvous across
    /// devices via iCloud Keychain.
    private func synchronizableQuery(kind: FfiCredentialKind, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.pgagent.sync.\(kind.rawValue)",
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any
        ]
    }

    // MARK: - Prompt (native dialog wrapper)

    #if os(macOS)
    /// Show a system dialog prompting the user for a password. Returns nil if cancelled.
    func promptPassword(account: String, message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Credential Required"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        field.placeholderString = "Password for \(account)"
        alert.accessoryView = field

        let response = alert.runModal()
        let value = field.stringValue
        // Clear the secure field so the secret doesn't linger in the
        // dismissed alert's view hierarchy.
        field.stringValue = ""
        guard response == .alertFirstButtonReturn else { return nil }
        return value.isEmpty ? nil : value
    }

    /// Prompt for a key passphrase.
    func promptPassphrase(keyPath: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Key Passphrase Required"
        alert.informativeText = "Enter passphrase for key:\n\(keyPath)"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        field.placeholderString = "Passphrase"
        alert.accessoryView = field

        let response = alert.runModal()
        let value = field.stringValue
        // Clear the secure field so the secret doesn't linger in the
        // dismissed alert's view hierarchy.
        field.stringValue = ""
        guard response == .alertFirstButtonReturn else { return nil }
        return value.isEmpty ? nil : value
    }
    #endif
}

// MARK: - FfiCredentialKind helper

#if canImport(PgAgentMacOS) || os(iOS)
extension FfiCredentialKind {
    var rawValue: String {
        switch self {
        case .sshPassword: return "ssh_password"
        case .sshKeyPassphrase: return "ssh_key_passphrase"
        case .sftpPassword: return "sftp_password"
        case .sftpKeyPassphrase: return "sftp_key_passphrase"
        case .ftpPassword: return "ftp_password"
        case .postgresPassword: return "postgres_password"
        }
    }
}
#endif
