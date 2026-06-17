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

    private enum Probe: Equatable {
        case noDependents
        case dependents(String)
        case failed(String)
    }

    @State private var phase: Phase = .preparing
    @State private var identityChanged = false
    @State private var oldHeader: String?
    @State private var newHeader: String?
    @State private var inPlace: Outcome?
    @State private var probe: Probe?
    @State private var grants: [String] = []
    @State private var grantCaptureFailed = false
    @State private var dropCreate: Outcome?
    @State private var useDropCreate = false
    @State private var commitError: String?
    /// Bumped on each dry-run so a superseded run (rapid toggle) can't write a
    /// stale outcome that wrongly enables Commit.
    @State private var dryRunGeneration = 0

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
        .interactiveDismissDisabled(phase == .committing)
        .task { await prepare() }
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

            switch probe {
            case .dependents(let detail):
                VStack(alignment: .leading, spacing: 4) {
                    Label("These dependents would be dropped (CASCADE):",
                          systemImage: "trash.fill")
                        .font(.caption.weight(.medium)).foregroundStyle(.red)
                    Text(detail)
                        .font(.caption.monospaced()).foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            case .noDependents:
                Label("No dependents — nothing else is affected.",
                      systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let msg):
                Label("Couldn't determine dependents (\(msg)). CASCADE may still drop objects.",
                      systemImage: "questionmark.diamond.fill")
                    .font(.caption).foregroundStyle(.orange)
            case nil:
                EmptyView()
            }

            Label(grantCaptureFailed
                  ? "Couldn't read grants — they may NOT be restored after recreate."
                  : (grants.isEmpty
                     ? "Default grants — nothing to restore."
                     : "\(grants.count) grant statement(s) will be re-applied (recaptured at commit)."),
                  systemImage: "key.fill")
                .font(.caption)
                .foregroundStyle(grantCaptureFailed ? .orange : .secondary)

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
            probe = await runDropProbe()
            let captured = await captureGrants()
            grants = captured ?? []
            grantCaptureFailed = (captured == nil)
            dropCreate = await dryRun(dropCreatePreviewPlan())
        }
        phase = .reviewing
    }

    /// The plan shown/dry-run for the DROP + CREATE path. The real commit
    /// recaptures grants inside its transaction (see `commitDropCreate`); these
    /// pre-captured grants drive the preview and the dry-run.
    private func dropCreatePreviewPlan() -> [String] {
        PostgresSafeApply.dropCreatePlan(
            schema: schema, name: name, signature: signature, isProcedure: isProcedure,
            createText: createText, grants: grants)
    }

    private func runActiveDryRun() async {
        dryRunGeneration += 1
        let gen = dryRunGeneration
        let wantDropCreate = useDropCreate
        phase = .preparing
        let outcome = await dryRun(
            wantDropCreate
                ? dropCreatePreviewPlan()
                : PostgresSafeApply.inPlacePlan(createText: createText))
        // A newer toggle superseded this run — discard its result so it can't
        // wrongly enable Commit for a plan that wasn't the last dry-run.
        guard gen == dryRunGeneration else { return }
        if wantDropCreate { dropCreate = outcome } else { inPlace = outcome }
        phase = .reviewing
    }

    private func commit() async {
        phase = .committing
        commitError = nil
        let result: Result<Void, Error>
        if useDropCreate {
            result = await commitDropCreate()
        } else {
            result = await runTransaction(PostgresSafeApply.inPlacePlan(createText: createText), commit: true)
        }
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
    /// server's own DETAIL. Distinguishes "no dependents" (drop succeeded) from
    /// "probe failed" (couldn't determine — CASCADE may still drop objects).
    private func runDropProbe() async -> Probe {
        let stmt = PostgresSafeApply.dropProbe(
            schema: schema, name: name, signature: signature, isProcedure: isProcedure)
        let result = await runTransaction([stmt], commit: false)
        switch result {
        case .success:
            return .noDependents
        case .failure(let error):
            let se = (error as? PostgresBridgeError)?.serverError
            // Only SQLSTATE 2BP01 (dependent_objects_still_exist) means the DROP
            // was blocked BY dependents; its DETAIL enumerates them. Any other
            // failure (permissions, network, not-found) is not a dependency list
            // and must not be shown as one.
            if se?.sqlstate == "2BP01", let detail = se?.detail, !detail.isEmpty {
                return .dependents(detail)
            }
            return .failed((error as? PostgresBridgeError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Read the live ACL and build restore statements. Returns nil when the
    /// read itself failed (so the UI can warn that grants may be lost).
    private func captureGrants(sessionId: String) async -> [String]? {
        guard let connectionId else { return nil }
        do {
            let res = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId, sessionId: sessionId,
                sql: PostgresSafeApply.aclQuery(schema: schema, name: name, signature: signature),
                pageSize: 100)
            return PostgresSafeApply.grantStatements(
                schema: schema, name: name, signature: signature, isProcedure: isProcedure,
                aclRows: res.rows.map(\.cells))
        } catch {
            return nil
        }
    }

    /// Preview/dry-run grant capture on its own ephemeral session.
    private func captureGrants() async -> [String]? {
        let sessionId = "safe-apply-acl-\(UUID().uuidString)"
        let result = await captureGrants(sessionId: sessionId)
        if let connectionId {
            await BridgeManager.shared.pgReleaseSession(connectionId: connectionId, sessionId: sessionId)
        }
        return result
    }

    /// Atomic DROP + CREATE commit: capture the ACL *inside* the transaction
    /// (so it can't drift between probe and commit), then DROP CASCADE,
    /// recreate, and restore grants — all or nothing.
    private func commitDropCreate() async -> Result<Void, Error> {
        guard let connectionId else {
            return .failure(PostgresBridgeError.notConnected("No connection."))
        }
        let sessionId = "safe-apply-\(UUID().uuidString)"
        do {
            try await BridgeManager.shared.pgBegin(connectionId: connectionId, sessionId: sessionId)
            let liveGrants = await captureGrants(sessionId: sessionId) ?? []
            let plan = PostgresSafeApply.dropCreatePlan(
                schema: schema, name: name, signature: signature, isProcedure: isProcedure,
                createText: createText, grants: liveGrants)
            for statement in plan {
                _ = try await BridgeManager.shared.pgExecute(
                    connectionId: connectionId, sessionId: sessionId, sql: statement, pageSize: 1)
            }
            try await BridgeManager.shared.pgCommit(connectionId: connectionId, sessionId: sessionId)
            await BridgeManager.shared.pgReleaseSession(connectionId: connectionId, sessionId: sessionId)
            return .success(())
        } catch {
            try? await BridgeManager.shared.pgRollback(connectionId: connectionId, sessionId: sessionId)
            await BridgeManager.shared.pgReleaseSession(connectionId: connectionId, sessionId: sessionId)
            return .failure(error)
        }
    }

    /// BEGIN → run each statement → COMMIT or ROLLBACK on a fresh ephemeral
    /// session, then release it. The session is released only after the
    /// transaction is closed (commit/rollback), so the pool never receives a
    /// connection with an open transaction.
    private func runTransaction(_ statements: [String], commit: Bool) async -> Result<Void, Error> {
        guard let connectionId else {
            return .failure(PostgresBridgeError.notConnected("No connection."))
        }
        let sessionId = "safe-apply-\(UUID().uuidString)"
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
            await BridgeManager.shared.pgReleaseSession(connectionId: connectionId, sessionId: sessionId)
            return .success(())
        } catch {
            // Clear the aborted/open transaction, THEN release — so the pool
            // never gets a connection with a live transaction.
            try? await BridgeManager.shared.pgRollback(connectionId: connectionId, sessionId: sessionId)
            await BridgeManager.shared.pgReleaseSession(connectionId: connectionId, sessionId: sessionId)
            return .failure(error)
        }
    }
}
#endif
