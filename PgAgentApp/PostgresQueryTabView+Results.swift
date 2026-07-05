import OSLog
import PgAgentMacOS
import SwiftUI

// =============================================================================
// PostgresQueryTabView results area — the results grid host, its
// toolbar, pagination footers, and FK-navigation plumbing.
//
// Extracted from PostgresQueryTabView.swift; behavior-preserving.
// =============================================================================

extension PostgresQueryTabView {
    @ViewBuilder
    func resultsArea(for tab: PostgresQueryTab) -> some View {
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
                    if let browse = tab.browse {
                        browsePagerFooter(for: tab, browse: browse)
                    } else if tab.hasMore || tab.isLoadingMore {
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
        // Read-only profiles additionally hide every write affordance
        // (cell edit, insert, delete). The bridge would refuse the DML
        // anyway — this just keeps the UI honest about it.
        let canEdit = tab.editTarget != nil
            && result.columns.contains(where: { $0.name == POSTGRES_ROWID_COLUMN })
            && !(profile?.isReadOnly ?? false)
        // Full export is offered when there's any visible result —
        // even tabs without a cursor benefit (writes the in-memory
        // rows + skips the drain step). The menu validates by
        // checking the host wired a callback at all.
        PostgresResultsTable(
            result: result,
            // Cheap change detection: the store bumps the tab's
            // revision whenever the rows change, so the table can
            // skip the 50k-row deep compare on unrelated updates.
            revision: PostgresResultsRevision(tabId: tab.id, value: tab.resultsRevision),
            filterText: resultFilter,
            // Continuous row numbering across browse pages; generic
            // SQL tabs number from 1.
            rowNumberBase: tab.browse.map { $0.page * $0.pageSize } ?? 0,
            serverSort: tab.browse.flatMap { browse in
                browse.sortColumn.map {
                    PostgresServerSort(columnName: $0, ascending: browse.sortAscending)
                }
            },
            // Browse tabs sort server-side (ORDER BY re-run); generic
            // SQL tabs keep the local fetched-rows sort.
            onHeaderSort: tab.browse != nil
                ? { column in cycleBrowseSort(column: column, tab: tab) }
                : nil,
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
            },
            // FK navigation lights up once the metadata load (kicked
            // off below) lands. Generic SQL tabs have no source
            // table, so no FK map and no menu items.
            foreignKeys: tab.editTarget.flatMap {
                foreignKeysBySourceTable["\($0.schema).\($0.table)"]
            },
            onNavigateFK: { navigation in
                openFKNavigationTab(navigation)
            }
        )
        .task(id: tab.editTarget.map { "\($0.schema).\($0.table)" }) {
            await loadForeignKeysIfNeeded(target: tab.editTarget)
        }
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

    /// Load FK constraints for the tab's source table into local
    /// state, via the schema store's cache. No-op for generic SQL
    /// tabs and for tables already loaded this view's lifetime.
    private func loadForeignKeysIfNeeded(target: PostgresEditTarget?) async {
        guard let target else { return }
        let key = "\(target.schema).\(target.table)"
        guard foreignKeysBySourceTable[key] == nil,
              let schemaStore = PostgresConnectionManager.shared.schemaStores[profileId],
              let database = profile?.database
        else { return }
        if let fks = await schemaStore.loadForeignKeys(
            database: database,
            schema: target.schema,
            table: target.table
        ) {
            foreignKeysBySourceTable[key] = fks
        }
    }

    /// Open the FK target as a filtered relation tab, through the
    /// same notification bus the sidebar uses. The generated WHERE
    /// (quoted identifiers, quoted literals — the untyped literal
    /// casts server-side to the column type) lands in the editor for
    /// review; the user runs it, like every generated tab.
    private func openFKNavigationTab(_ navigation: PostgresFKNavigation) {
        let whereClause = navigation.filters
            .map { "\(pgQuoteIdent($0.column)) = \(pgQuoteLiteral($0.value))" }
            .joined(separator: " AND ")
        NotificationCenter.default.post(
            name: .openPostgresObjectTab,
            object: nil,
            userInfo: [
                "profileId": profileId,
                "kind": "relation",
                "schema": navigation.schema,
                "name": navigation.table,
                "whereClause": whereClause,
            ]
        )
    }

    // MARK: - Footers

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

    /// Pager for browse tabs: first / previous / next page, with the
    /// current row range. Replaces the cursor-based "Load more"
    /// footer — each page is a fresh LIMIT/OFFSET SELECT, so the grid
    /// never accumulates unbounded rows.
    @ViewBuilder
    private func browsePagerFooter(for tab: PostgresQueryTab, browse: PostgresBrowseState) -> some View {
        let rowCount = tab.fetchedRowCount
        let first = browse.firstRowNumber
        HStack(spacing: 8) {
            Button {
                goToBrowsePage(0, tab: tab)
            } label: {
                Image(systemName: "chevron.left.2")
            }
            .disabled(browse.page == 0 || isRunning(tab))
            .help("First page")
            Button {
                goToBrowsePage(browse.page - 1, tab: tab)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(browse.page == 0 || isRunning(tab))
            .help("Previous page")
            Text(rowCount == 0
                 ? "Page \(browse.page + 1) · no rows"
                 : "Page \(browse.page + 1) · rows \(first)–\(first + rowCount - 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                goToBrowsePage(browse.page + 1, tab: tab)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!browse.hasNextPage || isRunning(tab))
            .help("Next page")
            if let sort = browse.sortColumn {
                Divider().frame(height: 12)
                Label("\(sort) \(browse.sortAscending ? "ascending" : "descending")",
                      systemImage: "arrow.up.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Sorted server-side — click the column header to cycle")
            }
            Spacer()
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.7))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(NSColor.separatorColor))
                .frame(height: 1)
        }
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
                guard !Task.isCancelled else { return }
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

    // MARK: - JetBrains Mimic Results Grid Toolbar

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
}
