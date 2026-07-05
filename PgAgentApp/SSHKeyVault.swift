import CryptoKit
import Foundation
import OSLog
import Security
import PgAgentMacOS

struct SSHKeyMetadata: Equatable {
    let id: String
    let label: String
    let source: String
    let publicKey: String?
    let fingerprint: String?
}

enum SSHKeyVaultError: LocalizedError {
    case unreadable
    case tooLarge
    case unsupportedFormat
    case keyNotFound
    case keychainUnavailable(OSStatus)
    case encryptionFailed
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "The selected file could not be read as a private key."
        case .tooLarge:
            return "The selected private key is too large."
        case .unsupportedFormat:
            return "The selected file does not look like a supported private key."
        case .keyNotFound:
            return "The SSH key could not be found in the app key vault."
        case .keychainUnavailable(let status):
            return "The app key vault could not unlock its Keychain secret (\(status))."
        case .encryptionFailed:
            return "The SSH key could not be encrypted for the app key vault."
        case .decryptionFailed:
            return "The SSH key could not be decrypted from the app key vault."
        }
    }
}

private struct SSHKeyVaultRecord: Codable {
    let id: String
    let label: String
    let source: String
    let createdAt: Date
    let publicKey: String?
    let fingerprint: String?
    let encryptedKey: Data
}

final class SSHKeyVault {
    static let shared = SSHKeyVault()

    private let fileManager = FileManager.default
    private let maxKeyBytes = 256 * 1024
    private let keychainService = "com.mc-ssh.ssh.key-vault"
    private let keychainAccount = "master-key"
    private let logger = Logger(subsystem: "com.mc-ssh", category: "ssh-key-vault")

    private init() {}

    /// True when a master key exists in the Keychain and at least one
    /// vault record is readable. False after a Keychain reset or
    /// migration, in which case the caller should surface a warning
    /// before the user blames the app for "losing" keys that were
    /// encrypted with a now-missing master key.
    var isVaultOperational: Bool {
        guard hasMasterKey() else { return false }
        // If there are vault records, the master key must actually
        // decrypt them. Probe the first record — cheap because we
        // only need to check one, and the vault is expected to be
        // small (tens of keys at most).
        guard let url = findFirstRecord() else { return true }
        do {
            let data = try Data(contentsOf: url)
            let record = try JSONDecoder.midnightSSH.decode(SSHKeyVaultRecord.self, from: data)
            _ = try decrypt(record.encryptedKey)
            return true
        } catch {
            return false
        }
    }

    private func hasMasterKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess && (item as? Data)?.count == 32
    }

    private func findFirstRecord() -> URL? {
        let dir = vaultDirectory()
        guard let names = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return nil }
        return names.first { $0.hasSuffix(".msshkey") }.map { dir.appendingPathComponent($0) }
    }

    func importKey(from sourceURL: URL) throws -> SSHKeyReference {
        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let resourceValues = try sourceURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard resourceValues.isDirectory != true else { throw SSHKeyVaultError.unreadable }
        if let fileSize = resourceValues.fileSize, fileSize > maxKeyBytes {
            throw SSHKeyVaultError.tooLarge
        }

        let keyData = try Data(contentsOf: sourceURL)
        guard !keyData.isEmpty, keyData.count <= maxKeyBytes else {
            throw keyData.isEmpty ? SSHKeyVaultError.unreadable : SSHKeyVaultError.tooLarge
        }
        guard let text = String(data: keyData, encoding: .utf8), Self.looksLikePrivateKey(text) else {
            throw SSHKeyVaultError.unsupportedFormat
        }

        let publicKey = Self.readAdjacentPublicKey(for: sourceURL)
        let id = UUID().uuidString
        try writeRecord(
            id: id,
            label: sourceURL.lastPathComponent.isEmpty ? "Imported SSH key" : sourceURL.lastPathComponent,
            source: "Imported",
            privateKey: keyData,
            publicKey: publicKey
        )
        return .importedVaultKey(id: id)
    }

    func generateEd25519Key(comment: String) throws -> (reference: SSHKeyReference, publicKey: String, fingerprint: String) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicBytes = privateKey.publicKey.rawRepresentation
        let privateBytes = privateKey.rawRepresentation + publicBytes
        let publicKey = Self.openSSHPublicKey(publicBytes: publicBytes, comment: comment)
        let fingerprint = Self.fingerprint(publicKeyLine: publicKey) ?? "SHA256:unknown"
        let privateKeyText = try Self.openSSHPrivateKey(
            privateBytes: privateBytes,
            publicBytes: publicBytes,
            comment: comment
        )

        let id = UUID().uuidString
        try writeRecord(
            id: id,
            label: "pgAgent \(comment)",
            source: "Generated",
            privateKey: Data(privateKeyText.utf8),
            publicKey: publicKey
        )
        return (.generatedVaultKey(id: id), publicKey, fingerprint)
    }

    func metadata(for reference: SSHKeyReference?) -> SSHKeyMetadata? {
        guard let reference else { return nil }
        switch reference {
        case .plainPath(let path):
            return SSHKeyMetadata(
                id: path,
                label: URL(fileURLWithPath: path).lastPathComponent,
                source: "Plain path",
                publicKey: Self.readAdjacentPublicKey(for: URL(fileURLWithPath: path)),
                fingerprint: Self.fingerprint(publicKeyLine: Self.readAdjacentPublicKey(for: URL(fileURLWithPath: path)))
            )
        case .securityScopedBookmark(let data):
            guard let url = try? Self.resolveBookmark(data) else {
                return SSHKeyMetadata(
                    id: "external",
                    label: "External key",
                    source: "External",
                    publicKey: nil,
                    fingerprint: nil
                )
            }
            let publicKey = Self.readAdjacentPublicKey(for: url)
            return SSHKeyMetadata(
                id: url.path,
                label: url.lastPathComponent,
                source: "External",
                publicKey: publicKey,
                fingerprint: Self.fingerprint(publicKeyLine: publicKey)
            )
        case .importedVaultKey(let id), .generatedVaultKey(let id):
            guard let record = try? readRecord(id: id) else { return nil }
            return SSHKeyMetadata(
                id: record.id,
                label: record.label,
                source: record.source,
                publicKey: record.publicKey,
                fingerprint: record.fingerprint
            )
        case .agent(let identityHint):
            return SSHKeyMetadata(
                id: identityHint ?? "agent",
                label: identityHint?.isEmpty == false ? identityHint! : "Default SSH agent identity",
                source: "SSH agent",
                publicKey: nil,
                fingerprint: nil
            )
        case .advancedAuthIdentity(let id):
            let identity = (try? PlatformIntegrationStore().load())?.authIdentity(id: id)
            guard let identity else {
                return SSHKeyMetadata(
                    id: id,
                    label: "Advanced identity \(String(id.prefix(8)))",
                    source: "Advanced",
                    publicKey: nil,
                    fingerprint: nil
                )
            }
            return SSHKeyMetadata(
                id: identity.id,
                label: identity.displayName,
                source: identity.kind.displayName,
                publicKey: identity.publicKey,
                fingerprint: identity.publicKeyFingerprint
            )
        }
    }

    func materializeKey(id: String) throws -> URL {
        let record = try readRecord(id: id)
        let privateKey = try decrypt(record.encryptedKey)
        let directory = try materializedDirectory()
        let url = directory.appendingPathComponent("\(id).key", isDirectory: false)
        try privateKey.write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    func deleteKey(id: String) {
        try? fileManager.removeItem(at: recordURL(id: id))
    }

    /// Purge every file in the materialized-keys directory. Decrypted keys
    /// are normally removed by their session's teardown, but a crash strands
    /// plaintext key files on disk indefinitely. At app launch no sessions
    /// are live, so a full purge is always safe — call this once from
    /// startup before any connection can materialize a key.
    func sweepStaleMaterializedKeys() {
        guard let dir = try? materializedDirectory(),
              let names = try? fileManager.contentsOfDirectory(atPath: dir.path)
        else { return }
        var removed = 0
        for name in names {
            let url = dir.appendingPathComponent(name)
            do {
                try fileManager.removeItem(at: url)
                removed += 1
            } catch {
                logger.error("Failed to sweep stale materialized key \(name, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
        }
        if removed > 0 {
            logger.notice("Swept \(removed) stale materialized SSH key file(s) left by a previous session")
        }
    }

    static func fingerprint(publicKeyLine: String?) -> String? {
        guard let publicKeyLine else { return nil }
        let parts = publicKeyLine.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        let digest = Data(SHA256.hash(data: blob))
            .base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(digest)"
    }

    static func looksLikePrivateKey(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("ssh-rsa "),
              !trimmed.hasPrefix("ssh-ed25519 "),
              !trimmed.hasPrefix("ecdsa-sha2-") else {
            return false
        }

        let markers = [
            "-----BEGIN OPENSSH PRIVATE KEY-----",
            "-----BEGIN RSA PRIVATE KEY-----",
            "-----BEGIN EC PRIVATE KEY-----",
            "-----BEGIN DSA PRIVATE KEY-----",
            "-----BEGIN PRIVATE KEY-----",
            "PuTTY-User-Key-File-",
        ]
        return markers.contains { trimmed.contains($0) }
    }

    private func writeRecord(
        id: String,
        label: String,
        source: String,
        privateKey: Data,
        publicKey: String?
    ) throws {
        let record = SSHKeyVaultRecord(
            id: id,
            label: label,
            source: source,
            createdAt: Date(),
            publicKey: publicKey,
            fingerprint: Self.fingerprint(publicKeyLine: publicKey),
            encryptedKey: try encrypt(privateKey)
        )
        let data = try JSONEncoder.midnightSSH.encode(record)
        let url = recordURL(id: id)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try excludeFromBackups(url.deletingLastPathComponent())
    }

    private func readRecord(id: String) throws -> SSHKeyVaultRecord {
        let url = recordURL(id: id)
        guard fileManager.fileExists(atPath: url.path) else { throw SSHKeyVaultError.keyNotFound }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.midnightSSH.decode(SSHKeyVaultRecord.self, from: data)
    }

    private func encrypt(_ data: Data) throws -> Data {
        let key = SymmetricKey(data: try masterKey())
        guard let combined = try AES.GCM.seal(data, using: key).combined else {
            throw SSHKeyVaultError.encryptionFailed
        }
        return combined
    }

    private func decrypt(_ data: Data) throws -> Data {
        let key = SymmetricKey(data: try masterKey())
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw SSHKeyVaultError.decryptionFailed
        }
    }

    private func masterKey() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            return data
        }
        if status != errSecItemNotFound {
            throw SSHKeyVaultError.keychainUnavailable(status)
        }

        var bytes = Data(count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw SSHKeyVaultError.keychainUnavailable(randomStatus)
        }

        var addQuery = query
        addQuery.removeValue(forKey: kSecReturnData as String)
        addQuery.removeValue(forKey: kSecMatchLimit as String)
        addQuery[kSecValueData as String] = bytes
        // Pin the accessibility class explicitly — readable only while the
        // device is unlocked, never migrated to another device — matching
        // AdvancedAuthenticationStore and the iOS KeychainManager. Existing
        // installs keep the class their item was created with; only newly
        // created master keys get the pinned attribute.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SSHKeyVaultError.keychainUnavailable(addStatus)
        }
        return bytes
    }

    private func recordURL(id: String) -> URL {
        vaultDirectory().appendingPathComponent("\(id).msshkey", isDirectory: false)
    }

    private func vaultDirectory() -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("pgAgent", isDirectory: true)
            .appendingPathComponent("key-vault", isDirectory: true)
    }

    private func materializedDirectory() throws -> URL {
        // Keep decrypted key material out of /tmp (world-readable on
        // macOS by default) and inside the app's own Application Support
        // hierarchy, which macOS sandbox rules scope to the app alone.
        let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        let dir = url
            .appendingPathComponent("com.mc-ssh", isDirectory: true)
            .appendingPathComponent("materialized-keys", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        // Set the directory itself to owner-only so no inherited ACL
        // grants read access to other processes.
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    private func excludeFromBackups(_ url: URL) throws {
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try resourceURL.setResourceValues(values)
    }

    private static func resolveBookmark(_ data: Data) throws -> URL {
        var isStale = false
        return try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    private static func readAdjacentPublicKey(for privateKeyURL: URL) -> String? {
        let publicURL = URL(fileURLWithPath: privateKeyURL.path + ".pub")
        guard let data = try? Data(contentsOf: publicURL),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let line = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard line?.hasPrefix("ssh-") == true || line?.hasPrefix("ecdsa-") == true else {
            return nil
        }
        return line
    }

    private static func openSSHPublicKey(publicBytes: Data, comment: String) -> String {
        var blob = Data()
        blob.appendSSHString(Data("ssh-ed25519".utf8))
        blob.appendSSHString(publicBytes)
        return "ssh-ed25519 \(blob.base64EncodedString()) \(comment)"
    }

    private static func openSSHPrivateKey(
        privateBytes: Data,
        publicBytes: Data,
        comment: String
    ) throws -> String {
        var checkBytes = Data(count: 4)
        let randomStatus = checkBytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 4, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw SSHKeyVaultError.keychainUnavailable(randomStatus)
        }
        let check = checkBytes.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian

        var publicBlob = Data()
        publicBlob.appendSSHString(Data("ssh-ed25519".utf8))
        publicBlob.appendSSHString(publicBytes)

        var privateBlock = Data()
        privateBlock.appendUInt32(check)
        privateBlock.appendUInt32(check)
        privateBlock.appendSSHString(Data("ssh-ed25519".utf8))
        privateBlock.appendSSHString(publicBytes)
        privateBlock.appendSSHString(privateBytes)
        privateBlock.appendSSHString(Data(comment.utf8))
        var pad: UInt8 = 1
        repeat {
            privateBlock.append(pad)
            pad &+= 1
        } while privateBlock.count % 8 != 0

        var body = Data("openssh-key-v1\0".utf8)
        body.appendSSHString(Data("none".utf8))
        body.appendSSHString(Data("none".utf8))
        body.appendSSHString(Data())
        body.appendUInt32(1)
        body.appendSSHString(publicBlob)
        body.appendSSHString(privateBlock)

        let encoded = body.base64EncodedString()
        let wrapped = stride(from: 0, to: encoded.count, by: 70).map { offset -> String in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            let end = encoded.index(start, offsetBy: min(70, encoded.distance(from: start, to: encoded.endIndex)))
            return String(encoded[start..<end])
        }.joined(separator: "\n")

        return """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(wrapped)
        -----END OPENSSH PRIVATE KEY-----

        """
    }
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var bigEndian = value.bigEndian
        append(Data(bytes: &bigEndian, count: MemoryLayout<UInt32>.size))
    }

    mutating func appendSSHString(_ data: Data) {
        appendUInt32(UInt32(data.count))
        append(data)
    }
}

private extension JSONEncoder {
    static var midnightSSH: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var midnightSSH: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
