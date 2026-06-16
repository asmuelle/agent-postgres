#if os(macOS)
import AppKit
import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// PostgresRoutineEditorView — editable function/procedure editor (Slice 1).
//
// Replaces the read-only PostgresRoutineVisualizerView on the routine tab.
// What it does:
//   - Loads the EXACT overload's definition via PostgresNodeDDL (authoritative
//     pg_get_functiondef, fetched live every time — never cached), into the
//     AppKit-backed PostgresSQLEditor with plpgsql highlighting + autocomplete.
//   - Apply runs the edited text as a single CREATE OR REPLACE statement, then
//     re-fetches from the catalog (so the editor shows the server-normalized
//     text) and refreshes the schema tree.
//   - A failed apply maps the server's error position straight onto the
//     offending token via the editor's error underline.
//
// Out of scope here (later slices, see docs/routine-editor-plan.md): typed
// parameter runner, structured attribute panel, plpgsql_check, transactional
// dry-run + dependency blast-radius, AI grounding.
//
// Correctness note: because Apply submits the editor text VERBATIM, the server
// error position (1-based into the submitted statement) maps directly to the
// editor offset (position - 1) — no header-offset bookkeeping needed yet.
// =============================================================================

struct PostgresRoutineEditorView: View {
    let connectionId: String?
    let profileId: String
    let schema: String
    let name: String
    /// Identity-argument signature (e.g. `integer, text`, no parentheses) that
    /// pins the exact overload. Matches `pg_get_function_identity_arguments`.
    let signature: String

    private enum Phase: Equatable {
        case loading
        case ready
        case error(String)
    }

    private enum Tab: String, CaseIterable, Identifiable {
        case source = "Source"
        case properties = "Properties"
        var id: String { rawValue }
    }

    /// Routine kind derived from `pg_proc.prokind`.
    private enum Kind {
        case function, procedure, aggregate, window, other

        init(prokind: String) {
            switch prokind {
            case "f": self = .function
            case "p": self = .procedure
            case "a": self = .aggregate
            case "w": self = .window
            default: self = .other
            }
        }

        var icon: String {
            switch self {
            case .function:  return "function"
            case .procedure: return "rectangle.dashed"
            case .aggregate: return "sum"
            case .window:    return "macwindow"
            case .other:     return "f.cursive"
            }
        }

        var label: String {
            switch self {
            case .function:  return "Function"
            case .procedure: return "Procedure"
            case .aggregate: return "Aggregate"
            case .window:    return "Window function"
            case .other:     return "Routine"
            }
        }
    }

    private struct Meta {
        let kind: Kind
        let language: String
        let returns: String?
        let identityArgs: String
        let fullArgs: String
        /// `true` when the loaded definition is a re-runnable CREATE OR REPLACE
        /// (the common function/procedure case). Aggregates render as plain
        /// CREATE AGGREGATE and C/internal routines as a commented stub — those
        /// can't simply be re-applied, so the editor warns.
        let isReplaceable: Bool

        init?(row: [String?]?, loadedDDL: String) {
            guard let row else { return nil }
            func c(_ i: Int) -> String? { i < row.count ? row[i] : nil }
            identityArgs = c(0) ?? ""
            kind = Kind(prokind: c(1) ?? "f")
            language = c(2) ?? "sql"
            returns = c(5)
            fullArgs = c(6) ?? identityArgs
            isReplaceable = loadedDDL.range(of: "CREATE OR REPLACE", options: .caseInsensitive) != nil
        }
    }

    @State private var phase: Phase = .loading
    @State private var selectedTab: Tab = .source
    /// Editable buffer bound to the SQL editor.
    @State private var editorText: String = ""
    /// Catalog baseline (last loaded/applied). Drives dirty detection + Revert.
    @State private var loadedText: String = ""
    @State private var meta: Meta?
    @State private var isApplying = false
    @State private var applyError: String?
    /// 0-based offset to underline after a failed apply (mapped from the
    /// server's 1-based position into the submitted statement).
    @State private var errorOffset: Int?
    @State private var applied = false

    private var schemaStore: PgSchemaStore? {
        PostgresConnectionManager.shared.schemaStores[profileId]
    }

    private var database: String? {
        PostgresProfileStore.shared.profile(withId: profileId)?.database
    }

    private var isDirty: Bool { editorText != loadedText }

    private var canApply: Bool {
        connectionId != nil && !isApplying && isDirty
            && !editorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            content
        }
        .background(MidnightMacDesign.ColorToken.windowBackground)
        .task(id: routineKey) {
            await load(initial: true)
        }
    }

    /// Reload whenever the bound routine identity changes (tab switch).
    private var routineKey: String {
        "\(connectionId ?? "-")|\(schema).\(name)(\(signature))"
    }

    // MARK: - Header

    @ViewBuilder
    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: meta?.kind.icon ?? "function")
                .font(.title2)
                .foregroundStyle(.purple)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(name)
                        .font(.headline)
                    Text("(\(signature))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if isDirty {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 7, height: 7)
                            .help("Unsaved changes")
                    }
                }
                Text("\(meta?.kind.label ?? "Routine") in \(schema)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)

            if selectedTab == .source {
                Button("Revert") { revert() }
                    .disabled(!isDirty || isApplying)
                    .help("Discard changes and restore the live definition")

                Button {
                    Task { await apply() }
                } label: {
                    if isApplying {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Apply", systemImage: "checkmark.circle")
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!canApply)
                .help("Run CREATE OR REPLACE for this routine (⌘S)")
            }

            Button {
                Task { await load(initial: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(isApplying)
            .help("Reload the live definition from the database")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading routine definition…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .error(let msg):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Failed to load routine")
                    .font(.headline)
                Text(msg)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Button("Retry") { Task { await load(initial: true) } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .ready:
            if selectedTab == .source {
                sourceEditor
            } else {
                propertiesView
            }
        }
    }

    @ViewBuilder
    private var sourceEditor: some View {
        VStack(spacing: 0) {
            if let meta, !meta.isReplaceable {
                banner(
                    "This isn't a plain CREATE OR REPLACE definition (aggregate, or "
                        + "C/internal source). Applying may require dropping it first.",
                    systemImage: "exclamationmark.triangle",
                    tint: .orange
                )
            }

            PostgresSQLEditor(
                text: Binding(
                    get: { editorText },
                    set: { newValue in
                        editorText = newValue
                        // Any edit invalidates the stale error underline and the
                        // last apply error (mirrors the query tab's setSQL).
                        errorOffset = nil
                        applyError = nil
                        applied = false
                    }
                ),
                isEditable: !isApplying,
                errorCharOffset: errorOffset,
                identifiers: { schemaStore?.completionIdentifiers ?? [] }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            statusStrip
        }
    }

    @ViewBuilder
    private var statusStrip: some View {
        if let applyError {
            banner(applyError, systemImage: "xmark.octagon.fill", tint: .red)
        } else if applied {
            banner("Applied — definition saved.", systemImage: "checkmark.seal.fill", tint: .green)
        } else if isDirty {
            banner("Modified — ⌘S to apply.", systemImage: "pencil", tint: .secondary)
        }
    }

    @ViewBuilder
    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(NSColor.separatorColor)).frame(height: 1)
        }
    }

    @ViewBuilder
    private var propertiesView: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 12)],
                spacing: 12
            ) {
                PropertyCard(label: "Kind", value: meta?.kind.label ?? "Routine")
                PropertyCard(
                    label: "Language",
                    value: (meta?.language ?? "—").uppercased(),
                    statusPill: "ACTIVE",
                    pillColor: .purple
                )
                if let returns = meta?.returns, !returns.isEmpty {
                    PropertyCard(label: "Returns", value: returns)
                }
                PropertyCard(
                    label: "Arguments",
                    value: (meta?.fullArgs).flatMap { $0.isEmpty ? nil : $0 } ?? "(none)"
                )
            }
            .padding(16)
        }
    }

    // MARK: - Load / apply

    private func load(initial: Bool) async {
        guard let connectionId else {
            phase = .error("Not connected.")
            return
        }
        if initial { phase = .loading }
        let sessionId = "routine-editor-\(UUID().uuidString)"
        defer {
            Task {
                await BridgeManager.shared.pgReleaseSession(
                    connectionId: connectionId, sessionId: sessionId)
            }
        }
        do {
            let result = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId,
                sessionId: sessionId,
                sql: PostgresNodeDDL.routineQuery(schema: schema, name: name),
                pageSize: 200
            )
            let cells = result.rows.map(\.cells)
            let ddl = PostgresNodeDDL.renderRoutineDDL(
                rows: cells, schema: schema, name: name, signature: signature)
            let wanted = signature.trimmingCharacters(in: .whitespaces)
            let exactRow = cells.first {
                ($0.first.flatMap { $0 })?.trimmingCharacters(in: .whitespaces) == wanted
            }
            loadedText = ddl
            editorText = ddl
            meta = Meta(row: exactRow ?? cells.first, loadedDDL: ddl)
            errorOffset = nil
            applyError = nil
            phase = .ready
        } catch {
            let message = (error as? PostgresBridgeError)?.errorDescription
                ?? error.localizedDescription
            if initial {
                phase = .error(message)
            } else {
                applyError = "Applied, but reloading the definition failed: \(message)"
            }
        }
    }

    private func apply() async {
        guard let connectionId else {
            applyError = "Not connected."
            return
        }
        let sql = editorText
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isApplying = true
        applyError = nil
        errorOffset = nil
        applied = false
        let sessionId = "routine-editor-apply-\(UUID().uuidString)"
        defer {
            Task {
                await BridgeManager.shared.pgReleaseSession(
                    connectionId: connectionId, sessionId: sessionId)
            }
        }
        do {
            _ = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId,
                sessionId: sessionId,
                sql: sql,
                pageSize: 1
            )
            // Refresh the schema tree so the sidebar reflects any rename/signature
            // change, then re-fetch the live definition (never trust a cache).
            if let database {
                await schemaStore?.loadSchemaContents(database: database, schema: schema)
            }
            await load(initial: false)
            isApplying = false
            applied = true
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            applied = false
        } catch let err as PostgresBridgeError {
            applyError = err.errorDescription ?? "Apply failed."
            // Server position is 1-based into the submitted statement; we submit
            // the editor text verbatim, so it maps directly.
            if let pos = err.serverError?.position, pos >= 1 {
                errorOffset = Int(pos) - 1
            }
            isApplying = false
        } catch {
            applyError = error.localizedDescription
            isApplying = false
        }
    }

    private func revert() {
        editorText = loadedText
        errorOffset = nil
        applyError = nil
        applied = false
    }
}
#endif
