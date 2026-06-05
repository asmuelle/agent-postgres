import Foundation
import OSLog
import PgAgentMacOS

/// Encapsulates the "load credential → try connect → evict stale →
/// re-prompt → retry" loop so it can be shared between the initial
/// `openConnection` flow and the `reconnect` fast path.
///
/// All state mutations (Keychain eviction, persistence of freshly
/// prompted secrets) happen exactly once per resolved credential set —
/// the caller gets back a `ResolvedCredential` ready to pass to
/// `BridgeManager.connect`.
///
/// Marked `@MainActor` because all Keychain access (load/save/delete)
/// is main-actor-isolated; caller-provided prompt closures dispatch to
/// main internally.
@MainActor
final class CredentialResolver {
    typealias PasswordProvider = (_ account: String, _ message: String) async -> String?
    typealias PassphraseProvider = (_ keyPath: String) async -> String?

    /// Outcome returned to the caller so `openConnection` / `reconnect`
    /// can carry on without knowing which branch was taken.
    struct ResolvedCredential {
        let password: String?
        let passphrase: String?
        let usedStoredPassword: Bool
        let usedStoredPassphrase: Bool
    }

    private let profile: ConnectionProfile
    private let passwordProvider: PasswordProvider
    private let passphraseProvider: PassphraseProvider
    private let logger = Logger(subsystem: "com.mc-ssh", category: "credential-resolver")

    /// The stored-password flag tracks whether the credential came from
    /// the Keychain (so an auth failure triggers eviction) or from a
    /// fresh prompt / caller argument (which should survive the attempt).
    private var usedStoredPassword = false
    private var usedStoredPassphrase = false

    init(
        profile: ConnectionProfile,
        passwordProvider: @escaping PasswordProvider,
        passphraseProvider: @escaping PassphraseProvider
    ) {
        self.profile = profile
        self.passwordProvider = passwordProvider
        self.passphraseProvider = passphraseProvider
    }

    // MARK: - Public entry point

    /// Resolve credentials for the profile. The optional `explicitPassword`
    /// and `explicitPassphrase` parameters short-circuit the Keychain and
    /// prompt paths — used by the retry recursion (after eviction) and
    /// by callers that already have a credential in hand.
    func resolve(
        explicitPassword: String? = nil,
        explicitPassphrase: String? = nil
    ) async -> ResolvedCredential? {
        switch profile.authMethod {
        case .password:
            return await resolvePassword(explicit: explicitPassword)
        case .publicKey:
            return await resolvePublicKey(explicit: explicitPassphrase)
        }
    }

    // MARK: - Password path

    private func resolvePassword(explicit: String?) async -> ResolvedCredential? {
        if let explicit {
            return ResolvedCredential(
                password: explicit, passphrase: nil,
                usedStoredPassword: false, usedStoredPassphrase: false
            )
        }

        let account = profile.keychainAccount
        if let stored = KeychainManager.shared.loadPassword(
            kind: .sshPassword, account: account
        ) {
            usedStoredPassword = true
            return ResolvedCredential(
                password: stored, passphrase: nil,
                usedStoredPassword: true, usedStoredPassphrase: false
            )
        }

        guard let prompted = await passwordProvider(
            account,
            "Enter password for \(profile.name) (\(account))"
        ) else {
            logger.info("Password prompt cancelled for \(account, privacy: .public)")
            return nil
        }
        return ResolvedCredential(
            password: prompted, passphrase: nil,
            usedStoredPassword: false, usedStoredPassphrase: false
        )
    }

    // MARK: - Public key path

    private func resolvePublicKey(explicit: String?) async -> ResolvedCredential? {
        if profile.sshKeyReference?.needsStoredPassphrase == false {
            return ResolvedCredential(
                password: nil, passphrase: nil,
                usedStoredPassword: false, usedStoredPassphrase: false
            )
        }

        if let explicit {
            return ResolvedCredential(
                password: nil, passphrase: explicit,
                usedStoredPassword: false, usedStoredPassphrase: false
            )
        }

        let account = profile.keychainAccount
        if let stored = KeychainManager.shared.loadPassword(
            kind: .sshKeyPassphrase, account: account
        ) {
            usedStoredPassphrase = true
            return ResolvedCredential(
                password: nil, passphrase: stored,
                usedStoredPassword: false, usedStoredPassphrase: true
            )
        }

        // Key may be unencrypted — try without passphrase first.
        return ResolvedCredential(
            password: nil, passphrase: nil,
            usedStoredPassword: false, usedStoredPassphrase: false
        )
    }

    // MARK: - Post-connect persistence

    /// Persist a prompted password that just succeeded, so the next
    /// connect is silent. No-ops if the password was already stored.
    func persistPasswordIfPrompted(_ password: String, usedStoredPassword: Bool) {
        guard !usedStoredPassword else { return }
        KeychainManager.shared.savePassword(
            kind: .sshPassword,
            account: profile.keychainAccount,
            secret: password
        )
    }

    /// Persist a prompted passphrase that just succeeded.
    func persistPassphraseIfPrompted(_ passphrase: String, usedStoredPassphrase: Bool) {
        guard !usedStoredPassphrase else { return }
        KeychainManager.shared.savePassword(
            kind: .sshKeyPassphrase,
            account: profile.keychainAccount,
            secret: passphrase
        )
    }

    // MARK: - Auth-failure eviction

    /// Called when a stored password was rejected. Evicts the stale entry
    /// so a re-prompt picks up the new value.
    func evictStalePassword() {
        KeychainManager.shared.deletePassword(kind: .sshPassword, account: profile.keychainAccount)
    }

    func evictStalePassphrase() {
        KeychainManager.shared.deletePassword(kind: .sshKeyPassphrase, account: profile.keychainAccount)
    }
}
