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
    @State private var historyOpen: Bool = false
    @State private var savedOpen: Bool = false
    @State private var explainPlanOpen: Bool = false
    @State private var exportProgress: PostgresExportProgressState? = nil
    @State private var exportCancel = ExportCancelToken()
    @State private var exportSummary: ExportSummary? = nil
    @State private var insertSheet: InsertSheetContext? = nil
    @State private var isTransposed: Bool = false
    @State private var selectedTransposedRowIndex: Int = 0
    /// Case-insensitive substring filter over the loaded result rows. Applied
    /// client-side by the grid; reset when a new query runs.
    @State private var resultFilter: String = ""
    /// A cell the user asked to inspect (right-click → "Show value…").
    @State private var inspectedCell: PostgresCellInspection? = nil
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
    @StateObject private var aiErrorStore = PgAIErrorExplainStore()
    /// Drives the on-device "Generate SQL from a description" sheet.
    @StateObject private var nlToSQLStore = PgAINLToSQLStore()
    /// Drives the on-device streaming "Explain query & results" sheet.
    @StateObject private var aiExplainStore = PgAIExplainStore()
    /// Resolved once: whether the on-device model can run on this device.
    @State private var aiAvailable = PgAIAvailabilityProbe.current().isAvailable

    private let logger = Logger(subsystem: "com.mc-ssh", category: "postgres-query")

    private var tab: PostgresQueryTab? {
        store.tabs.first { $0.id == tabId }
    }

    private var profile: PostgresProfile? {
        PostgresProfileStore.shared.profile(withId: profileId)
    }

    private var environmentColor: Color? {
        guard let p = profile else { return nil }
        switch p.color {
        case "production": return .red
        case "development": return .green
        case "testing": return .yellow
        default: return nil
        }
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
            case .routine(let schema, let name, let signature):
                PostgresRoutineVisualizerView(
                    connectionId: connectionId,
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
            PostgresCellInspectorView(inspection: cell)
        }
    }

    // MARK: - SQL editor

    @ViewBuilder
    private func sqlEditor(for tab: PostgresQueryTab) -> some View {
        ZStack(alignment: .topTrailing) {
            PostgresSQLEditor(
                text: Binding(
                    get: { tab.sql },
                    set: { store.setSQL($0, forTab: tab.id) }
                ),
                errorCharOffset: tab.errorCharOffset,
                identifiers: {
                    PostgresConnectionManager.shared
                        .schemaStores[profileId]?.completionIdentifiers ?? []
                }
            )
            .background(Color(NSColor.textBackgroundColor))
            // ⌘↵ runs, ⌘. cancels. These hidden buttons register as
            // window-level key equivalents, so they fire regardless of editor
            // focus and before the text view sees the keystroke (no double-run).
            .overlay(alignment: .top) {
                HStack(spacing: 0) {
                    Button("Run", action: { run(tab: tab) })
                        .keyboardShortcut(.return, modifiers: .command)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                    Button("Cancel", action: { cancel(tab: tab) })
                        .keyboardShortcut(".", modifiers: .command)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                }
                .accessibilityHidden(true)
            }

            HStack(spacing: 6) {
                if aiAvailable {
                    Button {
                        nlToSQLStore.present()
                    } label: {
                        Label("Generate", systemImage: "sparkles")
                    }
                    .help("Generate SQL from a description (on-device AI)")
                    .disabled(connectionId == nil)
                }

                Button {
                    historyOpen.toggle()
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .keyboardShortcut("y", modifiers: .command)
                .help("Recent queries on this profile (⌘Y)")
                .popover(isPresented: $historyOpen, arrowEdge: .bottom) {
                    PostgresHistoryPopover(
                        profileId: profileId,
                        onPick: { entry in
                            store.setSQL(entry.sql, forTab: tab.id)
                        },
                        onDismiss: { historyOpen = false }
                    )
                }

                Button {
                    savedOpen.toggle()
                } label: {
                    Label("Saved", systemImage: "bookmark")
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .help("Saved queries on this profile (⇧⌘S)")
                .popover(isPresented: $savedOpen, arrowEdge: .bottom) {
                    PostgresSavedQueriesPopover(
                        profileId: profileId,
                        currentSql: tab.sql,
                        onPick: { entry in
                            store.setSQL(entry.sql, forTab: tab.id)
                        },
                        onDismiss: { savedOpen = false }
                    )
                }

                // Staged edit status indicator for active query sessions.
                if tab.hasPendingEdits {
                    Label("Staged (\(tab.pendingEdits.count))", systemImage: "square.stack.3d.up.fill")
                        .foregroundStyle(.blue)
                        .font(.caption)
                        .padding(.trailing, 4)
                }

                if isRunning(tab) {
                    Button {
                        cancel(tab: tab)
                    } label: {
                        Label("Cancel", systemImage: "stop.fill")
                    }
                    .help("Cancel the in-flight query (⌘.)")
                } else {
                    Button {
                        explainPlanOpen = true
                    } label: {
                        Label("Explain", systemImage: "chart.bar.doc.horizontal.fill")
                    }
                    .help("Explain the query plan visually")
                    .disabled(connectionId == nil
                              || tab.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        run(tab: tab)
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Execute the SQL above (⌘↵)")
                    .disabled(connectionId == nil
                              || tab.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .controlSize(.small)
            .padding(8)
        }
        .sheet(isPresented: $nlToSQLStore.isPresented) {
            PgAINLToSQLView(
                store: nlToSQLStore,
                connectionId: connectionId ?? "",
                defaultSchema: "public"
            ) { generatedSql in
                store.setAIGeneratedSQL(generatedSql, forTab: tab.id)
            }
        }
    }

    // MARK: - Status bar

    @ViewBuilder
    private func statusBar(for tab: PostgresQueryTab) -> some View {
        HStack(spacing: 12) {
            statusBadge(for: tab)
            if case .failed(let msg, _) = tab.execState, aiAvailable, let conn = connectionId {
                Button {
                    aiErrorStore.explain(
                        sql: tab.sql,
                        errorMessage: msg,
                        connectionId: conn,
                        defaultSchema: "public"
                    )
                } label: {
                    Label("Explain", systemImage: "sparkles")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Explain this error with on-device AI")
            }
            if let r = tab.lastResult {
                Text(rowSummary(r))
                    .foregroundStyle(.secondary)
                    .font(.caption)
                if tab.hasMore {
                    Text("more available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if tab.fetchedRowCount >= store.maxAccumulatedRows {
                    Label("limit reached (\(store.maxAccumulatedRows) rows)",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("Add LIMIT/WHERE to your SQL or COPY for an export.")
                }
            }
            if let err = tab.paginationError {
                Label(err, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(err)
            }
            Spacer()
            if let elapsed = elapsedDescription(for: tab) {
                Text(elapsed)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .sheet(isPresented: $aiErrorStore.isPresented) {
            PgAIErrorExplainView(store: aiErrorStore) { correctedSql in
                store.setAIGeneratedSQL(correctedSql, forTab: tab.id)
            }
        }
        .sheet(isPresented: $aiExplainStore.isPresented) {
            PgAIExplainView(store: aiExplainStore)
        }
    }

    @ViewBuilder
    private func statusBadge(for tab: PostgresQueryTab) -> some View {
        switch tab.execState {
        case .idle:
            Label("Ready", systemImage: "circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Running…").font(.caption)
            }
        case .completed:
            Label("Done", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let msg, _):
            Label(msg, systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
                .help(msg)
        case .cancelled:
            Label("Cancelled", systemImage: "stop.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Results

    @ViewBuilder
    private func resultsArea(for tab: PostgresQueryTab) -> some View {
        if let r = tab.lastResult {
            // Treat "no visible columns" as no result set. The hidden
            // `__pg_rowid__` column never counts on its own.
            let visibleColumns = r.columns.filter { !$0.name.hasPrefix("__pg_") }
            if visibleColumns.isEmpty {
                // Non-row-returning statement. Show the rows-affected
                // line and stop — there's no grid to draw.
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.seal")
                        .font(.title2)
                        .foregroundStyle(.green)
                    Text(r.rowsAffected.map { "\($0) rows affected" } ?? "Statement completed")
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    resultsToolbar(for: tab, result: r)
                    Divider()
                    if isTransposed {
                        transposedView(result: r, tab: tab)
                    } else {
                        resultsGrid(result: r, tab: tab)
                    }
                    if tab.hasMore || tab.isLoadingMore {
                        loadMoreFooter(for: tab)
                    }
                }
            }
        } else if case .running = tab.execState {
            VStack(spacing: 8) {
                ProgressView()
                Text("Running query…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "table")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No results yet").font(.caption).foregroundStyle(.secondary)
                Text("Type SQL above and press ⌘↵ to run.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func resultsGrid(result: FfiPgExecutionResult, tab: PostgresQueryTab) -> some View {
        // Native NSTableView via NSViewRepresentable. Gives column
        // resize, multi-row selection, and ⌘C-to-clipboard out of
        // the box — none of which `LazyVGrid` provides.
        //
        // Editing is enabled only when the tab knows which table to
        // UPDATE (set by `openRelationTab`) AND the result carries
        // the hidden `__pg_rowid__` column. The grid hides that
        // column from display but uses it to identify rows on
        // commit.
        let canEdit = tab.editTarget != nil
            && result.columns.contains(where: { $0.name == POSTGRES_ROWID_COLUMN })
        // Full export is offered when there's any visible result —
        // even tabs without a cursor benefit (writes the in-memory
        // rows + skips the drain step). The menu validates by
        // checking the host wired a callback at all.
        PostgresResultsTable(
            result: result,
            filterText: resultFilter,
            onInspectCell: { inspectedCell = $0 },
            editable: canEdit,
            pendingEdits: tab.pendingEdits,
            onCellEdit: canEdit ? { edit, complete in
                runCellUpdate(edit: edit, tab: tab, complete: complete)
            } : nil,
            onExportFull: { runFullExport(tab: tab, format: .csv) },
            onExportFullJsonl: { runFullExport(tab: tab, format: .jsonl) },
            onExportFullParquet: { runFullExport(tab: tab, format: .parquet) },
            onDeleteRows: canEdit ? { rowIndices in
                runDeleteRows(rowIndices: rowIndices, tab: tab)
            } : nil,
            onInsertRow: canEdit ? { presentInsertSheet(tab: tab) } : nil,
            // Width persistence is keyed on the editable target —
            // generic SQL tabs don't get persistent widths because
            // there's no stable shape to key on across reruns.
            widthPersistKey: tab.editTarget.map { target in
                PostgresColumnWidthKey(
                    profileId: profileId,
                    schema: target.schema,
                    table: target.table
                )
            }
        )
        .background(Color(NSColor.textBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(NSColor.gridColor))
                .frame(height: 1)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color(NSColor.gridColor))
                .frame(width: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(NSColor.gridColor))
                .frame(height: 1)
        }
    }

    /// Confirm + run a bulk DELETE for the selected rows. Removes
    /// the rows from the in-memory result on success so the grid
    /// reflects the change without a re-query.
    private func runDeleteRows(rowIndices: [Int], tab: PostgresQueryTab) {
        guard !rowIndices.isEmpty,
              let connectionId,
              let target = tab.editTarget,
              let result = tab.lastResult,
              let rowIdColIdx = result.columns.firstIndex(where: { $0.name == POSTGRES_ROWID_COLUMN })
        else { return }

        // Confirm. Bulk DELETE is destructive enough that even
        // power-user surfaces should require an explicit "yes".
        let alert = NSAlert()
        alert.messageText = rowIndices.count == 1
            ? "Delete 1 row from \"\(target.schema)\".\"\(target.table)\"?"
            : "Delete \(rowIndices.count) rows from \"\(target.schema)\".\"\(target.table)\"?"
        alert.informativeText = "This can't be undone from mc-ssh."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Build the ctid list from the in-memory rows. Keep the row
        // index alongside so we can remove them after success.
        var ctids: [String] = []
        var validIndices: [Int] = []
        for idx in rowIndices where idx < result.rows.count {
            let cells = result.rows[idx].cells
            guard rowIdColIdx < cells.count, let ctid = cells[rowIdColIdx] else { continue }
            ctids.append(ctid)
            validIndices.append(idx)
        }
        guard !ctids.isEmpty else { return }

        let sessionId = tab.id.uuidString
        let storeRef = store
        let tabId = tab.id
        Task { @MainActor in
            do {
                let outcome = try await BridgeManager.shared.pgDeleteRows(
                    connectionId: connectionId,
                    sessionId: sessionId,
                    schema: target.schema,
                    table: target.table,
                    rowIds: ctids
                )
                // Drop the indices we asked to delete from the
                // in-memory result regardless of the actual count —
                // any "missing" rows are gone server-side too. The
                // partial-success message tells the user when ctids
                // had moved.
                storeRef.removeRows(
                    rowIndexes: IndexSet(validIndices),
                    forTab: tabId
                )
                if outcome.rowsAffected != UInt64(ctids.count) {
                    let alert = NSAlert()
                    alert.messageText = "Some rows were already gone"
                    alert.informativeText = "Deleted \(outcome.rowsAffected) of \(ctids.count) rows. The others had been removed by another session."
                    alert.runModal()
                }
            } catch let err as PostgresBridgeError {
                logger.error("delete_rows failed: \(err.localizedDescription, privacy: .public)")
                let alert = NSAlert()
                alert.messageText = "Delete failed"
                alert.informativeText = err.errorDescription ?? "Unknown error."
                alert.alertStyle = .warning
                alert.runModal()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Delete failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    /// Bridge between the table's commit callback and the FFI. The
    /// `complete` closure is invoked on the main queue with the
    /// outcome the table uses to apply or revert the cell display.
    private func runCellUpdate(
        edit: PostgresCellEdit,
        tab: PostgresQueryTab,
        complete: @escaping (PostgresCellEditOutcome) -> Void
    ) {
        guard let connectionId, let target = tab.editTarget else {
            complete(.failed(message: "Not connected, or this tab isn't tied to a table."))
            return
        }

        // Batch mode: stage the edit instead of writing through.
        // The visual update still flows (`.applied` → coordinator
        // mutates its in-memory copy + reloads). Discard later
        // restores from `originalValue`.
        if tab.batchMode {
            let original: String? = tab.lastResult.flatMap { result -> String? in
                guard edit.rowIndex < result.rows.count,
                      edit.columnIndex < result.rows[edit.rowIndex].cells.count
                else { return nil }
                return result.rows[edit.rowIndex].cells[edit.columnIndex]
            }
            store.addPendingEdit(
                PostgresPendingEdit(
                    columnName: edit.columnName,
                    columnType: edit.columnType,
                    originalValue: original,
                    newValue: edit.newValue,
                    rowId: edit.rowId
                ),
                key: PostgresPendingEditKey(
                    rowIndex: edit.rowIndex,
                    columnIndex: edit.columnIndex
                ),
                forTab: tab.id
            )
            store.setCellValue(
                edit.newValue,
                rowIndex: edit.rowIndex,
                columnIndex: edit.columnIndex,
                forTab: tab.id
            )
            complete(.applied)
            return
        }

        let sessionId = tab.id.uuidString
        let storeRef = store
        let tabId = tab.id
        Task {
            do {
                let res = try await BridgeManager.shared.pgUpdateCell(
                    connectionId: connectionId,
                    sessionId: sessionId,
                    schema: target.schema,
                    table: target.table,
                    column: edit.columnName,
                    columnType: edit.columnType,
                    newValue: edit.newValue,
                    rowId: edit.rowId
                )
                if res.rowsAffected == 0 {
                    complete(.conflict)
                    return
                }
                storeRef.setCellValue(
                    edit.newValue,
                    rowIndex: edit.rowIndex,
                    columnIndex: edit.columnIndex,
                    forTab: tabId
                )
                complete(.applied)
            } catch let err as PostgresBridgeError {
                logger.error("update_cell failed: \(err.localizedDescription, privacy: .public)")
                complete(.failed(message: err.errorDescription ?? "Update failed"))
            } catch {
                complete(.failed(message: error.localizedDescription))
            }
        }
    }

    /// Apply all staged edits atomically. The batch is wrapped in its own
    /// transaction (BEGIN … COMMIT, ROLLBACK on the first hard failure) so it is
    /// all-or-nothing — unless the user already has an explicit transaction
    /// open, in which case the edits join it and they control the outcome.
    /// Conflicts (zero rows affected because the ctid moved) revert that one
    /// cell and continue; the staged edits survive a rollback so the user can
    /// fix the offending value and retry.
    private func commitPendingEdits(tab: PostgresQueryTab) {
        guard let connectionId, let target = tab.editTarget else { return }
        let pending = tab.pendingEdits
        guard !pending.isEmpty else { return }
        let sessionId = tab.id.uuidString
        let storeRef = store
        let tabId = tab.id
        // Deterministic order — the server applies edits top-to-bottom.
        let edits = pending.sorted {
            ($0.key.rowIndex, $0.key.columnIndex) < ($1.key.rowIndex, $1.key.columnIndex)
        }
        let ownTransaction = (tab.transactionState == .none)

        Task { @MainActor in
            if ownTransaction {
                do {
                    try await BridgeManager.shared.pgBegin(connectionId: connectionId, sessionId: sessionId)
                } catch {
                    presentBatchAlert(title: "Apply failed", message: Self.batchMessage(for: error))
                    return
                }
            }
            var succeeded = 0
            // Defer reverting conflicted cells until the batch actually commits,
            // so a later rollback leaves the grid showing all staged values
            // (consistent with the still-pending edits we keep for retry).
            var conflictKeys: [PostgresPendingEditKey] = []
            for (key, edit) in edits {
                do {
                    let res = try await BridgeManager.shared.pgUpdateCell(
                        connectionId: connectionId,
                        sessionId: sessionId,
                        schema: target.schema,
                        table: target.table,
                        column: edit.columnName,
                        columnType: edit.columnType,
                        newValue: edit.newValue,
                        rowId: edit.rowId
                    )
                    if res.rowsAffected == 0 {
                        conflictKeys.append(key)  // ctid moved/deleted — skip
                    } else {
                        succeeded += 1
                    }
                } catch {
                    // All-or-nothing: roll back so nothing is half-applied. The
                    // staged edits (and their grid values) are kept untouched so
                    // the user can fix the offending value and retry.
                    if ownTransaction {
                        try? await BridgeManager.shared.pgRollback(connectionId: connectionId, sessionId: sessionId)
                    } else {
                        // The user's explicit transaction is now aborted.
                        storeRef.setTransactionState(.failed, forTab: tabId)
                    }
                    presentBatchAlert(
                        title: "Apply rolled back",
                        message: "No changes were applied; your staged edits were kept.\n\n\(Self.batchMessage(for: error))"
                    )
                    return
                }
            }
            if ownTransaction {
                do {
                    try await BridgeManager.shared.pgCommit(connectionId: connectionId, sessionId: sessionId)
                } catch {
                    presentBatchAlert(
                        title: "Commit failed",
                        message: "The outcome is uncertain — re-run the query to check, then retry if needed.\n\n\(Self.batchMessage(for: error))"
                    )
                    return
                }
            }
            // Committed. Revert the cells whose rows had moved/been deleted
            // (their edits didn't apply), then clear the staged edits.
            for key in conflictKeys {
                if let edit = pending[key] {
                    storeRef.setCellValue(
                        edit.originalValue,
                        rowIndex: key.rowIndex,
                        columnIndex: key.columnIndex,
                        forTab: tabId
                    )
                }
            }
            storeRef.clearPendingEdits(forTab: tabId)
            if !conflictKeys.isEmpty {
                presentBatchAlert(
                    title: "Applied \(succeeded), skipped \(conflictKeys.count)",
                    message: "Some rows had moved or been deleted by another session; their pending edits were reverted."
                )
            }
        }
    }

    private func presentBatchAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private static func batchMessage(for error: Error) -> String {
        (error as? PostgresBridgeError)?.errorDescription ?? error.localizedDescription
    }

    /// Throw away all staged edits, restoring original values.
    private func discardPendingEdits(tab: PostgresQueryTab) {
        let pending = tab.pendingEdits
        guard !pending.isEmpty else { return }
        for (key, edit) in pending {
            store.setCellValue(
                edit.originalValue,
                rowIndex: key.rowIndex,
                columnIndex: key.columnIndex,
                forTab: tab.id
            )
        }
        store.clearPendingEdits(forTab: tab.id)
    }

    @ViewBuilder
    private func loadMoreFooter(for tab: PostgresQueryTab) -> some View {
        let atCap = tab.fetchedRowCount >= store.maxAccumulatedRows
        HStack(spacing: 8) {
            if tab.isLoadingMore {
                ProgressView().controlSize(.small)
                Text("Fetching next \(store.pageSize) rows…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if atCap {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Row limit reached. Refine your SQL to load more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    loadMore(tab: tab)
                } label: {
                    Label("Load more", systemImage: "arrow.down.circle")
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .help("Fetch the next page (⇧⌘J)")
                Text("\(tab.fetchedRowCount) rows so far")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.7))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(NSColor.separatorColor))
                .frame(height: 1)
        }
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

    private func run(tab: PostgresQueryTab) {
        guard let connectionId else {
            store.setExecState(
                .failed(message: "Not connected.", elapsed: 0),
                forTab: tab.id
            )
            return
        }
        let trimmed = tab.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

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
                storeRef.setResult(result, forTab: tabId)
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

    // MARK: - Transaction control

    private func beginTransaction(tab: PostgresQueryTab) {
        guard let connectionId else { return }
        let sessionId = tab.id.uuidString
        let tabId = tab.id
        Task { @MainActor in
            do {
                try await BridgeManager.shared.pgBegin(connectionId: connectionId, sessionId: sessionId)
                store.setTransactionState(.open, forTab: tabId)
            } catch {
                logger.error("BEGIN failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func commitTransaction(tab: PostgresQueryTab) {
        guard let connectionId else { return }
        let sessionId = tab.id.uuidString
        let tabId = tab.id
        Task { @MainActor in
            do {
                try await BridgeManager.shared.pgCommit(connectionId: connectionId, sessionId: sessionId)
                store.setTransactionState(.none, forTab: tabId)
            } catch {
                logger.error("COMMIT failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func rollbackTransaction(tab: PostgresQueryTab) {
        guard let connectionId else { return }
        let sessionId = tab.id.uuidString
        let tabId = tab.id
        Task { @MainActor in
            do {
                try await BridgeManager.shared.pgRollback(connectionId: connectionId, sessionId: sessionId)
                store.setTransactionState(.none, forTab: tabId)
            } catch {
                // Rollback is the user's escape hatch — never leave the banner
                // stuck. A failure here is almost always a dropped connection,
                // which itself ends the server-side transaction, so clear it.
                logger.error("ROLLBACK failed: \(error.localizedDescription, privacy: .public)")
                store.setTransactionState(.none, forTab: tabId)
            }
        }
    }

    // MARK: - INSERT row

    /// Build the sheet's input shape from the tab's current result
    /// and present it. Visible columns drive both the form rows and
    /// the RETURNING list (so the new row matches the grid shape).
    /// Also kicks off a background `describe_columns` lookup so
    /// the form can pre-set toggles based on schema metadata once
    /// it lands.
    private func presentInsertSheet(tab: PostgresQueryTab) {
        guard let target = tab.editTarget,
              let result = tab.lastResult,
              let connectionId
        else { return }
        let visibleColumns = result.columns.filter { !$0.name.hasPrefix("__pg_") }
        var returnNames = result.columns.map(\.name)
        if !returnNames.contains(POSTGRES_ROWID_COLUMN) {
            returnNames.append(POSTGRES_ROWID_COLUMN)
        }
        // Show the sheet immediately so the user doesn't wait for
        // metadata. The metadata fetch updates the context once it
        // resolves; the sheet's `.onAppear` primes from the
        // (initially nil) metadata, so we re-prime when it lands.
        let ctx = InsertSheetContext(
            tab: tab,
            target: target,
            columns: visibleColumns,
            returnColumnNames: returnNames,
            columnDetails: nil
        )
        insertSheet = ctx
        let ctxId = ctx.id
        Task { @MainActor in
            do {
                let details = try await BridgeManager.shared.pgDescribeColumns(
                    connectionId: connectionId,
                    schema: target.schema,
                    table: target.table
                )
                // Only update if the user hasn't switched to a
                // different sheet in the meantime.
                if insertSheet?.id == ctxId {
                    insertSheet?.columnDetails = details
                }
            } catch {
                // Non-fatal — the sheet falls back to the
                // metadata-less behavior. Log for diagnostics.
                logger.warning("describe_columns failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Build the FFI input list from the sheet's filled-in forms
    /// (skipping `useDefault` columns), call the bridge, and on
    /// success append the new row to the in-memory result.
    private func runInsertRow(
        tab: PostgresQueryTab,
        forms: [PostgresInsertColumnForm],
        returnNames: [String],
        complete: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let connectionId, let target = tab.editTarget else {
            complete(.failure(NSError(
                domain: "mc-ssh",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Not connected."]
            )))
            return
        }
        // Walk the forms; columns with `useDefault = true` are
        // omitted entirely so the server provides the default.
        var inputs: [FfiPgInsertColumn] = []
        for form in forms {
            if form.useDefault { continue }
            inputs.append(FfiPgInsertColumn(
                name: form.columnName,
                typeName: form.typeName,
                value: form.useNull ? nil : form.textValue
            ))
        }

        let sessionId = tab.id.uuidString
        let storeRef = store
        let tabId = tab.id
        Task { @MainActor in
            do {
                let inserted = try await BridgeManager.shared.pgInsertRow(
                    connectionId: connectionId,
                    sessionId: sessionId,
                    schema: target.schema,
                    table: target.table,
                    inputs: inputs,
                    returnColumns: returnNames
                )
                // Reorder cells to match the existing result's
                // column order. The RETURNING shape was driven by
                // `returnNames` which we constructed from
                // `result.columns.map(\.name)` — so the ordering
                // already matches. Just append.
                let newRow = FfiPgRow(cells: inserted.cells)
                storeRef.appendRow(newRow, forTab: tabId)
                complete(.success(()))
            } catch let err as PostgresBridgeError {
                logger.error("insert_row failed: \(err.localizedDescription, privacy: .public)")
                complete(.failure(NSError(
                    domain: "mc-ssh",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: err.errorDescription ?? "Insert failed."]
                )))
            } catch {
                complete(.failure(error))
            }
        }
    }

    // MARK: - Full export (cursor drain)

    enum FullExportFormat {
        case csv
        case jsonl
        case parquet
    }

    /// Drains the tab's full result to a user-chosen file. Writes
    /// the currently-loaded rows first, then loops `pgFetchPage` to
    /// stream the rest of the cursor — bounded only by the disk and
    /// the user's patience (no in-memory accumulation past one page).
    /// Cancellable via the progress sheet.
    ///
    /// Format-specific bits (header line, per-row encoding) live in
    /// `format`; the streaming + cancel + cursor-drain orchestration
    /// is shared.
    private func runFullExport(tab: PostgresQueryTab, format: FullExportFormat) {
        guard let result = tab.lastResult, let connectionId else {
            exportSummary = ExportSummary(
                title: "Nothing to export",
                message: "Run a query that returns rows, then try again."
            )
            return
        }

        let panel = NSSavePanel()
        switch format {
        case .csv:
            panel.title = "Export full result as CSV"
            panel.nameFieldStringValue = "results.csv"
            panel.allowedContentTypes = [.commaSeparatedText]
        case .jsonl:
            panel.title = "Export full result as JSONL"
            panel.nameFieldStringValue = "results.jsonl"
            // No standard UTType for JSONL; .json is close enough.
            panel.allowedContentTypes = [.json]
        case .parquet:
            panel.title = "Export full result as Parquet"
            panel.nameFieldStringValue = "results.parquet"
            // No system UTType for Parquet; allow any extension.
            panel.allowedContentTypes = [.data]
        }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Parquet has a different IO model — opaque writer handle,
        // batch append, close-flushes-footer — so it gets its own
        // path. CSV/JSONL share the file-handle line writer below.
        if case .parquet = format {
            runParquetExport(
                tab: tab,
                result: result,
                url: url,
                connectionId: connectionId
            )
            return
        }

        // Plan: visible columns in display order, mapped back to
        // result-column indices (so hidden `__pg_*` columns are
        // skipped consistently).
        let visibleColumns: [(name: String, idx: Int)] = result.columns
            .enumerated()
            .compactMap { (idx, col) -> (String, Int)? in
                if col.name.hasPrefix("__pg_") { return nil }
                return (col.name, idx)
            }
        guard !visibleColumns.isEmpty else {
            exportSummary = ExportSummary(
                title: "Nothing to export",
                message: "No visible columns in the current result."
            )
            return
        }

        // Fresh cancellation token per export. Replace the @State
        // value so a previous export's lingering token can't
        // accidentally pre-cancel this one.
        let token = ExportCancelToken()
        exportCancel = token
        exportProgress = PostgresExportProgressState(path: url, rowsWritten: 0)

        let sessionId = tab.id.uuidString
        let pageSize = store.pageSize
        let initialCursorId = result.cursorId
        let storeRef = store
        let tabId = tab.id
        let preloadedRows = result.rows

        Task { @MainActor in
            var rowsWritten = 0
            // Open / truncate the file. Couldn't do this before the
            // Task because FileHandle init wants the file to exist.
            FileManager.default.createFile(atPath: url.path, contents: nil)
            guard let writer = try? FileHandle(forWritingTo: url) else {
                exportProgress = nil
                exportSummary = ExportSummary(
                    title: "Couldn't open file",
                    message: "Failed to create \(url.path) for writing."
                )
                return
            }
            defer { try? writer.close() }

            do {
                // Header. CSV gets one; JSONL doesn't (each row is
                // self-describing because keys ride alongside).
                if case .csv = format {
                    let header = visibleColumns
                        .map { csvEscape($0.name) }
                        .joined(separator: ",") + "\n"
                    try writer.write(contentsOf: Data(header.utf8))
                }

                // Currently-loaded rows.
                for row in preloadedRows {
                    if token.isCancelled { throw ExportCancelled() }
                    let line = renderRow(row, visibleColumns: visibleColumns, format: format)
                    try writer.write(contentsOf: Data(line.utf8))
                    rowsWritten += 1
                    if rowsWritten % 200 == 0 {
                        exportProgress?.rowsWritten = rowsWritten
                        await Task.yield()
                    }
                }

                // Cursor drain.
                var cursorId = initialCursorId
                while let cid = cursorId {
                    if token.isCancelled { throw ExportCancelled() }
                    let page: FfiPgPageResult
                    do {
                        page = try await BridgeManager.shared.pgFetchPage(
                            connectionId: connectionId,
                            sessionId: sessionId,
                            cursorId: cid,
                            count: pageSize
                        )
                    } catch let err as PostgresBridgeError where err.isCursorExpired {
                        // Another tab superseded the cursor mid-drain.
                        // Surface what we got; don't treat as failure.
                        throw ExportCursorSuperseded(rowsWritten: rowsWritten)
                    }
                    for row in page.rows {
                        if token.isCancelled { throw ExportCancelled() }
                        let line = renderRow(row, visibleColumns: visibleColumns, format: format)
                        try writer.write(contentsOf: Data(line.utf8))
                        rowsWritten += 1
                    }
                    exportProgress?.rowsWritten = rowsWritten
                    if !page.hasMore { break }
                    await Task.yield()
                }

                // Close the cursor server-side; mirror that in the
                // tab so "Load more" hides.
                if let cid = initialCursorId {
                    _ = await BridgeManager.shared.pgCloseQuery(
                        connectionId: connectionId,
                        sessionId: sessionId,
                        cursorId: cid
                    )
                    storeRef.clearCursor(forTab: tabId)
                }

                exportProgress = nil
                exportSummary = ExportSummary(
                    title: "Export complete",
                    message: "Wrote \(rowsWritten) row\(rowsWritten == 1 ? "" : "s") to \(url.path)."
                )
            } catch is ExportCancelled {
                exportProgress = nil
                exportSummary = ExportSummary(
                    title: "Export cancelled",
                    message: "Stopped after \(rowsWritten) row\(rowsWritten == 1 ? "" : "s"). The partial file is at \(url.path)."
                )
            } catch let err as ExportCursorSuperseded {
                exportProgress = nil
                exportSummary = ExportSummary(
                    title: "Cursor superseded",
                    message: "Another query took over the connection mid-export. \(err.rowsWritten) row\(err.rowsWritten == 1 ? "" : "s") written."
                )
                storeRef.clearCursor(forTab: tabId)
            } catch let err as PostgresBridgeError {
                exportProgress = nil
                exportSummary = ExportSummary(
                    title: "Export failed",
                    message: err.errorDescription ?? "Unknown error after \(rowsWritten) row\(rowsWritten == 1 ? "" : "s")."
                )
            } catch {
                exportProgress = nil
                exportSummary = ExportSummary(
                    title: "Export failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    /// Parquet-specific export. Different from CSV/JSONL because
    /// the writer is stateful in Rust (the FFI returns an opaque
    /// id) and rows are appended in batches rather than line by
    /// line. Uses the same progress sheet + cursor-drain shape so
    /// the UX is consistent.
    private func runParquetExport(
        tab: PostgresQueryTab,
        result: FfiPgExecutionResult,
        url: URL,
        connectionId: String
    ) {
        let visibleColumns: [(name: String, idx: Int)] = result.columns
            .enumerated()
            .compactMap { (idx, col) -> (String, Int)? in
                if col.name.hasPrefix("__pg_") { return nil }
                return (col.name, idx)
            }
        guard !visibleColumns.isEmpty else {
            exportSummary = ExportSummary(
                title: "Nothing to export",
                message: "No visible columns in the current result."
            )
            return
        }

        let token = ExportCancelToken()
        exportCancel = token
        exportProgress = PostgresExportProgressState(path: url, rowsWritten: 0)

        let sessionId = tab.id.uuidString
        let pageSize = store.pageSize
        let initialCursorId = result.cursorId
        let storeRef = store
        let tabId = tab.id
        let preloadedRows = result.rows
        let columnNames = visibleColumns.map(\.name)
        let columnIndices = visibleColumns.map(\.idx)

        Task { @MainActor in
            var rowsWritten = 0
            let writerId: UInt64
            do {
                writerId = try await BridgeManager.shared.pgParquetOpen(
                    path: url.path,
                    columns: columnNames
                )
            } catch {
                exportProgress = nil
                exportSummary = ExportSummary(
                    title: "Couldn't open Parquet file",
                    message: error.localizedDescription
                )
                return
            }

            // Helper: project a row's cells to the visible-columns
            // subset, in display order.
            func projected(_ row: FfiPgRow) -> FfiPgRow {
                let cells = columnIndices.map { idx -> String? in
                    idx < row.cells.count ? row.cells[idx] : nil
                }
                return FfiPgRow(cells: cells)
            }

            // Append in chunks so cancel checks fire between batches.
            // 500-row batches keep the writer-side memory bounded.
            let batchSize = 500

            do {
                // Preloaded rows.
                var i = 0
                while i < preloadedRows.count {
                    if token.isCancelled { throw ExportCancelled() }
                    let end = min(i + batchSize, preloadedRows.count)
                    let batch = preloadedRows[i..<end].map(projected)
                    try await BridgeManager.shared.pgParquetAppend(
                        writerId: writerId, rows: batch
                    )
                    rowsWritten += batch.count
                    exportProgress?.rowsWritten = rowsWritten
                    i = end
                    await Task.yield()
                }

                // Cursor drain.
                var cursorId = initialCursorId
                while let cid = cursorId {
                    if token.isCancelled { throw ExportCancelled() }
                    let page: FfiPgPageResult
                    do {
                        page = try await BridgeManager.shared.pgFetchPage(
                            connectionId: connectionId,
                            sessionId: sessionId,
                            cursorId: cid,
                            count: pageSize
                        )
                    } catch let err as PostgresBridgeError where err.isCursorExpired {
                        throw ExportCursorSuperseded(rowsWritten: rowsWritten)
                    }
                    let batch = page.rows.map(projected)
                    if !batch.isEmpty {
                        try await BridgeManager.shared.pgParquetAppend(
                            writerId: writerId, rows: batch
                        )
                        rowsWritten += batch.count
                        exportProgress?.rowsWritten = rowsWritten
                    }
                    if !page.hasMore { break }
                    await Task.yield()
                }

                // Close + clear cursor.
                try await BridgeManager.shared.pgParquetClose(writerId: writerId)
                if let cid = initialCursorId {
                    _ = await BridgeManager.shared.pgCloseQuery(
                        connectionId: connectionId,
                        sessionId: sessionId,
                        cursorId: cid
                    )
                    storeRef.clearCursor(forTab: tabId)
                }
                exportProgress = nil
                exportSummary = ExportSummary(
                    title: "Export complete",
                    message: "Wrote \(rowsWritten) row\(rowsWritten == 1 ? "" : "s") to \(url.path)."
                )
            } catch is ExportCancelled {
                _ = try? await BridgeManager.shared.pgParquetClose(writerId: writerId)
                exportProgress = nil
                exportSummary = ExportSummary(
                    title: "Export cancelled",
                    message: "Stopped after \(rowsWritten) row\(rowsWritten == 1 ? "" : "s"). Partial Parquet file at \(url.path)."
                )
            } catch let err as ExportCursorSuperseded {
                _ = try? await BridgeManager.shared.pgParquetClose(writerId: writerId)
                exportProgress = nil
                exportSummary = ExportSummary(
                    title: "Cursor superseded",
                    message: "Another query took over the connection mid-export. \(err.rowsWritten) row(s) written."
                )
                storeRef.clearCursor(forTab: tabId)
            } catch let err as PostgresBridgeError {
                _ = try? await BridgeManager.shared.pgParquetClose(writerId: writerId)
                exportProgress = nil
                exportSummary = ExportSummary(
                    title: "Export failed",
                    message: err.errorDescription ?? "Unknown error after \(rowsWritten) row(s)."
                )
            } catch {
                _ = try? await BridgeManager.shared.pgParquetClose(writerId: writerId)
                exportProgress = nil
                exportSummary = ExportSummary(
                    title: "Export failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    /// Format-aware row rendering for the streaming export.
    private func renderRow(
        _ row: FfiPgRow,
        visibleColumns: [(name: String, idx: Int)],
        format: FullExportFormat
    ) -> String {
        switch format {
        case .parquet:
            // Parquet doesn't go through the line-renderer; this
            // branch shouldn't run because `runFullExport` routes
            // Parquet to its own pipeline. Returning empty avoids
            // a compiler exhaustiveness gap without being a real
            // code path.
            return ""
        case .csv:
            let parts = visibleColumns.map { plan -> String in
                guard plan.idx < row.cells.count else { return "" }
                // NULL → empty field (CSV convention).
                return row.cells[plan.idx].map(csvEscape) ?? ""
            }
            return parts.joined(separator: ",") + "\n"
        case .jsonl:
            // One JSON object per line, key-ordered by visible
            // column. Values: string for text representations, null
            // for SQL NULL. We don't try to coerce text back to
            // typed JSON values (number / bool) because that would
            // need per-column type inspection plus careful parsing
            // — a meaningful slice on its own. Strings round-trip
            // every type the server can serialize.
            var obj: [String: Any?] = [:]
            for plan in visibleColumns {
                guard plan.idx < row.cells.count else { continue }
                if let value = row.cells[plan.idx] {
                    obj[plan.name] = value
                } else {
                    obj[plan.name] = nil
                }
            }
            // JSONSerialization handles nil → null when wrapped
            // through NSNull; transform once.
            let nsObj = obj.mapValues { $0 as Any? ?? NSNull() }
            do {
                let data = try JSONSerialization.data(
                    withJSONObject: nsObj,
                    options: [.sortedKeys]
                )
                if var line = String(data: data, encoding: .utf8) {
                    line.append("\n")
                    return line
                }
                return "{}\n"
            } catch {
                return "{}\n"
            }
        }
    }

    /// RFC 4180 quoting. Identical to the coordinator's helper but
    /// duplicated here so the export path stays self-contained.
    private func csvEscape(_ s: String) -> String {
        let needs = s.contains(",") || s.contains("\"")
            || s.contains("\n") || s.contains("\r")
        if !needs { return s }
        return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Fetch the next page from the tab's active cursor and append it
    /// to the accumulated rows. No-op if there's no cursor or a fetch
    /// is already in flight. `cursorExpired` is treated as a soft
    /// failure: the rows already shown remain, the cursor handle
    /// drops, and the user gets a one-line explanation.
    private func loadMore(tab: PostgresQueryTab) {
        guard let connectionId,
              let cursorId = tab.lastResult?.cursorId,
              !tab.isLoadingMore,
              tab.fetchedRowCount < store.maxAccumulatedRows
        else { return }

        store.setLoadingMore(true, forTab: tab.id)
        let storeRef = store
        let tabId = tab.id
        let sessionId = tab.id.uuidString
        let pageSize = store.pageSize
        Task { @MainActor in
            do {
                let page = try await BridgeManager.shared.pgFetchPage(
                    connectionId: connectionId,
                    sessionId: sessionId,
                    cursorId: cursorId,
                    count: pageSize
                )
                storeRef.appendPage(page, forTab: tabId)
            } catch let err as PostgresBridgeError where err.isCursorExpired {
                storeRef.setPaginationError(
                    "Result was superseded. Re-run to fetch fresh data.",
                    forTab: tabId
                )
            } catch let err as PostgresBridgeError {
                storeRef.setPaginationError(
                    err.errorDescription ?? "Failed to load more rows.",
                    forTab: tabId
                )
                logger.error("loadMore failed: \(err.localizedDescription, privacy: .public)")
            } catch {
                storeRef.setPaginationError(error.localizedDescription, forTab: tabId)
            }
        }
    }

    private func cancel(tab: PostgresQueryTab) {
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

    // MARK: - Formatting

    private func isRunning(_ tab: PostgresQueryTab) -> Bool {
        if case .running = tab.execState { return true }
        return false
    }

    private func rowSummary(_ r: FfiPgExecutionResult) -> String {
        let visibleColumns = r.columns.filter { !$0.name.hasPrefix("__pg_") }
        if !visibleColumns.isEmpty {
            let n = r.rows.count
            return n == 1 ? "1 row" : "\(n) rows"
        }
        return r.rowsAffected.map { "\($0) rows affected" } ?? ""
    }

    private func elapsedDescription(for tab: PostgresQueryTab) -> String? {
        switch tab.execState {
        case .idle:
            return nil
        case .running(let startedAt):
            // Coarse text — the live ticker would require a Timer.
            // The status badge already animates so the user knows
            // something is happening; precise timing belongs in the
            // completed state.
            return "started \(formatTime(startedAt))"
        case .completed(let elapsed, _),
             .failed(_, let elapsed),
             .cancelled(let elapsed):
            return formatElapsed(elapsed)
        }
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        if seconds < 1.0 {
            return String(format: "%.0f ms", seconds * 1_000)
        }
        if seconds < 60 {
            return String(format: "%.2f s", seconds)
        }
        return String(format: "%.0f s", seconds)
    }

    private func formatTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f.string(from: d)
    }
}

// =============================================================================
// Export helpers — kept inside this file because they only exist to
// glue `runFullExport` to its progress sheet and result alert.
// =============================================================================

/// Reference-typed cancel flag observed by the export task between
/// page fetches. Reference type so `@State` value-copy semantics
/// don't silently drop signals when the parent view re-renders.
final class ExportCancelToken {
    private(set) var isCancelled: Bool = false
    func cancel() { isCancelled = true }
}

/// Sentinel thrown to break out of the export loop on user cancel.
private struct ExportCancelled: Error {}

/// Sentinel thrown when another session supersedes the cursor
/// mid-drain. Carries the row count so the alert can include it.
private struct ExportCursorSuperseded: Error {
    let rowsWritten: Int
}

/// One-shot summary alert presented after an export ends. Identifiable
/// so SwiftUI's `.alert(presenting:)` modifier can drive it.
struct ExportSummary: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Context passed into the insert-row sheet. Identifiable so
/// `.sheet(item:)` can drive presentation. `columnDetails` is
/// initially nil and filled in asynchronously by a `describe_columns`
/// lookup; the sheet falls back to the metadata-less behavior while
/// the lookup is in flight.
struct InsertSheetContext: Identifiable {
    let id = UUID()
    let tab: PostgresQueryTab
    let target: PostgresEditTarget
    let columns: [FfiPgColumn]
    let returnColumnNames: [String]
    var columnDetails: [FfiPgColumnDetail]?
}

// MARK: - JetBrains Mimic Results Grid Toolbar & Transposed View Extensions
extension PostgresQueryTabView {
    @ViewBuilder
    private func resultsToolbar(for tab: PostgresQueryTab, result: FfiPgExecutionResult) -> some View {
        HStack(spacing: 12) {
            // Batch edit mode toggle
            Button {
                store.setBatchMode(!tab.batchMode, forTab: tab.id)
            } label: {
                Label(tab.batchMode ? "Batch Mode: ON" : "Batch Mode: OFF", systemImage: "square.stack.3d.up")
                    .foregroundColor(tab.batchMode ? .cyan : .secondary)
            }
            .buttonStyle(.plain)
            .help("Toggle Batch Edit Mode. When enabled, edits are staged in-memory before committing.")

            Divider().frame(height: 14)

            // Apply staged edits — atomic (one transaction).
            Button {
                commitPendingEdits(tab: tab)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                    Text("Apply \(tab.pendingEdits.isEmpty ? "" : "(\(tab.pendingEdits.count))")")
                }
                .foregroundColor(tab.pendingEdits.isEmpty ? .secondary : .green)
            }
            .buttonStyle(.plain)
            .disabled(tab.pendingEdits.isEmpty)
            .help("Apply all staged edits atomically — they commit together or not at all.")

            // Discard staged edits (in-memory; nothing was sent to the server).
            Button {
                discardPendingEdits(tab: tab)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Discard")
                }
                .foregroundColor(tab.pendingEdits.isEmpty ? .secondary : .red)
            }
            .buttonStyle(.plain)
            .disabled(tab.pendingEdits.isEmpty)
            .help("Discard all staged edits.")

            Divider().frame(height: 14)

            // Transposed View Toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isTransposed.toggle()
                }
            } label: {
                Label("Transposed", systemImage: "rectangle.split.2x1")
                    .foregroundColor(isTransposed ? .blue : .secondary)
            }
            .buttonStyle(.plain)
            .help("Toggle Transposed View (flips wide rows into a vertical column-value details panel)")

            if aiAvailable {
                Divider().frame(height: 14)
                Button {
                    aiExplainStore.explain(
                        sql: tab.sql,
                        resultSample: PgAIContext.summarize(result),
                        title: "Explain query & results",
                        connectionId: connectionId ?? "",
                        defaultSchema: "public"
                    )
                } label: {
                    Label("Explain", systemImage: "sparkles")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(connectionId == nil
                          || tab.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Explain this query and its results with on-device AI")
            }

            Spacer()

            // Quick filter over the loaded rows (client-side substring match).
            HStack(spacing: 3) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $resultFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                if !resultFilter.isEmpty {
                    Button {
                        resultFilter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter")
                }
            }
            .help("Filter the loaded rows (case-insensitive, across columns). Filtering and column sorting act on fetched rows, not the full server result; clear both to edit cells.")

            // Export Menu
            Menu {
                Button("CSV...") {
                    runFullExport(tab: tab, format: .csv)
                }
                Button("JSONL...") {
                    runFullExport(tab: tab, format: .jsonl)
                }
                Button("Parquet...") {
                    runFullExport(tab: tab, format: .parquet)
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 90)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
        .controlSize(.small)
    }

    @ViewBuilder
    private func transposedView(result: FfiPgExecutionResult, tab: PostgresQueryTab) -> some View {
        let visibleColumns = result.columns.enumerated().filter { !$0.element.name.hasPrefix("__pg_") }
        let totalRows = result.rows.count

        VStack(spacing: 0) {
            // Record Selector / Navigation bar
            HStack {
                Button {
                    if selectedTransposedRowIndex > 0 {
                        selectedTransposedRowIndex -= 1
                    }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(selectedTransposedRowIndex <= 0)

                Text("Record \(selectedTransposedRowIndex + 1) of \(totalRows)")
                    .font(.headline)
                    .padding(.horizontal, 8)

                Button {
                    if selectedTransposedRowIndex < totalRows - 1 {
                        selectedTransposedRowIndex += 1
                    }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(selectedTransposedRowIndex >= totalRows - 1)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()

            if totalRows == 0 {
                VStack(spacing: 8) {
                    Image(systemName: "table")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No records to display")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let rowIndex = min(selectedTransposedRowIndex, totalRows - 1)
                let row = result.rows[rowIndex]
                let canEdit = tab.editTarget != nil
                    && result.columns.contains(where: { $0.name == POSTGRES_ROWID_COLUMN })
                let rowIdVal = result.columns.firstIndex(where: { $0.name == POSTGRES_ROWID_COLUMN })
                    .flatMap { colIdx -> String? in
                        guard colIdx < row.cells.count else { return nil }
                        return row.cells[colIdx]
                    }

                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(visibleColumns, id: \.offset) { colIdx, column in
                            let cellKey = PostgresPendingEditKey(rowIndex: rowIndex, columnIndex: colIdx)
                            let isStaged = tab.pendingEdits[cellKey] != nil
                            let originalValue = row.cells[colIdx]
                            let currentValue = isStaged ? tab.pendingEdits[cellKey]?.newValue : originalValue

                            TransposedRowField(
                                columnName: column.name,
                                columnType: column.typeName,
                                originalValue: originalValue,
                                currentValue: currentValue,
                                isStaged: isStaged,
                                editable: canEdit,
                                onSave: { newValue in
                                    guard canEdit, let rowId = rowIdVal else { return }
                                    let edit = PostgresCellEdit(
                                        rowIndex: rowIndex,
                                        columnIndex: colIdx,
                                        columnName: column.name,
                                        columnType: column.typeName,
                                        newValue: newValue,
                                        rowId: rowId
                                    )
                                    runCellUpdate(edit: edit, tab: tab) { outcome in
                                        // Cell updates will automatically be reflected in the tab's pending edits & cell value!
                                    }
                                }
                            )
                        }
                    }
                    .padding(16)
                }
                .background(Color(NSColor.textBackgroundColor))
            }
        }
    }
}

struct TransposedRowField: View {
    let columnName: String
    let columnType: String
    let originalValue: String?
    let currentValue: String?
    let isStaged: Bool
    let editable: Bool
    let onSave: (String?) -> Void

    @State private var isEditing: Bool = false
    @State private var editValue: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Column Name & Type
            VStack(alignment: .leading, spacing: 2) {
                Text(columnName)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
                Text(columnType)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(width: 180, alignment: .leading)
            .padding(.vertical, 4)

            // Cell Value / Editor
            Group {
                if isEditing {
                    HStack(spacing: 8) {
                        TextField("", text: $editValue, onCommit: {
                            isEditing = false
                            if editValue == "NULL" {
                                onSave(nil)
                            } else {
                                onSave(editValue)
                            }
                        })
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(6)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.blue, lineWidth: 1)
                        )

                        Button("Set NULL") {
                            isEditing = false
                            onSave(nil)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)

                        Button("Cancel") {
                            isEditing = false
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                } else {
                    HStack {
                        if let currentValue {
                            Text(currentValue)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(isStaged ? .blue : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    if editable {
                                        editValue = currentValue
                                        isEditing = true
                                    }
                                }
                        } else {
                            Text("NULL")
                                .font(.system(.body, design: .monospaced).italic())
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    if editable {
                                        editValue = ""
                                        isEditing = true
                                    }
                                }
                        }
                        
                        if editable {
                            Image(systemName: "pencil")
                                .foregroundColor(.secondary.opacity(0.5))
                                .font(.caption)
                                .padding(.trailing, 4)
                        }
                    }
                    .padding(6)
                    .background(
                        isStaged ? Color.blue.opacity(0.08) :
                        (currentValue == nil ? Color.orange.opacity(0.05) : Color.clear)
                    )
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(
                                isStaged ? Color.blue.opacity(0.3) :
                                (currentValue == nil ? Color.orange.opacity(0.2) : Color.gray.opacity(0.15)),
                                lineWidth: 1
                            )
                    )
                }
            }
        }
        .padding(.vertical, 4)
        .overlay(
            Rectangle()
                .fill(Color(NSColor.gridColor).opacity(0.5))
                .frame(height: 1),
            alignment: .bottom
        )
    }
}
