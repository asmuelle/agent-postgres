import XCTest

// `FleetMonitorSettings.swift` is compiled directly into this logic-test target
// (see project.yml). Each test uses an isolated UserDefaults suite so persistence
// is verified without touching the app's real defaults.

@MainActor
final class FleetMonitorSettingsTests: XCTestCase {

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "test.fleet.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaultsWhenUnset() {
        let settings = FleetMonitorSettings(defaults: makeDefaults(#function))
        let d = FleetMonitorThresholds.defaults
        XCTAssertEqual(settings.longRunningSeconds, d.longRunningSeconds)
        XCTAssertEqual(settings.longRunningCountAlert, d.longRunningCountAlert)
        XCTAssertEqual(settings.blockedLockAlert, d.blockedLockAlert)
        XCTAssertEqual(settings.alertOnUnreachable, d.alertOnUnreachable)
        XCTAssertFalse(settings.backgroundAlertsEnabled) // opt-in
    }

    func testPersistsAcrossInstances() {
        let defaults = makeDefaults(#function)
        let first = FleetMonitorSettings(defaults: defaults)
        first.longRunningSeconds = 42
        first.blockedLockAlert = 3
        first.backgroundAlertsEnabled = true

        let second = FleetMonitorSettings(defaults: defaults)
        XCTAssertEqual(second.longRunningSeconds, 42)
        XCTAssertEqual(second.blockedLockAlert, 3)
        XCTAssertTrue(second.backgroundAlertsEnabled)
    }

    func testThresholdsStructMirrorsProperties() {
        let settings = FleetMonitorSettings(defaults: makeDefaults(#function))
        settings.longRunningSeconds = 10
        settings.longRunningCountAlert = 2
        settings.blockedLockAlert = 4
        settings.alertOnUnreachable = true

        let t = settings.thresholds
        XCTAssertEqual(t.longRunningSeconds, 10)
        XCTAssertEqual(t.longRunningCountAlert, 2)
        XCTAssertEqual(t.blockedLockAlert, 4)
        XCTAssertTrue(t.alertOnUnreachable)
        XCTAssertEqual(settings.longRunningThreshold, 10)
    }
}
