import Combine
import Foundation
import OSLog

// =============================================================================
// MobileSSHIdentityStore — named SSH keypairs shared across connections (iOS).
//
// Before this, every Postgres profile with a private-key tunnel needed its own
// pasted key, stored under the endpoint account `user@host:port`. An identity
// instead owns the key once, under the account `identity:<uuid>`, and any
// number of tunnels point at it via `PostgresTunnel.sshIdentityId`.
//
// Split of responsibilities:
//   • private key PEM  → Keychain, via the existing `MobileSSHKeyStore`
//   • passphrase       → Keychain, via `KeychainManager` (.sshKeyPassphrase)
//   • public metadata  → this store's JSON file (name, public key, fingerprint)
//
// Identities are deliberately device-local: the private key is stored
// `…ThisDeviceOnly` and never enters iCloud sync, so the metadata file is not
// part of `CloudSyncEngine` either.
// =============================================================================

enum MobileSSHIdentitySource: String, Codable, Hashable, Sendable {
    case generated
    case imported

    var displayName: String {
        switch self {
        case .generated: return "Generated on this device"
        case .imported:  return "Imported"
        }
    }
}

struct MobileSSHIdentity: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    /// The `ssh-ed25519 AAAA… comment` line to install on servers. Nil only
    /// for imported legacy-PEM keys, where it isn't recoverable.
    var publicKey: String?
    var fingerprint: String?
    var source: MobileSSHIdentitySource
    var createdAt: Date
    /// Whether the stored key needs a passphrase. Recorded at import so a
    /// passphrase that fails to load is distinguishable from a key that never
    /// had one — otherwise an encrypted key gets opened as unencrypted and the
    /// only symptom is an opaque SSH auth failure.
    var isEncrypted: Bool = false

    /// Keychain account for this identity's key material. Namespaced so it can
    /// never collide with an endpoint account (`user@host:port`).
    var keychainAccount: String { "identity:\(id)" }
}

enum MobileSSHIdentityError: LocalizedError {
    case nameRequired
    case unsupportedFormat
    case keychainWriteFailed
    case notFound

    var errorDescription: String? {
        switch self {
        case .nameRequired:
            return "Give the identity a name so you can tell it apart from your other keys."
        case .unsupportedFormat:
            return "That doesn't look like an SSH private key. Paste the contents of a private key file (it starts with \"-----BEGIN\")."
        case .keychainWriteFailed:
            return "Couldn't save the key to the Keychain. The identity was not created."
        case .notFound:
            return "That SSH identity no longer exists on this device."
        }
    }
}

@MainActor
final class MobileSSHIdentityStore: ObservableObject {
    static let shared = MobileSSHIdentityStore()

    @Published private(set) var identities: [MobileSSHIdentity] = []

    private let logger = Logger(subsystem: "com.mc-ssh", category: "mobile-ssh-identity-store")

    private static var storeFileURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let dir = appSupport.appendingPathComponent("com.mc-ssh")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ssh-identities.json")
    }

    private init() {
        load()
    }

    // MARK: - Lookup

    func identity(id: String?) -> MobileSSHIdentity? {
        guard let id else { return nil }
        return identities.first { $0.id == id }
    }

    /// The private key PEM for an identity, read straight from the Keychain.
    /// Never cached in memory — the resolver asks for it per connect.
    func privateKeyPEM(id: String) -> String? {
        guard let identity = identity(id: id) else { return nil }
        return MobileSSHKeyStore.load(account: identity.keychainAccount)
    }

    /// The passphrase for an encrypted imported key, or nil when the key is
    /// unencrypted (the generated case is always unencrypted).
    ///
    /// Callers must check `identity.isEncrypted` before treating nil as "no
    /// passphrase" — see `MobileSSHIdentity.isEncrypted`.
    func passphrase(id: String) -> String? {
        guard let identity = identity(id: id) else { return nil }
        let stored = MobileSSHKeyStore.loadPassphrase(account: identity.keychainAccount)
        return (stored?.isEmpty == false) ? stored : nil
    }

    // MARK: - Mutation

    /// Generate a new Ed25519 keypair on the device and store it.
    @discardableResult
    func create(name: String) throws -> MobileSSHIdentity {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw MobileSSHIdentityError.nameRequired }

        let id = UUID().uuidString
        let generated = try SSHKeyGeneration.generateEd25519(comment: keyComment(for: trimmedName))

        let identity = MobileSSHIdentity(
            id: id,
            name: trimmedName,
            publicKey: generated.publicKeyLine,
            fingerprint: generated.fingerprint,
            source: .generated,
            createdAt: Date()
        )
        guard MobileSSHKeyStore.save(pem: generated.privateKeyPEM, account: identity.keychainAccount) else {
            throw MobileSSHIdentityError.keychainWriteFailed
        }

        identities.append(identity)
        persist()
        logger.log("Created SSH identity \(id, privacy: .public)")
        return identity
    }

    /// Store an existing private key as a shared identity.
    @discardableResult
    func importKey(name: String, pem: String, passphrase: String) throws -> MobileSSHIdentity {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw MobileSSHIdentityError.nameRequired }

        let trimmedPem = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SSHKeyGeneration.looksLikePrivateKey(trimmedPem) else {
            throw MobileSSHIdentityError.unsupportedFormat
        }

        let id = UUID().uuidString
        // Recoverable for openssh-key-v1 keys (even encrypted ones); nil for
        // legacy PEM, where the UI tells the user to add the .pub themselves.
        let publicKey = SSHKeyGeneration.publicKeyLine(
            fromOpenSSHPrivateKey: trimmedPem,
            comment: keyComment(for: trimmedName)
        )

        let identity = MobileSSHIdentity(
            id: id,
            name: trimmedName,
            publicKey: publicKey,
            fingerprint: SSHKeyGeneration.fingerprint(publicKeyLine: publicKey),
            source: .imported,
            createdAt: Date(),
            isEncrypted: !passphrase.isEmpty
        )
        // The PEM is stored with its trailing newline restored — some key
        // parsers reject a file that doesn't end in one.
        guard MobileSSHKeyStore.save(pem: trimmedPem + "\n", account: identity.keychainAccount) else {
            throw MobileSSHIdentityError.keychainWriteFailed
        }
        guard persistPassphrase(passphrase, account: identity.keychainAccount) else {
            MobileSSHKeyStore.delete(account: identity.keychainAccount)
            throw MobileSSHIdentityError.keychainWriteFailed
        }

        identities.append(identity)
        persist()
        logger.log("Imported SSH identity \(id, privacy: .public)")
        return identity
    }

    func rename(id: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MobileSSHIdentityError.nameRequired }
        guard let index = identities.firstIndex(where: { $0.id == id }) else {
            throw MobileSSHIdentityError.notFound
        }
        identities[index].name = trimmed
        persist()
    }

    /// Delete an identity and evict its Keychain material. Connections still
    /// pointing at it are left alone — they surface a "pick another identity"
    /// error at connect time rather than silently falling back to another key.
    func delete(id: String) {
        guard let index = identities.firstIndex(where: { $0.id == id }) else { return }
        let identity = identities[index]
        MobileSSHKeyStore.delete(account: identity.keychainAccount)
        MobileSSHKeyStore.deletePassphrase(account: identity.keychainAccount)
        identities.remove(at: index)
        persist()
        logger.log("Deleted SSH identity \(id, privacy: .public)")
    }

    /// Profiles whose tunnel uses this identity — shown before a delete so the
    /// user knows what they're about to break.
    func profilesUsing(id: String) -> [PostgresProfile] {
        PostgresProfileStore.shared.profiles.filter { $0.tunnel?.sshIdentityId == id }
    }

    // MARK: - Persistence

    private func persistPassphrase(_ passphrase: String, account: String) -> Bool {
        if passphrase.isEmpty {
            return MobileSSHKeyStore.deletePassphrase(account: account)
        }
        return MobileSSHKeyStore.savePassphrase(passphrase, account: account)
    }

    private func keyComment(for name: String) -> String {
        // Mirrors ssh-keygen's user@host comment shape closely enough to be
        // recognizable in authorized_keys, without leaking the device name.
        let slug = name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return "pgagent-\(slug.isEmpty ? "identity" : slug)"
    }

    private func load() {
        let url = Self.storeFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            identities = try decoder.decode([MobileSSHIdentity].self, from: data)
        } catch {
            logger.error("Failed to load SSH identities: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(identities).write(to: Self.storeFileURL, options: [.atomic])
        } catch {
            logger.error("Failed to save SSH identities: \(error.localizedDescription, privacy: .public)")
        }
    }
}
