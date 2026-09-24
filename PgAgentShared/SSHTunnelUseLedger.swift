import Foundation

// =============================================================================
// SSHTunnelUseLedger — pure bookkeeping for how many Postgres connections use
// each SSH tunnel connection, so the SSH connection is closed exactly when its
// last Postgres consumer goes away.
//
// A use is *reserved* before the Postgres connect is awaited and *bound* to the
// Postgres connection id once it is known. Counting the reservation closes the
// window where a concurrent disconnect of the tunnel's last bound user would
// tear the SSH connection down underneath an in-flight connect.
// =============================================================================
struct SSHTunnelUseLedger: Sendable {
    struct Reservation: Hashable, Sendable {
        let key: String
        fileprivate let serial: UInt64
    }

    private var counts: [String: Int] = [:]          // ssh key -> uses (bound + reserved)
    private var pending: Set<Reservation> = []
    private var pgToKey: [String: String] = [:]      // pg conn id -> ssh key
    private var nextSerial: UInt64 = 0

    init() {}

    func useCount(for key: String) -> Int {
        counts[key] ?? 0
    }

    /// Count a use of `key` ahead of the Postgres connect.
    mutating func reserve(key: String) -> Reservation {
        nextSerial &+= 1
        let reservation = Reservation(key: key, serial: nextSerial)
        pending.insert(reservation)
        counts[key, default: 0] += 1
        return reservation
    }

    /// Attach a reservation to the Postgres connection it produced. A second
    /// bind for an already-bound Postgres id (the core reuses a profile's pool
    /// id) folds into the existing use. Returns a key whose use count dropped
    /// to zero — the caller closes that SSH connection — else nil.
    mutating func bind(_ reservation: Reservation, pgConnectionId: String) -> String? {
        guard pending.remove(reservation) != nil else { return nil }
        if pgToKey[pgConnectionId] == nil {
            pgToKey[pgConnectionId] = reservation.key
            return nil
        }
        return decrement(reservation.key)
    }

    /// Drop a reservation whose connect failed. Returns the key to close if
    /// that was its last use.
    mutating func cancel(_ reservation: Reservation) -> String? {
        guard pending.remove(reservation) != nil else { return nil }
        return decrement(reservation.key)
    }

    /// Drop a disconnected Postgres connection's use. Returns the key to close
    /// if that was its last use.
    mutating func release(pgConnectionId: String) -> String? {
        guard let key = pgToKey.removeValue(forKey: pgConnectionId) else { return nil }
        return decrement(key)
    }

    private mutating func decrement(_ key: String) -> String? {
        let count = counts[key] ?? 0
        if count <= 1 {
            counts.removeValue(forKey: key)
            return key
        }
        counts[key] = count - 1
        return nil
    }
}
