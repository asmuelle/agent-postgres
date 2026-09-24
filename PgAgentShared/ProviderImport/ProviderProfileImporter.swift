import Foundation

/// Turns selected `ProviderDatabase` entries into saved profiles.
/// Shared by the macOS and iOS provider-import sheets so the
/// password-to-keychain rule lives in exactly one place.
@MainActor
enum ProviderProfileImporter {

    struct Result {
        var importedCount = 0
        var skippedExistingCount = 0
        /// Names of profiles imported without a password (Supabase) — the
        /// UI tells the user those will prompt on first connect.
        var needingPassword: [String] = []
    }

    /// Import `databases` into `store`. Passwords (when the provider
    /// returned one) go straight to the keychain under the profile's
    /// keychain account; they are never written into the profile. Entries
    /// matching an existing profile's endpoint (same user@host:port/db) are
    /// skipped rather than duplicated. (The keychain account is id-scoped,
    /// so it can't detect duplicates — every new profile has a fresh id.)
    static func importDatabases(
        _ databases: [ProviderDatabase],
        into store: PostgresProfileStore
    ) async -> Result {
        var result = Result()
        var existingEndpoints = Set(store.profiles.map(\.endpointIdentity))
        for database in databases {
            var profile = database.connection.makeProfile(named: database.name)
            if database.requiresPasswordOnFirstConnect {
                profile.notes = "Imported from provider — database password required on first connect (edit the connection to add it)."
            }

            guard existingEndpoints.insert(profile.endpointIdentity).inserted else {
                result.skippedExistingCount += 1
                continue
            }

            if let password = database.connection.password, !password.isEmpty {
                // Saved before the profile, so a connect can't beat it.
                await KeychainManager.shared.savePasswordAsync(
                    kind: .postgresPassword, account: profile.keychainAccount, secret: password
                )
            } else {
                result.needingPassword.append(profile.name)
            }
            store.saveOrUpdate(profile)
            result.importedCount += 1
        }
        return result
    }
}
