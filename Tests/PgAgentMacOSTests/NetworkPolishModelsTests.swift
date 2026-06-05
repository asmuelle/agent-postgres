import XCTest
@testable import PgAgentMacOS

final class NetworkPolishAddressTests: XCTestCase {
    func testTailscaleIPv4RangeClassification() {
        XCTAssertTrue(TailscaleAddressClassifier.isTailscaleAddress("100.64.0.1"))
        XCTAssertTrue(TailscaleAddressClassifier.isTailscaleAddress("100.127.255.254"))
        XCTAssertFalse(TailscaleAddressClassifier.isTailscaleAddress("100.63.255.255"))
        XCTAssertFalse(TailscaleAddressClassifier.isTailscaleAddress("100.128.0.1"))
        XCTAssertFalse(TailscaleAddressClassifier.isTailscaleAddress("203.0.113.10"))
    }

    func testTailscaleIPv6RangeClassification() {
        XCTAssertTrue(TailscaleAddressClassifier.isTailscaleAddress("fd7a:115c:a1e0::1"))
        XCTAssertTrue(TailscaleAddressClassifier.isTailscaleAddress("fd7a:115c:a1e0:abcd::1"))
        XCTAssertFalse(TailscaleAddressClassifier.isTailscaleAddress("fd7a:115c:a1e1::1"))
        XCTAssertFalse(TailscaleAddressClassifier.isTailscaleAddress("2001:db8::1"))
    }
}

final class NetworkPolishResolverTests: XCTestCase {
    func testSystemModeDoesNotResolveOrUseTailnetOverride() throws {
        let options = NetworkConnectionOptions(
            tailscaleResolutionMode: .system,
            tailscaleHostOverride: "api.tailnet.ts.net"
        )

        let resolution = try NetworkPolishResolver.resolve(
            host: "api.example.com",
            port: 22,
            options: options
        ) { _, _ in
            XCTFail("system mode should not perform a Tailnet preflight")
            return ["100.64.0.10"]
        }

        XCTAssertEqual(resolution.connectHost, "api.example.com")
        XCTAssertFalse(resolution.usedHostOverride)
        XCTAssertFalse(resolution.isTailnetRoute)
    }

    func testPreferTailnetUsesOverrideAndCapturesTailnetAddress() throws {
        let options = NetworkConnectionOptions(
            tailscaleResolutionMode: .preferTailnet,
            tailscaleHostOverride: "api.tailnet.ts.net"
        )

        let resolution = try NetworkPolishResolver.resolve(
            host: "api.example.com",
            port: 22,
            options: options
        ) { host, port in
            XCTAssertEqual(host, "api.tailnet.ts.net")
            XCTAssertEqual(port, 22)
            return ["100.88.1.20", "fd7a:115c:a1e0::20"]
        }

        XCTAssertEqual(resolution.connectHost, "api.tailnet.ts.net")
        XCTAssertEqual(resolution.tailnetAddress, "100.88.1.20")
        XCTAssertTrue(resolution.usedHostOverride)
        XCTAssertTrue(resolution.isTailnetRoute)
    }

    func testRequireTailnetFailsWhenLookupReturnsOnlyPublicAddresses() {
        let options = NetworkConnectionOptions(tailscaleResolutionMode: .requireTailnet)

        XCTAssertThrowsError(
            try NetworkPolishResolver.resolve(
                host: "api.example.com",
                port: 22,
                options: options
            ) { _, _ in ["203.0.113.10"] }
        ) { error in
            XCTAssertEqual(
                error as? TailscaleResolutionError,
                .requiredTailnetUnavailable(
                    host: "api.example.com",
                    port: 22,
                    resolvedAddresses: ["203.0.113.10"]
                )
            )
        }
    }
}

final class NetworkPolishPersistenceTests: XCTestCase {
    func testConnectionProfileDefaultsNetworkOptionsForLegacyRecords() throws {
        let json = """
        {
          "id": "profile-1",
          "name": "Prod",
          "host": "prod.example.com",
          "port": 22,
          "username": "deploy",
          "authMethod": "password",
          "kind": "ssh"
        }
        """

        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.networkOptions, .default)
    }

    func testSyncedProfileRoundTripsNetworkOptions() {
        let profile = ConnectionProfile(
            id: "profile-1",
            name: "Prod",
            host: "prod.example.com",
            username: "deploy",
            networkOptions: NetworkConnectionOptions(
                tailscaleResolutionMode: .requireTailnet,
                tailscaleHostOverride: "prod.tailnet.ts.net",
                multipathTCPMode: .interactive
            )
        )

        let record = SyncedConnectionProfileRecord(profile: profile)
        let restored = record.connectionProfile()

        XCTAssertEqual(restored.networkOptions.tailscaleResolutionMode, .requireTailnet)
        XCTAssertEqual(restored.networkOptions.tailscaleHostOverride, "prod.tailnet.ts.net")
        XCTAssertEqual(restored.networkOptions.multipathTCPMode, .interactive)
    }
}

final class NetworkPolishAuditTests: XCTestCase {
    func testAuditKeepsUnsupportedSSHCapabilitiesOutOfTheConnectPath() {
        let report = NetworkPolishAuditReport.current

        XCTAssertFalse(report.sshMultipathTCP.isSupported)
        XCTAssertTrue(report.urlSessionMultipathTCP.isSupported)
        XCTAssertFalse(report.postQuantumKex.exposesPostQuantumKex)
        XCTAssertTrue(report.postQuantumKex.missingPostQuantumAlgorithms.contains("sntrup761x25519-sha512@openssh.com"))
        XCTAssertTrue(report.postQuantumKex.missingPostQuantumAlgorithms.contains("mlkem768x25519-sha256"))
    }
}
