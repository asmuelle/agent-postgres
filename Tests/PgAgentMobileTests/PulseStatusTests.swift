import XCTest

// `PulseStatus.swift` is compiled directly into this logic-test target (see
// project.yml): the one-word health summary each Pulse tile leads with.

final class PulseStatusTests: XCTestCase {

    func testNotYetPolledIsChecking() {
        let status = PulseStatus.make(from: .unknown("p"), isProduction: true)
        XCTAssertEqual(status.title, "Checking…")
        XCTAssertEqual(status.tone, .muted)
    }

    func testHealthyShowsActivityAndLatency() {
        let status = PulseStatus.make(from: health(active: 4, latency: 12.4), isProduction: false)
        XCTAssertEqual(status.title, "Healthy")
        XCTAssertEqual(status.tone, .good)
        XCTAssertEqual(status.detail, "4 active · 12 ms")
    }

    func testNoActiveSessionsReadsIdle() {
        let status = PulseStatus.make(from: health(active: 0, latency: 8), isProduction: false)
        XCTAssertEqual(status.detail, "Idle · 8 ms")
    }

    /// Reachable, but the posture probe failed (commonly no pg_monitor):
    /// wraparound and saturation went unchecked, so don't claim "Healthy".
    func testUnevaluatedPostureIsNotHealthy() {
        let health = FleetInstanceHealth(
            profileId: "p", reachable: true,
            activeBackends: 1, longRunningCount: 0, blockedLockCount: 0,
            errorMessage: "Metrics unavailable: permission denied", lastUpdated: Date()
        )
        let status = PulseStatus.make(from: health, isProduction: false)
        XCTAssertEqual(status.title, "Reachable")
        XCTAssertEqual(status.tone, .muted)
        XCTAssertEqual(status.detail, "Metrics unavailable: permission denied")
    }

    func testBlockedOutranksSlow() {
        let status = PulseStatus.make(from: health(long: 2, blocked: 3), isProduction: false)
        XCTAssertEqual(status.title, "3 Blocked")
        XCTAssertEqual(status.tone, .critical)
    }

    func testSlowQueriesPluralise() {
        XCTAssertEqual(PulseStatus.make(from: health(long: 1), isProduction: false).title, "1 Slow Query")
        XCTAssertEqual(PulseStatus.make(from: health(long: 2), isProduction: false).title, "2 Slow Queries")
        XCTAssertEqual(PulseStatus.make(from: health(long: 2), isProduction: false).tone, .warning)
    }

    func testPostureCriticalNeedsAttention() {
        var metrics = FleetProbeMetrics()
        metrics.connectionUtilizationPercent = 97
        let status = PulseStatus.make(from: health(metrics: metrics), isProduction: false)
        XCTAssertEqual(status.title, "Needs Attention")
        XCTAssertEqual(status.tone, .critical)
    }

    func testPostureWarningNeedsAttention() {
        var metrics = FleetProbeMetrics()
        metrics.connectionUtilizationPercent = 85
        let status = PulseStatus.make(from: health(metrics: metrics), isProduction: false)
        XCTAssertEqual(status.title, "Needs Attention")
        XCTAssertEqual(status.tone, .warning)
    }

    /// An unreachable production database is an incident; an unreachable
    /// laptop dev database is just off.
    func testUnreachableToneDependsOnEnvironment() {
        let down = FleetInstanceHealth(
            profileId: "p", reachable: false,
            activeBackends: 0, longRunningCount: 0, blockedLockCount: 0,
            errorMessage: "connection refused", lastUpdated: Date()
        )
        let prod = PulseStatus.make(from: down, isProduction: true)
        // "Can't Connect", not "Unreachable": the cause is as often a
        // missing password as a down host.
        XCTAssertEqual(prod.title, "Can't Connect")
        XCTAssertEqual(prod.tone, .critical)
        XCTAssertEqual(prod.detail, "connection refused")
        XCTAssertEqual(PulseStatus.make(from: down, isProduction: false).tone, .muted)
    }

    private func health(
        active: Int = 0,
        long: Int = 0,
        blocked: Int = 0,
        latency: Double? = nil,
        metrics: FleetProbeMetrics? = nil
    ) -> FleetInstanceHealth {
        FleetInstanceHealth(
            profileId: "p", reachable: true,
            activeBackends: active, longRunningCount: long, blockedLockCount: blocked,
            errorMessage: nil, lastUpdated: Date(),
            latencyMilliseconds: latency, metrics: metrics
        )
    }
}
