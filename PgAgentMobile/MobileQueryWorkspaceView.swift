import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// MARK: - Query Workspace View
struct MobileQueryWorkspaceView: View {
    @ObservedObject var store: PostgresQueryTabsStore
    let connectionId: String?
    let profileId: String
    let schemaStore: PgSchemaStore?
    
    @Environment(MobileAppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var runTask: Task<Void, Never>?
    @State private var executionDuration: TimeInterval = 0
    @State private var editorController = MobileSQLEditorController()
    @State private var editorFocused = false
    @State private var completions: [SQLCompletionItem] = []
    @State private var aiAvailable = false
    @State private var showingAsk = false
    /// AI-written SQL that would change data, waiting for an explicit OK.
    @State private var pendingAIWrite: PendingAIWrite?
    /// Last (text, caret) completion ran for — selection and text changes
    /// both report, so each keystroke would otherwise compute twice.
    @State private var lastCompletionInput: CompletionInput?

    /// Collapsed editor (about four lines) once rows are on screen.
    @ScaledMetric(relativeTo: .callout) private var collapsedEditorHeight: CGFloat = 96
    @ScaledMetric(relativeTo: .callout) private var minimumEditorHeight: CGFloat = 160
    /// Room kept for the suggestion and status bars under the editor.
    private static let reservedBelowEditor: CGFloat = 120
    private static let smallestEditorHeight: CGFloat = 72
    /// Share of the workspace the editor takes while you write.
    private static let expandedEditorShare: CGFloat = 0.42
    private static let maxSuggestions = 12
    /// Schemas whose contents are loaded up front so completion knows the
    /// tables before anyone opens Browse.
    private static let primedSchemaLimit = 8

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
        VStack(spacing: 0) {
            if let envColor = environmentColor {
                Rectangle()
                    .fill(envColor)
                    .frame(height: 2)
            }

            // Tab Header Strip
            queryTabHeaderStrip
            
            Divider().background(MidnightColors.borderGray)
            
            if let activeId = store.activeTabId,
               let tab = store.tabs.first(where: { $0.id == activeId }) {
                
                switch tab.kind {
                case .properties(let node):
                    if let sStore = schemaStore {
                        MobilePropertyInspectorView(
                            node: node,
                            connectionId: connectionId,
                            schemaStore: sStore,
                            onClose: {
                                store.closeTab(id: tab.id)
                            }
                        )
                    } else {
                        Text("No schema store available")
                            .font(MidnightMobileDesign.FontToken.caption)
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                case .routine(let schema, let name, let signature):
                    MobileRoutineEditorView(
                        connectionId: connectionId,
                        profileId: profileId,
                        schema: schema,
                        name: name,
                        signature: signature
                    )
                default:
                    GeometryReader { proxy in
                        VStack(spacing: 0) {
                            sqlEditor(tab: tab, tabId: activeId)
                                .frame(height: editorHeight(available: proxy.size.height, tab: tab))

                            // While typing the bar keeps its height even when
                            // empty, so Run and the results don't jump.
                            if editorFocused {
                                MobileCompletionBar(items: completions) { item in
                                    editorController.insert(item)
                                }
                            }

                            Divider().background(MidnightColors.borderGray)

                            // Status + Run/Cancel bar (also carries the row
                            // count and timing, so the button never overlaps
                            // the SQL editor).
                            resultsStatusBar(tab: tab)

                            Divider().background(MidnightColors.borderGray)

                            resultsDisplayPane(tab: tab)
                        }
                    }
                }
            } else {
                emptyTabArea
            }
        }
        .background(MidnightColors.canvas)
        .onReceive(MobileShortcutRelay.shared.actions, perform: handleShortcut)
        .task(id: profileId) {
            aiAvailable = PgAIAvailabilityProbe.current().isAvailable
            await primeCompletionCatalog()
        }
        // Apple Intelligence can finish setting up while the app is open.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                aiAvailable = PgAIAvailabilityProbe.current().isAvailable
            }
        }
        .alert(
            "Run a statement that modifies data?",
            isPresented: Binding(
                get: { pendingAIWrite != nil },
                set: { if !$0 { pendingAIWrite = nil } }
            ),
            presenting: pendingAIWrite
        ) { pending in
            Button("Run", role: .destructive) {
                // The user takes ownership: drop the AI provenance so the
                // same statement isn't challenged again, then run it.
                store.mutate(id: pending.tabId) { $0.aiGeneratedSQL = nil }
                if let tab = store.tabs.first(where: { $0.id == pending.tabId }) {
                    executeSQL(tab: tab)
                }
                pendingAIWrite = nil
            }
            Button("Cancel", role: .cancel) { pendingAIWrite = nil }
        } message: { pending in
            Text("Ask wrote this statement and it changes data. Review it before running:\n\n\(String(pending.sql.prefix(400)))")
        }
        .sheet(isPresented: $showingAsk) {
            if let connectionId {
                MobileAskSQLView(
                    connectionId: connectionId,
                    defaultSchema: defaultSchema,
                    onUse: useGeneratedSQL
                )
            }
        }
    }

    // MARK: - Editor

    private func sqlEditor(tab: PostgresQueryTab, tabId: UUID) -> some View {
        MobileSQLCodeEditor(
            text: Binding(
                get: { tab.sql },
                set: { store.setSQL($0, forTab: tabId) }
            ),
            errorCharOffset: tab.errorCharOffset,
            controller: editorController,
            onFocusChange: { focused in
                withAnimation(reduceMotion ? nil : .snappy) { editorFocused = focused }
                if !focused {
                    completions = []
                    lastCompletionInput = nil
                }
            },
            onCaretChange: updateCompletions
        )
        // A fresh text view per query tab (caret and undo restart on switch).
        .id(tabId)
        // Browse's "Open Data" opens a tab flagged to run at once; the id
        // re-fires when the flag flips on and `consumeAutoRun` clears it, so
        // re-renders can't double-fire (mirrors the macOS tab view).
        .task(id: "\(tabId)-autorun-\(tab.pendingAutoRun)") {
            guard tab.pendingAutoRun,
                  store.consumeAutoRun(forTab: tabId),
                  let current = store.tabs.first(where: { $0.id == tabId })
            else { return }
            executeSQL(tab: current)
        }
    }

    /// The editor is the hero while you write; once rows arrive and you stop
    /// typing it steps back to a few lines and the grid takes the screen.
    private func editorHeight(available: CGFloat, tab: PostgresQueryTab) -> CGFloat {
        // Never so tall that Run and the suggestions fall under the keyboard
        // (iPhone landscape, Split View).
        let ceiling = max(Self.smallestEditorHeight, available - Self.reservedBelowEditor)
        if tab.lastResult != nil && !editorFocused {
            return min(collapsedEditorHeight, ceiling)
        }
        return min(max(minimumEditorHeight, available * Self.expandedEditorShare), ceiling)
    }

    private func updateCompletions(text: String, cursorUTF16: Int?) {
        let input = CompletionInput(text: text, cursorUTF16: cursorUTF16)
        guard input != lastCompletionInput else { return }
        lastCompletionInput = input
        guard editorFocused,
              let cursorUTF16,
              let schemaStore,
              let database = profile?.database
        else {
            completions = []
            return
        }
        let result = SQLCompletionEngine.complete(
            sql: text,
            cursorUTF16: cursorUTF16,
            catalog: schemaStore.completionCatalog(database: database)
        )
        // Tables the statement uses but whose columns aren't loaded yet:
        // fetch them so the next keystroke can complete columns.
        for relation in result.relationsNeedingColumns {
            schemaStore.requestColumnsIfIdle(database: database, schema: relation.schema, table: relation.name)
        }
        completions = SQLCompletionInsertion.shouldOffer(result.items, in: text, cursorUTF16: cursorUTF16)
            ? Array(result.items.prefix(Self.maxSuggestions))
            : []
    }

    /// Completion only knows what's loaded; load the database's schemas and
    /// their tables up front instead of waiting for someone to open Browse.
    private func primeCompletionCatalog() async {
        guard let schemaStore, let database = profile?.database else { return }
        if schemaStore.schemasState[database]?.isLoaded != true {
            await schemaStore.loadSchemas(database: database)
        }
        guard case .loaded(let schemas) = schemaStore.schemasState[database] else { return }
        for schema in schemas.prefix(Self.primedSchemaLimit) {
            if Task.isCancelled { return }
            let key = PgCompositeKey.schema(database: database, schema: schema.name)
            switch schemaStore.schemaContentsState[key] {
            case .loaded?, .loading?:
                continue
            case .idle?, .failed?, nil:
                await schemaStore.loadSchemaContents(database: database, schema: schema.name)
            }
        }
    }

    // MARK: - Ask

    /// The schema Ask grounds its SQL in: the one Browse opens on.
    private var defaultSchema: String {
        guard let database = profile?.database,
              case .loaded(let schemas)? = schemaStore?.schemasState[database]
        else { return "public" }
        return BrowseSchemaChoice.initial(from: schemas.map(\.name)) ?? "public"
    }

    /// Put generated SQL where you'll read it before running: into an empty
    /// query tab, otherwise a new one — never over your own work.
    ///
    /// The SQL is marked as AI-written, so Run asks first if it would change
    /// data (PgReadOnlyGuard) — the model's instructions are not a boundary.
    private func useGeneratedSQL(_ sql: String) {
        let tabId: UUID
        if let tab = store.activeTab, tab.isSQLTab,
           tab.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tabId = tab.id
        } else {
            tabId = store.openSqlTab(title: "Ask", sql: sql)
        }
        store.setAIGeneratedSQL(sql, forTab: tabId)
    }

    // MARK: - Hardware keyboard

    /// Dispatch a menu/keyboard action (see `MobileKeyboardCommands`).
    /// Run/cancel only apply to SQL tabs; property inspectors and routine
    /// editors have no statement to execute.
    private func handleShortcut(_ action: MobileShortcutAction) {
        // The tab view keeps this workspace alive behind Pulse and Browse;
        // ⌘↩ there must never run (or ⌘W close) a query nobody can see.
        guard app.selectedTab == .query else { return }
        switch action {
        case .runQuery:
            guard let tab = store.activeTab, tab.isSQLTab else { return }
            if case .running = tab.execState { return }
            executeSQL(tab: tab)
        case .cancelQuery:
            guard let tab = store.activeTab, case .running = tab.execState else { return }
            cancelSQL(tab: tab)
        case .newTab:
            store.openBlankTab()
        case .closeTab:
            guard let tab = store.activeTab else { return }
            closeTab(tab)
        case .nextTab:
            store.activateNextTab()
        case .previousTab:
            store.activatePreviousTab()
        case .selectTab(let index):
            store.activateTab(atIndex: index)
        case .selectLastTab:
            store.activateLastTab()
        case .newConnection, .showTab:
            break // handled by MobileContentView
        }
    }
    
    private var queryTabHeaderStrip: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.tabs) { tab in
                        let isActive = tab.id == store.activeTabId
                        HStack(spacing: 6) {
                            Text(tab.title)
                                .font(MidnightMobileDesign.FontToken.captionStrong)
                                .foregroundStyle(isActive ? MidnightColors.accentCyan : .secondary)
                            
                            Button {
                                closeTab(tab)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(isActive ? MidnightColors.accentCyan.opacity(0.12) : MidnightColors.subtleFill)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isActive ? MidnightColors.accentCyan : MidnightColors.borderGray, lineWidth: 1))
                        .onTapGesture {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                store.setActive(tab.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            
            Button {
                store.openBlankTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(MidnightColors.accentCyan)
                    .frame(width: 36, height: 36)
                    .background(MidnightColors.subtleFill)
                    .clipShape(Circle())
                    .padding(.trailing, 8)
            }
            .buttonStyle(.plain)
            .help("New query tab (⌘T)")
        }
        .background(MidnightColors.recessedFill)
    }
    
    @ViewBuilder
    private func resultsStatusBar(tab: PostgresQueryTab) -> some View {
        HStack(spacing: 12) {
            switch tab.execState {
            case .idle:
                EmptyView()
            case .running:
                Text("Running…")
                    .foregroundStyle(.secondary)
            case .completed(let elapsed, _):
                Group {
                    if let result = tab.lastResult {
                        Text("\(result.rows.count) \(result.rows.count == 1 ? "row" : "rows") · \(Self.formatElapsed(elapsed))")
                    } else {
                        Text("Done · \(Self.formatElapsed(elapsed))")
                    }
                }
                .monospacedDigit()
                .foregroundStyle(.secondary)
            case .failed:
                Text("Failed")
                    .foregroundStyle(.red)
            case .cancelled:
                Text("Cancelled")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if aiAvailable, connectionId != nil {
                Button {
                    showingAsk = true
                } label: {
                    Label("Ask", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .help("Describe a query in plain English")
            }

            switch tab.execState {
            case .running:
                Button(role: .cancel) {
                    cancelSQL(tab: tab)
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .help("Cancel query (⌘.)")
            default:
                Button {
                    executeSQL(tab: tab)
                } label: {
                    Label("Run", systemImage: "play.fill")
                        .foregroundStyle(MidnightColors.onAccent)
                }
                .buttonStyle(.borderedProminent)
                .help("Run query (⌘↩)")
                .disabled(tab.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .font(MidnightMobileDesign.FontToken.captionStrong)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(MidnightColors.recessedFill)
    }

    /// "84 ms" under a second, "2.4 s" (locale decimal) above.
    private static func formatElapsed(_ seconds: TimeInterval) -> String {
        seconds < 1
            ? "\(Int((seconds * 1000).rounded())) ms"
            : seconds.formatted(.number.precision(.fractionLength(1))) + " s"
    }

    @ViewBuilder
    private func resultsDisplayPane(tab: PostgresQueryTab) -> some View {
        ZStack {
            MidnightColors.canvas.ignoresSafeArea()

            switch tab.execState {
            case .idle:
                Text("Results appear here.")
                    .font(MidnightMobileDesign.FontToken.subheadline)
                    .foregroundStyle(.tertiary)
            case .running:
                ProgressView()
            case .completed:
                if let result = tab.lastResult {
                    MobileResultsGridView(
                        columns: result.columns,
                        rows: result.rows,
                        hasMore: tab.hasMore,
                        isLoadingMore: tab.isLoadingMore,
                        pendingEdits: tab.pendingEdits,
                        onLoadMore: {
                            loadMoreRows(tab: tab)
                        },
                        browse: tab.browse,
                        onGoToPage: tab.browse != nil
                            ? { page in goToBrowsePage(page, tab: tab) }
                            : nil,
                        onCycleSort: tab.browse != nil
                            ? { column in cycleBrowseSort(column: column, tab: tab) }
                            : nil
                    )
                } else {
                    Text("Done. No rows returned.")
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed(let msg, _):
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Error", systemImage: "exclamationmark.triangle.fill")
                            .font(MidnightMobileDesign.FontToken.captionStrong)
                            .foregroundStyle(.red)
                        Text(msg)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.2), lineWidth: 1))
                    .padding()
                }
            case .cancelled:
                Text("Cancelled.")
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private var emptyTabArea: some View {
        ContentUnavailableView(
            "No Open Queries",
            systemImage: "text.cursor",
            description: Text("Tap + to start one.")
        )
    }
    
    private func closeTab(_ tab: PostgresQueryTab) {
        if let connId = connectionId {
            let sessionId = tab.id.uuidString
            let cursorId = tab.lastResult?.cursorId
            Task {
                if case .running = tab.execState {
                    _ = await BridgeManager.shared.pgCancel(connectionId: connId, sessionId: sessionId)
                }
                if let cursorId {
                    _ = await BridgeManager.shared.pgCloseQuery(connectionId: connId, sessionId: sessionId, cursorId: cursorId)
                }
                _ = await BridgeManager.shared.pgReleaseSession(connectionId: connId, sessionId: sessionId)
            }
        }
        store.closeTab(id: tab.id)
        if store.tabs.isEmpty {
            store.openBlankTab()
        }
    }
    
    private func cancelSQL(tab: PostgresQueryTab) {
        runTask?.cancel()
        guard let connId = connectionId else { return }
        Task {
            _ = await BridgeManager.shared.pgCancel(
                connectionId: connId,
                sessionId: tab.id.uuidString
            )
        }
    }

    private func executeSQL(tab: PostgresQueryTab) {
        guard let connId = connectionId else { return }
        let trimmed = tab.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Unmodified AI-written SQL that would change data needs an explicit
        // OK — same rule as macOS. SQL you typed or edited runs as is.
        if let aiSQL = tab.aiGeneratedSQL,
           aiSQL.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed,
           !PgReadOnlyGuard.isReadOnly(trimmed) {
            pendingAIWrite = PendingAIWrite(tabId: tab.id, sql: trimmed)
            return
        }

        // Put the keyboard away so the results get the screen.
        editorController.resignFocus()

        // A browse tab whose editor no longer matches its generated
        // SELECT has been taken over by hand-written SQL — drop the
        // pager so the page/sort controls can't re-run stale browse
        // state over the user's own query. Mirrors the macOS `run`.
        if let browse = tab.browse,
           trimmed != browse.sql().trimmingCharacters(in: .whitespacesAndNewlines) {
            store.setBrowse(nil, forTab: tab.id)
        }

        runTask?.cancel()
        let started = Date()
        store.setErrorPosition(nil, forTab: tab.id)
        store.setExecState(.running(startedAt: started), forTab: tab.id)

        let tabId = tab.id
        let sessionId = tab.id.uuidString
        let pageSize = store.pageSize

        runTask = Task { @MainActor in
            do {
                let result = try await BridgeManager.shared.pgExecute(
                    connectionId: connId,
                    sessionId: sessionId,
                    sql: trimmed,
                    pageSize: pageSize
                )
                let elapsed = Date().timeIntervalSince(started)
                guard !Task.isCancelled else {
                    store.setExecState(.cancelled(elapsed: elapsed), forTab: tabId)
                    return
                }
                // Browse tabs derive `hasNextPage` from the page fill and
                // page via LIMIT/OFFSET re-runs — no cursor "Load more".
                if store.tabs.first(where: { $0.id == tabId })?.browse != nil {
                    store.setBrowseResult(result, forTab: tabId)
                } else {
                    store.setResult(result, forTab: tabId)
                }
                store.setExecState(.completed(elapsed: elapsed, atTime: Date()), forTab: tabId)

                // Save to execution logs
                let rowsReturned = result.columns.isEmpty ? nil : result.rows.count
                PostgresHistoryStore.shared.record(
                    profileId: profileId,
                    sql: trimmed,
                    durationMs: UInt32(min(elapsed * 1000, Double(UInt32.max))),
                    rowsReturned: rowsReturned
                )
            } catch {
                // A newer run replaced this one — its outcome is not news.
                guard !Task.isCancelled else { return }
                let elapsed = Date().timeIntervalSince(started)
                // Underline where the server says the statement went wrong —
                // unless the text was edited meanwhile and no longer matches.
                if let bridgeError = error as? PostgresBridgeError,
                   store.tabs.first(where: { $0.id == tabId })?.sql
                       .trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
                    store.setErrorPosition(bridgeError.serverError?.position, forTab: tabId)
                }
                store.setExecState(.failed(message: error.localizedDescription, elapsed: elapsed), forTab: tabId)
            }
        }
    }

    // MARK: - Browse paging (server-side sort + pagination)

    /// Re-run the browse SELECT with new state (page or sort change).
    /// The regenerated SQL replaces the editor text — same
    /// see-what-runs convention as the generated tab. Mirrors macOS
    /// `applyBrowse`.
    private func applyBrowse(_ newBrowse: PostgresBrowseState, tabId: UUID) {
        store.setBrowse(newBrowse, forTab: tabId)
        store.setSQL(newBrowse.sql(), forTab: tabId)
        if let updated = store.tabs.first(where: { $0.id == tabId }) {
            executeSQL(tab: updated)
        }
    }

    private func goToBrowsePage(_ page: Int, tab: PostgresQueryTab) {
        guard let browse = tab.browse else { return }
        applyBrowse(browse.movingToPage(page), tabId: tab.id)
    }

    private func cycleBrowseSort(column: String, tab: PostgresQueryTab) {
        guard let browse = tab.browse else { return }
        applyBrowse(browse.cyclingSort(by: column), tabId: tab.id)
    }
    
    private func loadMoreRows(tab: PostgresQueryTab) {
        guard let connId = connectionId,
              let result = tab.lastResult,
              let cursorId = result.cursorId else { return }
        
        store.setLoadingMore(true, forTab: tab.id)
        let storeRef = store
        let tabId = tab.id
        let sessionId = tab.id.uuidString
        let pageSize = store.pageSize
        // The page belongs to this exact result: a re-run while the fetch is
        // in flight replaces the result (and cancels this task), and the
        // store drops a page or error whose cursor/generation moved on.
        let resultGeneration = tab.resultGeneration

        let task = Task { @MainActor in
            do {
                let page = try await BridgeManager.shared.pgFetchPage(
                    connectionId: connId,
                    sessionId: sessionId,
                    cursorId: cursorId,
                    count: pageSize
                )
                guard !Task.isCancelled else { return }
                storeRef.appendPage(
                    page,
                    cursorId: cursorId,
                    resultGeneration: resultGeneration,
                    forTab: tabId
                )
            } catch {
                guard !Task.isCancelled else { return }
                storeRef.setPaginationError(
                    error.localizedDescription,
                    cursorId: cursorId,
                    resultGeneration: resultGeneration,
                    forTab: tabId
                )
            }
        }
        store.setLoadMoreTask(task, forTab: tabId)
    }
}

/// Unmodified AI-written SQL that changes data, awaiting confirmation.
private struct PendingAIWrite {
    let tabId: UUID
    let sql: String
}

private struct CompletionInput: Equatable {
    let text: String
    let cursorUTF16: Int?
}
