import Foundation

// =============================================================================
// MaintenanceModel — pure parsing/shaping for the Maintenance tab. Turns
// pg_stat_user_tables rows into ranked vacuum candidates and builds the VACUUM
// SQL. Kept free of the FFI bridge so it's unit-testable in the mobile
// logic-test target. Uses pgQuoteIdent from PostgresSQLQuoting.swift.
// =============================================================================

/// A user table carrying dead tuples — a candidate for VACUUM.
struct VacuumCandidate: Identifiable, Equatable, Sendable {
    let schema: String
    let table: String
    let deadTuples: Int64
    let liveTuples: Int64
    let lastVacuum: String?
    let lastAutovacuum: String?

    var id: String { "\(schema).\(table)" }

    /// Dead / (dead + live), 0…1. Zero when the table is empty.
    var deadRatio: Double {
        let total = deadTuples + liveTuples
        return total == 0 ? 0 : Double(deadTuples) / Double(total)
    }

    /// Safely-quoted `"schema"."table"` for use in SQL.
    var qualifiedName: String {
        "\(pgQuoteIdent(schema)).\(pgQuoteIdent(table))"
    }

    /// Build a VACUUM statement. `full` rewrites the table under an exclusive
    /// lock (destructive-ish); `analyze` refreshes planner stats.
    func vacuumSQL(analyze: Bool, full: Bool) -> String {
        var options: [String] = []
        if full { options.append("FULL") }
        if analyze { options.append("ANALYZE") }
        let clause = options.isEmpty ? "" : " (\(options.joined(separator: ", ")))"
        return "VACUUM\(clause) \(qualifiedName);"
    }
}

/// Parse rows from the bloat query (schemaname, relname, n_dead_tup, n_live_tup,
/// last_vacuum, last_autovacuum), most-dead-tuples first. Rows missing the
/// identity columns are dropped.
func vacuumCandidates(fromRows rows: [[String?]]) -> [VacuumCandidate] {
    rows.compactMap { cells -> VacuumCandidate? in
        guard cells.count >= 4, let schema = cells[0], let table = cells[1] else { return nil }
        return VacuumCandidate(
            schema: schema,
            table: table,
            deadTuples: Int64(cells[2] ?? "0") ?? 0,
            liveTuples: Int64(cells[3] ?? "0") ?? 0,
            lastVacuum: cells.count > 4 ? cells[4] : nil,
            lastAutovacuum: cells.count > 5 ? cells[5] : nil
        )
    }
    .sorted { lhs, rhs in
        if lhs.deadTuples != rhs.deadTuples { return lhs.deadTuples > rhs.deadTuples }
        return lhs.id < rhs.id
    }
}

enum MaintenanceQuery {
    /// Tables with dead tuples, worst first. Dead/live counts come straight from
    /// pg_stat_user_tables; the ratio is derived client-side.
    static let bloatCandidates = """
        SELECT schemaname, relname, n_dead_tup, n_live_tup,
               to_char(last_vacuum, 'YYYY-MM-DD HH24:MI'),
               to_char(last_autovacuum, 'YYYY-MM-DD HH24:MI')
        FROM pg_stat_user_tables
        WHERE n_dead_tup > 0
        ORDER BY n_dead_tup DESC
        LIMIT 100;
        """
}
