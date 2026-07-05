import OSLog
import PgAgentMacOS
import SwiftUI

// =============================================================================
// PostgresQueryTabView — one query tab's content.
//
// Three regions stacked top-to-bottom:
//   1. SQL editor   — TextEditor with monospaced font; ⌘↵ runs.
//   2. Status strip — execution state + row count + elapsed.
//   3. Results grid — header pinned, cells in a LazyVGrid for
//      virtualization. NSTableView via NSViewRepresentable would give
//      column resize and selection out of the box; LazyVGrid keeps
//      this MVP self-contained.
//
// State lives in `PostgresQueryTabsStore`. The view reads `tab` for
// presentation and writes back through helper methods on the store —
// avoids two sources of truth (e.g. local @State copies of sql).
//
// This file holds the view struct, its state, composition, and the
// run/execute/cancel pipeline. Companion files (extensions of this
// view, split to keep files focused):
//   - PostgresQueryTabView+EditorBar.swift    — SQL editor + status bar
//   - PostgresQueryTabView+Results.swift      — results grid, toolbar, footers
//   - PostgresQueryTabView+Transposed.swift   — transposed record view
//   - PostgresQueryTabView+Editing.swift      — cell update / insert / delete
//   - PostgresQueryTabView+Transactions.swift — BEGIN / COMMIT / ROLLBACK
//   - PostgresQueryExport.swift               — full-result export pipeline
// =============================================================================

struct PostgresQueryTabView: View {
    @ObservedObject var store: PostgresQueryTabsStore
    /// Identity of the tab this view represents. Resolved fresh every
    /// render — if the underlying tab was closed, we render an empty
    /// state rather than crash.
    let tabId: UUID
    /// Profile id for history scoping. Each profile has its own
    /// rolling SQL history; passing the id (not the whole profile)
    /// keeps the view's deps minimal.
    let profileId: String
    /// Current connection. Optional because the workspace may be in a
    /// reconnecting / disconnected state when the tab is foregrounded.
    let connectionId: String?

    @State private var runTask: Task<Void, Never>? = nil
    @State var historyOpen: Bool = false
    @State var savedOpen: Bool = false
    @State var snippetsOpen: Bool = false
    @State var explainPlanOpen: Bool = false
    @State var exportProgress: PostgresExportProgressState? = nil
    @State var exportCancel = ExportCancelToken()
    @State var exportSummary: ExportSummary? = nil
    @State var insertSheet: InsertSheetContext? = nil
    @State var isTransposed: Bool = false
    @State var selectedTransposedRowIndex: Int = 0
    /// Case-insensitive substring filter over the loaded result rows. Applied
    /// client-side by the grid; reset when a new query runs.
    @State var resultFilter: String = ""
    /// A cell the user asked to inspect (right-click → "Show value…").
    @State var inspectedCell: PostgresCellInspection? = nil
    /// FK constraints per `"<schema>.<table>"` for relation tabs,
    /// mirrored out of `PgSchemaStore` (which this view doesn't
    /// observe) so a load completion re-renders the grid with the
    /// navigation menu items lit up.
    @State var foreignKeysBySourceTable: [String: PgTableForeignKeys] = [:]
    /// A non-read-only statement the AI assistant generated, awaiting the
    /// user's explicit confirmation before it runs. `nil` when nothing is
    /// pending. Set by `run` when it refuses to silently execute AI-authored
    /// write SQL.
    @State private var pendingAIWrite: PendingAIWrite? = nil
    @FocusState private var editorFocused: Bool

    private struct PendingAIWrite: Identifiable {
        let id = UUID()
        let tabId: UUID
        let connectionId: String
        let sql: String
    }

    /// Drives the on-device "Explain this error" sheet. Inert on OSes below
    /// macOS 26 — `aiAvailable` gates the entry point so the sheet never shows.
    @StateObject var aiErrorStore = PgAIErrorExplainStore()
    /// Drives the on-device "Generate SQL from a description" sheet.
    @StateObject var nlToSQLStore = PgAINLToSQLStore()
    /// Drives the on-device streaming "Explain query & results" sheet.
    @StateObject var aiExplainStore = PgAIExplainStore()
    /// Resolved once: whether the on-device model can run on this device.
    @State var aiAvailable = PgAIAvailabilityProbe.current().isAvailable

    let logger = Logger(subsystem: "com.mc-ssh", category: "postgres-query")

    private var tab: PostgresQueryTab? {
        store.tabs.first { $0.id == tabId }
    }

    var profile: PostgresProfile? {
        PostgresProfileStore.shared.profile(withId: profileId)
    }

    private var environmentColor: Color? {
        profile?.effectiveEnvironment.tint
    }

    var body: some View {
        if let tab {
            switch tab.kind {
            case .query:
                content(for: tab)
                    .onChange(of: tabId) { _ in
                        // The host reuses one view across tabs (swaps tabId), so
                        // reset per-tab grid affordances on switch.
                        resultFilter = ""
                        inspectedCell = nil
                    }
                    // Command palette's "Explain Last Query" — only the active
                    // tab's view exists, so this can't double-present.
                    .onReceive(
                        NotificationCenter.default.publisher(for: .postgresExplainActiveTab)
                    ) { _ in
                        guard connectionId != nil,
                              !tab.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        else { return }
                        explainPlanOpen = true
                    }
                    // Command palette's snippet items — forward to this tab's
                    // editor channel so the NSTextView layer inserts at the
                    // caret and starts the placeholder session.
                    .onReceive(
                        NotificationCenter.default.publisher(for: .postgresInsertSnippetActiveTab)
                    ) { note in
                        guard let body = note.userInfo?["body"] as? String else { return }
                        NotificationCenter.default.post(
                            name: .pgSQLEditorInsertSnippet,
                            object: nil,
                            userInfo: [
                                "channel": tabId.uuidString,
                                "body": body,
                            ]
                        )
                    }
                    // Auto-run for sidebar double-click / "Open Data":
                    // the id re-fires the task whenever the flag flips
                    // on; `consumeAutoRun` clears it so re-renders
                    // can't double-fire.
                    .task(id: "\(tabId)-autorun-\(tab.pendingAutoRun)") {
                        guard tab.pendingAutoRun,
                              store.consumeAutoRun(forTab: tab.id)
                        else { return }
                        run(tab: tab)
                    }
            case .routine(let schema, let name, let signature):
                PostgresRoutineEditorView(
                    connectionId: connectionId,
                    profileId: profileId,
                    schema: schema,
                    name: name,
                    signature: signature
                )
            case .sequence(let schema, let name):
                PostgresSequenceVisualizerView(
                    connectionId: connectionId,
                    schema: schema,
                    name: name
                )
            case .objectType(let schema, let name, let typeKind):
                PostgresObjectTypeVisualizerView(
                    connectionId: connectionId,
                    schema: schema,
                    name: name,
                    typeKind: typeKind
                )
            case .activity:
                PostgresActivityMonitorView(connectionId: connectionId)
            case .erd(let schema):
                PostgresERDView(
                    connectionId: connectionId,
                    profileId: profileId,
                    schema: schema
                )
            case .health:
                PostgresHealthDashboardView(connectionId: connectionId)
            case .properties(let node):
                if let schemaStore = PostgresConnectionManager.shared.schemaStores[profileId] {
                    PostgresPropertyInspectorView(
                        node: node,
                        connectionId: connectionId,
                        store: schemaStore,
                        onClose: {
                            store.closeTab(id: tab.id)
                        }
                    )
                } else {
                    Text("No schema store available")
                        .padding()
                }
            }
        } else {
            placeholder
        }
    }

    // MARK: - Composition

    @ViewBuilder
    private func content(for tab: PostgresQueryTab) -> some View {
        VStack(spacing: 0) {
            if let envColor = environmentColor {
                Rectangle()
                    .fill(envColor)
                    .frame(height: 2)
            }
            PostgresTransactionBar(
                state: tab.transactionState,
                isConnected: connectionId != nil,
                onBegin: { beginTransaction(tab: tab) },
                onCommit: { commitTransaction(tab: tab) },
                onRollback: { rollbackTransaction(tab: tab) }
            )
            VSplitView {
                sqlEditor(for: tab)
                    .frame(minHeight: 100, idealHeight: 160)

                VStack(spacing: 0) {
                    statusBar(for: tab)
                    Divider()
                    resultsArea(for: tab)
                }
                .frame(minHeight: 200)
            }
        }
        .sheet(isPresented: Binding(
            get: { exportProgress != nil },
            set: { if !$0 { exportProgress = nil } }
        )) {
            if let progress = exportProgress {
                PostgresExportProgressSheet(
                    state: progress,
                    onCancel: {
                        exportProgress?.isCancelling = true
                        exportCancel.cancel()
                    }
                )
            }
        }
        .alert(
            exportSummary?.title ?? "",
            isPresented: Binding(
                get: { exportSummary != nil },
                set: { if !$0 { exportSummary = nil } }
            ),
            presenting: exportSummary
        ) { _ in
            Button("OK") { exportSummary = nil }
        } message: { summary in
            Text(summary.message)
        }
        .alert(
            "Run a statement that modifies data?",
            isPresented: Binding(
                get: { pendingAIWrite != nil },
                set: { if !$0 { pendingAIWrite = nil } }
            ),
            presenting: pendingAIWrite
        ) { pending in
            Button("Run write", role: .destructive) {
                // The user takes ownership: drop AI provenance so the same
                // statement isn't re-challenged, then execute it directly.
                store.mutate(id: pending.tabId) { $0.aiGeneratedSQL = nil }
                execute(tabId: pending.tabId, connectionId: pending.connectionId, sql: pending.sql)
                pendingAIWrite = nil
            }
            Button("Cancel", role: .cancel) { pendingAIWrite = nil }
        } message: { pending in
            Text("The AI assistant generated this statement and it is not a single read-only query. Review it before running:\n\n\(String(pending.sql.prefix(400)))")
        }
        .sheet(item: $insertSheet) { ctx in
            PostgresInsertRowSheet(
                target: ctx.target,
                columns: ctx.columns,
                returnColumnNames: ctx.returnColumnNames,
                columnDetails: ctx.columnDetails,
                onSubmit: { forms, returnNames, complete in
                    runInsertRow(
                        tab: ctx.tab,
                        forms: forms,
                        returnNames: returnNames,
                        complete: complete
                    )
                }
            )
        }
        .sheet(isPresented: $explainPlanOpen) {
            PostgresExplainVisualizerView(
                connectionId: connectionId,
                query: tab.sql
            )
            .frame(minWidth: 850, minHeight: 600)
        }
        .sheet(item: $inspectedCell) { cell in
            PostgresCellInspectorView(
                inspection: cell,
                editContext: inspectorEditContext(for: cell, tab: tab)
            )
        }
    }

    // MARK: - Browse (server-side sort + pagination)

    /// Re-run the browse SELECT with new state (sort or page change).
    /// The regenerated SQL replaces the editor text — same
    /// see-what-runs convention as the original generated tab; the
    /// re-run is immediate because the user asked for it through the
    /// grid controls.
    private func applyBrowse(_ newBrowse: PostgresBrowseState, tab: PostgresQueryTab) {
        guard let connectionId else { return }
        let sql = newBrowse.sql()
        store.setBrowse(newBrowse, forTab: tab.id)
        store.setSQL(sql, forTab: tab.id)
        execute(tabId: tab.id, connectionId: connectionId, sql: sql)
    }

    func goToBrowsePage(_ page: Int, tab: PostgresQueryTab) {
        guard let browse = tab.browse else { return }
        applyBrowse(browse.movingToPage(page), tab: tab)
    }

    func cycleBrowseSort(column: String, tab: PostgresQueryTab) {
        guard let browse = tab.browse else { return }
        applyBrowse(browse.cyclingSort(by: column), tab: tab)
    }

    // MARK: - Empty / placeholder

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Tab no longer exists").font(.headline)
            Text("It may have been closed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    func run(tab: PostgresQueryTab) {
        guard let connectionId else {
            store.setExecState(
                .failed(message: "Not connected.", elapsed: 0),
                forTab: tab.id
            )
            return
        }
        let trimmed = tab.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // A browse tab whose editor no longer matches its generated
        // SELECT has been taken over by hand-written SQL — drop the
        // pager so the server-side sort/page controls can't re-run
        // stale browse state over the user's own query.
        if let browse = tab.browse,
           trimmed != browse.sql().trimmingCharacters(in: .whitespacesAndNewlines) {
            store.setBrowse(nil, forTab: tab.id)
        }

        // Enforce the read-only guard for *unmodified* AI-generated SQL. The
        // on-device model is told to emit read-only SQL, but instructions are
        // not a boundary — this is. If the editor still holds verbatim AI
        // output and it is not a single read-only statement, require explicit
        // confirmation before it can reach pgExecute. SQL the user typed or
        // edited carries no AI provenance and runs unimpeded.
        if let aiSQL = tab.aiGeneratedSQL,
           aiSQL.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed,
           !PgReadOnlyGuard.isReadOnly(trimmed) {
            pendingAIWrite = PendingAIWrite(
                tabId: tab.id,
                connectionId: connectionId,
                sql: trimmed
            )
            return
        }

        // Scripts (2+ top-level statements) execute statement-by-statement so
        // each statement gets its own timing, result set, and read-only/audit
        // treatment. Splitting runs on the *editor* text so per-statement
        // offsets map straight onto the error underline. Single statements
        // stay byte-identical with the old path (`trimmed` is what executes).
        let statements = PostgresStatementSplitter.split(tab.sql)
        if statements.count >= 2 {
            executeScript(tabId: tab.id, connectionId: connectionId, statements: statements)
            return
        }

        execute(tabId: tab.id, connectionId: connectionId, sql: trimmed)
    }

    /// Submit `sql` to the engine. Split out from `run` so the AI-write
    /// confirmation can call straight through once the user accepts.
    private func execute(tabId: UUID, connectionId: String, sql trimmed: String) {
        runTask?.cancel()
        let started = Date()
        store.setExecState(.running(startedAt: started), forTab: tabId)
        store.setErrorPosition(nil, forTab: tabId)
        resultFilter = ""

        let storeRef = store
        let sessionId = tabId.uuidString
        let pageSize = store.pageSize
        runTask = Task { @MainActor in
            do {
                let result = try await BridgeManager.shared.pgExecute(
                    connectionId: connectionId,
                    sessionId: sessionId,
                    sql: trimmed,
                    pageSize: pageSize
                )
                let elapsed = Date().timeIntervalSince(started)
                guard !Task.isCancelled else {
                    storeRef.setExecState(.cancelled(elapsed: elapsed), forTab: tabId)
                    return
                }
                // Browse tabs derive `hasNextPage` from the page fill
                // and never expose the cursor-based "Load more" path.
                if storeRef.tabs.first(where: { $0.id == tabId })?.browse != nil {
                    storeRef.setBrowseResult(result, forTab: tabId)
                } else {
                    storeRef.setResult(result, forTab: tabId)
                }
                storeRef.setExecState(
                    .completed(elapsed: elapsed, atTime: Date()),
                    forTab: tabId
                )
                storeRef.applyTransactionEffect(sql: trimmed, error: nil, tabId: tabId)
                // Record successful executions only — failures and
                // cancellations don't represent something the user
                // would want to re-run via the history panel.
                let rowsReturned: Int? = result.columns.isEmpty ? nil : result.rows.count
                PostgresHistoryStore.shared.record(
                    profileId: profileId,
                    sql: trimmed,
                    durationMs: UInt32(min(elapsed * 1000, Double(UInt32.max))),
                    rowsReturned: rowsReturned
                )
            } catch let err as PostgresBridgeError {
                let elapsed = Date().timeIntervalSince(started)
                storeRef.setExecState(
                    .failed(message: err.errorDescription ?? "Query failed", elapsed: elapsed),
                    forTab: tabId
                )
                storeRef.applyTransactionEffect(sql: trimmed, error: err, tabId: tabId)
                // Underline the offending token in the editor when the server
                // reported an error position (syntax errors, type mismatches…).
                storeRef.setErrorPosition(err.serverError?.position, forTab: tabId)
                logger.error("query failed: \(err.localizedDescription, privacy: .public)")
            } catch {
                let elapsed = Date().timeIntervalSince(started)
                storeRef.setExecState(
                    .failed(message: error.localizedDescription, elapsed: elapsed),
                    forTab: tabId
                )
                // Unreachable from pgExecute today (pgWrapping maps everything to
                // PostgresBridgeError), but if a non-bridge error ever escapes,
                // don't leave a tracked-open transaction silently stale —
                // Postgres aborts the transaction on any statement error.
                storeRef.applyTransactionEffect(
                    sql: trimmed,
                    error: .other(error.localizedDescription),
                    tabId: tabId
                )
            }
        }
    }

    func cancel(tab: PostgresQueryTab) {
        guard let connectionId else { return }
        let sessionId = tab.id.uuidString
        // Server-side cancel scoped to this session — other tabs'
        // queries on the same profile keep running.
        Task {
            _ = await BridgeManager.shared.pgCancel(
                connectionId: connectionId,
                sessionId: sessionId
            )
        }
        runTask?.cancel()
    }

    // MARK: - Script execution (multi-statement)

    /// Run a 2+-statement script sequentially through the same
    /// `BridgeManager.pgExecute` bridge the single-statement path uses —
    /// which is precisely what keeps the read-only classifier and the write
    /// audit log applying *per statement*. Stops on the first error,
    /// keeping the completed prefix's outcomes. Only the last
    /// `PostgresScriptRun.maxRetainedResults` result sets stay in memory;
    /// earlier statements keep a summary line only.
    private func executeScript(
        tabId: UUID,
        connectionId: String,
        statements: [PostgresScriptStatement]
    ) {
        runTask?.cancel()
        let startedAll = Date()
        store.setExecState(.running(startedAt: startedAll), forTab: tabId)
        store.setErrorPosition(nil, forTab: tabId)
        store.setScriptRun(nil, forTab: tabId)
        resultFilter = ""

        let storeRef = store
        let sessionId = tabId.uuidString
        let pageSize = store.pageSize
        let total = statements.count
        let scriptText = statements.map(\.text).joined(separator: ";\n")
        runTask = Task { @MainActor in
            var outcomes: [PostgresScriptStatementOutcome] = []
            var retained: [Int] = [] // outcome indices still holding a result

            // Nested funcs don't inherit the closure's @MainActor isolation;
            // annotate explicitly so the store calls stay main-actor.
            @MainActor func publish(selecting index: Int) {
                storeRef.setScriptRun(
                    PostgresScriptRun(
                        statements: outcomes,
                        selectedIndex: index,
                        totalCount: total
                    ),
                    forTab: tabId
                )
                storeRef.selectScriptStatement(index, forTab: tabId)
            }

            for (i, statement) in statements.enumerated() {
                let started = Date()
                do {
                    var result = try await BridgeManager.shared.pgExecute(
                        connectionId: connectionId,
                        sessionId: sessionId,
                        sql: statement.text,
                        pageSize: pageSize
                    )
                    let elapsed = Date().timeIntervalSince(started)
                    guard !Task.isCancelled else {
                        storeRef.setExecState(
                            .cancelled(elapsed: Date().timeIntervalSince(startedAll)),
                            forTab: tabId
                        )
                        return
                    }
                    // Each subsequent execute on this session supersedes the
                    // previous statement's cursor server-side, so only the
                    // final statement may keep a live "Load more" handle.
                    if i < total - 1 { result.cursorId = nil }
                    let hasVisibleColumns = result.columns.contains {
                        !$0.name.hasPrefix("__pg_")
                    }
                    outcomes.append(PostgresScriptStatementOutcome(
                        index: i,
                        preview: Self.statementPreview(statement.text),
                        statementText: Self.collapsed(statement.text),
                        elapsed: elapsed,
                        rowCount: hasVisibleColumns ? result.rows.count : nil,
                        rowsAffected: result.rowsAffected,
                        errorMessage: nil,
                        result: result
                    ))
                    retained.append(outcomes.count - 1)
                    if retained.count > PostgresScriptRun.maxRetainedResults {
                        let dropIndex = retained.removeFirst()
                        outcomes[dropIndex].result = nil
                        outcomes[dropIndex].resultDropped = true
                    }
                    storeRef.applyTransactionEffect(
                        sql: statement.text, error: nil, tabId: tabId
                    )
                    // Progressive display: the strip and grid advance as
                    // statements complete, so long scripts show progress.
                    publish(selecting: i)
                } catch {
                    let bridgeError = error as? PostgresBridgeError
                        ?? .other(error.localizedDescription)
                    let elapsed = Date().timeIntervalSince(started)
                    let message = bridgeError.errorDescription ?? "Statement failed"
                    outcomes.append(PostgresScriptStatementOutcome(
                        index: i,
                        preview: Self.statementPreview(statement.text),
                        statementText: Self.collapsed(statement.text),
                        elapsed: elapsed,
                        rowCount: nil,
                        rowsAffected: nil,
                        errorMessage: message,
                        result: nil
                    ))
                    storeRef.applyTransactionEffect(
                        sql: statement.text, error: bridgeError, tabId: tabId
                    )
                    // Map the server's 1-based position inside *this*
                    // statement onto the full editor text for the underline.
                    if let position = bridgeError.serverError?.position, position >= 1 {
                        storeRef.setAbsoluteErrorOffset(
                            statement.startCharOffset + Int(position) - 1,
                            forTab: tabId
                        )
                    }
                    publish(selecting: i)
                    storeRef.setExecState(
                        .failed(
                            message: "Statement \(i + 1) of \(total): \(message)",
                            elapsed: Date().timeIntervalSince(startedAll)
                        ),
                        forTab: tabId
                    )
                    logger.error(
                        "script statement \(i + 1)/\(total) failed: \(message, privacy: .public)"
                    )
                    return
                }
            }

            storeRef.setExecState(
                .completed(elapsed: Date().timeIntervalSince(startedAll), atTime: Date()),
                forTab: tabId
            )
            // One history entry for the whole script, like the old bulk path.
            let rowsReturned = outcomes.last?.rowCount
            PostgresHistoryStore.shared.record(
                profileId: profileId,
                sql: scriptText,
                durationMs: UInt32(min(
                    Date().timeIntervalSince(startedAll) * 1000, Double(UInt32.max)
                )),
                rowsReturned: rowsReturned
            )
        }
    }

    /// Uppercase leading-keyword preview for a script chip ("SELECT",
    /// "CREATE INDEX" → "CREATE", …). Falls back to a text prefix for
    /// statements starting with something unlexable.
    private static func statementPreview(_ sql: String) -> String {
        let keyword = PostgresQueryTab.leadingKeyword(of: sql)
        if !keyword.isEmpty { return keyword }
        return String(collapsed(sql).prefix(16))
    }

    /// One-line, whitespace-collapsed statement text capped for tooltips.
    private static func collapsed(_ sql: String) -> String {
        let joined = sql
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return joined.count > 200 ? String(joined.prefix(200)) + "…" : joined
    }

    // MARK: - Cell inspector editing

    /// Build the inspector's edit context when — and only when — the
    /// inspected cell is writable JSON: the tab has an edit target, the row
    /// carries a ctid, the column's affinity is json/jsonb, and the profile
    /// is not read-only (the bridge re-checks read-only as defense in
    /// depth). Saves go through `runCellUpdate`, the same pipeline the grid
    /// uses, so batch mode staging and the write audit keep working.
    func inspectorEditContext(
        for cell: PostgresCellInspection,
        tab: PostgresQueryTab
    ) -> PostgresCellInspectorEditContext? {
        guard tab.editTarget != nil,
              let rowId = cell.rowId, !rowId.isEmpty,
              cell.rowIndex >= 0, cell.columnIndex >= 0,
              !cell.typeName.isEmpty,
              PostgresColumnAffinity.from(typeOid: cell.typeOid) == .json,
              !(profile?.isReadOnly ?? false)
        else { return nil }
        return PostgresCellInspectorEditContext(onSave: { newValue, complete in
            runCellUpdate(
                edit: PostgresCellEdit(
                    rowIndex: cell.rowIndex,
                    columnIndex: cell.columnIndex,
                    columnName: cell.columnName,
                    columnType: cell.typeName,
                    newValue: newValue,
                    rowId: rowId
                ),
                tab: tab,
                complete: complete
            )
        })
    }
}
