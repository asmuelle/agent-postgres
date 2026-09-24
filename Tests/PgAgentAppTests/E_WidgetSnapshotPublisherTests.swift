// Tests for fleet health → widget snapshot conversion: state/summary
// mapping per severity, deep-link URLs, name fallback + sorting,
// lastChangedAt continuity across polls, and the App Group round trip.

import PgAgentMacOS
import XCTest

@testable import PgAgentApp

final class E_WidgetSnapshotPublisherTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func health(
        _ id: String,
        reachable: Bool = true,
        backends: Int = 0,
        longRunning: Int = 0,
        blocked: Int = 0,
        error: String? = nil,
        updated: Date? = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> FleetInstanceHealth {
        FleetInstanceHealth(
            profileId: id,
            reachable: reachable,
            activeBackends: backends,
            longRunningCount: longRunning,
            blockedLockCount: blocked,
            errorMessage: error,
            lastUpdated: updated
        )
    }

    func testStateAndSummaryPerSeverity() {
        typealias P = WidgetSnapshotPublisher
        XCTAssertEqual(P.state(for: health("a")), .up)
        XCTAssertEqual(P.summary(for: health("a")), "Healthy")

        XCTAssertEqual(P.state(for: health("a", backends: 3)), .up)
        XCTAssertEqual(P.summary(for: health("a", backends: 1)), "1 active backend")

        XCTAssertEqual(P.state(for: health("a", longRunning: 2)), .degraded)
        XCTAssertEqual(P.summary(for: health("a", longRunning: 2)), "2 long-running queries")

        XCTAssertEqual(P.state(for: health("a", blocked: 1)), .degraded)
        XCTAssertEqual(P.summary(for: health("a", blocked: 1)), "1 blocked lock")

        let down = health("a", reachable: false, error: "connection refused")
        XCTAssertEqual(P.state(for: down), .down)
        XCTAssertEqual(P.summary(for: down), "Unreachable")
    }

    func testNeverPolledInstanceIsUnknownNotDown() {
        let placeholder = FleetInstanceHealth.unknown("a")
        XCTAssertEqual(WidgetSnapshotPublisher.state(for: placeholder), .unknown)
        XCTAssertEqual(WidgetSnapshotPublisher.summary(for: placeholder), "Not checked yet")
    }

    func testSnapshotsCarryIdentityURLAndSortByName() throws {
        let snapshots = WidgetSnapshotPublisher.snapshots(
            healths: [health("p2"), health("p1", reachable: false, error: "boom"), health("p3")],
            names: ["p1": "zeta", "p2": "Alpha"],
            now: now
        )
        XCTAssertEqual(snapshots.map(\.displayName), ["Alpha", "p3", "zeta"])
        let zeta = try XCTUnwrap(snapshots.last)
        XCTAssertEqual(zeta.id, "postgres:p1")
        XCTAssertEqual(zeta.kind, .postgres)
        XCTAssertEqual(zeta.state, .down)
        XCTAssertEqual(zeta.detail, "boom")
        XCTAssertEqual(zeta.lastCheckedAt, now)
        XCTAssertEqual(zeta.openURL, "pgAgent://monitoring/p1")
        let url = try XCTUnwrap(zeta.openURL.flatMap(URL.init(string:)))
        XCTAssertEqual(PgAgentDeepLink(url: url), .monitoring(profileId: "p1"))
    }

    func testLastChangedAtPersistsWhileStateIsUnchanged() throws {
        let earlier = now.addingTimeInterval(-600)
        let first = WidgetSnapshotPublisher.snapshots(
            healths: [health("p1")], names: [:], now: earlier)
        XCTAssertEqual(first.first?.lastChangedAt, earlier)

        let same = WidgetSnapshotPublisher.snapshots(
            healths: [health("p1")], names: [:], previous: first, now: now)
        XCTAssertEqual(same.first?.lastChangedAt, earlier)

        let flipped = WidgetSnapshotPublisher.snapshots(
            healths: [health("p1", reachable: false, error: "x")], names: [:],
            previous: first, now: now)
        XCTAssertEqual(flipped.first?.lastChangedAt, now)
    }

    func testSnapshotsRoundTripThroughStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("E_WidgetSnapshotPublisherTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WidgetSnapshotStore(directoryURL: dir)
        let snapshots = WidgetSnapshotPublisher.snapshots(
            healths: [health("p1"), health("p2", blocked: 2)],
            names: ["p1": "one", "p2": "two"], now: now)

        try store.saveSnapshots(snapshots, generatedAt: now)

        XCTAssertEqual(try store.loadSnapshots(), snapshots)
        let presented = WidgetSnapshotPresenter.displayModel(
            snapshotFile: try store.loadSnapshotFile(), now: now)
        XCTAssertEqual(presented.overallState, .degraded)
    }
}
