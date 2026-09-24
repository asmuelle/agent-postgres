import Foundation
import OSLog
import Security

/// Which macOS keychain an item lives in.
///
/// `kSecAttrAccessible…ThisDeviceOnly` is only honoured by the
/// data-protection keychain; on macOS a query without
/// `kSecUseDataProtectionKeychain` lands in the legacy file-based login
/// keychain, which silently ignores the accessibility class (and syncs
/// nowhere, but also offers no device binding).
enum MacKeychainTier: Sendable, Hashable {
    case dataProtection
    case legacyFile
}

/// Minimal generic-password primitive, abstracted so the tier
/// selection / migration rules in `DeviceLocalKeychainStore` are testable.
protocol GenericPasswordKeychainBackend: Sendable {
    func copy(service: String, account: String, tier: MacKeychainTier) -> (status: OSStatus, data: Data?)
    func add(service: String, account: String, data: Data, tier: MacKeychainTier) -> OSStatus
    func delete(service: String, account: String, tier: MacKeychainTier) -> OSStatus
}

struct SecItemGenericPasswordBackend: GenericPasswordKeychainBackend {
    private func baseQuery(service: String, account: String, tier: MacKeychainTier) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: tier == .dataProtection,
        ]
    }

    func copy(service: String, account: String, tier: MacKeychainTier) -> (status: OSStatus, data: Data?) {
        var query = baseQuery(service: service, account: account, tier: tier)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }

    func add(service: String, account: String, data: Data, tier: MacKeychainTier) -> OSStatus {
        var query = baseQuery(service: service, account: account, tier: tier)
        query[kSecValueData as String] = data
        // Readable only while unlocked, never migrated to another device.
        // Effective in the data-protection keychain; recorded but ignored
        // by the legacy file keychain.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
    }

    func delete(service: String, account: String, tier: MacKeychainTier) -> OSStatus {
        SecItemDelete(baseQuery(service: service, account: account, tier: tier) as CFDictionary)
    }
}

struct KeychainStatusError: Error, Equatable {
    let status: OSStatus
}

/// Device-bound secrets (vault master key, Secure Enclave key references)
/// stored in the macOS data-protection keychain, so their
/// `WhenUnlockedThisDeviceOnly` class is actually enforced.
///
/// The data-protection keychain needs a signed build carrying
/// `application-identifier` / `keychain-access-groups`; unsigned builds
/// (`CODE_SIGNING_ALLOWED=NO`) get `errSecMissingEntitlement`. So:
///   • reads prefer the data-protection keychain, then the legacy one;
///   • a legacy hit is migrated: written to data-protection, read back and
///     compared, and only then deleted from the legacy keychain;
///   • when data-protection is unavailable everything falls back to the
///     legacy keychain with a logged warning — never an error, never a
///     lost secret.
struct DeviceLocalKeychainStore: Sendable {
    let service: String
    private let backend: any GenericPasswordKeychainBackend
    private static let logger = Logger(subsystem: "com.mc-ssh", category: "device-keychain")

    init(service: String, backend: any GenericPasswordKeychainBackend = SecItemGenericPasswordBackend()) {
        self.service = service
        self.backend = backend
    }

    /// The secret, or nil when it exists in neither keychain. Throws on any
    /// other failure (locked keychain, denied access) — callers must not
    /// treat that as absence (e.g. by generating a replacement key).
    func read(account: String) throws -> Data? {
        let dp = backend.copy(service: service, account: account, tier: .dataProtection)
        let dataProtectionAvailable: Bool
        switch dp.status {
        case errSecSuccess:
            if let data = dp.data { return data }
            throw KeychainStatusError(status: errSecDecode)
        case errSecItemNotFound:
            dataProtectionAvailable = true
        case errSecMissingEntitlement:
            dataProtectionAvailable = false
            warnDataProtectionUnavailable()
        default:
            throw KeychainStatusError(status: dp.status)
        }

        let legacy = backend.copy(service: service, account: account, tier: .legacyFile)
        switch legacy.status {
        case errSecSuccess:
            guard let data = legacy.data else { throw KeychainStatusError(status: errSecDecode) }
            if dataProtectionAvailable {
                migrateToDataProtection(account: account, data: data)
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStatusError(status: legacy.status)
        }
    }

    /// Store `data`, replacing any existing copy in either keychain.
    func write(account: String, data: Data) throws {
        _ = backend.delete(service: service, account: account, tier: .dataProtection)
        let status = backend.add(service: service, account: account, data: data, tier: .dataProtection)
        switch status {
        case errSecSuccess:
            // Drop a stale legacy copy so reads can't resurrect it.
            _ = backend.delete(service: service, account: account, tier: .legacyFile)
        case errSecMissingEntitlement:
            warnDataProtectionUnavailable()
            _ = backend.delete(service: service, account: account, tier: .legacyFile)
            let legacyStatus = backend.add(service: service, account: account, data: data, tier: .legacyFile)
            guard legacyStatus == errSecSuccess else { throw KeychainStatusError(status: legacyStatus) }
        default:
            throw KeychainStatusError(status: status)
        }
    }

    /// Remove the secret from both keychains.
    func delete(account: String) throws {
        for tier in [MacKeychainTier.dataProtection, .legacyFile] {
            let status = backend.delete(service: service, account: account, tier: tier)
            guard status == errSecSuccess || status == errSecItemNotFound
                    || status == errSecMissingEntitlement else {
                throw KeychainStatusError(status: status)
            }
        }
    }

    private func migrateToDataProtection(account: String, data: Data) {
        let status = backend.add(service: service, account: account, data: data, tier: .dataProtection)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            Self.logger.warning("Keeping \(service, privacy: .public) in the legacy keychain; data-protection write failed (\(status, privacy: .public))")
            return
        }
        // Verify before deleting the only other copy.
        let check = backend.copy(service: service, account: account, tier: .dataProtection)
        guard check.status == errSecSuccess, check.data == data else {
            Self.logger.warning("Keeping legacy \(service, privacy: .public) item; data-protection copy did not verify")
            return
        }
        let deleted = backend.delete(service: service, account: account, tier: .legacyFile)
        if deleted == errSecSuccess {
            Self.logger.notice("Migrated \(service, privacy: .public) item to the data-protection keychain")
        }
    }

    private func warnDataProtectionUnavailable() {
        Self.logger.warning("Data-protection keychain unavailable (missing entitlement — unsigned build?); \(service, privacy: .public) uses the legacy file keychain, where ThisDeviceOnly is not enforced")
    }
}
