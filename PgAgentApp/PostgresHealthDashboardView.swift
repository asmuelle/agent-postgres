import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// PostgresHealthDashboardView — the DBA daily-driver health view.
//
// Four stat tiles (cache hit ratio, client connections, waiting locks,
// database size) over three triage tables:
//   1. Top queries by total execution time (pg_stat_statements; shows an
//      install hint when the extension is absent)
//   2. Dead tuples / vacuum debt per table
//   3. Unused non-unique indexes (never scanned, by size)
//
// Read-only catalog/statistics queries throughout; auto-refresh optional.
// =============================================================================

struct PgHealthSnapshot: Sendable {
    var cacheHitPercent: String?
    var activeConnections: String = "–"
    var idleConnections: String = "–"
    var idleInTxnConnections: String = "–"
    var totalConnections: String = "–"
    var maxConnections: String = "–"
    var waitingLocks: String = "–"
    var databaseSize: String = "–"
    var hasStatStatements: Bool = false
    var topQueries: [PgHealthTopQuery] = []
    var deadTupleTables: [PgHealthDeadTuples] = []
    var unusedIndexes: [PgHealthUnusedIndex] = []
}

struct PgHealthTopQuery: Identifiable, Sendable {
    let id = UUID()
    let query: String
    let calls: String
    let totalMs: String
    let meanMs: String
    let rows: String
}

struct PgHealthDeadTuples: Identifiable, Sendable {
    let id = UUID()
    let schema: String
    let table: String
    let liveTuples: String
    let deadTuples: String
    let deadPercent: String
    let lastVacuum: String
}

struct PgHealthUnusedIndex: Identifiable, Sendable {
    let id = UUID()
    let schema: String
    let table: String
    let index: String
    let size: String
}

/// Row→model mapping, separated from the view for unit testing.
enum PgHealthParser {
    static func topQueries(_ rows: [[String?]]) -> [PgHealthTopQuery] {
        rows.compactMap { c in
            guard c.count >= 5, let q = c[0] else { return nil }
            return PgHealthTopQuery(
                query: q,
                calls: c[1] ?? "–",
                totalMs: c[2] ?? "–",
                meanMs: c[3] ?? "–",
                rows: c[4] ?? "–"
            )
        }
    }

    static func deadTuples(_ rows: [[String?]]) -> [PgHealthDeadTuples] {
        rows.compactMap { c in
            guard c.count >= 6, let schema = c[0], let table = c[1] else { return nil }
            return PgHealthDeadTuples(
                schema: schema,
                table: table,
                liveTuples: c[2] ?? "0",
                deadTuples: c[3] ?? "0",
                deadPercent: c[4] ?? "–",
                lastVacuum: c[5] ?? "never"
            )
        }
    }

    static func unusedIndexes(_ rows: [[String?]]) -> [PgHealthUnusedIndex] {
        rows.compactMap { c in
            guard c.count >= 4, let schema = c[0], let table = c[1], let index = c[2] else {
                return nil
            }
            return PgHealthUnusedIndex(
                schema: schema,
                table: table,
                index: index,
                size: c[3] ?? "–"
            )
        }
    }
}

struct PostgresHealthDashboardView: View {
    let connectionId: String?

    @State private var snapshot = PgHealthSnapshot()
    @State private var errorMessage: String? = nil
    @State private var isLoading = false
    @State private var autoRefresh = false
    @State private var lastRefreshed: Date? = nil

    private static let autoRefreshSeconds: UInt64 = 30

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let errorMessage {
                errorBanner(errorMessage)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    tileRow
                    topQueriesSection
                    deadTuplesSection
                    unusedIndexesSection
                }
                .padding(16)
            }
        }
        .task(id: connectionId) { await refresh() }
        .task(id: autoRefresh) {
            guard autoRefresh else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.autoRefreshSeconds * 1_000_000_000)
                if Task.isCancelled { return }
                await refresh()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Label("Server Health", systemImage: "waveform.path.ecg")
                .font(.headline)
            if let lastRefreshed {
                Text("updated \(lastRefreshed.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Auto-refresh (30 s)", isOn: $autoRefresh)
                .toggleStyle(.checkbox)
                .font(.caption)
            Button {
                Task { await refresh() }
            } label: {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(isLoading)
            .help("Refresh now")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).font(.callout)
            Spacer()
        }
        .padding(10)
        .background(Color.red.opacity(0.15))
        .foregroundStyle(.red)
    }

    // MARK: - Tiles

    private var tileRow: some View {
        HStack(spacing: 12) {
            statTile(
                title: "Cache hit",
                value: snapshot.cacheHitPercent.map { "\($0)%" } ?? "–",
                detail: "of reads served from shared buffers",
                symbol: "memorychip",
                // <99% on a steady-state OLTP box usually means the
                // working set outgrew shared_buffers.
                tint: tintForCacheHit
            )
            statTile(
                title: "Connections",
                value: "\(snapshot.totalConnections) / \(snapshot.maxConnections)",
                detail: "\(snapshot.activeConnections) active · \(snapshot.idleConnections) idle · \(snapshot.idleInTxnConnections) idle-in-txn",
                symbol: "person.2",
                tint: .blue
            )
            statTile(
                title: "Waiting locks",
                value: snapshot.waitingLocks,
                detail: "ungranted lock requests right now",
                symbol: "lock.badge.clock",
                tint: snapshot.waitingLocks == "0" ? .green : .orange
            )
            statTile(
                title: "Database size",
                value: snapshot.databaseSize,
                detail: "current database on disk",
                symbol: "externaldrive",
                tint: .indigo
            )
        }
    }

    private var tintForCacheHit: Color {
        guard let text = snapshot.cacheHitPercent, let value = Double(text) else {
            return .secondary
        }
        if value >= 99 { return .green }
        if value >= 95 { return .yellow }
        return .orange
    }

    private func statTile(
        title: String, value: String, detail: String, symbol: String, tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Top queries

    @ViewBuilder
    private var topQueriesSection: some View {
        sectionHeader(
            "Top queries by total time",
            symbol: "tortoise",
            count: snapshot.hasStatStatements ? snapshot.topQueries.count : nil
        )
        if !snapshot.hasStatStatements {
            VStack(alignment: .leading, spacing: 6) {
                Text("pg_stat_statements is not installed in this database.")
                    .font(.callout)
                Text("CREATE EXTENSION pg_stat_statements;  -- also requires shared_preload_libraries = 'pg_stat_statements' and a restart")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if snapshot.topQueries.isEmpty {
            emptyHint("No statements recorded yet.")
        } else {
            Table(snapshot.topQueries) {
                TableColumn("Query") { q in
                    Text(q.query)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(2)
                        .help(q.query)
                }
                .width(min: 260, ideal: 460)
                TableColumn("Calls") { q in rightAligned(q.calls) }.width(70)
                TableColumn("Total ms") { q in rightAligned(q.totalMs) }.width(90)
                TableColumn("Mean ms") { q in rightAligned(q.meanMs) }.width(80)
                TableColumn("Rows") { q in rightAligned(q.rows) }.width(80)
            }
            .frame(height: tableHeight(snapshot.topQueries.count))
        }
    }

    // MARK: - Dead tuples

    @ViewBuilder
    private var deadTuplesSection: some View {
        sectionHeader(
            "Vacuum debt (dead tuples)",
            symbol: "trash.slash",
            count: snapshot.deadTupleTables.count
        )
        if snapshot.deadTupleTables.isEmpty {
            emptyHint("No tables with dead tuples — autovacuum is keeping up.")
        } else {
            Table(snapshot.deadTupleTables) {
                TableColumn("Table") { t in
                    Text("\(t.schema).\(t.table)")
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                }
                .width(min: 200, ideal: 320)
                TableColumn("Live") { t in rightAligned(t.liveTuples) }.width(90)
                TableColumn("Dead") { t in rightAligned(t.deadTuples) }.width(90)
                TableColumn("Dead %") { t in rightAligned(t.deadPercent) }.width(70)
                TableColumn("Last (auto)vacuum") { t in
                    Text(t.lastVacuum)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 150, ideal: 220)
            }
            .frame(height: tableHeight(snapshot.deadTupleTables.count))
        }
    }

    // MARK: - Unused indexes

    @ViewBuilder
    private var unusedIndexesSection: some View {
        sectionHeader(
            "Unused indexes (never scanned)",
            symbol: "square.3.layers.3d.slash",
            count: snapshot.unusedIndexes.count
        )
        if snapshot.unusedIndexes.isEmpty {
            emptyHint("Every non-unique index has been used since the last stats reset.")
        } else {
            Table(snapshot.unusedIndexes) {
                TableColumn("Index") { i in
                    Text(i.index)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                }
                .width(min: 200, ideal: 300)
                TableColumn("Table") { i in
                    Text("\(i.schema).\(i.table)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 180, ideal: 280)
                TableColumn("Size") { i in rightAligned(i.size) }.width(90)
            }
            .frame(height: tableHeight(snapshot.unusedIndexes.count))
        }
    }

    // MARK: - Small helpers

    private func sectionHeader(_ title: String, symbol: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            if let count {
                Text("\(count)")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            Spacer()
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func rightAligned(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func tableHeight(_ rows: Int) -> CGFloat {
        CGFloat(min(max(rows, 1), 15)) * 28 + 32
    }

    // MARK: - Loading

    private func refresh() async {
        guard let connectionId, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let sessionId = "health-loader-\(UUID().uuidString)"

        func run(_ sql: String, pageSize: UInt32 = 100) async throws -> [[String?]] {
            try await BridgeManager.shared.pgExecute(
                connectionId: connectionId,
                sessionId: sessionId,
                sql: sql,
                pageSize: pageSize
            ).rows.map(\.cells)
        }

        do {
            var next = PgHealthSnapshot()

            let tiles = try await run("""
            SELECT
              (SELECT round(100 * sum(blks_hit)::numeric
                      / NULLIF(sum(blks_hit) + sum(blks_read), 0), 1)
                 FROM pg_stat_database),
              (SELECT count(*) FROM pg_stat_activity
                WHERE backend_type = 'client backend' AND state = 'active'),
              (SELECT count(*) FROM pg_stat_activity
                WHERE backend_type = 'client backend' AND state = 'idle'),
              (SELECT count(*) FROM pg_stat_activity
                WHERE backend_type = 'client backend' AND state LIKE 'idle in%'),
              (SELECT count(*) FROM pg_stat_activity
                WHERE backend_type = 'client backend'),
              (SELECT setting FROM pg_settings WHERE name = 'max_connections'),
              (SELECT count(*) FROM pg_locks WHERE NOT granted),
              pg_size_pretty(pg_database_size(current_database()));
            """)
            if let row = tiles.first, row.count >= 8 {
                next.cacheHitPercent = row[0]
                next.activeConnections = row[1] ?? "–"
                next.idleConnections = row[2] ?? "–"
                next.idleInTxnConnections = row[3] ?? "–"
                next.totalConnections = row[4] ?? "–"
                next.maxConnections = row[5] ?? "–"
                next.waitingLocks = row[6] ?? "–"
                next.databaseSize = row[7] ?? "–"
            }

            let ext = try await run(
                "SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements';")
            next.hasStatStatements = !ext.isEmpty
            if next.hasStatStatements {
                next.topQueries = PgHealthParser.topQueries(
                    try await run("""
                    SELECT left(regexp_replace(query, '\\s+', ' ', 'g'), 300),
                           calls,
                           round(total_exec_time::numeric, 1),
                           round(mean_exec_time::numeric, 2),
                           rows
                    FROM pg_stat_statements
                    ORDER BY total_exec_time DESC
                    LIMIT 15;
                    """))
            }

            next.deadTupleTables = PgHealthParser.deadTuples(
                try await run("""
                SELECT schemaname, relname, n_live_tup, n_dead_tup,
                       round(100 * n_dead_tup::numeric
                             / NULLIF(n_live_tup + n_dead_tup, 0), 1),
                       COALESCE(greatest(last_autovacuum, last_vacuum)::text, 'never')
                FROM pg_stat_user_tables
                WHERE n_dead_tup > 0
                ORDER BY n_dead_tup DESC
                LIMIT 15;
                """))

            next.unusedIndexes = PgHealthParser.unusedIndexes(
                try await run("""
                SELECT s.schemaname, s.relname, s.indexrelname,
                       pg_size_pretty(pg_relation_size(s.indexrelid))
                FROM pg_stat_user_indexes s
                JOIN pg_index i ON i.indexrelid = s.indexrelid
                WHERE s.idx_scan = 0 AND NOT i.indisunique AND NOT i.indisprimary
                ORDER BY pg_relation_size(s.indexrelid) DESC
                LIMIT 15;
                """))

            snapshot = next
            errorMessage = nil
            lastRefreshed = Date()
        } catch {
            errorMessage = (error as? PostgresBridgeError)?.errorDescription
                ?? error.localizedDescription
        }
        await BridgeManager.shared.pgReleaseSession(
            connectionId: connectionId, sessionId: sessionId)
    }
}
