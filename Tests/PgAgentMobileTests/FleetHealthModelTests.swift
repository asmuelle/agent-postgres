import XCTest

// `FleetHealthModel.swift` is compiled directly into this logic-test target
// (see project.yml) — the same pure types the Fleet Monitor ships, with no app
// host or FFI bridge required.

final class FleetHealthModelTests: XCTestCase {

    // MARK: - Severity derivation (most-severe-first precedence)

    func testSeverityOfflineWhenUnreachable() {
        // Unreachable wins even if stale counts are non-zero.
        let health = FleetInstanceHealth(
            profileId: "p", reachable: false,
            activeBackends: 9, longRunningCount: 9, blockedLockCount: 9,
            errorMessage: "boom", lastUpdated: nil
        )
        XCTAssertEqual(health.severity, .offline)
    }

    func testSeverityBlockedOutranksSlowAndBusy() {
        let health = makeHealth(active: 4, long: 2, blocked: 1)
        XCTAssertEqual(health.severity, .blocked)
    }

    func testSeveritySlowOutranksBusy() {
        let health = makeHealth(active: 4, long: 1, blocked: 0)
        XCTAssertEqual(health.severity, .slow)
    }

    func testSeverityBusyWhenOnlyActiveBackends() {
        let health = makeHealth(active: 2, long: 0, blocked: 0)
        XCTAssertEqual(health.severity, .busy)
    }

    func testSeverityHealthyWhenReachableAndQuiet() {
        let health = makeHealth(active: 0, long: 0, blocked: 0)
        XCTAssertEqual(health.severity, .healthy)
    }

    func testUnknownIsOffline() {
        XCTAssertEqual(FleetInstanceHealth.unknown("p").severity, .offline)
    }

    // MARK: - Age formatting

    func testAgeNilIsDash() {
        XCTAssertEqual(FleetFormat.age(sinceEpoch: nil), "—")
    }

    func testAgeSeconds() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(FleetFormat.age(sinceEpoch: 988, now: now), "12s")
    }

    func testAgeMinutesAndSeconds() {
        let now = Date(timeIntervalSince1970: 1_000)
        // 905s ago = 15m 5s
        XCTAssertEqual(FleetFormat.age(sinceEpoch: 95, now: now), "15m 5s")
    }

    func testAgeHoursAndMinutes() {
        let now = Date(timeIntervalSince1970: 10_000)
        // 7300s ago = 2h 1m
        XCTAssertEqual(FleetFormat.age(sinceEpoch: 2_700, now: now), "2h 1m")
    }

    func testAgeFutureClampsToZero() {
        let now = Date(timeIntervalSince1970: 1_000)
        // start in the future (clock skew) must not go negative.
        XCTAssertEqual(FleetFormat.age(sinceEpoch: 1_050, now: now), "0s")
    }

    // MARK: - Helpers

    private func makeHealth(active: Int, long: Int, blocked: Int) -> FleetInstanceHealth {
        FleetInstanceHealth(
            profileId: "p", reachable: true,
            activeBackends: active, longRunningCount: long, blockedLockCount: blocked,
            errorMessage: nil, lastUpdated: nil
        )
    }
}
