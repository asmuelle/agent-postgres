#if os(macOS)
import AppKit
#endif
import Foundation
import OSLog
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif
#if os(iOS)
import Security
#endif

/// Wraps the keychain access for Swift.
/// - On macOS: Uses `rshell_keychain_*` from the uniffi bindings (macOS Keychain via Rust core).
/// - On iOS: Uses native iOS Security framework.
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

    func loadPassword(kind: FfiCredentialKind, account: String) -> String? {
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

    @discardableResult
    func deletePassword(kind: FfiCredentialKind, account: String) -> Bool {
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
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue.isEmpty ? nil : field.stringValue
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
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue.isEmpty ? nil : field.stringValue
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
