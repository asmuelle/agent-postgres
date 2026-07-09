import XCTest
@testable import PgAgentApp

// Tests for the activity-monitor prompt packers. Pure string shaping over the
// FFI value types — no model, no network.
final class PgActivityAIContextTests: XCTestCase {

    private let now: Double = 1_000_000
    private let threshold: Double = 60

    private func session(
        pid: Int32 = 100,
        state: String = "active",
        query: String? = "SELECT 1",
        waitEvent: String? = nil,
        startedSecondsAgo: Double? = 10,
        datname: String = "appdb",
        usename: String = "app"
    ) -> FfiPgSessionDetail {
        FfiPgSessionDetail(
            pid: pid,
            datname: datname,
            usename: usename,
            clientAddr: nil,
            state: state,
            query: query,
            waitEvent: waitEvent,
            queryStart: startedSecondsAgo.map { UInt64(now - $0) }
        )
    }

    // MARK: - describeSession

    func testDescribeSessionIncludesCoreFacts() {
        let context = PgActivityAIContext.describeSession(
            session(pid: 42, waitEvent: "Lock", startedSecondsAgo: 30),
            now: now,
            longRunningThreshold: threshold
        )
        XCTAssertTrue(context.contains("pid: 42"))
        XCTAssertTrue(context.contains("wait_event: Lock"))
        XCTAssertTrue(context.contains("running_for: 30s"))
        XCTAssertTrue(context.contains("SELECT 1"))
        XCTAssertFalse(context.contains("long-running threshold"))
    }

    func testDescribeSessionFlagsLongRunning() {
        let context = PgActivityAIContext.describeSession(
            session(startedSecondsAgo: 120),
            now: now,
            longRunningThreshold: threshold
        )
        XCTAssertTrue(context.contains("running_for: 120s (exceeds the long-running threshold)"))
    }

    func testDescribeSessionAppendsPlanWhenProvided() {
        let context = PgActivityAIContext.describeSession(
            session(),
            now: now,
            longRunningThreshold: threshold,
            planText: "Seq Scan on users"
        )
        XCTAssertTrue(context.contains("EXPLAIN PLAN"))
        XCTAssertTrue(context.contains("Seq Scan on users"))
    }

    func testDescribeSessionRendersMissingQuery() {
        let context = PgActivityAIContext.describeSession(
            session(query: nil, startedSecondsAgo: nil),
            now: now,
            longRunningThreshold: threshold
        )
        XCTAssertTrue(context.contains("(none)"))
        XCTAssertFalse(context.contains("running_for"))
    }

    // MARK: - packSessions

    func testPackSessionsPutsBlockedAndActiveFirst() {
        let context = PgActivityAIContext.packSessions(
            [
                session(pid: 1, state: "idle", query: nil),
                session(pid: 2, state: "active"),
                session(pid: 3, state: "idle in transaction", waitEvent: "Lock"),
            ],
            now: now,
            longRunningThreshold: threshold
        )
        let lines = context.components(separatedBy: "\n")
        XCTAssertTrue(lines[0].contains("3 backends"))
        XCTAssertTrue(lines[1].contains("pid=3"), "blocked session should rank first")
        XCTAssertTrue(lines[2].contains("pid=2"))
        XCTAssertTrue(lines[3].contains("pid=1"))
    }

    func testPackSessionsMarksLongRunningAndTruncatesOverflow() {
        let many = (1...25).map { session(pid: Int32($0), startedSecondsAgo: 120) }
        let context = PgActivityAIContext.packSessions(many, now: now, longRunningThreshold: threshold)
        XCTAssertTrue(context.contains("LONG-RUNNING"))
        XCTAssertTrue(context.contains("and 5 more backends"))
    }

    func testPackSessionsEmptyList() {
        let context = PgActivityAIContext.packSessions([], now: now, longRunningThreshold: threshold)
        XCTAssertTrue(context.contains("(no backends)"))
    }

    // MARK: - packLocks

    func testPackLocksRendersOnlyInterestingRows() {
        let context = PgActivityAIContext.packLocks([
            FfiPgLockDetail(pid: 1, relation: "users", mode: "AccessShareLock", granted: true, blockedByPid: nil),
            FfiPgLockDetail(pid: 2, relation: "orders", mode: "RowExclusiveLock", granted: false, blockedByPid: 7),
        ])
        XCTAssertFalse(context.contains("pid=1"), "granted, unblocked locks are noise")
        XCTAssertTrue(context.contains("pid=2 blocked_by=7 mode=RowExclusiveLock relation=orders NOT granted"))
    }

    func testPackLocksEmptyWhenNothingBlocked() {
        let context = PgActivityAIContext.packLocks([
            FfiPgLockDetail(pid: 1, relation: nil, mode: "AccessShareLock", granted: true, blockedByPid: nil)
        ])
        XCTAssertEqual(context, "")
    }

    // MARK: - Trend

    func testMakeTrendSampleCountsStates() {
        let sample = PgActivityAIContext.makeTrendSample(
            sessions: [
                session(pid: 1, state: "active", startedSecondsAgo: 120),
                session(pid: 2, state: "active", startedSecondsAgo: 5),
                session(pid: 3, state: "idle in transaction", query: nil),
                session(pid: 4, state: "idle", query: nil, waitEvent: "Lock"),
            ],
            now: now,
            longRunningThreshold: threshold
        )
        XCTAssertEqual(sample.total, 4)
        XCTAssertEqual(sample.active, 2)
        XCTAssertEqual(sample.idleInTransaction, 1)
        XCTAssertEqual(sample.waiting, 1)
        XCTAssertEqual(sample.longRunning, 1)
    }

    func testPackTrendUsesOffsetsFromNewestSample() {
        let samples = [
            PgActivityAIContext.TrendSample(epoch: now - 60, total: 5, active: 1, idleInTransaction: 0, waiting: 0, longRunning: 0),
            PgActivityAIContext.TrendSample(epoch: now, total: 9, active: 4, idleInTransaction: 2, waiting: 1, longRunning: 1),
        ]
        let context = PgActivityAIContext.packTrend(samples)
        let lines = context.components(separatedBy: "\n")
        XCTAssertTrue(lines[1].hasPrefix("-60s total=5"))
        XCTAssertTrue(lines[2].hasPrefix("0s total=9 active=4 idle_in_tx=2 waiting=1 long_running=1"))
    }

    func testPackTrendKeepsOnlyNewestWindow() {
        let samples = (0..<20).map { idx in
            PgActivityAIContext.TrendSample(
                epoch: now - Double(20 - idx), total: idx, active: 0,
                idleInTransaction: 0, waiting: 0, longRunning: 0
            )
        }
        let context = PgActivityAIContext.packTrend(samples)
        let dataLines = context.components(separatedBy: "\n").dropFirst()
        XCTAssertEqual(dataLines.count, PgActivityAIContext.maxTrendLines)
        XCTAssertTrue(dataLines.last?.contains("total=19") ?? false, "newest sample must survive the window")
    }

    func testPackTrendEmpty() {
        XCTAssertTrue(PgActivityAIContext.packTrend([]).contains("(no samples)"))
    }
}
