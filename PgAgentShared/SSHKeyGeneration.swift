import CryptoKit
import Foundation
import Security

// =============================================================================
// SSHKeyGeneration — on-device Ed25519 keypair generation and OpenSSH
// serialization, shared by both app targets.
//
// macOS reaches this through `SSHKeyVault` (its file-backed, AES-GCM encrypted
// key vault); iOS reaches it through `MobileSSHIdentityStore` (Keychain-backed
// named identities). Only Foundation/CryptoKit/Security are used so the file
// compiles for both platforms.
//
// The private key is emitted in the modern unencrypted `openssh-key-v1` format
// (RFC-less but documented in OpenSSH's PROTOCOL.key) because that is what
// russh accepts and what `ssh-keygen -t ed25519` produces.
// =============================================================================

enum SSHKeyGenerationError: LocalizedError {
    case randomUnavailable(OSStatus)

    var errorDescription: String? {
        switch self {
        case .randomUnavailable(let status):
            return "The system random number generator was unavailable (\(status))."
        }
    }
}

/// A freshly generated keypair: the private key to store, the public key line
/// to install on servers, and its fingerprint for display.
struct GeneratedSSHKey: Sendable {
    let privateKeyPEM: String
    let publicKeyLine: String
    let fingerprint: String
}

enum SSHKeyGeneration {
    private static let keyType = "ssh-ed25519"

    /// Generate an Ed25519 keypair. `comment` is embedded in both the public
    /// key line and the private key blob, matching `ssh-keygen -C`.
    static func generateEd25519(comment: String) throws -> GeneratedSSHKey {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicBytes = privateKey.publicKey.rawRepresentation
        // OpenSSH stores the Ed25519 private key as seed||public.
        let privateBytes = privateKey.rawRepresentation + publicBytes

        let publicKeyLine = openSSHPublicKey(publicBytes: publicBytes, comment: comment)
        let privateKeyPEM = try openSSHPrivateKey(
            privateBytes: privateBytes,
            publicBytes: publicBytes,
            comment: comment
        )
        return GeneratedSSHKey(
            privateKeyPEM: privateKeyPEM,
            publicKeyLine: publicKeyLine,
            fingerprint: fingerprint(publicKeyLine: publicKeyLine) ?? "SHA256:unknown"
        )
    }

    static func openSSHPublicKey(publicBytes: Data, comment: String) -> String {
        var blob = Data()
        blob.appendSSHString(Data(keyType.utf8))
        blob.appendSSHString(publicBytes)
        return "\(keyType) \(blob.base64EncodedString()) \(comment)"
    }

    static func openSSHPrivateKey(
        privateBytes: Data,
        publicBytes: Data,
        comment: String
    ) throws -> String {
        let check = try randomUInt32()

        var publicBlob = Data()
        publicBlob.appendSSHString(Data(keyType.utf8))
        publicBlob.appendSSHString(publicBytes)

        var privateBlock = Data()
        // The check integer is written twice; a decrypter that reads back two
        // matching values knows it applied the right passphrase.
        privateBlock.appendUInt32(check)
        privateBlock.appendUInt32(check)
        privateBlock.appendSSHString(Data(keyType.utf8))
        privateBlock.appendSSHString(publicBytes)
        privateBlock.appendSSHString(privateBytes)
        privateBlock.appendSSHString(Data(comment.utf8))
        // Pad to the cipher block size with the 1,2,3… sequence OpenSSH expects.
        var pad: UInt8 = 1
        while privateBlock.count % 8 != 0 {
            privateBlock.append(pad)
            pad &+= 1
        }

        var body = Data("openssh-key-v1\0".utf8)
        body.appendSSHString(Data("none".utf8))  // ciphername — unencrypted
        body.appendSSHString(Data("none".utf8))  // kdfname
        body.appendSSHString(Data())             // kdfoptions
        body.appendUInt32(1)                     // number of keys
        body.appendSSHString(publicBlob)
        body.appendSSHString(privateBlock)

        return """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(wrapBase64(body.base64EncodedString()))
        -----END OPENSSH PRIVATE KEY-----

        """
    }

    /// The `SHA256:…` fingerprint OpenSSH prints for a public key line.
    static func fingerprint(publicKeyLine: String?) -> String? {
        guard let publicKeyLine else { return nil }
        let parts = publicKeyLine.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        let digest = Data(SHA256.hash(data: blob))
            .base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(digest)"
    }

    /// Recover the public key line from an `openssh-key-v1` private key.
    ///
    /// The public-key list in that container is stored in the clear even when
    /// the private block is passphrase-encrypted, so this works for imported
    /// encrypted keys too. Returns nil for legacy PEM formats (`BEGIN RSA
    /// PRIVATE KEY` and friends), where the public part isn't recoverable
    /// without parsing ASN.1 and doing key math.
    static func publicKeyLine(fromOpenSSHPrivateKey pem: String, comment: String) -> String? {
        let base64 = pem
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        guard let body = Data(base64Encoded: base64) else { return nil }

        var reader = SSHBlobReader(body)
        guard reader.readBytes(count: magic.count) == magic,
              reader.readString() != nil,        // ciphername
              reader.readString() != nil,        // kdfname
              reader.readString() != nil,        // kdfoptions
              let keyCount = reader.readUInt32(), keyCount >= 1,
              let publicBlob = reader.readString()
        else { return nil }

        var blobReader = SSHBlobReader(publicBlob)
        guard let typeBytes = blobReader.readString(),
              let keyType = String(data: typeBytes, encoding: .utf8),
              keyType.hasPrefix("ssh-") || keyType.hasPrefix("ecdsa-")
        else { return nil }

        return "\(keyType) \(publicBlob.base64EncodedString()) \(comment)"
    }

    /// Whether text looks like a private key rather than a public key line or
    /// unrelated file — the gate before importing pasted key material.
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

    // MARK: - Private

    private static let magic = Data("openssh-key-v1\0".utf8)
    private static let base64LineWidth = 70

    private static func wrapBase64(_ encoded: String) -> String {
        stride(from: 0, to: encoded.count, by: base64LineWidth).map { offset -> String in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            let end = encoded.index(
                start,
                offsetBy: min(base64LineWidth, encoded.distance(from: start, to: encoded.endIndex))
            )
            return String(encoded[start..<end])
        }.joined(separator: "\n")
    }

    private static func randomUInt32() throws -> UInt32 {
        var bytes = Data(count: 4)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 4, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw SSHKeyGenerationError.randomUnavailable(status)
        }
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
    }
}

/// Sequential reader for the SSH wire format: length-prefixed strings and
/// big-endian integers. Every read is bounds-checked and returns nil past the
/// end, so a truncated or non-SSH blob fails closed instead of trapping.
private struct SSHBlobReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = 0
    }

    mutating func readBytes(count: Int) -> Data? {
        guard count >= 0, offset + count <= data.count else { return nil }
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: count)
        offset += count
        return Data(data[start..<end])
    }

    mutating func readUInt32() -> UInt32? {
        guard let bytes = readBytes(count: 4) else { return nil }
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readString() -> Data? {
        guard let length = readUInt32() else { return nil }
        return readBytes(count: Int(length))
    }
}

extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var bigEndian = value.bigEndian
        append(Data(bytes: &bigEndian, count: MemoryLayout<UInt32>.size))
    }

    /// Append an SSH wire-format string: a big-endian length prefix, then bytes.
    mutating func appendSSHString(_ data: Data) {
        appendUInt32(UInt32(data.count))
        append(data)
    }
}
