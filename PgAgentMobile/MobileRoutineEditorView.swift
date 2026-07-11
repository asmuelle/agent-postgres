import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// MobileRoutineEditorView — editable function/procedure editor for iPad.
//
// The mobile counterpart of the macOS PostgresRoutineEditorView (Slice 1
// scope): loads the EXACT overload's definition live via PostgresNodeDDL
// (pg_get_functiondef — never cached), edits it in MobileSQLCodeEditor with
// the shared plpgsql-aware highlighting, and Apply runs the buffer verbatim
// as one CREATE OR REPLACE statement. A failed apply maps the server's
// 1-based error position straight onto the editor's underline (position - 1,
// exact because the text is submitted verbatim).
//
// Out of scope on mobile (mac-only slices): typed parameter runner, attribute
// panel, plpgsql_check, transactional Safe-Apply.
// =============================================================================
struct MobileRoutineEditorView: View {
    let connectionId: String?
    let profileId: String
    let schema: String
    let name: String
    /// Identity-argument signature pinning the exact overload.
    let signature: String

    private enum Phase: Equatable {
        case loading
        case ready
        case error(String)
    }

    private struct Meta {
        let kindLabel: String
        let kindIcon: String
        let language: String
        let isReplaceable: Bool

        init?(row: [String?]?, loadedDDL: String) {
            guard let row else { return nil }
            func c(_ i: Int) -> String? { i < row.count ? row[i] : nil }
            switch c(1) ?? "f" {
            case "p": kindLabel = "Procedure"; kindIcon = "rectangle.dashed"
            case "a": kindLabel = "Aggregate"; kindIcon = "sum"
            case "w": kindLabel = "Window function"; kindIcon = "macwindow"
            default: kindLabel = "Function"; kindIcon = "function"
            }
            language = c(2) ?? "sql"
            isReplaceable = loadedDDL.range(of: "CREATE OR REPLACE", options: .caseInsensitive) != nil
        }
    }

    @State private var phase: Phase = .loading
    @State private var editorText: String = ""
    /// Catalog baseline (last loaded/applied). Drives dirty detection + Revert.
    @State private var loadedText: String = ""
    @State private var meta: Meta?
    @State private var applyError: String?
    /// 0-based offset to underline after a failed apply.
    @State private var errorOffset: Int?
    @State private var isApplying = false
    @State private var applied = false
    /// Invalidates in-flight loads/applies when the bound routine changes.
    @State private var generation = 0

    private var isDirty: Bool { editorText != loadedText }

    private var canApply: Bool {
        connectionId != nil && isDirty && !isApplying
            && !editorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().background(MidnightColors.borderGray)
            content
        }
        .background(MidnightColors.primaryBackground)
        .task(id: "\(connectionId ?? "-")|\(schema).\(name)(\(signature))") {
            await reload()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: meta?.kindIcon ?? "function")
                .foregroundStyle(.purple)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(name)
                        .font(MidnightMobileDesign.FontToken.captionStrong)
                    Text("(\(signature))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if isDirty {
                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                    }
                }
                Text("\(meta?.kindLabel ?? "Routine") in \(schema) · \(meta?.language ?? "")")
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                editorText = loadedText
                errorOffset = nil
                applyError = nil
                applied = false
            } label: {
                Text("Revert")
                    .font(MidnightMobileDesign.FontToken.captionStrong)
            }
            .buttonStyle(.bordered)
            .disabled(!isDirty || isApplying)

            Button {
                Task { await apply() }
            } label: {
                if isApplying {
                    ProgressView().tint(.black)
                        .padding(.horizontal, 12)
                } else {
                    Label("Apply", systemImage: "checkmark.circle")
                        .font(MidnightMobileDesign.FontToken.captionStrong)
                        .foregroundStyle(canApply ? .black : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(canApply ? MidnightColors.accentCyan : Color.gray.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
            .buttonStyle(.plain)
            .disabled(!canApply)

            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(MidnightColors.accentCyan)
            }
            .buttonStyle(.plain)
            .disabled(isApplying)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.3))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 12) {
                ProgressView().tint(MidnightColors.accentCyan)
                Text("Loading routine definition…")
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text("Failed to load routine")
                    .font(MidnightMobileDesign.FontToken.headline)
                Text(message)
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await reload() } }
                    .buttonStyle(.borderedProminent)
                    .tint(MidnightColors.accentCyan)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            VStack(spacing: 0) {
                if let meta, !meta.isReplaceable {
                    banner(
                        "This isn't a plain CREATE OR REPLACE definition (aggregate, or "
                            + "C/internal source). Applying may require dropping it first.",
                        systemImage: "exclamationmark.triangle",
                        tint: .orange
                    )
                }

                MobileSQLCodeEditor(
                    text: Binding(
                        get: { editorText },
                        set: { newValue in
                            editorText = newValue
                            errorOffset = nil
                            applyError = nil
                            applied = false
                        }
                    ),
                    isEditable: !isApplying,
                    errorCharOffset: errorOffset
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                statusStrip
            }
        }
    }

    @ViewBuilder
    private var statusStrip: some View {
        if let applyError {
            banner(applyError, systemImage: "xmark.octagon.fill", tint: .red)
        } else if applied {
            banner("Applied — definition saved.", systemImage: "checkmark.seal.fill", tint: .green)
        } else if isDirty {
            banner("Modified — Apply to save.", systemImage: "pencil", tint: .secondary)
        }
    }

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(MidnightMobileDesign.FontToken.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.35))
        .overlay(alignment: .top) {
            Rectangle().fill(MidnightColors.borderGray).frame(height: 1)
        }
    }

    // MARK: - Load / apply

    private func reload() async {
        generation += 1
        await load(gen: generation, initial: true)
    }

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

    /// Submit the buffer verbatim as one statement, then re-fetch the
    /// server-normalized definition and refresh the schema tree.
    private func apply() async {
        guard let connectionId, canApply else { return }
        generation += 1
        let gen = generation
        isApplying = true
        applyError = nil
        errorOffset = nil
        defer { isApplying = false }

        let sessionId = "routine-apply-\(UUID().uuidString)"
        do {
            _ = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId,
                sessionId: sessionId,
                sql: editorText,
                pageSize: 10
            )
            await BridgeManager.shared.pgReleaseSession(connectionId: connectionId, sessionId: sessionId)
            guard gen == generation else { return }

            if let database = PostgresProfileStore.shared.profile(withId: profileId)?.database {
                await PostgresConnectionManager.shared.schemaStores[profileId]?
                    .loadSchemaContents(database: database, schema: schema)
            }
            // Re-fetch so the editor shows the server-normalized text
            // (never trust the local buffer as the new baseline).
            await load(gen: gen, initial: false)
            guard gen == generation else { return }
            applied = true
        } catch {
            await BridgeManager.shared.pgReleaseSession(connectionId: connectionId, sessionId: sessionId)
            guard gen == generation else { return }
            if case PostgresBridgeError.database(let serverError) = error {
                applyError = serverError.message
                if let position = serverError.position, position >= 1 {
                    errorOffset = Int(position) - 1
                }
            } else {
                applyError = (error as? PostgresBridgeError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}
