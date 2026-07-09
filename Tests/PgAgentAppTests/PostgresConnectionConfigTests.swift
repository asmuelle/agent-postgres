import XCTest
@testable import PgAgentApp

// Locks in the connection-pool defaults chosen to curb connection exhaustion:
// idle profiles must fully release (minIdle 0), the per-profile ceiling must
// NOT be silently lowered (query tabs hold leases), and explicit editor values
// must win. Also guards the shared TLS hint used by both platform forms.
final class PostgresConnectionConfigTests: XCTestCase {

    private func makeProfile(
        maxPoolSize: UInt32? = nil,
        minIdleConnections: UInt32? = nil
    ) -> PostgresProfile {
        PostgresProfile(
            name: "t",
            database: "db",
            user: "u",
            maxPoolSize: maxPoolSize,
            minIdleConnections: minIdleConnections
        )
    }

    func testIdleProfilesReleaseByDefault() {
        // nil minIdle coalesces to 0 so an idle-but-open profile drops its last
        // connection instead of pinning one for the app's lifetime.
        XCTAssertEqual(makeProfile().toFfiConfig().minIdleConnections, 0)
    }

    func testExplicitMinIdleRespected() {
        XCTAssertEqual(makeProfile(minIdleConnections: 2).toFfiConfig().minIdleConnections, 2)
    }

    func testMaxPoolSizeNotLowered() {
        // Intentionally left as nil (core default) — a low ceiling would
        // exhaust multi-tab workflows since each tab holds a session lease.
        XCTAssertNil(makeProfile().toFfiConfig().maxPoolSize)
    }

    func testExplicitMaxPoolSizeRespected() {
        XCTAssertEqual(makeProfile(maxPoolSize: 8).toFfiConfig().maxPoolSize, 8)
    }

    func testTlsHintNonEmptyForEveryMode() {
        for mode in PostgresTlsMode.allCases {
            XCTAssertFalse(mode.hint.isEmpty, "TLS hint missing for \(mode)")
        }
    }
}
