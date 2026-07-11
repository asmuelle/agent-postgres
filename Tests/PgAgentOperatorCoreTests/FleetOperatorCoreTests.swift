import Foundation
import XCTest
@testable import PgAgentOperatorCore

final class FleetOperatorCoreTests: XCTestCase {
    func testProbeParserBuildsPostgres14CompatibleMetrics() throws {
        let row: [String?] = [
            "140012", "false", "86400", "82", "100", "3600", "3",
            "1700000000", "4.5", "1048576", "2147483648", "2",
            "524288", "1", "true", "7", "12"
        ]

        let metrics = try FleetProbeParser.parse(row)

        XCTAssertEqual(metrics.serverMajorVersion, 14)
        XCTAssertEqual(metrics.isInRecovery, false)
        XCTAssertEqual(metrics.connectionUtilizationPercent, 82)
        XCTAssertEqual(metrics.oldestTransactionSeconds, 3600)
        XCTAssertEqual(metrics.xidAge, 1_700_000_000)
        XCTAssertEqual(metrics.replicationLagSeconds, 4.5)
        XCTAssertEqual(metrics.retainedWalBytes, 1_048_576)
        XCTAssertEqual(metrics.sslInUse, true)
        XCTAssertEqual(metrics.runningMaintenanceCount, 7)
        XCTAssertEqual(metrics.schemaFingerprint, "12")
    }

    func testMinimumSupportedServerVersionIsPostgres14() {
        XCTAssertNoThrow(try PostgresServerVersionPolicy.validate(versionNum: 140000))
        XCTAssertNoThrow(try PostgresServerVersionPolicy.validate(versionNum: 180001))
        XCTAssertThrowsError(try PostgresServerVersionPolicy.validate(versionNum: 130012))
    }

    func testProbeSQLUsesOnlyPostgres14Surfaces() {
        XCTAssertTrue(FleetProbeSQL.posture.contains("server_version_num"))
        XCTAssertTrue(FleetProbeSQL.posture.contains("pg_stat_progress_vacuum"))
        XCTAssertTrue(FleetProbeSQL.posture.contains("pg_stat_replication"))
        XCTAssertFalse(FleetProbeSQL.posture.contains("wal_distance"))
    }

    func testTwentyProfilesArePolledFourAtATime() {
        let batches = FleetPollingPolicy.batches(Array(0..<20), maxConcurrent: 4)
        XCTAssertEqual(batches.map(\.count), [4, 4, 4, 4, 4])
        XCTAssertEqual(batches.flatMap { $0 }, Array(0..<20))
    }

    func testEnvironmentDefaultsAreProductionConservative() {
        let production = FleetEnvironmentPolicy.defaults(for: "production")
        let development = FleetEnvironmentPolicy.defaults(for: "development")

        XCTAssertEqual(production.longRunningSeconds, 30)
        XCTAssertTrue(production.alertOnUnreachable)
        XCTAssertLessThan(production.connectionWarningPercent, development.connectionWarningPercent)
    }

    func testEnvironmentPolicyKeepsUserAlertCountsButAppliesPostureThresholds() {
        let user = FleetMonitorThresholds(
            longRunningSeconds: 9,
            longRunningCountAlert: 4,
            blockedLockAlert: 2,
            alertOnUnreachable: false,
            connectionWarningPercent: 99,
            replicationLagWarningSeconds: 999)

        let production = FleetEnvironmentPolicy.alertThresholds(
            for: "production", user: user)

        XCTAssertEqual(production.longRunningSeconds, 30)
        XCTAssertEqual(production.longRunningCountAlert, 4)
        XCTAssertEqual(production.blockedLockAlert, 2)
        XCTAssertTrue(production.alertOnUnreachable)
        XCTAssertEqual(production.connectionWarningPercent, 80)
        XCTAssertEqual(production.replicationLagWarningSeconds, 60)
    }

    func testPostureDetectsWraparoundAndReplicationRisk() {
        var metrics = FleetProbeMetrics.empty
        metrics.xidAge = 1_900_000_000
        XCTAssertEqual(FleetPosturePolicy.severity(metrics: metrics), .critical)

        metrics.xidAge = 10
        metrics.replicationLagSeconds = 120
        XCTAssertEqual(FleetPosturePolicy.severity(metrics: metrics), .warning)
    }

    func testAlertLifecycleSuppressesAcknowledgedSnoozedAndMaintenance() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(FleetAlertLifecyclePolicy.shouldDeliver(
            disposition: .acknowledged(at: now), now: now))
        XCTAssertFalse(FleetAlertLifecyclePolicy.shouldDeliver(
            disposition: .snoozed(until: now.addingTimeInterval(60)), now: now))
        XCTAssertTrue(FleetAlertLifecyclePolicy.shouldDeliver(
            disposition: .snoozed(until: now.addingTimeInterval(-1)), now: now))
        XCTAssertFalse(FleetAlertLifecyclePolicy.shouldDeliver(
            disposition: .maintenance(until: now.addingTimeInterval(60)), now: now))
        XCTAssertTrue(FleetAlertLifecyclePolicy.shouldDeliver(disposition: .active, now: now))
    }

    @MainActor
    func testLifecycleReactivatesResolvedAndExpiredSnoozedAlertsOnce() {
        let suite = "FleetOperatorCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FleetAlertLifecycleStore(defaults: defaults)
        let alert = FleetAlert(
            profileId: "p1", profileName: "Prod", kind: .blockedLocks,
            title: "blocked", body: "blocked")
        let now = Date(timeIntervalSince1970: 1_000)

        store.acknowledge(alert, at: now.addingTimeInterval(-10))
        store.noteResolved(alertIds: [alert.id], at: now.addingTimeInterval(-5))
        XCTAssertEqual(
            store.prepareForPoll(alerts: [alert], previouslyFiring: [], now: now),
            [alert.id])
        XCTAssertTrue(store.shouldDeliver(alert, now: now))

        store.snooze(alert, until: now.addingTimeInterval(-1))
        XCTAssertEqual(
            store.prepareForPoll(alerts: [alert], previouslyFiring: [alert.id], now: now),
            [alert.id])
        XCTAssertTrue(store.prepareForPoll(
            alerts: [alert], previouslyFiring: [alert.id], now: now).isEmpty)
    }

    func testSnapshotStorePersistsAndReadsNewestFirst() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FleetSnapshotStore(fileURL: directory.appendingPathComponent("fleet.jsonl"))

        try await store.append(.fixture(profileId: "a", capturedAt: Date(timeIntervalSince1970: 10)))
        try await store.append(.fixture(profileId: "b", capturedAt: Date(timeIntervalSince1970: 20)))
        try await store.append(.fixture(profileId: "a", capturedAt: Date(timeIntervalSince1970: 30)))

        let recent = try await store.recent(profileId: "a", limit: 10)
        XCTAssertEqual(recent.map(\.capturedAt.timeIntervalSince1970), [30, 10])
    }
}

private extension FleetSnapshotRecord {
    static func fixture(profileId: String, capturedAt: Date) -> FleetSnapshotRecord {
        FleetSnapshotRecord(
            profileId: profileId,
            capturedAt: capturedAt,
            reachable: true,
            activeBackends: 1,
            longRunningCount: 0,
            blockedLockCount: 0,
            latencyMilliseconds: 5,
            metrics: .empty,
            errorMessage: nil
        )
    }
}
