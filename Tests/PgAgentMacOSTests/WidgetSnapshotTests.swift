import XCTest
@testable import PgAgentMacOS

final class WidgetSnapshotFreshnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let policy = WidgetSnapshotFreshnessPolicy(
        freshInterval: 15 * 60,
        staleInterval: 60 * 60
    )

    func testFreshnessThresholds() {
        XCTAssertEqual(snapshot(checkedSecondsAgo: 14 * 60).freshness(now: now, policy: policy), .fresh)
        XCTAssertEqual(snapshot(checkedSecondsAgo: 15 * 60).freshness(now: now, policy: policy), .aging)
        XCTAssertEqual(snapshot(checkedSecondsAgo: 60 * 60).freshness(now: now, policy: policy), .aging)
        XCTAssertEqual(snapshot(checkedSecondsAgo: 61 * 60).freshness(now: now, policy: policy), .stale)
    }

    func testNeverCheckedIsUnknownForDisplay() {
        let unchecked = WidgetMonitorSnapshot(
            id: "unchecked",
            displayName: "Unchecked host",
            kind: .host,
            state: .up,
            lastCheckedAt: nil,
            summary: "No result yet"
        )

        XCTAssertEqual(unchecked.freshness(now: now, policy: policy), .neverChecked)
        XCTAssertEqual(unchecked.displayState(now: now, policy: policy), .unknown)
    }

    func testDownAndUnknownRemainDistinctWhenFresh() {
        let down = snapshot(state: .down, checkedSecondsAgo: 5 * 60)
        let unknown = snapshot(state: .unknown, checkedSecondsAgo: 5 * 60)

        XCTAssertTrue(down.displayState(now: now, policy: policy).isConfirmedFailure)
        XCTAssertEqual(down.displayState(now: now, policy: policy), .down)
        XCTAssertFalse(unknown.displayState(now: now, policy: policy).isConfirmedFailure)
        XCTAssertEqual(unknown.displayState(now: now, policy: policy), .unknown)
    }

    func testStaleDataDoesNotPresentLastKnownStateAsCurrent() {
        let staleUp = snapshot(state: .up, checkedSecondsAgo: 2 * 60 * 60)
        let staleDown = snapshot(state: .down, checkedSecondsAgo: 2 * 60 * 60)

        XCTAssertEqual(staleUp.displayState(now: now, policy: policy), .stale)
        XCTAssertEqual(staleDown.displayState(now: now, policy: policy), .stale)
    }

    func testPausedStateDoesNotBecomeStale() {
        let paused = snapshot(state: .paused, checkedSecondsAgo: 2 * 60 * 60)

        XCTAssertEqual(paused.freshness(now: now, policy: policy), .stale)
        XCTAssertEqual(paused.displayState(now: now, policy: policy), .paused)
    }

    func testOverallStateUsesDerivedDisplayStates() {
        let snapshots = [
            snapshot(id: "healthy", state: .up, checkedSecondsAgo: 5 * 60),
            snapshot(id: "stale", state: .down, checkedSecondsAgo: 2 * 60 * 60),
        ]

        XCTAssertEqual(
            WidgetSnapshotReducer.overallState(for: snapshots, now: now, policy: policy),
            .stale
        )
    }

    private func snapshot(
        id: String = "snapshot",
        state: WidgetMonitorState = .up,
        checkedSecondsAgo seconds: TimeInterval
    ) -> WidgetMonitorSnapshot {
        WidgetMonitorSnapshot(
            id: id,
            displayName: "Example",
            kind: .host,
            state: state,
            lastCheckedAt: now.addingTimeInterval(-seconds),
            lastChangedAt: now.addingTimeInterval(-seconds),
            summary: state.rawValue
        )
    }
}

final class WidgetSnapshotStoreTests: XCTestCase {
    func testStoreRoundTripsSnapshotFileFromExplicitDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pgAgent-widget-tests")
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let generatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = WidgetMonitorSnapshot(
            id: "prod-web",
            displayName: "prod-web",
            kind: .host,
            state: .down,
            lastCheckedAt: generatedAt,
            lastChangedAt: generatedAt.addingTimeInterval(-120),
            summary: "SSH check failed",
            detail: "Connection timed out",
            openURL: "pgAgent://monitoring/prod-web"
        )

        let store = WidgetSnapshotStore(directoryURL: directory)
        try store.saveSnapshots([snapshot], generatedAt: generatedAt)

        let file = try XCTUnwrap(store.loadSnapshotFile())
        XCTAssertEqual(file.schemaVersion, WidgetSnapshotConfiguration.schemaVersion)
        XCTAssertEqual(file.generatedAt, generatedAt)
        XCTAssertEqual(file.snapshots, [snapshot])
    }

    func testPlaceholderSeedDoesNotOverwriteExistingSnapshots() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pgAgent-widget-tests")
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = WidgetSnapshotStore(directoryURL: directory)
        let existing = WidgetMonitorSnapshot(
            id: "existing",
            displayName: "Existing",
            kind: .custom,
            state: .up,
            lastCheckedAt: Date(timeIntervalSince1970: 1_700_000_000),
            summary: "Already present"
        )

        try store.saveSnapshots([existing])
        try store.savePlaceholderIfNeeded()

        XCTAssertEqual(try store.loadSnapshots(), [existing])
    }
}

final class WidgetMonitoringPreferencesTests: XCTestCase {
    func testDefaultPreferencesIncludeEverySnapshot() {
        let snapshots = [
            monitorSnapshot(id: "host", kind: .host),
            monitorSnapshot(id: "db", kind: .postgres),
            monitorSnapshot(id: "service", kind: .custom),
        ]

        XCTAssertEqual(WidgetMonitoringPreferences.default.filteredSnapshots(snapshots), snapshots)
    }

    func testPreferencesFilterByKindAndPinnedIds() {
        let host = monitorSnapshot(id: "host", kind: .host)
        let database = monitorSnapshot(id: "db", kind: .postgres)
        let service = monitorSnapshot(id: "service", kind: .custom)
        let preferences = WidgetMonitoringPreferences(
            includedKinds: [.host, .custom],
            pinnedSnapshotIds: ["service", "service", "  "],
            showOnlyPinnedWhenConfigured: true
        )

        XCTAssertEqual(preferences.pinnedSnapshotIds, ["service"])
        XCTAssertEqual(preferences.filteredSnapshots([host, database, service]), [service])
    }

    func testPreferenceStoreReturnsDefaultWhenMissingAndRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pgAgent-widget-preferences-tests")
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = WidgetMonitoringPreferencesStore(directoryURL: directory)
        XCTAssertEqual(try store.loadPreferences(), .default)

        let preferences = WidgetMonitoringPreferences(
            includedKinds: [.host, .postgres],
            pinnedSnapshotIds: ["ssh:prod-web"],
            showOnlyPinnedWhenConfigured: true
        )
        try store.save(preferences)

        XCTAssertEqual(try store.loadPreferences(), preferences)
    }

    private func monitorSnapshot(id: String, kind: WidgetMonitorKind) -> WidgetMonitorSnapshot {
        WidgetMonitorSnapshot(
            id: id,
            displayName: id,
            kind: kind,
            state: .up,
            lastCheckedAt: Date(timeIntervalSince1970: 1_700_000_000),
            summary: "up"
        )
    }
}

final class WidgetSnapshotStateClassifierTests: XCTestCase {
    func testTerminalStatusClassification() {
        XCTAssertEqual(WidgetSnapshotStateClassifier.state(forTerminalStatus: .connected), .up)
        XCTAssertEqual(WidgetSnapshotStateClassifier.state(forTerminalStatus: .connecting), .unknown)
        XCTAssertEqual(WidgetSnapshotStateClassifier.state(forTerminalStatus: .disconnected), .down)
        XCTAssertEqual(WidgetSnapshotStateClassifier.state(forTerminalStatus: .error), .down)
    }

    func testPostgresStatusClassification() {
        XCTAssertEqual(WidgetSnapshotStateClassifier.stateForPostgresStatus("connected"), .up)
        XCTAssertEqual(WidgetSnapshotStateClassifier.stateForPostgresStatus("connecting"), .unknown)
        XCTAssertEqual(WidgetSnapshotStateClassifier.stateForPostgresStatus("error"), .down)
        XCTAssertEqual(WidgetSnapshotStateClassifier.stateForPostgresStatus("unexpected"), .unknown)
    }

    func testSystemdStatusClassification() {
        XCTAssertEqual(
            WidgetSnapshotStateClassifier.stateForSystemdService(active: "active", sub: "running"),
            .up
        )
        XCTAssertEqual(
            WidgetSnapshotStateClassifier.stateForSystemdService(active: "failed", sub: "failed"),
            .down
        )
        XCTAssertEqual(
            WidgetSnapshotStateClassifier.stateForSystemdService(active: "inactive", sub: "dead"),
            .unknown
        )
        XCTAssertEqual(
            WidgetSnapshotStateClassifier.stateForSystemdService(active: "activating", sub: "start"),
            .degraded
        )
        XCTAssertEqual(
            WidgetSnapshotStateClassifier.stateForSystemdService(active: "unknown", sub: "unknown"),
            .unknown
        )
    }
}

final class WidgetSnapshotPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let policy = WidgetSnapshotFreshnessPolicy.default

    func testEmptyDatasetProducesUnknownPlaceholder() {
        let model = WidgetSnapshotPresenter.displayModel(
            snapshotFile: WidgetMonitorSnapshotFile(generatedAt: now, snapshots: []),
            now: now,
            policy: policy
        )

        XCTAssertEqual(model.overallState, .unknown)
        XCTAssertEqual(model.unknownCount, 1)
        XCTAssertEqual(model.lastCheckedText, "Not checked yet")
        XCTAssertEqual(model.items.first?.displayName, "Monitoring")
        XCTAssertEqual(model.openURL, WidgetSnapshotPresenter.monitoringOverviewURL)
    }

    func testHealthyDatasetShowsFreshLastCheckedText() {
        let snapshot = monitorSnapshot(
            id: "healthy",
            displayName: "prod-web",
            state: .up,
            checkedSecondsAgo: 8 * 60
        )

        let model = displayModel([snapshot])

        XCTAssertEqual(model.overallState, .up)
        XCTAssertEqual(model.downCount, 0)
        XCTAssertEqual(model.staleCount, 0)
        XCTAssertEqual(model.items.first?.state, .up)
        XCTAssertEqual(model.items.first?.lastCheckedText, "Last checked 8 min ago")
        XCTAssertEqual(model.lastCheckedText, "Last checked 8 min ago")
    }

    func testDownDatasetKeepsConfirmedFailureDistinctFromUnknown() {
        let down = monitorSnapshot(
            id: "down",
            displayName: "prod-db",
            state: .down,
            checkedSecondsAgo: 5 * 60
        )
        let unknown = monitorSnapshot(
            id: "unknown",
            displayName: "prod-cache",
            state: .unknown,
            checkedSecondsAgo: 5 * 60
        )

        let model = displayModel([unknown, down])

        XCTAssertEqual(model.overallState, .down)
        XCTAssertEqual(model.downCount, 1)
        XCTAssertEqual(model.unknownCount, 1)
        XCTAssertEqual(model.items.map(\.id), ["down", "unknown"])
        XCTAssertEqual(model.items[0].state, .down)
        XCTAssertEqual(model.items[1].state, .unknown)
    }

    func testDegradedDatasetRanksBeforeHealthyItems() {
        let degraded = monitorSnapshot(
            id: "degraded",
            displayName: "prod-api",
            state: .degraded,
            checkedSecondsAgo: 4 * 60
        )
        let healthy = monitorSnapshot(
            id: "healthy",
            displayName: "prod-web",
            state: .up,
            checkedSecondsAgo: 1 * 60
        )

        let model = displayModel([healthy, degraded])

        XCTAssertEqual(model.overallState, .degraded)
        XCTAssertEqual(model.degradedCount, 1)
        XCTAssertEqual(model.items.map(\.id), ["degraded", "healthy"])
    }

    func testStaleDatasetDoesNotPresentLastKnownStateAsCurrent() {
        let stale = monitorSnapshot(
            id: "stale",
            displayName: "prod-worker",
            state: .up,
            checkedSecondsAgo: 2 * 60 * 60
        )

        let model = displayModel([stale])

        XCTAssertEqual(model.overallState, .stale)
        XCTAssertEqual(model.staleCount, 1)
        XCTAssertEqual(model.items.first?.state, .stale)
        XCTAssertEqual(model.items.first?.summary, "Was up")
        XCTAssertEqual(model.items.first?.lastCheckedText, "Stale: checked 2 hr ago")
        XCTAssertEqual(model.lastCheckedText, "Stale: checked 2 hr ago")
    }

    func testGroupsItemsForLargeWidgetOperationsView() {
        let snapshots = [
            monitorSnapshot(id: "service", displayName: "nginx.service", kind: .custom, state: .up, checkedSecondsAgo: 2 * 60),
            monitorSnapshot(id: "db", displayName: "orders-db", kind: .postgres, state: .degraded, checkedSecondsAgo: 3 * 60),
            monitorSnapshot(id: "tunnel", displayName: "orders tunnel", kind: .tunnel, state: .up, checkedSecondsAgo: 4 * 60),
            monitorSnapshot(id: "host", displayName: "prod-web", kind: .host, state: .down, checkedSecondsAgo: 5 * 60),
        ]

        let model = displayModel(snapshots)

        XCTAssertEqual(model.groups.map(\.title), ["Hosts", "Tunnels", "Databases", "Services"])
        XCTAssertEqual(model.groups.map(\.items.first?.id), ["host", "tunnel", "db", "service"])
    }

    func testGroupsPreserveSeverityOrderingInsideSection() {
        let snapshots = [
            monitorSnapshot(id: "healthy", displayName: "prod-web", kind: .host, state: .up, checkedSecondsAgo: 1 * 60),
            monitorSnapshot(id: "failed", displayName: "prod-api", kind: .host, state: .down, checkedSecondsAgo: 5 * 60),
            monitorSnapshot(id: "stale", displayName: "prod-worker", kind: .host, state: .up, checkedSecondsAgo: 2 * 60 * 60),
        ]

        let model = displayModel(snapshots)

        XCTAssertEqual(model.groups.first?.title, "Hosts")
        XCTAssertEqual(model.groups.first?.items.map(\.id), ["failed", "stale", "healthy"])
    }

    func testPreferencesFilterPresentationItemsAndCounts() {
        let snapshots = [
            monitorSnapshot(id: "host", displayName: "prod-web", kind: .host, state: .down, checkedSecondsAgo: 5 * 60),
            monitorSnapshot(id: "db", displayName: "orders-db", kind: .postgres, state: .up, checkedSecondsAgo: 4 * 60),
            monitorSnapshot(id: "service", displayName: "nginx.service", kind: .custom, state: .degraded, checkedSecondsAgo: 3 * 60),
        ]
        let preferences = WidgetMonitoringPreferences(includedKinds: [.host, .custom])

        let model = displayModel(snapshots, preferences: preferences)

        XCTAssertEqual(model.items.map(\.id), ["host", "service"])
        XCTAssertEqual(model.downCount, 1)
        XCTAssertEqual(model.degradedCount, 1)
        XCTAssertEqual(model.groups.map(\.title), ["Hosts", "Services"])
    }

    func testPreferencesEmptyScopeProducesScopedPlaceholder() {
        let snapshots = [
            monitorSnapshot(id: "host", displayName: "prod-web", kind: .host, state: .up, checkedSecondsAgo: 5 * 60),
        ]
        let preferences = WidgetMonitoringPreferences(includedKinds: [.postgres])

        let model = displayModel(snapshots, preferences: preferences)

        XCTAssertEqual(model.overallState, .unknown)
        XCTAssertEqual(model.items.first?.id, "monitoring-filtered-placeholder")
        XCTAssertEqual(model.items.first?.summary, "No matching checks")
        XCTAssertEqual(model.lastCheckedText, "Not checked yet")
    }

    private func displayModel(
        _ snapshots: [WidgetMonitorSnapshot],
        preferences: WidgetMonitoringPreferences = .default
    ) -> WidgetMonitoringDisplayModel {
        WidgetSnapshotPresenter.displayModel(
            snapshotFile: WidgetMonitorSnapshotFile(generatedAt: now, snapshots: snapshots),
            now: now,
            policy: policy,
            preferences: preferences
        )
    }

    private func monitorSnapshot(
        id: String,
        displayName: String,
        kind: WidgetMonitorKind = .host,
        state: WidgetMonitorState,
        checkedSecondsAgo seconds: TimeInterval
    ) -> WidgetMonitorSnapshot {
        WidgetMonitorSnapshot(
            id: id,
            displayName: displayName,
            kind: kind,
            state: state,
            lastCheckedAt: now.addingTimeInterval(-seconds),
            lastChangedAt: now.addingTimeInterval(-seconds),
            summary: state.rawValue,
            detail: nil,
            openURL: "pgAgent://monitoring/\(id)"
        )
    }
}

final class WidgetMonitorAlertEvaluatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testConfirmedFailureRuleFiresOnlyForFreshDownTransition() {
        let previous = monitorSnapshot(id: "prod-web", state: .up, checkedSecondsAgo: 60)
        let current = monitorSnapshot(
            id: "prod-web",
            state: .down,
            checkedSecondsAgo: 5,
            detail: "Connection timed out"
        )

        let decision = WidgetMonitorAlertEvaluator.decision(
            for: current,
            previousSnapshot: previous,
            now: now
        )

        XCTAssertEqual(decision?.ruleId, WidgetMonitorAlertRule.confirmedFailures.id)
        XCTAssertEqual(decision?.snapshotId, "prod-web")
        XCTAssertEqual(decision?.title, "prod-web is down")
        XCTAssertEqual(decision?.body, "Connection timed out")
    }

    func testUnknownDoesNotFireConfirmedFailureAlert() {
        let current = monitorSnapshot(id: "prod-web", state: .unknown, checkedSecondsAgo: 5)

        let decision = WidgetMonitorAlertEvaluator.decision(
            for: current,
            previousSnapshot: nil,
            now: now
        )

        XCTAssertNil(decision)
    }

    func testRepeatedDownStateDoesNotFireAgain() {
        let previous = monitorSnapshot(id: "prod-web", state: .down, checkedSecondsAgo: 60)
        let current = monitorSnapshot(id: "prod-web", state: .down, checkedSecondsAgo: 5)

        let decision = WidgetMonitorAlertEvaluator.decision(
            for: current,
            previousSnapshot: previous,
            now: now
        )

        XCTAssertNil(decision)
    }

    func testStaleDownSnapshotDoesNotFireConfirmedFailureAlert() {
        let staleDown = monitorSnapshot(id: "prod-web", state: .down, checkedSecondsAgo: 2 * 60 * 60)

        let decision = WidgetMonitorAlertEvaluator.decision(
            for: staleDown,
            previousSnapshot: nil,
            now: now
        )

        XCTAssertNil(decision)
    }

    func testHistoryThrottleSuppressesRecentRepeatAfterRecoveryTransition() {
        let previous = monitorSnapshot(id: "prod-web", state: .up, checkedSecondsAgo: 60)
        let current = monitorSnapshot(id: "prod-web", state: .down, checkedSecondsAgo: 5)
        var history = WidgetMonitorAlertHistory()
        history.record(
            ruleId: WidgetMonitorAlertRule.confirmedFailures.id,
            snapshotId: current.id,
            deliveredAt: now.addingTimeInterval(-120)
        )

        let decision = WidgetMonitorAlertEvaluator.decision(
            for: current,
            previousSnapshot: previous,
            history: history,
            now: now
        )

        XCTAssertNil(decision)
    }

    func testRuleCanLimitAlertKinds() {
        let rule = WidgetMonitorAlertRule(
            id: "database-failures",
            displayName: "Database failures",
            includedKinds: [.postgres],
            matchingStates: [.down]
        )
        let host = monitorSnapshot(id: "prod-web", kind: .host, state: .down, checkedSecondsAgo: 5)
        let postgres = monitorSnapshot(id: "orders-db", kind: .postgres, state: .down, checkedSecondsAgo: 5)

        let decisions = WidgetMonitorAlertEvaluator.decisions(
            for: [host, postgres],
            previousSnapshots: [:],
            rules: [rule],
            now: now
        )

        XCTAssertEqual(decisions.map(\.snapshotId), ["orders-db"])
    }

    func testDecisionBuildsPortableDeliveryPayload() throws {
        let previous = monitorSnapshot(id: "prod-web", state: .up, checkedSecondsAgo: 60)
        let current = monitorSnapshot(
            id: "prod-web",
            state: .down,
            checkedSecondsAgo: 5,
            detail: "Connection timed out"
        )
        let decision = try XCTUnwrap(WidgetMonitorAlertEvaluator.decision(
            for: current,
            previousSnapshot: previous,
            now: now
        ))

        let payload = decision.deliveryPayload(source: .iOSApp, occurredAt: now)

        XCTAssertEqual(payload.id, decision.notificationIdentifier)
        XCTAssertEqual(payload.source, .iOSApp)
        XCTAssertEqual(payload.severity, .failure)
        XCTAssertEqual(payload.ruleId, WidgetMonitorAlertRule.confirmedFailures.id)
        XCTAssertEqual(payload.snapshotId, "prod-web")
        XCTAssertEqual(payload.checkedAt, current.lastCheckedAt)
        XCTAssertEqual(payload.openURL, "pgAgent://monitoring/prod-web")
    }

    func testDeliveryPayloadRoundTripsThroughNotificationUserInfo() throws {
        let payload = MonitoringAlertDeliveryPayload(
            id: "alert-1",
            title: "prod-web is down",
            body: "Connection timed out",
            severity: .failure,
            source: .pushGateway,
            ruleId: "confirmed-failures",
            snapshotId: "prod-web",
            occurredAt: now,
            checkedAt: now.addingTimeInterval(-5),
            openURL: "pgAgent://monitoring/prod-web"
        )

        let decoded = try XCTUnwrap(MonitoringAlertDeliveryPayload(userInfo: payload.userInfo))

        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.notificationThreadIdentifier, "monitoring-alerts")
    }

    private func monitorSnapshot(
        id: String,
        kind: WidgetMonitorKind = .host,
        state: WidgetMonitorState,
        checkedSecondsAgo seconds: TimeInterval,
        detail: String? = nil
    ) -> WidgetMonitorSnapshot {
        WidgetMonitorSnapshot(
            id: id,
            displayName: id,
            kind: kind,
            state: state,
            lastCheckedAt: now.addingTimeInterval(-seconds),
            lastChangedAt: now.addingTimeInterval(-seconds),
            summary: state.rawValue,
            detail: detail,
            openURL: "pgAgent://monitoring/\(id)"
        )
    }
}
