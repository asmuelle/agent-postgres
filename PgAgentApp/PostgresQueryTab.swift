import Foundation
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// PostgresQueryTab — one open query within a Postgres workspace.
//
// State is intentionally a plain struct — the store wraps `[Tab]` and
// publishes mutations. Avoids the trap of giving each tab its own
// ObservableObject identity, which would require either a sea of
// @StateObject per tab or hand-rolled change forwarding for the list.
// =============================================================================

enum PostgresQueryExecState: Sendable {
    case idle
    case running(startedAt: Date)
    case completed(elapsed: TimeInterval, atTime: Date)
    case failed(message: String, elapsed: TimeInterval)
    case cancelled(elapsed: TimeInterval)
}

/// Set on tabs opened from the schema browser (double-click a
/// relation). Carries the (schema, table) so cell edits know what
/// to UPDATE. Generic SQL tabs leave this `nil` and stay read-only.
struct PostgresEditTarget: Codable, Hashable, Sendable {
    let schema: String
    let table: String
}

/// Magic column name the auto-generated SELECT aliases `ctid` to.
/// The grid hides any column whose name starts with `__pg_`, so this
/// stays out of the user's sight while still being available for
/// row identification on UPDATEs.
let POSTGRES_ROWID_COLUMN: String = "__pg_rowid__"

/// Key for the per-tab pending-edits map. Indices are stable within
/// a result (pagination append doesn't shift earlier indices, and
/// we clear pending edits on result-shape changes anyway).
struct PostgresPendingEditKey: Hashable, Sendable {
    let rowIndex: Int
    let columnIndex: Int
}

/// One staged edit awaiting Commit / Discard. The original value is
/// captured so Discard can revert the in-memory grid to the
/// server-truthful state without re-querying.
struct PostgresPendingEdit: Sendable {
    let columnName: String
    let columnType: String
    let originalValue: String?
    let newValue: String?
    let rowId: String
}

enum TabKind: Hashable, Sendable {
    case query
    case routine(schema: String, name: String, signature: String)
    case sequence(schema: String, name: String)
    case objectType(schema: String, name: String, typeKind: String)
    case activity
    case properties(node: PgSchemaNode)
}

struct PostgresQueryTab: Identifiable, @unchecked Sendable {
    let id: UUID
    /// User-visible label shown in the query tab strip. Either "Query N" for
    /// a fresh tab or "<schema>.<table>" when opened from a relation.
    var title: String
    /// SQL text in the editor. Owned by the tab so unsaved drafts
    /// survive switching to another tab.
    var sql: String
    /// Most-recent successful result. `nil` until the user runs a
    /// query at least once. Mutated in place when "Load more"
    /// appends rows from a cursor — `lastResult.rows` accumulates;
    /// `lastResult.cursorId` is cleared when the cursor exhausts
    /// or expires.
    var lastResult: FfiPgExecutionResult?
    /// Most-recent execution status. Drives the run/cancel button
    /// and the status bar.
    var execState: PostgresQueryExecState
    /// `true` while a `pgFetchPage` is in flight. Drives the
    /// progress indicator on the "Load more" affordance.
    var isLoadingMore: Bool
    /// Sticky error text from the last pagination attempt. Cleared
    /// on the next successful fetch or on a fresh `execute`. Used
    /// to surface "result no longer available" when a cursor expires.
    var paginationError: String?
    /// Set when this tab was opened from the schema browser; the
    /// auto-generated SELECT carries `ctid AS __pg_rowid__` so the
    /// grid can offer cell editing. Generic SQL tabs leave this
    /// `nil` and stay read-only.
    var editTarget: PostgresEditTarget?
    /// Batch-edit mode toggle. When `false` (default), cell edits
    /// commit-on-blur as before. When `true`, edits stage as
    /// pending until the user clicks Commit or Discard.
    var batchMode: Bool
    /// Pending cell edits keyed by (rowIndex, columnIndex). Empty
    /// in non-batch mode. Toolbar Commit / Discard buttons are
    /// gated on this being non-empty.
    var pendingEdits: [PostgresPendingEditKey: PostgresPendingEdit]
    var kind: TabKind
    /// Verbatim SQL the AI assistant placed into the editor, if any. Tracked
    /// so `PgReadOnlyGuard` can be enforced at execution time for *unmodified*
    /// AI output without interfering with SQL the user typed or edited. Set by
    /// `setAIGeneratedSQL`; cleared the moment the editor text changes.
    var aiGeneratedSQL: String?

    init(
        id: UUID = UUID(),
        title: String,
        sql: String = "",
        lastResult: FfiPgExecutionResult? = nil,
        execState: PostgresQueryExecState = .idle,
        isLoadingMore: Bool = false,
        paginationError: String? = nil,
        editTarget: PostgresEditTarget? = nil,
        batchMode: Bool = false,
        pendingEdits: [PostgresPendingEditKey: PostgresPendingEdit] = [:],
        kind: TabKind = .query,
        aiGeneratedSQL: String? = nil
    ) {
        self.id = id
        self.title = title
        self.sql = sql
        self.lastResult = lastResult
        self.execState = execState
        self.isLoadingMore = isLoadingMore
        self.paginationError = paginationError
        self.editTarget = editTarget
        self.batchMode = batchMode
        self.pendingEdits = pendingEdits
        self.kind = kind
        self.aiGeneratedSQL = aiGeneratedSQL
    }

    /// Convenience for the toolbar — Commit/Discard appear when
    /// the tab has staged edits.
    var hasPendingEdits: Bool { !pendingEdits.isEmpty }

    /// Whether the result has more pages available server-side.
    /// Derived from the cursor handle; UI uses this to gate the
    /// "Load more" button.
    var hasMore: Bool {
        lastResult?.cursorId != nil
    }

    /// Number of rows currently fetched into the tab. Used by the
    /// status bar and the safety cap.
    var fetchedRowCount: Int {
        lastResult?.rows.count ?? 0
    }
}

@MainActor
final class PostgresQueryTabsStore: ObservableObject {
    @Published private(set) var tabs: [PostgresQueryTab] = []
    @Published var activeTabId: UUID? = nil

    /// Rows to fetch per round trip (initial page or "Load more").
    /// Tuned to balance perceived snappiness ("Load more" feels
    /// instant under ~200 ms) against round-trip count for big
    /// browses. 500 fits comfortably in the FFI marshaling budget.
    var pageSize: UInt32 = 500

    /// Hard cap on accumulated rows per tab. Past this, "Load more"
    /// disables — running the query for 200K rows in a UI grid is
    /// almost always a sign the user wants to refine their query
    /// (or use COPY for an export).
    var maxAccumulatedRows: Int = 50_000

    var activeTab: PostgresQueryTab? {
        guard let id = activeTabId else { return nil }
        return tabs.first { $0.id == id }
    }

    // MARK: - Tab CRUD

    @discardableResult
    func openBlankTab() -> UUID {
        let n = tabs.count + 1
        let tab = PostgresQueryTab(title: "Query \(n)")
        tabs.append(tab)
        activeTabId = tab.id
        return tab.id
    }

    /// Open a tab pre-filled with arbitrary SQL for review — used by
    /// the Object Explorer's context menu actions (DROP / TRUNCATE /
    /// REFRESH MATERIALIZED VIEW …). Nothing executes until the user
    /// presses Run, which is the whole point: destructive statements
    /// are scripted, never fired directly from a menu click.
    @discardableResult
    func openSqlTab(title: String, sql: String) -> UUID {
        let tab = PostgresQueryTab(title: title, sql: sql)
        tabs.append(tab)
        activeTabId = tab.id
        return tab.id
    }

    /// Open a tab pre-populated with `SELECT *, ctid AS __pg_rowid__
    /// FROM <schema>.<table> LIMIT 200`. The hidden ctid column gives
    /// the grid a row identifier for cell-level UPDATEs; the grid
    /// hides it from display. Identifiers are quoted defensively —
    /// Postgres allows mixed-case and reserved-word identifiers, so
    /// an unquoted `Order` would silently target `order`.
    @discardableResult
    func openRelationTab(schema: String, name: String) -> UUID {
        let qualified = "\(quoteIdent(schema)).\(quoteIdent(name))"
        // `ctid AS __pg_rowid__` is the row-identity column the
        // editable-grid path keys on. The alias keeps it findable
        // by name (the grid scans column names, not OIDs).
        let sql = "SELECT *, ctid AS \(POSTGRES_ROWID_COLUMN) FROM \(qualified) LIMIT 500;"
        let tab = PostgresQueryTab(
            title: "\(schema).\(name)",
            sql: sql,
            editTarget: PostgresEditTarget(schema: schema, table: name)
        )
        tabs.append(tab)
        activeTabId = tab.id
        return tab.id
    }

    @discardableResult
    func openRoutineTab(schema: String, name: String, signature: String) -> UUID {
        if let existing = tabs.first(where: {
            if case .routine(let s, let n, let sig) = $0.kind {
                return s == schema && n == name && sig == signature
            }
            return false
        }) {
            activeTabId = existing.id
            return existing.id
        }
        let tab = PostgresQueryTab(
            title: "\(name)\(signature)",
            kind: .routine(schema: schema, name: name, signature: signature)
        )
        tabs.append(tab)
        activeTabId = tab.id
        return tab.id
    }

    @discardableResult
    func openSequenceTab(schema: String, name: String) -> UUID {
        if let existing = tabs.first(where: {
            if case .sequence(let s, let n) = $0.kind {
                return s == schema && n == name
            }
            return false
        }) {
            activeTabId = existing.id
            return existing.id
        }
        let tab = PostgresQueryTab(
            title: name,
            kind: .sequence(schema: schema, name: name)
        )
        tabs.append(tab)
        activeTabId = tab.id
        return tab.id
    }

    @discardableResult
    func openObjectTypeTab(schema: String, name: String, typeKind: String) -> UUID {
        if let existing = tabs.first(where: {
            if case .objectType(let s, let n, _) = $0.kind {
                return s == schema && n == name
            }
            return false
        }) {
            activeTabId = existing.id
            return existing.id
        }
        let tab = PostgresQueryTab(
            title: name,
            kind: .objectType(schema: schema, name: name, typeKind: typeKind)
        )
        tabs.append(tab)
        activeTabId = tab.id
        return tab.id
    }

    @discardableResult
    func openPropertyTab(node: PgSchemaNode) -> UUID {
        // Reuse existing property tab if present to avoid cluttering tabs bar
        if let existingIndex = tabs.firstIndex(where: {
            if case .properties = $0.kind { return true }
            return false
        }) {
            var updated = tabs[existingIndex]
            updated.title = "Properties: \(node.name)"
            updated.kind = .properties(node: node)
            tabs[existingIndex] = updated
            activeTabId = updated.id
            return updated.id
        } else {
            let tab = PostgresQueryTab(
                title: "Properties: \(node.name)",
                kind: .properties(node: node)
            )
            tabs.append(tab)
            activeTabId = tab.id
            return tab.id
        }
    }

    @discardableResult
    func openActivityTab() -> UUID {
        if let existing = tabs.first(where: {
            if case .activity = $0.kind { return true }
            return false
        }) {
            activeTabId = existing.id
            return existing.id
        }
        let tab = PostgresQueryTab(
            title: "Activity Monitor",
            kind: .activity
        )
        tabs.append(tab)
        activeTabId = tab.id
        return tab.id
    }

    func closeTab(id: UUID) {
        tabs.removeAll { $0.id == id }
        if activeTabId == id {
            activeTabId = tabs.last?.id
        }
    }

    func setActive(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabId = id
    }

    // MARK: - Tab mutation

    /// Apply an in-place mutation to the tab with `id`. Marks the
    /// store as changed so SwiftUI re-renders the affected views.
    func mutate(id: UUID, _ change: (inout PostgresQueryTab) -> Void) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        change(&tabs[idx])
        // `@Published` on `tabs` already fires on mutation since
        // `tabs[idx] = ...` is a setter; this is just to be explicit.
    }

    func setSQL(_ sql: String, forTab id: UUID) {
        mutate(id: id) {
            $0.sql = sql
            // Any explicit edit or non-AI insert revokes AI provenance: once
            // the user owns the text, it runs on the normal (unguarded) path.
            $0.aiGeneratedSQL = nil
        }
    }

    /// Place AI-generated SQL into the editor and remember it verbatim, so
    /// `run` can enforce `PgReadOnlyGuard` on unmodified AI output before it
    /// reaches `pgExecute`.
    func setAIGeneratedSQL(_ sql: String, forTab id: UUID) {
        mutate(id: id) {
            $0.sql = sql
            $0.aiGeneratedSQL = sql
        }
    }

    func setExecState(_ state: PostgresQueryExecState, forTab id: UUID) {
        mutate(id: id) { $0.execState = state }
    }

    func setResult(_ result: FfiPgExecutionResult?, forTab id: UUID) {
        mutate(id: id) {
            $0.lastResult = result
            $0.paginationError = nil
            $0.isLoadingMore = false
        }
    }

    func setLoadingMore(_ loading: Bool, forTab id: UUID) {
        mutate(id: id) { $0.isLoadingMore = loading }
    }

    /// Append a fetched page to the tab's accumulated result, and
    /// clear the cursor handle when the cursor has exhausted.
    func appendPage(
        _ page: FfiPgPageResult,
        forTab id: UUID
    ) {
        mutate(id: id) { tab in
            guard var result = tab.lastResult else { return }
            result.rows.append(contentsOf: page.rows)
            // Cursor exhausted server-side → drop the handle so
            // the UI hides "Load more".
            if !page.hasMore {
                result.cursorId = nil
            }
            tab.lastResult = result
            tab.isLoadingMore = false
            tab.paginationError = nil
        }
    }

    /// Mutate a cell value in the tab's accumulated result. Called
    /// after a successful UPDATE so the grid reflects the new value
    /// without re-querying.
    func setCellValue(
        _ value: String?,
        rowIndex: Int,
        columnIndex: Int,
        forTab id: UUID
    ) {
        mutate(id: id) { tab in
            guard var result = tab.lastResult,
                  rowIndex < result.rows.count,
                  columnIndex < result.rows[rowIndex].cells.count
            else { return }
            var row = result.rows[rowIndex]
            row.cells[columnIndex] = value
            result.rows[rowIndex] = row
            tab.lastResult = result
        }
    }

    /// Toggle batch-edit mode on/off. Discarding pending edits when
    /// switching off is the safer default — the user opted out, so
    /// retaining ghost edits would surprise.
    func setBatchMode(_ on: Bool, forTab id: UUID) {
        mutate(id: id) { tab in
            tab.batchMode = on
            if !on {
                tab.pendingEdits = [:]
            }
        }
    }

    /// Stage one cell edit. If a pending edit exists for the same
    /// (row, col), the original value sticks (the user's first
    /// stage captured the truth) and only the new value updates.
    func addPendingEdit(_ edit: PostgresPendingEdit, key: PostgresPendingEditKey, forTab id: UUID) {
        mutate(id: id) { tab in
            if let existing = tab.pendingEdits[key] {
                tab.pendingEdits[key] = PostgresPendingEdit(
                    columnName: edit.columnName,
                    columnType: edit.columnType,
                    originalValue: existing.originalValue,
                    newValue: edit.newValue,
                    rowId: edit.rowId
                )
            } else {
                tab.pendingEdits[key] = edit
            }
        }
    }

    func clearPendingEdits(forTab id: UUID) {
        mutate(id: id) { $0.pendingEdits = [:] }
    }

    /// Append a freshly-INSERTed row to the tab's accumulated
    /// result. Used by the INSERT row flow so the new row appears
    /// in the grid without re-running the query.
    func appendRow(_ row: FfiPgRow, forTab id: UUID) {
        mutate(id: id) { tab in
            guard var result = tab.lastResult else { return }
            result.rows.append(row)
            tab.lastResult = result
        }
    }

    /// Remove rows from the tab's accumulated result by index.
    /// Used after a successful DELETE so the grid reflects the
    /// deletion without re-querying. Indexes are sorted descending
    /// internally so removal is index-stable across the iteration.
    func removeRows(rowIndexes: IndexSet, forTab id: UUID) {
        guard !rowIndexes.isEmpty else { return }
        mutate(id: id) { tab in
            guard var result = tab.lastResult else { return }
            // Walk descending so each removal doesn't shift the
            // remaining indexes.
            let sorted = rowIndexes.sorted(by: >)
            for idx in sorted where idx < result.rows.count {
                result.rows.remove(at: idx)
            }
            tab.lastResult = result
        }
    }

    /// Drop the cursor handle for a tab. Used after a full export
    /// drains and closes the cursor server-side — the in-memory
    /// rows stay where they were before the export, but the "Load
    /// more" affordance disappears since there's nothing to fetch.
    func clearCursor(forTab id: UUID) {
        mutate(id: id) { tab in
            guard var result = tab.lastResult else { return }
            result.cursorId = nil
            tab.lastResult = result
            tab.isLoadingMore = false
        }
    }

    /// Surface a pagination failure on the tab. Drops the cursor
    /// handle so subsequent "Load more" clicks don't hit the same
    /// dead cursor.
    func setPaginationError(_ message: String, forTab id: UUID) {
        mutate(id: id) { tab in
            tab.paginationError = message
            tab.isLoadingMore = false
            if var result = tab.lastResult {
                result.cursorId = nil
                tab.lastResult = result
            }
        }
    }

    // MARK: - Identifier quoting

    /// Postgres double-quote escaping — embedded double quotes
    /// become two double quotes, and the whole thing is wrapped.
    /// Defensive against schema/table names with spaces, mixed case,
    /// or reserved words.
    private func quoteIdent(_ s: String) -> String {
        "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
