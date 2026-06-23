import XCTest

// `LockChainModel.swift` is compiled directly into this logic-test target
// (see project.yml) — the same pure chain-shaping the Locks tab ships, with no
// app host or FFI bridge required.

final class LockChainModelTests: XCTestCase {

    func testEmptyEdgesYieldNoGroups() {
        XCTAssertTrue(lockWaitGroups(from: []).isEmpty)
    }

    func testSingleBlockerGroupsItsWaiters() {
        let edges = [
            LockEdge(waiterPid: 20, blockerPid: 10, relation: "orders", mode: "RowExclusiveLock"),
            LockEdge(waiterPid: 21, blockerPid: 10, relation: "orders", mode: "RowExclusiveLock"),
        ]
        let groups = lockWaitGroups(from: edges)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].blockerPid, 10)
        XCTAssertEqual(groups[0].waiterCount, 2)
        XCTAssertEqual(groups[0].waiters.map(\.pid), [20, 21])
        XCTAssertFalse(groups[0].blockerIsAlsoBlocked)
    }

    func testWaitersDeduplicatedByPidFirstEdgeWins() {
        let edges = [
            LockEdge(waiterPid: 20, blockerPid: 10, relation: "orders", mode: "ShareLock"),
            LockEdge(waiterPid: 20, blockerPid: 10, relation: "items", mode: "ExclusiveLock"),
        ]
        let groups = lockWaitGroups(from: edges)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].waiterCount, 1)
        XCTAssertEqual(groups[0].waiters[0].relation, "orders")
        XCTAssertEqual(groups[0].waiters[0].mode, "ShareLock")
    }

    func testGroupsSortedByMostWaitersThenPid() {
        let edges = [
            LockEdge(waiterPid: 30, blockerPid: 11, relation: nil, mode: "m"),
            LockEdge(waiterPid: 31, blockerPid: 12, relation: nil, mode: "m"),
            LockEdge(waiterPid: 32, blockerPid: 12, relation: nil, mode: "m"),
        ]
        let groups = lockWaitGroups(from: edges)
        // 12 has 2 waiters → first; 11 has 1 → second.
        XCTAssertEqual(groups.map(\.blockerPid), [12, 11])
    }

    func testChainMarksBlockerAlsoBlocked() {
        // A blocks B (pid 20), and C (pid 10) blocks A (pid 30) — so 30 is a
        // blocker that is itself a waiter elsewhere → chain.
        let edges = [
            LockEdge(waiterPid: 20, blockerPid: 30, relation: nil, mode: "m"),
            LockEdge(waiterPid: 30, blockerPid: 10, relation: nil, mode: "m"),
        ]
        let groups = lockWaitGroups(from: edges)
        let head30 = groups.first { $0.blockerPid == 30 }
        let head10 = groups.first { $0.blockerPid == 10 }
        XCTAssertEqual(head30?.blockerIsAlsoBlocked, true)
        XCTAssertEqual(head10?.blockerIsAlsoBlocked, false)
    }

    func testSelfEdgesAreIgnored() {
        let edges = [LockEdge(waiterPid: 10, blockerPid: 10, relation: nil, mode: "m")]
        XCTAssertTrue(lockWaitGroups(from: edges).isEmpty)
    }
}
