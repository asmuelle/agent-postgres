import XCTest
@testable import PgAgentApp

// `SSHKeyGeneration` produces the key material that both platforms hand to
// russh, so a malformed blob would only surface as an opaque SSH auth failure
// at connect time. These tests parse the output back apart and assert it
// matches the OpenSSH wire format (PROTOCOL.key), rather than just checking
// that the PEM has the right header.
final class SSHKeyGenerationTests: XCTestCase {

    // MARK: - Public key line

    func testPublicKeyLineHasOpenSSHShape() throws {
        let key = try SSHKeyGeneration.generateEd25519(comment: "pgagent-test")

        let parts = key.publicKeyLine.split(separator: " ").map(String.init)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0], "ssh-ed25519")
        XCTAssertEqual(parts[2], "pgagent-test")

        let blob = try XCTUnwrap(Data(base64Encoded: parts[1]))
        // string("ssh-ed25519") + string(32-byte public key)
        XCTAssertEqual(blob.count, 4 + 11 + 4 + 32)
        XCTAssertEqual(String(data: blob[4..<15], encoding: .utf8), "ssh-ed25519")
    }

    func testEachGenerationProducesADistinctKey() throws {
        let first = try SSHKeyGeneration.generateEd25519(comment: "pgagent-test")
        let second = try SSHKeyGeneration.generateEd25519(comment: "pgagent-test")

        XCTAssertNotEqual(first.publicKeyLine, second.publicKeyLine)
        XCTAssertNotEqual(first.privateKeyPEM, second.privateKeyPEM)
        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
    }

    // MARK: - Fingerprint

    func testFingerprintIsUnpaddedBase64SHA256OfTheBlob() throws {
        let key = try SSHKeyGeneration.generateEd25519(comment: "pgagent-test")

        XCTAssertTrue(key.fingerprint.hasPrefix("SHA256:"))
        XCTAssertFalse(key.fingerprint.hasSuffix("="), "OpenSSH prints fingerprints without base64 padding")
        // 32-byte digest → 43 base64 characters once padding is stripped.
        XCTAssertEqual(key.fingerprint.count, "SHA256:".count + 43)
        // Stable for a given public key line.
        XCTAssertEqual(SSHKeyGeneration.fingerprint(publicKeyLine: key.publicKeyLine), key.fingerprint)
    }

    func testFingerprintRejectsNonKeyInput() {
        XCTAssertNil(SSHKeyGeneration.fingerprint(publicKeyLine: nil))
        XCTAssertNil(SSHKeyGeneration.fingerprint(publicKeyLine: "not-a-key"))
        XCTAssertNil(SSHKeyGeneration.fingerprint(publicKeyLine: "ssh-ed25519 !!!not-base64!!! comment"))
    }

    // MARK: - Private key container

    func testPrivateKeyIsAnUnencryptedOpenSSHV1Container() throws {
        let key = try SSHKeyGeneration.generateEd25519(comment: "pgagent-test")

        XCTAssertTrue(key.privateKeyPEM.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
        XCTAssertTrue(key.privateKeyPEM.hasSuffix("-----END OPENSSH PRIVATE KEY-----\n"))

        let body = try XCTUnwrap(base64Body(of: key.privateKeyPEM))
        var reader = TestSSHReader(body)

        XCTAssertEqual(reader.readBytes(15), Data("openssh-key-v1\0".utf8))
        XCTAssertEqual(reader.readString().map { String(decoding: $0, as: UTF8.self) }, "none", "cipher")
        XCTAssertEqual(reader.readString().map { String(decoding: $0, as: UTF8.self) }, "none", "kdf")
        XCTAssertEqual(reader.readString(), Data(), "kdfoptions must be empty when unencrypted")
        XCTAssertEqual(reader.readUInt32(), 1, "key count")

        let publicBlob = try XCTUnwrap(reader.readString())
        let privateBlock = try XCTUnwrap(reader.readString())

        // The embedded public blob must be byte-identical to the one advertised
        // in the public key line — otherwise the server would accept the
        // published key but the client would offer a different one.
        let advertised = try XCTUnwrap(
            Data(base64Encoded: String(key.publicKeyLine.split(separator: " ").map(String.init)[1]))
        )
        XCTAssertEqual(publicBlob, advertised)

        // The private block is padded to the cipher block size.
        XCTAssertEqual(privateBlock.count % 8, 0)
    }

    func testPrivateBlockCarriesMatchingCheckIntegersAndKeyMaterial() throws {
        let key = try SSHKeyGeneration.generateEd25519(comment: "pgagent-test")
        let body = try XCTUnwrap(base64Body(of: key.privateKeyPEM))

        var reader = TestSSHReader(body)
        _ = reader.readBytes(15)
        _ = reader.readString()
        _ = reader.readString()
        _ = reader.readString()
        _ = reader.readUInt32()
        let publicBlob = try XCTUnwrap(reader.readString())
        let privateBlock = try XCTUnwrap(reader.readString())

        var inner = TestSSHReader(privateBlock)
        let check1 = inner.readUInt32()
        let check2 = inner.readUInt32()
        XCTAssertNotNil(check1)
        XCTAssertEqual(check1, check2, "the two check integers must match for a passphrase check to succeed")

        XCTAssertEqual(inner.readString().map { String(decoding: $0, as: UTF8.self) }, "ssh-ed25519")
        let publicBytes = try XCTUnwrap(inner.readString())
        let privateBytes = try XCTUnwrap(inner.readString())
        XCTAssertEqual(inner.readString().map { String(decoding: $0, as: UTF8.self) }, "pgagent-test")

        XCTAssertEqual(publicBytes.count, 32)
        // OpenSSH stores the Ed25519 private key as seed || public.
        XCTAssertEqual(privateBytes.count, 64)
        XCTAssertEqual(privateBytes.suffix(32), publicBytes)
        // And the public half must match what the public blob advertises.
        XCTAssertTrue(publicBlob.suffix(32) == publicBytes)
    }

    // MARK: - Public key recovery from an imported key

    func testRecoversPublicKeyFromGeneratedPrivateKey() throws {
        let key = try SSHKeyGeneration.generateEd25519(comment: "original")

        let recovered = SSHKeyGeneration.publicKeyLine(
            fromOpenSSHPrivateKey: key.privateKeyPEM,
            comment: "recovered"
        )

        let originalBlob = key.publicKeyLine.split(separator: " ").map(String.init)[1]
        XCTAssertEqual(recovered, "ssh-ed25519 \(originalBlob) recovered")
        XCTAssertEqual(
            SSHKeyGeneration.fingerprint(publicKeyLine: recovered),
            key.fingerprint,
            "a recovered key must fingerprint identically — it's the same keypair"
        )
    }

    func testPublicKeyRecoveryFailsClosedOnNonOpenSSHInput() throws {
        // Legacy PEM: the public half isn't recoverable without ASN.1 parsing.
        XCTAssertNil(SSHKeyGeneration.publicKeyLine(
            fromOpenSSHPrivateKey: "-----BEGIN RSA PRIVATE KEY-----\nMIIBOgIBAAJBAK==\n-----END RSA PRIVATE KEY-----",
            comment: "c"
        ))
        XCTAssertNil(SSHKeyGeneration.publicKeyLine(fromOpenSSHPrivateKey: "", comment: "c"))
        XCTAssertNil(SSHKeyGeneration.publicKeyLine(fromOpenSSHPrivateKey: "not base64 at all !!!", comment: "c"))
    }

    func testTruncatedContainerDoesNotCrash() throws {
        let key = try SSHKeyGeneration.generateEd25519(comment: "pgagent-test")
        let body = try XCTUnwrap(base64Body(of: key.privateKeyPEM))

        // Every truncation of a valid container must be rejected, not trapped.
        for length in stride(from: 0, to: body.count, by: 7) {
            let truncated = """
            -----BEGIN OPENSSH PRIVATE KEY-----
            \(body.prefix(length).base64EncodedString())
            -----END OPENSSH PRIVATE KEY-----
            """
            _ = SSHKeyGeneration.publicKeyLine(fromOpenSSHPrivateKey: truncated, comment: "c")
        }
    }

    // MARK: - Private key detection

    func testLooksLikePrivateKeyAcceptsGeneratedKeysAndRejectsPublicOnes() throws {
        let key = try SSHKeyGeneration.generateEd25519(comment: "pgagent-test")

        XCTAssertTrue(SSHKeyGeneration.looksLikePrivateKey(key.privateKeyPEM))
        XCTAssertFalse(SSHKeyGeneration.looksLikePrivateKey(key.publicKeyLine))
        XCTAssertFalse(SSHKeyGeneration.looksLikePrivateKey("ssh-rsa AAAAB3Nza user@host"))
        XCTAssertFalse(SSHKeyGeneration.looksLikePrivateKey(""))
        XCTAssertTrue(SSHKeyGeneration.looksLikePrivateKey("-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----"))
    }

    // MARK: - Helpers

    private func base64Body(of pem: String) -> Data? {
        let joined = pem
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        return Data(base64Encoded: joined)
    }
}

/// Minimal SSH wire-format reader for assertions — deliberately independent of
/// the production reader so a bug there can't make these tests pass.
private struct TestSSHReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data }

    mutating func readBytes(_ count: Int) -> Data? {
        guard offset + count <= data.count else { return nil }
        defer { offset += count }
        return Data(data[data.index(data.startIndex, offsetBy: offset)...].prefix(count))
    }

    mutating func readUInt32() -> UInt32? {
        readBytes(4).map { $0.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
    }

    mutating func readString() -> Data? {
        guard let length = readUInt32() else { return nil }
        return readBytes(Int(length))
    }
}
