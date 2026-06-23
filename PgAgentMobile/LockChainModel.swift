import Foundation

// =============================================================================
// LockChainModel — pure, dependency-free shaping of pg_locks wait relationships
// into "blocker → waiters" groups. Kept free of the FFI bridge so the chain
// logic is unit-testable in the mobile logic-test target. The view maps
// FfiPgLockDetail rows into LockEdge values and calls `lockWaitGroups`.
// =============================================================================

/// One "pid is blocked by blockerPid (on relation, holding/seeking mode)" edge,
/// distilled from an FfiPgLockDetail whose blockedByPid is non-nil.
struct LockEdge: Equatable, Sendable {
    let waiterPid: Int32
    let blockerPid: Int32
    let relation: String?
    let mode: String
}

/// A backend stuck waiting on a blocker.
struct LockWaiter: Identifiable, Equatable, Sendable {
    let pid: Int32
    let relation: String?
    let mode: String
    var id: Int32 { pid }
}

/// A blocker (chain head) and everyone directly waiting on it. The actionable
/// quick fix is "terminate the blocker".
struct LockWaitGroup: Identifiable, Equatable, Sendable {
    let blockerPid: Int32
    let waiters: [LockWaiter]
    /// True when the blocker is itself waiting on something else — i.e. this is
    /// a deeper chain (or a deadlock), so terminating this pid may only move the
    /// contention up one level.
    let blockerIsAlsoBlocked: Bool

    var id: Int32 { blockerPid }
    var waiterCount: Int { waiters.count }
}

/// Group wait edges by their blocker. Waiters are de-duplicated by pid (first
/// edge wins for relation/mode). Groups are ordered by most-waiters-first, then
/// by blockerPid for stable rendering.
func lockWaitGroups(from edges: [LockEdge]) -> [LockWaitGroup] {
    guard !edges.isEmpty else { return [] }

    let waiterPids = Set(edges.map(\.waiterPid))

    // Preserve first-seen order per blocker while de-duplicating waiters.
    var orderByBlocker: [Int32] = []
    var waitersByBlocker: [Int32: [LockWaiter]] = [:]
    var seenWaiterPerBlocker: [Int32: Set<Int32>] = [:]

    for edge in edges {
        // A backend never meaningfully blocks itself; skip self-edges.
        guard edge.waiterPid != edge.blockerPid else { continue }

        if waitersByBlocker[edge.blockerPid] == nil {
            orderByBlocker.append(edge.blockerPid)
            waitersByBlocker[edge.blockerPid] = []
            seenWaiterPerBlocker[edge.blockerPid] = []
        }
        if seenWaiterPerBlocker[edge.blockerPid]?.contains(edge.waiterPid) == true {
            continue
        }
        seenWaiterPerBlocker[edge.blockerPid]?.insert(edge.waiterPid)
        waitersByBlocker[edge.blockerPid]?.append(
            LockWaiter(pid: edge.waiterPid, relation: edge.relation, mode: edge.mode)
        )
    }

    let groups = orderByBlocker.map { blocker in
        LockWaitGroup(
            blockerPid: blocker,
            waiters: waitersByBlocker[blocker] ?? [],
            blockerIsAlsoBlocked: waiterPids.contains(blocker)
        )
    }

    return groups.sorted { lhs, rhs in
        if lhs.waiterCount != rhs.waiterCount { return lhs.waiterCount > rhs.waiterCount }
        return lhs.blockerPid < rhs.blockerPid
    }
}
