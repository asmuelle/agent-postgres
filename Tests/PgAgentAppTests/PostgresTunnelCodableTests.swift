import XCTest
@testable import PgAgentApp

// The iOS SSH-tunnel feature added inline SSH fields to `PostgresTunnel` (a
// shared type, so it's exercised here in the FFI-linked app test target).
// These tests lock in that the change stays backward-compatible with tunnels
// saved by earlier builds and by macOS — which reference a saved SSH profile
// and never write the inline fields — and that an inline round-trip preserves
// the new config.
final class PostgresTunnelCodableTests: XCTestCase {

    // MARK: - Backward compatibility

    func testDecodesLegacyProfileReferenceTunnel() throws {
        // Shape written by macOS / pre-inline builds: no ssh* fields.
        let json = """
        { "sshConnectionId": "deploy@bastion:22", "remoteHost": "127.0.0.1", "remotePort": 5432 }
        """
        let tunnel = try JSONDecoder().decode(PostgresTunnel.self, from: Data(json.utf8))

        XCTAssertEqual(tunnel.sshConnectionId, "deploy@bastion:22")
        XCTAssertEqual(tunnel.remoteHost, "127.0.0.1")
        XCTAssertEqual(tunnel.remotePort, 5432)
        XCTAssertNil(tunnel.sshHost)
        XCTAssertNil(tunnel.sshAuth)
        XCTAssertFalse(tunnel.isInline)
        XCTAssertNil(tunnel.sshKeychainAccount)
    }

    // MARK: - Inline round-trip

    func testInlineTunnelRoundTrips() throws {
        let original = PostgresTunnel(
            sshConnectionId: "F1E2-D3C4",
            remoteHost: "127.0.0.1",
            remotePort: 5432,
            sshHost: "bastion.example.com",
            sshPort: 2222,
            sshUser: "deploy",
            sshAuth: .privateKey
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PostgresTunnel.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.isInline)
        XCTAssertEqual(decoded.sshAuth, .privateKey)
    }

    // MARK: - Keychain account derivation

    func testSshKeychainAccountMatchesUserHostPort() {
        let tunnel = PostgresTunnel(
            sshConnectionId: "id",
            remoteHost: "127.0.0.1",
            remotePort: 5432,
            sshHost: "bastion.example.com",
            sshPort: 2222,
            sshUser: "deploy",
            sshAuth: .password
        )
        XCTAssertEqual(tunnel.sshKeychainAccount, "deploy@bastion.example.com:2222")
    }

    func testSshKeychainAccountDefaultsPortTo22() {
        let tunnel = PostgresTunnel(
            sshConnectionId: "id",
            remoteHost: "127.0.0.1",
            remotePort: 5432,
            sshHost: "bastion.example.com",
            sshUser: "deploy",
            sshAuth: .password
        )
        XCTAssertEqual(tunnel.sshKeychainAccount, "deploy@bastion.example.com:22")
    }
}
