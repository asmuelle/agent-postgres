#if os(macOS)
import AppKit
import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// PostgresSafeApplyView — review-before-commit for a routine edit (Slice 5).
// The moat: an edit can't silently break the database.
//
//   1. Transactional dry-run (BEGIN → statements → ROLLBACK) on a pinned
//      session — the server validates the change with zero side effects.
//   2. Dependency blast radius — when a DROP is forced, Postgres's own DROP
//      (no CASCADE) error DETAIL enumerates exactly what would be lost.
//   3. ACL/search_path preservation — search_path survives in the recreated
//      DDL; GRANTs are captured from the live ACL and re-applied.
//   4. One explicit, transactional Commit.
//
// In-place CREATE OR REPLACE is the safe default (preserves dependents). A
// changed return type / parameter name forces a DROP + CREATE; that path is
// gated behind the blast radius and a destructive Commit.
// =============================================================================

struct PostgresSafeApplyView: View {
    let connectionId: String?
    let schema: String
    let name: String
    let signature: String
    let isProcedure: Bool
    /// The editor's current text (the CREATE OR REPLACE to apply).
    let createText: String
    /// The catalog baseline, for header-identity comparison.
    let loadedText: String
    /// Called after a successful commit. `identityChanged` is true when the
    /// edit created a new / renamed routine (the editor then can't reload by
    /// the original identity).
    var onCommitted: (_ identityChanged: Bool) -> Void = { _ in }
    /// Reports a failed dry-run's 1-based statement position so the editor can
    /// underline the offending token.
    var onError: (UInt32?) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable { case preparing, reviewing, committing }
    private enum Outcome: Equatable {
        case passed
        case failed(message: String, needsDropCreate: Bool)
    }

    @State private var phase: Phase = .preparing
    @State private var identityChanged = false
    @State private var oldHeader: String?
    @State private var newHeader: String?
    @State private var inPlace: Outcome?
    @State private var blastRadius: String?
    @State private var grants: [String] = []
    @State private var dropCreate: Outcome?
    @State private var useDropCreate = false
    @State private var commitError: String?
    @State private var sessionId = "safe-apply-\(UUID().uuidString)"

    private var activePlan: [String] {
        if useDropCreate {
            return PostgresSafeApply.dropCreatePlan(
                schema: schema, name: name, signature: signature, isProcedure: isProcedure,
                createText: createText, grants: grants)
        }
        return PostgresSafeApply.inPlacePlan(createText: createText)
    }

    private var canCommit: Bool {
        guard phase == .reviewing, connectionId != nil else { return false }
        return useDropCreate ? (dropCreate == .passed) : (inPlace == .passed)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if identityChanged { identityWarning }
                    statusSection
                    if useDropCreate || (inPlace.map(isNeedsDropCreate) ?? false) {
                        dropCreateSection
                    }
                    planSection
                    if let commitError {
                        Label(commitError, systemImage: "xmark.octagon.fill")
                            .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 640, maxWidth: 860,
               minHeight: 420, idealHeight: 560, maxHeight: 860)
        .task { await prepare() }
        .onDisappear {
            if let connectionId {
                Task { await BridgeManager.shared.pgReleaseSession(connectionId: connectionId, sessionId: sessionId) }
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill").font(.title2).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Review & Apply").font(.headline)
                Text("\(schema).\(name)(\(signature))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var identityWarning: some View {
        banner(
            "You changed the routine's name or arguments. This creates a NEW routine"
                + (oldHeader.map { " — \($0) is left unchanged" } ?? "") + ".",
            systemImage: "exclamationmark.triangle.fill", tint: .orange)
    }

    @ViewBuilder
    private var statusSection: some View {
        switch phase {
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Dry-running in a transaction…").font(.callout).foregroundStyle(.secondary)
            }
        case .reviewing, .committing:
            if useDropCreate {
                dryRunStatus(dropCreate, label: "DROP + CREATE dry-run")
            } else {
                dryRunStatus(inPlace, label: "Dry-run")
            }
        }
    }

    @ViewBuilder
    private func dryRunStatus(_ outcome: Outcome?, label: String) -> some View {
        switch outcome {
        case .passed:
            banner(
                "\(label) passed — runs in a transaction"
                    + (useDropCreate ? "." : "; dependents are preserved (CREATE OR REPLACE)."),
                systemImage: "checkmark.seal.fill", tint: .green)
        case .failed(let message, let needsDropCreate):
            if needsDropCreate {
                banner(
                    "In-place replace isn't possible — the return type or a parameter changed. "
                        + "A DROP + CREATE is required.",
                    systemImage: "exclamationmark.triangle.fill", tint: .orange)
            } else {
                banner(message, systemImage: "xmark.octagon.fill", tint: .red)
            }
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var dropCreateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("DROP + CREATE")
                .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)

            if let blastRadius, !blastRadius.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("These dependents would be dropped (CASCADE):",
                          systemImage: "trash.fill")
                        .font(.caption.weight(.medium)).foregroundStyle(.red)
                    Text(blastRadius)
                        .font(.caption.monospaced()).foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            } else {
                Label("No dependents — nothing else is affected.",
                      systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Label(grants.isEmpty
                  ? "Default grants — nothing to restore."
                  : "\(grants.count) grant statement(s) will be re-applied after recreate.",
                  systemImage: "key.fill")
                .font(.caption).foregroundStyle(.secondary)

            Toggle(isOn: $useDropCreate) {
                Text("I understand — DROP and recreate, dropping the dependents above.")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .onChange(of: useDropCreate) { _ in
                Task { await runActiveDryRun() }
            }
        }
    }

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("WILL RUN (in one transaction)")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            Text(activePlan.joined(separator: "\n\n"))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(NSColor.separatorColor)))
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(phase == .committing)
            Button {
                Task { await commit() }
            } label: {
                if phase == .committing {
                    ProgressView().controlSize(.small)
                } else {
                    Label(useDropCreate ? "Commit (DROP + CREATE)" : "Commit", systemImage: "checkmark")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(useDropCreate ? .red : .accentColor)
            .disabled(!canCommit)
        }
        .padding(16)
    }

    @ViewBuilder
    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.caption).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func isNeedsDropCreate(_ o: Outcome) -> Bool {
        if case .failed(_, true) = o { return true }
        return false
    }

    // MARK: - Orchestration

    private func prepare() async {
        oldHeader = PostgresRoutineHeader.identity(of: loadedText)
        newHeader = PostgresRoutineHeader.identity(of: createText)
        identityChanged = oldHeader != nil && newHeader != nil && oldHeader != newHeader

        let outcome = await dryRun(PostgresSafeApply.inPlacePlan(createText: createText))
        inPlace = outcome
        // A forced DROP + CREATE only applies when the header identity is the
        // same (a genuine return-type/param change) — a renamed routine is a
        // new object, not a drop-and-replace.
        if !identityChanged, isNeedsDropCreate(outcome) {
            blastRadius = await dropProbeDetail()
            grants = await captureGrants()
            dropCreate = await dryRun(activePlanForDropCreate())
        }
        phase = .reviewing
    }

    private func activePlanForDropCreate() -> [String] {
        PostgresSafeApply.dropCreatePlan(
            schema: schema, name: name, signature: signature, isProcedure: isProcedure,
            createText: createText, grants: grants)
    }

    private func runActiveDryRun() async {
        phase = .preparing
        if useDropCreate {
            dropCreate = await dryRun(activePlanForDropCreate())
        } else {
            inPlace = await dryRun(PostgresSafeApply.inPlacePlan(createText: createText))
        }
        phase = .reviewing
    }

    private func commit() async {
        phase = .committing
        commitError = nil
        let result = await runTransaction(activePlan, commit: true)
        switch result {
        case .success:
            onCommitted(identityChanged)
            dismiss()
        case .failure(let error):
            commitError = (error as? PostgresBridgeError)?.errorDescription ?? error.localizedDescription
            if let pos = (error as? PostgresBridgeError)?.serverError?.position { onError(pos) }
            phase = .reviewing
        }
    }

    private func dryRun(_ statements: [String]) async -> Outcome {
        let result = await runTransaction(statements, commit: false)
        switch result {
        case .success:
            return .passed
        case .failure(let error):
            let se = (error as? PostgresBridgeError)?.serverError
            let needs = PostgresSafeApply.requiresDropCreate(sqlstate: se?.sqlstate, message: se?.message)
            if !needs, let pos = se?.position { onError(pos) }
            let message = (error as? PostgresBridgeError)?.errorDescription ?? error.localizedDescription
            return .failed(message: message, needsDropCreate: needs)
        }
    }

    /// Run the no-CASCADE DROP to capture the dependency blast radius from the
    /// server's own DETAIL. Returns nil when the DROP would succeed (no
    /// dependents).
    private func dropProbeDetail() async -> String? {
        let probe = PostgresSafeApply.dropProbe(
            schema: schema, name: name, signature: signature, isProcedure: isProcedure)
        let result = await runTransaction([probe], commit: false)
        if case .failure(let error) = result {
            let se = (error as? PostgresBridgeError)?.serverError
            return se?.detail ?? (error as? PostgresBridgeError)?.errorDescription
        }
        return nil
    }

    private func captureGrants() async -> [String] {
        guard let connectionId else { return [] }
        do {
            let res = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId, sessionId: sessionId,
                sql: PostgresSafeApply.aclQuery(schema: schema, name: name, signature: signature),
                pageSize: 100)
            return PostgresSafeApply.grantStatements(
                schema: schema, name: name, signature: signature, isProcedure: isProcedure,
                aclRows: res.rows.map(\.cells))
        } catch {
            return []
        }
    }

    /// BEGIN → run each statement → COMMIT or ROLLBACK, on the pinned session.
    /// Any error rolls back so the session is left clean.
    private func runTransaction(_ statements: [String], commit: Bool) async -> Result<Void, Error> {
        guard let connectionId else {
            return .failure(PostgresBridgeError.notConnected("No connection."))
        }
        do {
            try await BridgeManager.shared.pgBegin(connectionId: connectionId, sessionId: sessionId)
            for statement in statements {
                _ = try await BridgeManager.shared.pgExecute(
                    connectionId: connectionId, sessionId: sessionId, sql: statement, pageSize: 1)
            }
            if commit {
                try await BridgeManager.shared.pgCommit(connectionId: connectionId, sessionId: sessionId)
            } else {
                try await BridgeManager.shared.pgRollback(connectionId: connectionId, sessionId: sessionId)
            }
            return .success(())
        } catch {
            // Clear the aborted/open transaction so the session is reusable.
            try? await BridgeManager.shared.pgRollback(connectionId: connectionId, sessionId: sessionId)
            return .failure(error)
        }
    }
}
#endif
