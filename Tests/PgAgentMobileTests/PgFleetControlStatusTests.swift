import XCTest

// `PgFleetWidgetSnapshot.swift` is compiled directly into this logic-test
// target (see project.yml): what the Control Center "Database Health"
// control shows, read from the snapshot the app writes after each refresh.

final class PgFleetControlStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func snapshot(_ statuses: [PgFleetInstanceStatus], age: TimeInterval = 60) -> PgFleetWidgetSnapshot {
        PgFleetWidgetSnapshot(
            generatedAt: now.addingTimeInterval(-age),
            instances: statuses.enumerated().map { index, status in
                PgFleetWidgetInstance(
                    profileId: "p\(index)", name: "DB \(index)", status: status,
                    activeBackends: 0, longRunningCount: 0, blockedLockCount: 0
                )
            }
        )
    }

    func testNothingKnownYet() {
        XCTAssertEqual(PgFleetControlStatus(snapshot: nil, now: now).title, "Databases")
    }

    func testNoDatabases() {
        XCTAssertEqual(PgFleetControlStatus(snapshot: snapshot([]), now: now).title, "No Databases")
    }

    func testAllHealthyCountsBusyAsHealthy() {
        let status = PgFleetControlStatus(snapshot: snapshot([.healthy, .busy]), now: now)
        XCTAssertEqual(status.title, "All Healthy")
        XCTAssertEqual(status.systemImage, "checkmark.circle")
    }

    func testCountsProblemsAndShowsTheWorst() {
        let status = PgFleetControlStatus(snapshot: snapshot([.healthy, .slow, .offline]), now: now)
        XCTAssertEqual(status.title, "2 Problems")
        XCTAssertEqual(status.systemImage, "bolt.horizontal.circle")
    }

    func testOneProblem() {
        XCTAssertEqual(PgFleetControlStatus(snapshot: snapshot([.blocked]), now: now).title, "1 Problem")
    }

    /// An old snapshot says nothing about now — no false "All Healthy".
    func testAStaleSnapshotClaimsNothing() {
        let stale = snapshot([.healthy], age: PgFleetWidgetConfiguration.staleAfter + 1)
        XCTAssertEqual(PgFleetControlStatus(snapshot: stale, now: now).title, "Databases")
    }
}
