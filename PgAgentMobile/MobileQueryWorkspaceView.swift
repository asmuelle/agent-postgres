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
    
    @State private var runTask: Task<Void, Never>?
    @State private var executionDuration: TimeInterval = 0

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
                    // Editor Panel
                    VStack(spacing: 0) {
                        TextEditor(text: Binding(
                            get: { tab.sql },
                            set: { store.setSQL($0, forTab: activeId) }
                        ))
                        .font(.subheadline.monospaced())
                        .padding(8)
                        .keyboardType(.asciiCapable)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    }
                    .frame(maxHeight: 280)

                    Divider().background(MidnightColors.borderGray)

                    // Status + Run/Cancel bar (also carries the row
                    // count and timing, so the button never overlaps
                    // the SQL editor).
                    resultsStatusBar(tab: tab)

                    Divider().background(MidnightColors.borderGray)

                    // Collapsible results display pane
                    resultsDisplayPane(tab: tab)
                }
            } else {
                emptyTabArea
            }
        }
        .background(MidnightColors.canvas)
        .onReceive(MobileShortcutRelay.shared.actions, perform: handleShortcut)
    }

    // MARK: - Hardware keyboard

    /// Dispatch a menu/keyboard action (see `MobileKeyboardCommands`).
    /// Run/cancel only apply to SQL tabs; property inspectors and routine
    /// editors have no statement to execute.
    private func handleShortcut(_ action: MobileShortcutAction) {
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
        case .toggleSidebar, .newConnection:
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
                        Text("\(result.rows.count) rows · \(Self.formatElapsed(elapsed))")
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
                let elapsed = Date().timeIntervalSince(started)
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

