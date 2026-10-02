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

    /// A control isn't refreshed on a schedule, so it says when it looked —
    /// "Healthy" alone could outlive the truth by hours.
    private func asOf(_ snapshot: PgFleetWidgetSnapshot) -> String {
        snapshot.generatedAt.formatted(date: .omitted, time: .shortened)
    }

    func testHealthySaysWhenItLooked() {
        let fleet = snapshot([.healthy, .busy])
        let status = PgFleetControlStatus(snapshot: fleet, now: now)
        XCTAssertEqual(status.title, "Healthy · \(asOf(fleet))")
        XCTAssertEqual(status.systemImage, "waveform.path.ecg")
    }

    func testCountsProblemsAndShowsTheWorst() {
        let fleet = snapshot([.healthy, .slow, .offline])
        let status = PgFleetControlStatus(snapshot: fleet, now: now)
        XCTAssertEqual(status.title, "2 Problems · \(asOf(fleet))")
        XCTAssertEqual(status.systemImage, "bolt.horizontal.circle")
    }

    func testOneProblem() {
        let fleet = snapshot([.blocked])
        XCTAssertEqual(PgFleetControlStatus(snapshot: fleet, now: now).title, "1 Problem · \(asOf(fleet))")
    }

    /// An old snapshot says nothing about now — no false "All Healthy".
    func testAStaleSnapshotClaimsNothing() {
        let stale = snapshot([.healthy], age: PgFleetWidgetConfiguration.staleAfter + 1)
        XCTAssertEqual(PgFleetControlStatus(snapshot: stale, now: now).title, "Databases")
    }
}
