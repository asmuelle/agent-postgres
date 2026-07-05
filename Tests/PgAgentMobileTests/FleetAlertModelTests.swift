import XCTest

// `FleetAlertModel.swift` + `FleetHealthModel.swift` are compiled directly into
// this logic-test target (see project.yml) — the same pure, edge-triggered alert
// evaluation the background monitor ships, with no app host or notifications.

final class FleetAlertModelTests: XCTestCase {

    private let names = ["p1": "Prod", "p2": "Stage"]

    private func health(
        _ id: String, reachable: Bool = true, slow: Int = 0, blocked: Int = 0,
        rootBlockerPid: Int32? = nil
    ) -> FleetInstanceHealth {
        FleetInstanceHealth(
            profileId: id, reachable: reachable,
            activeBackends: slow, longRunningCount: slow, blockedLockCount: blocked,
            errorMessage: reachable ? nil : "down", lastUpdated: nil,
            rootBlockerPid: rootBlockerPid
        )
    }

    func testNoAlertsWhenQuiet() {
        let result = evaluateFleetAlerts(
            healths: [health("p1")], names: names,
            thresholds: .defaults, previouslyFiring: []
        )
        XCTAssertTrue(result.newAlerts.isEmpty)
        XCTAssertTrue(result.firingNow.isEmpty)
    }

    func testSlowQueryFiresWhenAtThreshold() {
        let result = evaluateFleetAlerts(
            healths: [health("p1", slow: 1)], names: names,
            thresholds: .defaults, previouslyFiring: []
        )
        XCTAssertEqual(result.newAlerts.map(\.id), ["p1:longRunning"])
        XCTAssertEqual(result.firingNow, ["p1:longRunning"])
    }

    func testEdgeTriggeredDoesNotReNotifyWhileStillFiring() {
        let h = [health("p1", slow: 3)]
        let first = evaluateFleetAlerts(healths: h, names: names, thresholds: .defaults, previouslyFiring: [])
        XCTAssertEqual(first.newAlerts.count, 1)
        // Second poll, condition still active and already in previouslyFiring.
        let second = evaluateFleetAlerts(healths: h, names: names, thresholds: .defaults, previouslyFiring: first.firingNow)
        XCTAssertTrue(second.newAlerts.isEmpty)
        XCTAssertEqual(second.firingNow, ["p1:longRunning"])
    }

    func testConditionClearsThenCanReNotify() {
        let firing: Set<String> = ["p1:longRunning"]
        // Cleared this poll → not in firingNow → can fire again next time.
        let cleared = evaluateFleetAlerts(healths: [health("p1", slow: 0)], names: names, thresholds: .defaults, previouslyFiring: firing)
        XCTAssertTrue(cleared.firingNow.isEmpty)
        let recurs = evaluateFleetAlerts(healths: [health("p1", slow: 2)], names: names, thresholds: .defaults, previouslyFiring: cleared.firingNow)
        XCTAssertEqual(recurs.newAlerts.map(\.id), ["p1:longRunning"])
    }

    func testThresholdOfZeroDisablesThatAlert() {
        var thresholds = FleetMonitorThresholds.defaults
        thresholds.longRunningCountAlert = 0
        let result = evaluateFleetAlerts(healths: [health("p1", slow: 9)], names: names, thresholds: thresholds, previouslyFiring: [])
        XCTAssertTrue(result.newAlerts.isEmpty)
    }

    func testUnreachableOnlyAlertsWhenEnabled() {
        let off = evaluateFleetAlerts(healths: [health("p1", reachable: false)], names: names, thresholds: .defaults, previouslyFiring: [])
        XCTAssertTrue(off.newAlerts.isEmpty)

        var thresholds = FleetMonitorThresholds.defaults
        thresholds.alertOnUnreachable = true
        let on = evaluateFleetAlerts(healths: [health("p1", reachable: false)], names: names, thresholds: thresholds, previouslyFiring: [])
        XCTAssertEqual(on.newAlerts.map(\.id), ["p1:unreachable"])
        XCTAssertEqual(on.newAlerts.first?.profileName, "Prod")
    }

    func testUnreachableSuppressesContentAlerts() {
        // A down instance shouldn't also emit slow/blocked alerts from stale counts.
        var thresholds = FleetMonitorThresholds.defaults
        thresholds.alertOnUnreachable = true
        let down = FleetInstanceHealth(
            profileId: "p1", reachable: false,
            activeBackends: 9, longRunningCount: 9, blockedLockCount: 9,
            errorMessage: "down", lastUpdated: nil
        )
        let result = evaluateFleetAlerts(healths: [down], names: names, thresholds: thresholds, previouslyFiring: [])
        XCTAssertEqual(result.newAlerts.map(\.id), ["p1:unreachable"])
    }

    func testBlockedAlertCarriesRootBlockerPid() {
        let result = evaluateFleetAlerts(
            healths: [health("p1", blocked: 2, rootBlockerPid: 4242)],
            names: names, thresholds: .defaults, previouslyFiring: []
        )
        XCTAssertEqual(result.newAlerts.map(\.id), ["p1:blockedLocks"])
        XCTAssertEqual(result.newAlerts.first?.blockerPid, 4242)
    }

    func testBlockedAlertWithoutSnapshotPidHasNilBlockerPid() {
        let result = evaluateFleetAlerts(
            healths: [health("p1", blocked: 1)],
            names: names, thresholds: .defaults, previouslyFiring: []
        )
        XCTAssertNil(result.newAlerts.first?.blockerPid)
    }

    func testNonLockAlertsNeverCarryBlockerPid() {
        // A stale rootBlockerPid in the health snapshot must not leak into a
        // slow-query alert — the pid only means something for blockedLocks.
        let result = evaluateFleetAlerts(
            healths: [health("p1", slow: 2, rootBlockerPid: 4242)],
            names: names, thresholds: .defaults, previouslyFiring: []
        )
        XCTAssertEqual(result.newAlerts.map(\.id), ["p1:longRunning"])
        XCTAssertNil(result.newAlerts.first?.blockerPid)
    }

    func testMultipleInstancesAndConditions() {
        var thresholds = FleetMonitorThresholds.defaults
        thresholds.alertOnUnreachable = true
        let result = evaluateFleetAlerts(
            healths: [health("p1", slow: 2, blocked: 1), health("p2", reachable: false)],
            names: names, thresholds: thresholds, previouslyFiring: []
        )
        XCTAssertEqual(Set(result.firingNow), ["p1:longRunning", "p1:blockedLocks", "p2:unreachable"])
    }
}
