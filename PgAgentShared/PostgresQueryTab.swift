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

/// Whether the tab's session holds an open transaction. Tracked client-side —
/// Postgres exposes no transaction status over this path — and driven by the
/// explicit Begin/Commit/Rollback controls, a leading BEGIN/COMMIT/ROLLBACK in
/// executed SQL, and SQLSTATE class 25 (an aborted transaction) on a query error.
enum PgTransactionState: Sendable, Equatable {
    case none
    case open
    case failed
}

/// Set on tabs opened from the schema browser (double-click a
/// relation). Carries the (schema, table) so cell edits know what
/// to UPDATE. Generic SQL tabs leave this `nil` and stay read-only.
struct PostgresEditTarget: Codable, Hashable, Sendable {
    let schema: String
    let table: String
}

// `PostgresBrowseState` and `POSTGRES_ROWID_COLUMN` live in
// PostgresBrowseState.swift (compiled into the same targets,
// including PgAgentMobile).

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

/// Outcome of one statement in a multi-statement script run. The summary
/// fields (elapsed, counts, error) are always kept; the full `result` is
/// retained only for the most recent `PostgresScriptRun.maxRetainedResults`
/// statements so a 100-statement script can't pin 100 result sets in memory.
struct PostgresScriptStatementOutcome: Identifiable, @unchecked Sendable {
    /// 0-based position in the script — doubles as the identity (a run's
    /// outcomes are immutable once produced).
    let index: Int
    /// Short uppercase keyword preview ("SELECT", "INSERT", …) for the chip.
    let preview: String
    /// Collapsed one-line statement text (capped) for tooltips.
    let statementText: String
    let elapsed: TimeInterval
    /// Rows returned, for row-returning statements; `nil` otherwise.
    let rowCount: Int?
    let rowsAffected: UInt64?
    /// Non-nil marks the failing statement (scripts stop on first error).
    let errorMessage: String?
    /// Full result set while retained; dropped (with `resultDropped` set)
    /// once the retention window moves past this statement.
    var result: FfiPgExecutionResult?
    var resultDropped: Bool = false

    var id: Int { index }
}

/// Per-statement outcomes of the tab's most recent script run (2+
/// statements). `nil` for single-statement runs — those look exactly as
/// before.
struct PostgresScriptRun: @unchecked Sendable {
    var statements: [PostgresScriptStatementOutcome]
    /// Which statement's result the grid currently shows.
    var selectedIndex: Int
    /// How many statements the script contains in total — on a failed run,
    /// `statements` holds only the executed prefix, and the strip can say
    /// "stopped at 3 of 7".
    var totalCount: Int
    /// How many full result sets a run may keep in memory at once;
    /// older statements keep only their summary line.
    static let maxRetainedResults = 10
}

enum TabKind: Hashable, Sendable {
    case query
    case routine(schema: String, name: String, signature: String)
    case sequence(schema: String, name: String)
    case objectType(schema: String, name: String, typeKind: String)
    case activity
    case properties(node: PgSchemaNode)
    case erd(schema: String)
    case health
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
    /// pending until the user clicks Apply or Discard.
    var batchMode: Bool
    /// Pending cell edits keyed by (rowIndex, columnIndex). Empty
    /// in non-batch mode. Toolbar Apply / Discard buttons are
    /// gated on this being non-empty.
    var pendingEdits: [PostgresPendingEditKey: PostgresPendingEdit]
    var kind: TabKind
    /// Client-side transaction state for this tab's session. See
    /// `PgTransactionState`.
    var transactionState: PgTransactionState
    /// Verbatim SQL the AI assistant placed into the editor, if any. Tracked
    /// so `PgReadOnlyGuard` can be enforced at execution time for *unmodified*
    /// AI output without interfering with SQL the user typed or edited. Set by
    /// `setAIGeneratedSQL`; cleared the moment the editor text changes.
    var aiGeneratedSQL: String?
    /// 0-based character offset into `sql` to underline as the location of the
    /// last query error, mapped from the server's 1-based error position.
    /// `nil` when the last run succeeded or carried no position. Cleared on any
    /// edit (the offset is meaningless against changed text).
    var errorCharOffset: Int?
    /// Server-side sort + pagination state for relation-browse tabs.
    /// `nil` for generic SQL tabs (and for browse tabs the user took
    /// over by hand-editing the SQL — see `run`'s detach logic).
    var browse: PostgresBrowseState?
    /// `true` when the tab should execute its SQL as soon as the view
    /// shows it (double-click in the sidebar). Consumed exactly once
    /// via `consumeAutoRun(forTab:)`.
    var pendingAutoRun: Bool
    /// Per-statement outcomes of the last script run (2+ top-level
    /// statements). Drives the summary strip above the results grid;
    /// cleared whenever a single-statement run starts.
    var scriptRun: PostgresScriptRun? = nil
    /// Monotonically increasing revision of the displayed result rows.
    /// Bumped by the store on every mutation that changes what the
    /// results grid should render (new result, page append, cell
    /// write-back, row insert/delete). The grid compares
    /// `(tab id, resultsRevision)` instead of deep-equating up to
    /// 50k-row arrays on every unrelated store mutation.
    var resultsRevision: UInt64 = 0

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
        transactionState: PgTransactionState = .none,
        aiGeneratedSQL: String? = nil,
        errorCharOffset: Int? = nil,
        browse: PostgresBrowseState? = nil,
        pendingAutoRun: Bool = false
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
        self.transactionState = transactionState
        self.aiGeneratedSQL = aiGeneratedSQL
        self.errorCharOffset = errorCharOffset
        self.browse = browse
        self.pendingAutoRun = pendingAutoRun
    }

    /// Uppercased first word of a SQL statement, skipping leading whitespace and
    /// line/block comments. Cheap transaction-control detection, not a parser.
    static func leadingKeyword(of sql: String) -> String {
        var s = Substring(sql)
        while true {
            s = s.drop(while: { $0.isWhitespace })
            if s.hasPrefix("--") {
                if let nl = s.firstIndex(of: "\n") { s = s[s.index(after: nl)...] } else { return "" }
            } else if s.hasPrefix("/*") {
                if let end = s.range(of: "*/") { s = s[end.upperBound...] } else { return "" }
            } else {
                break
            }
        }
        return s.prefix { $0.isLetter }.uppercased()
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

    /// Open (or reactivate) a browse tab for `<schema>.<table>`,
    /// pre-populated with the generated SELECT from
    /// `PostgresBrowseState.sql()`. The hidden `ctid AS __pg_rowid__`
    /// column gives the grid a row identifier for cell-level UPDATEs.
    ///
    /// Tabs are deduped on (schema, table, whereClause): a sidebar
    /// double-click lands here twice (the first click opens, the
    /// second re-posts with `autoRun`), and reuse keeps that from
    /// stacking duplicate tabs. FK navigations carry distinct WHERE
    /// clauses, so each filter still gets its own tab.
    ///
    /// `autoRun` marks the tab to execute as soon as the view shows
    /// it (double-click = "show me the data now"); plain clicks and
    /// FK navigation keep the review-before-run convention.
    /// `relationKind` decides whether the generated SELECT may carry
    /// `ctid` (plain views and foreign tables have none — selecting it
    /// fails) and whether the tab is row-editable at all. `nil` means
    /// "unknown, assume table" — safe for FK navigation, since foreign
    /// keys can only reference tables.
    @discardableResult
    func openRelationTab(
        schema: String,
        name: String,
        whereClause: String? = nil,
        autoRun: Bool = false,
        relationKind: PgRelationDisplayKind? = nil
    ) -> UUID {
        if let existing = tabs.first(where: {
            $0.browse?.schema == schema
                && $0.browse?.table == name
                && $0.browse?.whereClause == whereClause
        }) {
            activeTabId = existing.id
            if autoRun {
                mutate(id: existing.id) { tab in
                    // Re-sync the editor to the browse state so the
                    // auto-run executes the generated SELECT, not a
                    // half-typed draft left in the editor.
                    if let browse = tab.browse { tab.sql = browse.sql() }
                    tab.pendingAutoRun = true
                }
            }
            return existing.id
        }
        // ctid is selectable on tables, partitioned tables, and
        // materialized views; plain views and foreign tables have none.
        // Row edits additionally require a physically updatable relation,
        // so only (partitioned) tables get an editTarget.
        let hasRowIdentity: Bool
        let isRowEditable: Bool
        switch relationKind {
        case .none, .table, .partitionedTable:
            hasRowIdentity = true
            isRowEditable = true
        case .materializedView:
            hasRowIdentity = true
            isRowEditable = false
        case .view, .foreignTable:
            hasRowIdentity = false
            isRowEditable = false
        }
        let browse = PostgresBrowseState(
            schema: schema,
            table: name,
            whereClause: whereClause,
            pageSize: Int(pageSize),
            hasRowIdentity: hasRowIdentity
        )
        let tab = PostgresQueryTab(
            title: "\(schema).\(name)",
            sql: browse.sql(),
            editTarget: isRowEditable
                ? PostgresEditTarget(schema: schema, table: name)
                : nil,
            browse: browse,
            pendingAutoRun: autoRun
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

    /// One health dashboard per workspace — reactivate if open.
    @discardableResult
    func openHealthTab() -> UUID {
        if let existing = tabs.first(where: {
            if case .health = $0.kind { return true }
            return false
        }) {
            activeTabId = existing.id
            return existing.id
        }
        let tab = PostgresQueryTab(title: "Server Health", kind: .health)
        tabs.append(tab)
        activeTabId = tab.id
        return tab.id
    }

    /// One diagram per schema — reactivate if already open.
    @discardableResult
    func openERDTab(schema: String) -> UUID {
        if let existing = tabs.first(where: {
            if case .erd(let s) = $0.kind { return s == schema }
            return false
        }) {
            activeTabId = existing.id
            return existing.id
        }
        let tab = PostgresQueryTab(
            title: "Diagram: \(schema)",
            kind: .erd(schema: schema)
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
            // The error underline is anchored to the previous text; drop it.
            $0.errorCharOffset = nil
        }
    }

    /// Map a 1-based Postgres error position (into the trimmed SQL that was
    /// executed) onto a 0-based character offset in the tab's current editor
    /// text, for the editor to underline. `nil` clears the underline.
    func setErrorPosition(_ position: UInt32?, forTab id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard let position, position >= 1 else {
            if tabs[idx].errorCharOffset != nil {
                mutate(id: id) { $0.errorCharOffset = nil }
            }
            return
        }
        // Postgres reports `position` in characters (not bytes), 1-based — which
        // aligns with Swift Character offsets for ASCII/typical SQL. `trimmed`
        // (what the server saw) drops leading whitespace from `sql`, so shift by
        // the leading-whitespace length to land on the right editor character.
        let sql = tabs[idx].sql
        let leadingWhitespace = sql.prefix(while: { $0.isWhitespace }).count
        let offset = leadingWhitespace + Int(position) - 1
        let clamped = (offset >= 0 && offset <= sql.count) ? offset : nil
        mutate(id: id) { $0.errorCharOffset = clamped }
    }

    /// Set the error underline at an absolute 0-based character offset into
    /// the tab's current editor text. Used by the script path, which knows
    /// each statement's offset in the full script and can therefore map a
    /// per-statement server error position itself. `nil` clears.
    func setAbsoluteErrorOffset(_ offset: Int?, forTab id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let count = tabs[idx].sql.count
        let clamped = offset.flatMap { ($0 >= 0 && $0 <= count) ? $0 : nil }
        mutate(id: id) { $0.errorCharOffset = clamped }
    }

    // MARK: - Script runs (multi-statement)

    /// Replace (or clear) the tab's script-run summary. Passing outcomes
    /// does not touch `lastResult` — use `selectScriptStatement` for that.
    func setScriptRun(_ run: PostgresScriptRun?, forTab id: UUID) {
        mutate(id: id) { $0.scriptRun = run }
    }

    /// Point the results grid at one statement of the script run: updates
    /// the strip selection and swaps `lastResult` to that statement's
    /// retained result (or `nil` when it errored / was dropped from the
    /// retention window — the strip shows why).
    func selectScriptStatement(_ index: Int, forTab id: UUID) {
        mutate(id: id) { tab in
            guard var run = tab.scriptRun, run.statements.indices.contains(index) else { return }
            run.selectedIndex = index
            tab.scriptRun = run
            tab.lastResult = run.statements[index].result
            tab.paginationError = nil
            tab.isLoadingMore = false
            tab.resultsRevision &+= 1
        }
    }

    /// Place AI-generated SQL into the editor and remember it verbatim, so
    /// `run` can enforce `PgReadOnlyGuard` on unmodified AI output before it
    /// reaches `pgExecute`.
    func setAIGeneratedSQL(_ sql: String, forTab id: UUID) {
        mutate(id: id) {
            $0.sql = sql
            $0.aiGeneratedSQL = sql
            $0.errorCharOffset = nil
        }
    }

    func setExecState(_ state: PostgresQueryExecState, forTab id: UUID) {
        mutate(id: id) { $0.execState = state }
    }

    func setTransactionState(_ state: PgTransactionState, forTab id: UUID) {
        mutate(id: id) { $0.transactionState = state }
    }

    /// Update transaction state from an executed statement. The leading keyword
    /// (BEGIN/COMMIT/ROLLBACK) drives the happy path; on a query error, SQLSTATE
    /// class 25 — or any error while a transaction is already open — marks it
    /// failed, since Postgres aborts the transaction on the first error.
    func applyTransactionEffect(sql: String, error: PostgresBridgeError?, tabId id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let current = tabs[idx].transactionState
        if let error {
            if error.serverError?.isInFailedTransaction == true || current == .open {
                setTransactionState(.failed, forTab: id)
            }
            return
        }
        switch PostgresQueryTab.leadingKeyword(of: sql) {
        case "BEGIN", "START":
            setTransactionState(.open, forTab: id)
        case "COMMIT", "ROLLBACK", "END", "ABORT":
            setTransactionState(.none, forTab: id)
        default:
            break
        }
    }

    func setResult(_ result: FfiPgExecutionResult?, forTab id: UUID) {
        mutate(id: id) {
            $0.lastResult = result
            // A direct (single-statement) result supersedes any script-run
            // strip left over from a previous multi-statement run.
            $0.scriptRun = nil
            $0.paginationError = nil
            $0.isLoadingMore = false
            $0.resultsRevision &+= 1
        }
    }

    /// Replace or clear a tab's browse state (server-side sort /
    /// pagination). Cleared when the user hand-edits the SQL and runs
    /// it — the pager controls would otherwise re-run stale state
    /// over the user's own query.
    func setBrowse(_ browse: PostgresBrowseState?, forTab id: UUID) {
        mutate(id: id) { $0.browse = browse }
    }

    /// Store a browse-mode result: derives `hasNextPage` from whether
    /// the page came back full, and drops any cursor handle — browse
    /// paging owns pagination, so the cursor-based "Load more"
    /// affordance never applies to these tabs.
    func setBrowseResult(_ result: FfiPgExecutionResult, forTab id: UUID) {
        mutate(id: id) { tab in
            var stored = result
            stored.cursorId = nil
            if var browse = tab.browse {
                browse.hasNextPage = stored.rows.count >= browse.pageSize
                tab.browse = browse
            }
            tab.lastResult = stored
            tab.paginationError = nil
            tab.isLoadingMore = false
            tab.resultsRevision &+= 1
        }
    }

    /// Read-and-clear the auto-run flag. Returns `true` exactly once
    /// per request so repeated view updates can't double-fire the
    /// query.
    func consumeAutoRun(forTab id: UUID) -> Bool {
        guard let idx = tabs.firstIndex(where: { $0.id == id }),
              tabs[idx].pendingAutoRun
        else { return false }
        mutate(id: id) { $0.pendingAutoRun = false }
        return true
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
            tab.resultsRevision &+= 1
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
            tab.resultsRevision &+= 1
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
            tab.resultsRevision &+= 1
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
            tab.resultsRevision &+= 1
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
}
