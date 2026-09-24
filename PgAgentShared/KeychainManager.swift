#if os(macOS)
import AppKit
#endif
import Foundation
import OSLog
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif
import Security

/// Outcome of a keychain read that distinguishes "definitely absent" from
/// "couldn't read" (locked keychain, denied prompt, missing entitlement).
/// Migration code must never treat a failed read as absence — that is how
/// secrets get deleted or overwritten.
enum KeychainLookup: Equatable, Sendable {
    case found(String)
    case notFound
    case failed

    var value: String? {
        if case .found(let secret) = self { return secret }
        return nil
    }
}

/// Wraps the keychain access for Swift.
/// - On macOS: Uses `rshell_keychain_*` from the uniffi bindings (macOS Keychain via Rust core).
/// - On iOS: Uses native iOS Security framework.
/// - Synchronizable (iCloud Keychain) items use the native Security framework
///   on BOTH platforms — the Rust core has no synchronizable concept.
///
/// Threading: every keychain call can block — the first access after login,
/// a locked login keychain, or an ACL prompt stalls until the user answers.
/// The storage work lives in the non-isolated `KeychainStorage`; the
/// `…Async` methods below run it on a background serial queue and are what
/// new code (and anything reachable from the main thread) should use. The
/// synchronous methods remain for callers that have not been migrated yet.
@MainActor
class KeychainManager {
    static let shared = KeychainManager()

    private nonisolated let storage = KeychainStorage()

    private init() {}

    var isAvailable: Bool { storage.isAvailable }

    // MARK: - Synchronous API (legacy; blocks the calling thread)

    @discardableResult
    func savePassword(kind: FfiCredentialKind, account: String, secret: String) -> Bool {
        storage.savePassword(kind: kind, account: account, secret: secret)
    }

    /// Load a secret, preferring the device-local store, falling back to the
    /// synchronizable (iCloud Keychain) store — so connect flows work no
    /// matter which store the password lives in.
    func loadPassword(kind: FfiCredentialKind, account: String) -> String? {
        storage.loadPassword(kind: kind, account: account)
    }

    /// Delete a secret from BOTH stores (device-local and synchronizable) so
    /// profile deletion never strands a synced copy.
    @discardableResult
    func deletePassword(kind: FfiCredentialKind, account: String) -> Bool {
        storage.deletePassword(kind: kind, account: account)
    }

    func listAccounts(kind: FfiCredentialKind) -> [String] {
        storage.listAccounts(kind: kind)
    }

    func hasPassword(kind: FfiCredentialKind, account: String) -> Bool {
        storage.hasPassword(kind: kind, account: account)
    }

    /// Save, choosing the store. `synchronizable: true` also removes any
    /// device-local copy (and vice versa) so exactly one store holds the
    /// secret — this is what makes toggling the option a migration.
    @discardableResult
    func savePassword(
        kind: FfiCredentialKind, account: String, secret: String, synchronizable: Bool
    ) -> Bool {
        storage.savePassword(kind: kind, account: account, secret: secret, synchronizable: synchronizable)
    }

    /// Persist (or clear) a Postgres profile's password for `account`,
    /// honouring the editor's "save to keychain" + "sync via iCloud" toggles.
    @discardableResult
    func persistPostgresPassword(
        account: String,
        password: String,
        saveToKeychain: Bool,
        synchronizable: Bool
    ) -> Bool {
        storage.persistPostgresPassword(
            account: account, password: password,
            saveToKeychain: saveToKeychain, synchronizable: synchronizable
        )
    }

    @discardableResult
    func setPasswordSynchronizable(
        kind: FfiCredentialKind, account: String, synchronizable: Bool
    ) -> Bool {
        storage.setPasswordSynchronizable(kind: kind, account: account, synchronizable: synchronizable)
    }

    func hasSynchronizablePassword(kind: FfiCredentialKind, account: String) -> Bool {
        storage.hasSynchronizablePassword(kind: kind, account: account)
    }

    // MARK: - Async API (runs off the main thread)

    nonisolated func loadPasswordAsync(kind: FfiCredentialKind, account: String) async -> String? {
        let storage = storage
        return await KeychainStorage.offMain { storage.loadPassword(kind: kind, account: account) }
    }

    nonisolated func lookupPasswordAsync(kind: FfiCredentialKind, account: String) async -> KeychainLookup {
        let storage = storage
        return await KeychainStorage.offMain { storage.lookupPassword(kind: kind, account: account) }
    }

    @discardableResult
    nonisolated func savePasswordAsync(
        kind: FfiCredentialKind, account: String, secret: String, synchronizable: Bool = false
    ) async -> Bool {
        let storage = storage
        return await KeychainStorage.offMain {
            storage.savePassword(kind: kind, account: account, secret: secret, synchronizable: synchronizable)
        }
    }

    @discardableResult
    nonisolated func deletePasswordAsync(kind: FfiCredentialKind, account: String) async -> Bool {
        let storage = storage
        return await KeychainStorage.offMain { storage.deletePassword(kind: kind, account: account) }
    }

    nonisolated func hasPasswordAsync(kind: FfiCredentialKind, account: String) async -> Bool {
        let storage = storage
        return await KeychainStorage.offMain { storage.hasPassword(kind: kind, account: account) }
    }

    @discardableResult
    nonisolated func persistPostgresPasswordAsync(
        account: String,
        password: String,
        saveToKeychain: Bool,
        synchronizable: Bool
    ) async -> Bool {
        let storage = storage
        return await KeychainStorage.offMain {
            storage.persistPostgresPassword(
                account: account, password: password,
                saveToKeychain: saveToKeychain, synchronizable: synchronizable
            )
        }
    }

    /// A Postgres profile's password, looked up under its id-scoped account
    /// and, until the one-time migration has copied it, under the legacy
    /// endpoint-scoped account. Use this rather than a raw
    /// `loadPassword(account: profile.keychainAccount)` wherever a password
    /// is shown or used.
    nonisolated func loadPostgresPasswordAsync(for profile: PostgresProfile) async -> String? {
        let storage = storage
        let primary = profile.keychainAccount
        let legacy = profile.legacyKeychainAccount
        return await KeychainStorage.offMain {
            storage.loadPassword(kind: .postgresPassword, account: primary)
                ?? storage.loadPassword(kind: .postgresPassword, account: legacy)
        }
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

// MARK: - Storage core (thread-safe, no actor isolation)

/// The actual keychain reads/writes. Stateless and `Sendable`: the Rust
/// keychain FFI and the Security framework are both thread-safe, so this can
/// run on any thread. `KeychainManager` wraps it for main-actor callers.
struct KeychainStorage: Sendable {
    private static let logger = Logger(subsystem: "com.mc-ssh", category: "keychain")

    /// All async keychain work funnels through one serial queue so a
    /// save-then-delete issued in that order also lands in that order.
    private static let queue = DispatchQueue(label: "com.pgagent.keychain", qos: .userInitiated)

    static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// Fire-and-forget: enqueue keychain work on the serial queue *now*, so
    /// it is ordered after everything enqueued before this call.
    static func enqueue(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    var isAvailable: Bool {
        #if os(macOS)
        return rshellKeychainIsSupported()
        #else
        return true
        #endif
    }

    // MARK: Device-local store

    @discardableResult
    func savePassword(kind: FfiCredentialKind, account: String, secret: String) -> Bool {
        #if os(macOS)
        let result = rshellKeychainSave(kind: kind, account: account, secret: secret)
        if !result.success {
            Self.logger.error("keychain save failed: \(result.error ?? "?", privacy: .public)")
        }
        return result.success
        #else
        guard let data = secret.data(using: .utf8) else { return false }
        let query = localQuery(kind: kind, account: account)
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

    func loadPassword(kind: FfiCredentialKind, account: String) -> String? {
        lookupPassword(kind: kind, account: account).value
    }

    /// Local store first, then the synchronizable store. `.failed` only when
    /// neither store produced the secret and at least one read errored.
    func lookupPassword(kind: FfiCredentialKind, account: String) -> KeychainLookup {
        let local = lookupLocalPassword(kind: kind, account: account)
        if case .found = local { return local }
        let synced = lookupSynchronizablePassword(kind: kind, account: account)
        if case .found = synced { return synced }
        return (local == .failed || synced == .failed) ? .failed : .notFound
    }

    func lookupLocalPassword(kind: FfiCredentialKind, account: String) -> KeychainLookup {
        #if os(macOS)
        let result = rshellKeychainLoad(kind: kind, account: account)
        if !result.success {
            Self.logger.error("keychain load failed: \(result.error ?? "?", privacy: .public)")
            return .failed
        }
        guard let value = result.value else { return .notFound }
        return .found(value)
        #else
        var query = localQuery(kind: kind, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return .failed }
        return .found(value)
        #endif
    }

    /// Delete a secret from BOTH stores (device-local and synchronizable).
    @discardableResult
    func deletePassword(kind: FfiCredentialKind, account: String) -> Bool {
        let localOk = deleteLocalPassword(kind: kind, account: account)
        let syncOk = deleteSynchronizablePassword(kind: kind, account: account)
        return localOk && syncOk
    }

    @discardableResult
    func deleteLocalPassword(kind: FfiCredentialKind, account: String) -> Bool {
        #if os(macOS)
        let result = rshellKeychainDelete(kind: kind, account: account)
        if !result.success {
            Self.logger.error("keychain delete failed: \(result.error ?? "?", privacy: .public)")
        }
        return result.success
        #else
        let status = SecItemDelete(localQuery(kind: kind, account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
        #endif
    }

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
        var query = localQuery(kind: kind, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
        #endif
    }

    #if os(iOS)
    private func localQuery(kind: FfiCredentialKind, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.pgagent.mobile.\(kind.rawValue)",
            kSecAttrAccount as String: account
        ]
    }
    #endif

    // MARK: Synchronizable variant (iCloud Keychain, opt-in per profile)
    //
    // Tradeoff, deliberately accepted and surfaced in the UI footnote:
    // synchronizable items CANNOT use a ThisDeviceOnly protection class, so
    // these are stored kSecAttrAccessibleWhenUnlocked instead of the
    // WhenUnlockedThisDeviceOnly default used for local items. In exchange
    // the secret follows the user's devices through iCloud Keychain
    // (end-to-end encrypted by Apple) — which is the entire point of the
    // per-connection "Sync password" opt-in.
    //
    // Items only rendezvous across devices when they live in the SAME
    // keychain access group. Each app's default group is its own
    // application identifier (…com.pgagent.macos vs …com.pgagent.mobile), so
    // writes pin the shared `KeychainAccessGroup.sharedSync` group
    // explicitly. Reads and deletes deliberately omit the group so items
    // written into an app's default group by older builds are still found
    // (and moved into the shared group on read).

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
    @discardableResult
    func persistPostgresPassword(
        account: String,
        password: String,
        saveToKeychain: Bool,
        synchronizable: Bool
    ) -> Bool {
        if saveToKeychain && !password.isEmpty {
            return savePassword(kind: .postgresPassword, account: account, secret: password, synchronizable: synchronizable)
        } else if saveToKeychain {
            // No new password entered — migrate whatever already exists.
            guard hasPassword(kind: .postgresPassword, account: account) else { return true }
            return setPasswordSynchronizable(kind: .postgresPassword, account: account, synchronizable: synchronizable)
        } else {
            return deletePassword(kind: .postgresPassword, account: account)
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
            if let secret = lookupLocalPassword(kind: kind, account: account).value {
                return savePassword(kind: kind, account: account, secret: secret, synchronizable: true)
            }
            // Nothing local — already migrated (or never saved).
            return lookupSynchronizablePassword(kind: kind, account: account).value != nil
        } else {
            if let secret = lookupSynchronizablePassword(kind: kind, account: account).value {
                return savePassword(kind: kind, account: account, secret: secret, synchronizable: false)
            }
            return lookupLocalPassword(kind: kind, account: account).value != nil
        }
    }

    func hasSynchronizablePassword(kind: FfiCredentialKind, account: String) -> Bool {
        lookupSynchronizablePassword(kind: kind, account: account).value != nil
    }

    @discardableResult
    private func saveSynchronizablePassword(
        kind: FfiCredentialKind, account: String, secret: String
    ) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }
        let query = synchronizableQuery(kind: kind, account: account)
        var update: [String: Any] = [kSecValueData as String: data]
        if let group = KeychainAccessGroup.sharedSync {
            update[kSecAttrAccessGroup as String] = group
        }
        var updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecMissingEntitlement, update[kSecAttrAccessGroup as String] != nil {
            // Shared group not in this build's entitlements — keep the item
            // where it is rather than failing the save.
            update.removeValue(forKey: kSecAttrAccessGroup as String)
            updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        }
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            Self.logger.error("synchronizable keychain update failed: \(updateStatus, privacy: .public)")
            return false
        }
        var attributes = query
        attributes[kSecValueData as String] = data
        // WhenUnlocked (not ThisDeviceOnly) — see the tradeoff note above.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        var status = errSecMissingEntitlement
        if let group = KeychainAccessGroup.sharedSync {
            var grouped = attributes
            grouped[kSecAttrAccessGroup as String] = group
            status = SecItemAdd(grouped as CFDictionary, nil)
            if status == errSecMissingEntitlement {
                Self.logger.warning("shared keychain access group \(group, privacy: .public) is not entitled; synced password stays in the app's default group and will not reach other platforms")
            }
        }
        if status == errSecMissingEntitlement {
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        if status != errSecSuccess {
            Self.logger.error("synchronizable keychain add failed: \(status, privacy: .public)")
        }
        return status == errSecSuccess
    }

    private func lookupSynchronizablePassword(kind: FfiCredentialKind, account: String) -> KeychainLookup {
        var query = synchronizableQuery(kind: kind, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .notFound }
        // Unsigned macOS builds can't reach the data-protection keychain at
        // all; that is "no synced item here", not a read failure.
        if status == errSecMissingEntitlement { return .notFound }
        guard status == errSecSuccess,
              let attributes = item as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data,
              let value = String(data: data, encoding: .utf8) else { return .failed }
        moveToSharedGroupIfNeeded(
            kind: kind, account: account,
            currentGroup: attributes[kSecAttrAccessGroup as String] as? String
        )
        return .found(value)
    }

    /// Items synced by older builds sit in the writing app's default access
    /// group, invisible to the other platform. Re-home them (best effort).
    private func moveToSharedGroupIfNeeded(
        kind: FfiCredentialKind, account: String, currentGroup: String?
    ) {
        guard let shared = KeychainAccessGroup.sharedSync,
              let currentGroup, currentGroup != shared else { return }
        var match = synchronizableQuery(kind: kind, account: account)
        match[kSecAttrAccessGroup as String] = currentGroup
        let status = SecItemUpdate(
            match as CFDictionary,
            [kSecAttrAccessGroup as String: shared] as CFDictionary
        )
        if status != errSecSuccess {
            Self.logger.info("could not move synced item into shared access group: \(status, privacy: .public)")
        }
    }

    @discardableResult
    private func deleteSynchronizablePassword(kind: FfiCredentialKind, account: String) -> Bool {
        let status = SecItemDelete(synchronizableQuery(kind: kind, account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement
    }

    /// Same service string on every platform so items rendezvous across
    /// devices via iCloud Keychain.
    private func synchronizableQuery(kind: FfiCredentialKind, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.pgagent.sync.\(kind.rawValue)",
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any
        ]
        #if os(macOS)
        // Synchronizable implies the data-protection keychain; say so
        // explicitly so the query never falls through to the file keychain.
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
}

// MARK: - Shared access group

/// The keychain access group both apps use for iCloud-synced secrets:
/// `<AppIdentifierPrefix>com.pgagent.shared`. It must be listed in
/// `keychain-access-groups` of BOTH the macOS and iOS entitlements.
///
/// The App ID prefix (team id) is discovered at runtime from the access
/// group the system assigns to a probe item, so no team id is hard-coded.
/// Nil when the data-protection keychain is unreachable (unsigned builds);
/// callers then fall back to the app's default group.
enum KeychainAccessGroup {
    static let sharedSuffix = "com.pgagent.shared"

    static let sharedSync: String? = {
        guard let prefix = appIdentifierPrefix() else { return nil }
        return prefix + sharedSuffix
    }()

    /// Given an access group such as `ABCDE12345.com.pgagent.mobile`, the
    /// App ID prefix including the trailing dot (`ABCDE12345.`).
    static func prefix(ofAccessGroup group: String) -> String? {
        guard let dot = group.firstIndex(of: "."), dot != group.startIndex else { return nil }
        return String(group[...dot])
    }

    private static func appIdentifierPrefix() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.pgagent.keychain-probe",
            kSecAttrAccount as String: "access-group-probe",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        var item: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            var add = query
            add.removeValue(forKey: kSecMatchLimit as String)
            add[kSecValueData as String] = Data()
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, &item)
        }
        guard status == errSecSuccess,
              let attributes = item as? [String: Any],
              let group = attributes[kSecAttrAccessGroup as String] as? String else {
            return nil
        }
        return prefix(ofAccessGroup: group)
    }
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
