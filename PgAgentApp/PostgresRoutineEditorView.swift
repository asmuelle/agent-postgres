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
        case attributes = "Attributes"
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
    /// Non-error notice shown after an apply that ran but did NOT replace the
    /// bound routine in place (the user changed its name/arguments, creating a
    /// new routine). Orange, persistent until the next edit/apply.
    @State private var applyNotice: String?
    /// 0-based offset to underline after a failed apply (mapped from the
    /// server's 1-based position into the submitted statement).
    @State private var errorOffset: Int?
    @State private var applied = false
    /// Bumped every time the bound routine identity changes (tab switch) or a
    /// manual reload starts. An in-flight `load`/`apply` captures the value and
    /// discards its results once a newer generation has begun — so a slow apply
    /// can't write the old routine's text (or flash success) onto a new tab.
    @State private var generation = 0
    /// Presents the typed parameter runner (Slice 2).
    @State private var showRunner = false
    /// Presents the Safe-Apply review sheet (Slice 5).
    @State private var showSafeApply = false
    /// Bumped after a successful Apply so the plpgsql_check panel re-runs
    /// against the freshly-saved definition.
    @State private var checkRefreshToken = 0

    private var isProcedure: Bool {
        if case .procedure = meta?.kind { return true }
        return false
    }

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
            await reload()
        }
        .sheet(isPresented: $showRunner) {
            PostgresRoutineRunnerView(
                connectionId: connectionId,
                profileId: profileId,
                schema: schema,
                name: name,
                signature: signature
            )
        }
        .sheet(isPresented: $showSafeApply) {
            PostgresSafeApplyView(
                connectionId: connectionId,
                schema: schema,
                name: name,
                signature: signature,
                isProcedure: isProcedure,
                createText: editorText,
                loadedText: loadedText,
                onCommitted: { identityChanged in
                    Task { await afterApplied(identityChanged: identityChanged) }
                },
                onError: { position in
                    if let position, position >= 1 { errorOffset = Int(position) - 1 }
                }
            )
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

            Button {
                showRunner = true
            } label: {
                Label("Run…", systemImage: "play.fill")
            }
            .disabled(connectionId == nil)
            .help("Call this routine with typed parameters")

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
                    showSafeApply = true
                } label: {
                    Label("Apply…", systemImage: "checkmark.circle")
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!canApply)
                .help("Review the change in a transaction, then commit (⌘S)")
            }

            Button {
                Task { await reload() }
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
                Button("Retry") { Task { await reload() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .ready:
            if selectedTab == .source {
                sourceEditor
            } else {
                PostgresRoutineAttributesView(
                    connectionId: connectionId,
                    profileId: profileId,
                    schema: schema,
                    name: name,
                    signature: signature,
                    onApplied: {
                        // An ALTER changed the catalog definition — refresh the
                        // Source buffer so it shows the server-normalized text.
                        Task { await reload() }
                    }
                )
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
                        // last apply error/notice (mirrors the query tab's setSQL).
                        errorOffset = nil
                        applyError = nil
                        applyNotice = nil
                        applied = false
                    }
                ),
                isEditable: !isApplying,
                errorCharOffset: errorOffset,
                identifiers: { schemaStore?.completionIdentifiers ?? [] }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            statusStrip

            // plpgsql_check diagnostics — only for PL/pgSQL routines (the
            // panel itself handles the extension-missing case gracefully).
            if meta?.language == "plpgsql" {
                PostgresRoutineCheckView(
                    connectionId: connectionId,
                    schema: schema,
                    name: name,
                    signature: signature,
                    refreshToken: checkRefreshToken,
                    onJump: { line in jumpToBodyLine(line) }
                )
            }
        }
    }

    /// Map a plpgsql_check body line onto the editor and highlight it (reusing
    /// the error-underline + scroll path). Best-effort against the current
    /// buffer; exact when not dirty (the check runs on the committed body).
    private func jumpToBodyLine(_ line: Int) {
        if let offset = PostgresRoutineCheck.bodyLineToCharOffset(
            editorText: editorText, bodyLine: line) {
            errorOffset = offset
        }
    }

    @ViewBuilder
    private var statusStrip: some View {
        if let applyError {
            banner(applyError, systemImage: "xmark.octagon.fill", tint: .red)
        } else if let applyNotice {
            banner(applyNotice, systemImage: "exclamationmark.triangle.fill", tint: .orange)
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

    // MARK: - Load / apply

    /// Bump the generation and load — the entry point for tab-switch and
    /// manual refresh. The bump invalidates any in-flight apply/load from a
    /// previous identity.
    private func reload() async {
        generation += 1
        await load(gen: generation, initial: true)
    }

    /// Fetch the live definition. `gen` is the generation this load belongs to;
    /// results are discarded if a newer generation began while awaiting, so a
    /// slow fetch never overwrites a newer routine's buffer.
    private func load(gen: Int, initial: Bool) async {
        guard let connectionId else {
            phase = .error("Not connected.")
            return
        }
        if initial { phase = .loading }
        let sessionId = "routine-editor-\(UUID().uuidString)"
        let outcome: Result<FfiPgExecutionResult, Error>
        do {
            let result = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId,
                sessionId: sessionId,
                sql: PostgresNodeDDL.routineQuery(schema: schema, name: name),
                pageSize: 200
            )
            outcome = .success(result)
        } catch {
            outcome = .failure(error)
        }
        // Structured release — awaited on every path (no fire-and-forget Task),
        // so rapid tab switching can't pile up leased sessions.
        await BridgeManager.shared.pgReleaseSession(connectionId: connectionId, sessionId: sessionId)
        guard gen == generation else { return }

        switch outcome {
        case .success(let result):
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
        case .failure(let error):
            let message = (error as? PostgresBridgeError)?.errorDescription
                ?? error.localizedDescription
            if initial {
                phase = .error(message)
            } else {
                applyError = "Applied, but reloading the definition failed: \(message)"
            }
        }
    }

    /// Post-commit steps after the Safe-Apply sheet commits. The sheet already
    /// ran the change transactionally; here we refresh the sidebar and editor.
    private func afterApplied(identityChanged: Bool) async {
        if let database {
            await schemaStore?.loadSchemaContents(database: database, schema: schema)
        }
        if identityChanged {
            // The original (name, signature) no longer matches what was applied
            // — reloading by it would mislead. Mark clean and point the user at
            // the new routine.
            loadedText = editorText
            applyNotice = "Created a new (or renamed) routine — the original is unchanged. "
                + "Reopen it from the sidebar to edit it."
        } else {
            // Re-fetch the server-normalized definition (never trust a cache).
            generation += 1
            let gen = generation
            await load(gen: gen, initial: false)
            guard gen == generation else { return }
            // Re-run plpgsql_check against the freshly-saved body.
            checkRefreshToken += 1
            applied = true
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard gen == generation else { return }
            applied = false
        }
    }

    private func revert() {
        editorText = loadedText
        errorOffset = nil
        applyError = nil
        applyNotice = nil
        applied = false
    }
}

// =============================================================================
// PostgresRoutineHeader — pure parse of a routine's CREATE header into the
// `name(args)` identity that CREATE OR REPLACE keys on, so the editor can warn
// when an edit would create a new overload / rename rather than replace in
// place. Extracted from the view to be unit-testable.
// =============================================================================

enum PostgresRoutineHeader {
    /// Normalized `name(args)` of a routine's CREATE header, or `nil` when the
    /// text isn't a parseable `CREATE [OR REPLACE] FUNCTION|PROCEDURE` (e.g. an
    /// aggregate or C-stub) — in which case the caller skips the change check.
    static func identity(of ddl: String) -> String? {
        let pattern = "(?is)\\bcreate\\b\\s+(?:or\\s+replace\\s+)?(?:function|procedure)\\s+(.+?)\\s*\\("
        guard let re = try? NSRegularExpression(pattern: pattern),
              let match = re.firstMatch(in: ddl, range: NSRange(ddl.startIndex..., in: ddl)),
              let nameRange = Range(match.range(at: 1), in: ddl),
              let fullRange = Range(match.range, in: ddl)
        else { return nil }
        let name = ddl[nameRange].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Balance-scan the argument list from the '(' the regex stopped at, so a
        // parenthesized default like `DEFAULT (a + b)` inside the args doesn't
        // end the list early.
        let openParen = ddl.index(before: fullRange.upperBound)
        var depth = 0
        var args = ""
        var i = openParen
        while i < ddl.endIndex {
            let ch = ddl[i]
            if ch == "(" {
                depth += 1
                if depth == 1 { i = ddl.index(after: i); continue }
            } else if ch == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            if depth >= 1 { args.append(ch) }
            i = ddl.index(after: i)
        }
        let normArgs = args.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
        return "\(name)(\(normArgs))"
    }
}
#endif
