import XCTest
@testable import PgAgentMacOS

final class PortForwardingModelsTests: XCTestCase {
    func testPortForwardProfileNormalizesAndSummarizesLocalForward() {
        let profile = PortForwardProfileRecord(
            id: "forward-1",
            profileId: "profile-1",
            name: "  Web  ",
            kind: .local,
            bindHost: " 127.0.0.1 ",
            bindPort: 8080,
            destinationHost: " localhost ",
            destinationPort: 80
        )

        XCTAssertEqual(profile.name, "Web")
        XCTAssertEqual(profile.bindHost, "127.0.0.1")
        XCTAssertEqual(profile.destinationHost, "localhost")
        XCTAssertEqual(profile.routeSummary, "127.0.0.1:8080 -> localhost:80")
        XCTAssertNil(profile.validationError)
    }

    func testDynamicSocksDoesNotRequireDestination() {
        let profile = PortForwardProfileRecord(
            id: "socks-1",
            profileId: "profile-1",
            name: "SOCKS",
            kind: .dynamicSocks,
            bindPort: 1080
        )

        XCTAssertFalse(profile.requiresDestination)
        XCTAssertNil(profile.validationError)
        XCTAssertEqual(profile.routeSummary, "SOCKS on 127.0.0.1:1080")
    }

    func testLocalForwardValidatesDestination() {
        let profile = PortForwardProfileRecord(
            id: "bad-1",
            profileId: "profile-1",
            name: "Bad",
            kind: .local,
            bindPort: 8080
        )

        XCTAssertEqual(profile.validationError, "Destination host is required.")
    }

    func testRuntimeStoreRoundTripsRecords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PortForwardRuntimeStore(directoryURL: directory)
        let record = PortForwardRuntimeRecord(
            id: "forward-1",
            profileId: "profile-1",
            connectionId: "conn-1",
            name: "Web",
            kind: .local,
            state: .running,
            bindHost: "127.0.0.1",
            requestedBindPort: 8080,
            boundPort: 49152,
            destinationHost: "localhost",
            destinationPort: 80,
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            bytesIn: 12,
            bytesOut: 34,
            connectionCount: 2
        )

        try store.upsert(record)

        XCTAssertEqual(try store.load().records, [record])
    }

    func testPortForwardWidgetSnapshotMapsRuntimeState() {
        let record = PortForwardRuntimeRecord(
            id: "forward-1",
            profileId: "profile-1",
            connectionId: "conn-1",
            name: "Web",
            kind: .local,
            state: .running,
            bindHost: "127.0.0.1",
            requestedBindPort: 8080,
            boundPort: 49152,
            destinationHost: "localhost",
            destinationPort: 80,
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        let snapshot = WidgetMonitorSnapshot.portForward(record, now: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(snapshot.id, "port-forward:forward-1")
        XCTAssertEqual(snapshot.kind, .tunnel)
        XCTAssertEqual(snapshot.state, .up)
        XCTAssertEqual(snapshot.summary, "127.0.0.1:49152 -> localhost:80")
    }
}
