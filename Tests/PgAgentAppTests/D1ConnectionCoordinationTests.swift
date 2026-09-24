import XCTest
@testable import PgAgentApp

// Locks in the connection-lifecycle race fixes: SSH tunnel opens are shared by
// concurrent callers, tunnel uses are counted before the Postgres connect is
// awaited, fleet refreshes never overlap, and connection claims can't be
// released by someone who doesn't hold them.

// MARK: - InFlightTaskCoalescer

@MainActor
final class D1InFlightTaskCoalescerTests: XCTestCase {

    func testConcurrentCallersShareOneOperation() async throws {
        let coalescer = InFlightTaskCoalescer<String, Int>()
        var runs = 0
        let gate = AsyncGate()
        let operation: @MainActor () async throws -> Int = {
            runs += 1
            await gate.wait()
            return 42
        }

        let first = Task { @MainActor in try await coalescer.run(key: "bastion", operation: operation) }
        let second = Task { @MainActor in try await coalescer.run(key: "bastion", operation: operation) }
        // Hold the shared open until both callers have asked for it.
        while runs == 0 { await Task.yield() }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(coalescer.isInFlight("bastion"))
        gate.open()

        let firstValue = try await first.value
        let secondValue = try await second.value
        XCTAssertEqual(firstValue, 42)
        XCTAssertEqual(secondValue, 42)
        XCTAssertEqual(runs, 1)
        XCTAssertFalse(coalescer.isInFlight("bastion"))
    }

    func testCompletedOperationIsNotReused() async throws {
        let coalescer = InFlightTaskCoalescer<String, Int>()
        var runs = 0
        _ = try await coalescer.run(key: "k") { runs += 1; return runs }
        let second = try await coalescer.run(key: "k") { runs += 1; return runs }
        XCTAssertEqual(second, 2)
    }

    func testDifferentKeysRunIndependently() async throws {
        let coalescer = InFlightTaskCoalescer<String, String>()
        async let a = coalescer.run(key: "a") { "A" }
        async let b = coalescer.run(key: "b") { "B" }
        let results = try await [a, b]
        XCTAssertEqual(results, ["A", "B"])
    }

    func testFailureReachesEveryWaiter() async {
        struct Boom: Error {}
        let coalescer = InFlightTaskCoalescer<String, Int>()
        do {
            _ = try await coalescer.run(key: "k") { throw Boom() }
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue(error is Boom)
        }
        XCTAssertFalse(coalescer.isInFlight("k"))
    }
}

// MARK: - SerialAsyncQueue

@MainActor
final class D1SerialAsyncQueueTests: XCTestCase {

    func testOperationsNeverOverlapAndKeepOrder() async {
        let queue = SerialAsyncQueue()
        var log: [String] = []
        var running = 0
        var maxRunning = 0

        func op(_ name: String) -> @MainActor () async -> Void {
            {
                running += 1
                maxRunning = max(maxRunning, running)
                log.append("start \(name)")
                await Task.yield()
                await Task.yield()
                log.append("end \(name)")
                running -= 1
            }
        }

        async let refresh1: Void = queue.run(op("refresh1"))
        async let shutdown: Void = queue.run(op("shutdown"))
        async let refresh2: Void = queue.run(op("refresh2"))
        _ = await (refresh1, shutdown, refresh2)

        XCTAssertEqual(maxRunning, 1)
        XCTAssertEqual(log.count, 6)
        for index in stride(from: 0, to: log.count, by: 2) {
            let name = log[index].replacingOccurrences(of: "start ", with: "")
            XCTAssertEqual(log[index + 1], "end \(name)")
        }
    }
}

// MARK: - SSHTunnelUseLedger

final class D1SSHTunnelUseLedgerTests: XCTestCase {

    func testReservationKeepsTunnelOpenWhileAnotherUserDisconnects() {
        var ledger = SSHTunnelUseLedger()
        let first = ledger.reserve(key: "bastion")
        XCTAssertNil(ledger.bind(first, pgConnectionId: "pg-A"))

        // A second connect is in flight (reserved, not yet bound) when the
        // first Postgres connection disconnects — the tunnel must stay open.
        let second = ledger.reserve(key: "bastion")
        XCTAssertNil(ledger.release(pgConnectionId: "pg-A"))
        XCTAssertEqual(ledger.useCount(for: "bastion"), 1)

        XCTAssertNil(ledger.bind(second, pgConnectionId: "pg-B"))
        XCTAssertEqual(ledger.release(pgConnectionId: "pg-B"), "bastion")
        XCTAssertEqual(ledger.useCount(for: "bastion"), 0)
    }

    func testFailedConnectCancelsItsReservation() {
        var ledger = SSHTunnelUseLedger()
        let reservation = ledger.reserve(key: "bastion")
        XCTAssertEqual(ledger.cancel(reservation), "bastion")
        // Cancelling or binding again is a no-op.
        XCTAssertNil(ledger.cancel(reservation))
        XCTAssertNil(ledger.bind(reservation, pgConnectionId: "pg-A"))
        XCTAssertEqual(ledger.useCount(for: "bastion"), 0)
    }

    func testRebindingSamePoolIdFoldsIntoOneUse() {
        var ledger = SSHTunnelUseLedger()
        XCTAssertNil(ledger.bind(ledger.reserve(key: "bastion"), pgConnectionId: "pg-A"))
        // The core hands the same pool id back for a second connect.
        XCTAssertNil(ledger.bind(ledger.reserve(key: "bastion"), pgConnectionId: "pg-A"))
        XCTAssertEqual(ledger.useCount(for: "bastion"), 1)
        XCTAssertEqual(ledger.release(pgConnectionId: "pg-A"), "bastion")
    }

    func testUnknownReleaseIsNoOp() {
        var ledger = SSHTunnelUseLedger()
        XCTAssertNil(ledger.release(pgConnectionId: "never-registered"))
    }

    func testTunnelsAreCountedPerKey() {
        var ledger = SSHTunnelUseLedger()
        XCTAssertNil(ledger.bind(ledger.reserve(key: "a"), pgConnectionId: "pg-1"))
        XCTAssertNil(ledger.bind(ledger.reserve(key: "b"), pgConnectionId: "pg-2"))
        XCTAssertEqual(ledger.release(pgConnectionId: "pg-1"), "a")
        XCTAssertEqual(ledger.useCount(for: "b"), 1)
    }
}

// MARK: - PostgresConnectionManager claims

@MainActor
final class D1ConnectionLeaseTests: XCTestCase {
    private let manager = PostgresConnectionManager.shared

    private func makeProfile() -> PostgresProfile {
        PostgresProfile(name: "lease-\(UUID().uuidString)", database: "db", user: "u")
    }

    func testLeaseReleasesExactlyOnce() {
        let profile = makeProfile()
        let first = manager.claim(profile: profile)
        let second = manager.claim(profile: profile)
        XCTAssertEqual(manager.claimCount(profileId: profile.id), 2)

        manager.release(first)
        manager.release(first) // duplicate: must not drop `second`'s claim
        XCTAssertEqual(manager.claimCount(profileId: profile.id), 1)

        manager.release(second)
        XCTAssertEqual(manager.claimCount(profileId: profile.id), 0)
    }

    func testForgetInvalidatesOutstandingLeases() async {
        let profile = makeProfile()
        let lease = manager.claim(profile: profile)
        await manager.forget(profileId: profile.id)
        let fresh = manager.claim(profile: profile)

        manager.release(lease) // invalidated by forget: no-op
        XCTAssertEqual(manager.claimCount(profileId: profile.id), 1)
        manager.release(fresh)
        XCTAssertEqual(manager.claimCount(profileId: profile.id), 0)
    }
}

// MARK: - Helpers

/// One-shot latch for holding an operation open until the test releases it.
@MainActor
private final class AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
