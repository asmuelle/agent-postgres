import AppKit
import CryptoKit
import Foundation
import LocalAuthentication
import PgAgentMacOS
import Security

enum AdvancedAuthenticationError: LocalizedError {
    case secureEnclaveUnavailable
    case keychainStatus(OSStatus)
    case identityNotFound
    case unsupportedIdentity(String)
    case invalidCertificate
    case invalidSecurityKey

    var errorDescription: String? {
        switch self {
        case .secureEnclaveUnavailable:
            return "Secure Enclave keys are not available on this device."
        case .keychainStatus(let status):
            return "The advanced authentication keychain item failed with status \(status)."
        case .identityNotFound:
            return "The advanced authentication identity could not be found."
        case .unsupportedIdentity(let detail):
            return detail
        case .invalidCertificate:
            return "Choose an OpenSSH user certificate public key (*-cert.pub)."
        case .invalidSecurityKey:
            return "Choose an OpenSSH security-key public key."
        }
    }
}

@MainActor
final class AdvancedAuthenticationStore: ObservableObject {
    static let shared = AdvancedAuthenticationStore()

    @Published private(set) var identities: [AdvancedAuthIdentityRecord] = []
    @Published var lastError: String?

    private let integrationStore = PlatformIntegrationStore()

    private init() {
        reload()
    }

    func reload() {
        do {
            identities = try integrationStore.load().authIdentities.sorted(by: identitySort)
            lastError = nil
        } catch {
            identities = []
            lastError = error.localizedDescription
        }
    }

    func upsert(_ identity: AdvancedAuthIdentityRecord) {
        do {
            var data = try integrationStore.load()
            if let index = data.authIdentities.firstIndex(where: { $0.id == identity.id }) {
                data.authIdentities[index] = identity
            } else {
                data.authIdentities.append(identity)
            }
            data.authIdentities.sort(by: identitySort)
            try integrationStore.save(data)
            identities = data.authIdentities
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func delete(_ identity: AdvancedAuthIdentityRecord) {
        do {
            if identity.kind == .secureEnclaveKey, let account = identity.keychainAccount {
                try SecureEnclaveSSHIdentityStore.shared.deleteKeyReference(account: account)
            }
            var data = try integrationStore.load()
            data.authIdentities.removeAll { $0.id == identity.id }
            try integrationStore.save(data)
            identities = data.authIdentities.sorted(by: identitySort)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func identity(id: String) -> AdvancedAuthIdentityRecord? {
        identities.first { $0.id == id }
    }

    private func identitySort(
        _ lhs: AdvancedAuthIdentityRecord,
        _ rhs: AdvancedAuthIdentityRecord
    ) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind.displayName.localizedStandardCompare(rhs.kind.displayName) == .orderedAscending
        }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
}

final class SecureEnclaveSSHIdentityStore {
    static let shared = SecureEnclaveSSHIdentityStore()

    private let keychainService = "com.mc-ssh.advanced-auth.secure-enclave"
    private let challenge = Data("pgAgent-secure-enclave-probe".utf8)

    private init() {}

    func generateIdentity(label rawLabel: String) throws -> AdvancedAuthIdentityRecord {
        guard SecureEnclave.isAvailable else { throw AdvancedAuthenticationError.secureEnclaveUnavailable }

        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = label.isEmpty ? "Secure Enclave SSH key" : label
        let context = LAContext()
        context.localizedReason = "Create a Secure Enclave SSH identity."

        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet],
            &accessError
        ) else {
            if let error = accessError?.takeRetainedValue() {
                throw error as Error
            }
            throw AdvancedAuthenticationError.secureEnclaveUnavailable
        }

        let privateKey = try SecureEnclave.P256.Signing.PrivateKey(
            accessControl: accessControl,
            authenticationContext: context
        )
        let id = UUID().uuidString
        try saveKeyReference(privateKey.dataRepresentation, account: id)

        let publicKey = Self.openSSHPublicKey(
            x963Representation: privateKey.publicKey.x963Representation,
            comment: "pgAgent-\(id.prefix(8))"
        )

        return AdvancedAuthIdentityRecord(
            id: id,
            kind: .secureEnclaveKey,
            displayName: displayName,
            publicKey: publicKey,
            publicKeyFingerprint: SSHKeyVault.fingerprint(publicKeyLine: publicKey),
            keychainAccount: id,
            createdAt: Date(),
            updatedAt: Date(),
            requiresBiometricApproval: true,
            agentApprovalWindow: .currentSession
        )
    }

    func signProbe(identity: AdvancedAuthIdentityRecord) throws -> String {
        guard identity.kind == .secureEnclaveKey,
              let account = identity.keychainAccount else {
            throw AdvancedAuthenticationError.unsupportedIdentity("Only Secure Enclave identities can run a biometric signing test.")
        }
        let context = LAContext()
        context.localizedReason = "Approve Secure Enclave signing for \(identity.displayName)."
        let reference = try loadKeyReference(account: account)
        let privateKey = try SecureEnclave.P256.Signing.PrivateKey(
            dataRepresentation: reference,
            authenticationContext: context
        )
        let signature = try privateKey.signature(for: challenge)
        return signature.derRepresentation.base64EncodedString()
    }

    func importSSHCertificate(from url: URL) throws -> AdvancedAuthIdentityRecord {
        let line = try Self.firstPublicKeyLine(from: url)
        guard line.contains("-cert-v01@openssh.com") else {
            throw AdvancedAuthenticationError.invalidCertificate
        }
        let comment = Self.comment(from: line) ?? url.deletingPathExtension().lastPathComponent
        return AdvancedAuthIdentityRecord(
            kind: .sshCertificate,
            displayName: comment.isEmpty ? "SSH certificate" : comment,
            publicKey: line,
            publicKeyFingerprint: SSHKeyVault.fingerprint(publicKeyLine: line),
            keychainAccount: nil,
            certificate: line,
            createdAt: Date(),
            updatedAt: Date(),
            agentApprovalWindow: .once
        )
    }

    func importSecurityKeyPublicKey(from url: URL) throws -> AdvancedAuthIdentityRecord {
        let line = try Self.firstPublicKeyLine(from: url)
        let type = line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard type.hasPrefix("sk-") || type.contains("-sk-") else {
            throw AdvancedAuthenticationError.invalidSecurityKey
        }
        let comment = Self.comment(from: line) ?? url.deletingPathExtension().lastPathComponent
        return AdvancedAuthIdentityRecord(
            kind: .securityKey,
            displayName: comment.isEmpty ? "Security key" : comment,
            publicKey: line,
            publicKeyFingerprint: SSHKeyVault.fingerprint(publicKeyLine: line),
            createdAt: Date(),
            updatedAt: Date(),
            requiresBiometricApproval: true,
            agentApprovalWindow: .once
        )
    }

    func loadKeyReference(account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw status == errSecItemNotFound
                ? AdvancedAuthenticationError.identityNotFound
                : AdvancedAuthenticationError.keychainStatus(status)
        }
        return data
    }

    func deleteKeyReference(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AdvancedAuthenticationError.keychainStatus(status)
        }
    }

    private func saveKeyReference(_ data: Data, account: String) throws {
        try? deleteKeyReference(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AdvancedAuthenticationError.keychainStatus(status)
        }
    }

    private static func firstPublicKeyLine(from url: URL) throws -> String {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let line = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
              line.split(whereSeparator: \.isWhitespace).count >= 2
        else {
            throw AdvancedAuthenticationError.invalidSecurityKey
        }
        return line
    }

    private static func comment(from publicKeyLine: String) -> String? {
        let parts = publicKeyLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3 else { return nil }
        let comment = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
        return comment.isEmpty ? nil : comment
    }

    private static func openSSHPublicKey(x963Representation: Data, comment: String) -> String {
        let keyType = "ecdsa-sha2-nistp256"
        var blob = Data()
        blob.appendAdvancedAuthSSHString(Data(keyType.utf8))
        blob.appendAdvancedAuthSSHString(Data("nistp256".utf8))
        blob.appendAdvancedAuthSSHString(x963Representation)
        return "\(keyType) \(blob.base64EncodedString()) \(comment)"
    }
}

private extension Data {
    mutating func appendAdvancedAuthUInt32(_ value: UInt32) {
        var bigEndian = value.bigEndian
        append(Data(bytes: &bigEndian, count: MemoryLayout<UInt32>.size))
    }

    mutating func appendAdvancedAuthSSHString(_ data: Data) {
        appendAdvancedAuthUInt32(UInt32(data.count))
        append(data)
    }
}
