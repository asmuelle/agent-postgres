import XCTest
@testable import PgAgentApp

/// `duplicated()` backs "Duplicate" on iPhone and iPad. The iPad copy used to
/// rebuild the profile field by field and silently dropped the environment
/// and read-only flag — a duplicated read-only production connection came
/// back writable and unmarked.
final class PostgresProfileDuplicateTests: XCTestCase {
    private func productionProfile() -> PostgresProfile {
        PostgresProfile(
            id: "orig",
            name: "Orders",
            host: "db.internal",
            port: 6543,
            database: "orders",
            user: "ops",
            tls: .verifyFull,
            tunnel: PostgresTunnel(
                sshConnectionId: "",
                remoteHost: "10.0.0.5",
                remotePort: 5432,
                sshHost: "bastion",
                sshUser: "ops"
            ),
            maxPoolSize: 2,
            folderPath: "Prod",
            createdAt: Date(timeIntervalSince1970: 1_000),
            lastConnected: Date(timeIntervalSince1970: 2_000),
            color: "production",
            notes: "primary",
            environment: .production,
            isReadOnly: true,
            updatedAt: Date(timeIntervalSince1970: 3_000)
        )
    }

    func testDuplicateKeepsSafetySettings() {
        let copy = productionProfile().duplicated()

        XCTAssertEqual(copy.environment, .production)
        XCTAssertTrue(copy.isReadOnly)
        XCTAssertEqual(copy.color, "production")
    }

    func testDuplicateKeepsConnectionSettings() {
        let original = productionProfile()
        let copy = original.duplicated()

        XCTAssertEqual(copy.host, original.host)
        XCTAssertEqual(copy.port, original.port)
        XCTAssertEqual(copy.database, original.database)
        XCTAssertEqual(copy.user, original.user)
        XCTAssertEqual(copy.tls, original.tls)
        XCTAssertEqual(copy.tunnel, original.tunnel)
        XCTAssertEqual(copy.maxPoolSize, original.maxPoolSize)
        XCTAssertEqual(copy.folderPath, original.folderPath)
        XCTAssertEqual(copy.notes, original.notes)
    }

    func testDuplicateIsANewConnection() {
        let now = Date(timeIntervalSince1970: 9_000)
        let copy = productionProfile().duplicated(now: now)

        XCTAssertNotEqual(copy.id, "orig")
        XCTAssertEqual(copy.name, "Orders Copy")
        XCTAssertEqual(copy.createdAt, now)
        XCTAssertEqual(copy.updatedAt, now)
        XCTAssertNil(copy.lastConnected)
    }

    func testEndpointSummaryNeverGroupsPortDigits() {
        let profile = productionProfile()

        XCTAssertEqual(profile.endpointSummary, "ops@db.internal:6543/orders")
        XCTAssertEqual(profile.hostSummary, "db.internal:6543/orders")
    }
}
