import Foundation
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

/// The slice of the keychain the Postgres-password account migration needs.
/// Abstracted so the migration rules are unit-testable with an in-memory
/// fake; production uses `LivePostgresPasswordKeychain`.
protocol PostgresPasswordKeychain: Sendable {
    func lookup(account: String) -> KeychainLookup
    func save(account: String, secret: String, synchronizable: Bool) -> Bool
    @discardableResult
    func delete(account: String) -> Bool
}

struct LivePostgresPasswordKeychain: PostgresPasswordKeychain {
    private let storage = KeychainStorage()

    func lookup(account: String) -> KeychainLookup {
        storage.lookupPassword(kind: .postgresPassword, account: account)
    }

    func save(account: String, secret: String, synchronizable: Bool) -> Bool {
        storage.savePassword(
            kind: .postgresPassword, account: account, secret: secret, synchronizable: synchronizable
        )
    }

    @discardableResult
    func delete(account: String) -> Bool {
        storage.deletePassword(kind: .postgresPassword, account: account)
    }
}

/// Moves Postgres passwords from the legacy endpoint-scoped keychain account
/// (`user@host:port/db`) to the id-scoped one (`pgprofile:<id>`).
///
/// Rules (all enforced here so the store and the tests share them):
///   • Copy, never move: the legacy entry may back other profiles that point
///     at the same endpoint, so migration leaves it in place.
///   • A failed read is never treated as "absent" — nothing is written or
///     deleted on `.failed`; the next launch retries.
///   • A legacy entry is deleted only when no remaining profile still maps
///     to it, and — when the surviving profile relies on the keychain — only
///     after its id-scoped copy is confirmed present.
enum PostgresKeychainAccountMigration {
    enum Outcome: Equatable, Sendable {
        /// The id-scoped entry already exists.
        case alreadyMigrated
        /// The legacy secret was copied to the id-scoped account.
        case copied
        /// Neither account holds a secret (the password was never saved).
        case nothingToMigrate
        /// The profile doesn't use keychain auth.
        case notApplicable
        /// A keychain read or write failed; retry later.
        case failed
    }

    static func migrate(
        _ profile: PostgresProfile, keychain: some PostgresPasswordKeychain
    ) -> Outcome {
        guard case .keychain = profile.auth else { return .notApplicable }
        switch keychain.lookup(account: profile.keychainAccount) {
        case .found: return .alreadyMigrated
        case .failed: return .failed
        case .notFound: break
        }
        switch keychain.lookup(account: profile.legacyKeychainAccount) {
        case .found(let secret):
            let saved = keychain.save(
                account: profile.keychainAccount, secret: secret,
                synchronizable: profile.syncPassword
            )
            return saved ? .copied : .failed
        case .notFound:
            return .nothingToMigrate
        case .failed:
            return .failed
        }
    }

    /// True when a profile other than `excludingId` still maps to `account`.
    static func legacyAccountIsShared(
        _ account: String, excludingId: String, among profiles: [PostgresProfile]
    ) -> Bool {
        profiles.contains { $0.id != excludingId && $0.legacyKeychainAccount == account }
    }

    /// The legacy account to purge when `removed` is deleted, or nil when
    /// another profile still maps to it.
    static func legacyAccountToDelete(
        removing removed: PostgresProfile, remaining: [PostgresProfile]
    ) -> String? {
        let account = removed.legacyKeychainAccount
        return legacyAccountIsShared(account, excludingId: removed.id, among: remaining)
            ? nil : account
    }

    /// The legacy account to purge after `previous` was edited into
    /// `updated`: only when the endpoint changed (or keychain auth was
    /// dropped) and nobody else maps to the old endpoint.
    static func legacyAccountToDelete(
        editing previous: PostgresProfile,
        into updated: PostgresProfile,
        among profiles: [PostgresProfile]
    ) -> String? {
        let account = previous.legacyKeychainAccount
        let usesKeychain: Bool = {
            if case .keychain = updated.auth { return true }
            return false
        }()
        guard account != updated.legacyKeychainAccount || !usesKeychain else { return nil }
        return legacyAccountIsShared(account, excludingId: previous.id, among: profiles)
            ? nil : account
    }

    /// Delete `legacyAccount`, but when `survivor` still uses keychain auth
    /// only after confirming its id-scoped copy exists — otherwise an edit
    /// racing the launch migration could destroy the only copy.
    @discardableResult
    static func purgeLegacyAccount(
        _ legacyAccount: String,
        survivor: PostgresProfile?,
        keychain: some PostgresPasswordKeychain
    ) -> Bool {
        if let survivor, case .keychain = survivor.auth {
            guard case .found = keychain.lookup(account: survivor.keychainAccount) else {
                return false
            }
        }
        return keychain.delete(account: legacyAccount)
    }
}
