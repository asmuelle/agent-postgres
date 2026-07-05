import PgAgentMacOS
import SwiftUI

// =============================================================================
// PostgresQueryTabView editor + status strip — the SQL editor with its
// button overlay (run/cancel/history/saved/AI generate) and the status
// bar underneath (state badge, row counts, elapsed time).
//
// Extracted from PostgresQueryTabView.swift; behavior-preserving.
// =============================================================================

extension PostgresQueryTabView {
    // MARK: - SQL editor

    @ViewBuilder
    func sqlEditor(for tab: PostgresQueryTab) -> some View {
        ZStack(alignment: .topTrailing) {
            PostgresSQLEditor(
                text: Binding(
                    get: { tab.sql },
                    set: { store.setSQL($0, forTab: tab.id) }
                ),
                snippetChannel: tab.id.uuidString,
                errorCharOffset: tab.errorCharOffset,
                completionCatalog: {
                    guard let store = PostgresConnectionManager.shared.schemaStores[profileId],
                          let database = profile?.database
                    else { return .empty }
                    return store.completionCatalog(database: database)
                },
                requestColumns: { schema, table in
                    guard let database = profile?.database else { return }
                    PostgresConnectionManager.shared.schemaStores[profileId]?
                        .requestColumnsIfIdle(database: database, schema: schema, table: table)
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

                Button {
                    snippetsOpen.toggle()
                } label: {
                    Label("Snippets", systemImage: "curlybraces")
                }
                .help("Snippet library — insert at the caret, Tab between placeholders")
                .popover(isPresented: $snippetsOpen, arrowEdge: .bottom) {
                    PostgresSnippetsPopover(
                        onInsert: { snippet in
                            // Route through the editor's snippet channel so
                            // the NSTextView inserts at the caret and starts
                            // the placeholder session (not a text replace).
                            NotificationCenter.default.post(
                                name: .pgSQLEditorInsertSnippet,
                                object: nil,
                                userInfo: [
                                    "channel": tab.id.uuidString,
                                    "body": snippet.body,
                                ]
                            )
                        },
                        onDismiss: { snippetsOpen = false }
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
    func statusBar(for tab: PostgresQueryTab) -> some View {
        HStack(spacing: 12) {
            // Environment badge + read-only lock: pinned in the status
            // strip so it stays visible whatever the editor/results
            // split looks like. PRODUCTION renders as a loud red capsule.
            if let p = profile {
                PostgresEnvironmentBadge(profile: p)
            }
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

    // MARK: - Formatting

    func isRunning(_ tab: PostgresQueryTab) -> Bool {
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
