import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// MobileInstanceMaintenanceView — vacuum candidates from pg_stat_user_tables,
// worst bloat first. VACUUM (ANALYZE) is a friction-free per-row button;
// VACUUM FULL (exclusive lock + table rewrite) is behind an extra confirm.
// Runs through pgExecute on a dedicated maintenance session.
// =============================================================================
struct MobileInstanceMaintenanceView: View {
    let profile: PostgresProfile

    @ObservedObject private var connectionManager = PostgresConnectionManager.shared
    @State private var candidates: [VacuumCandidate] = []
    @State private var loadState: LoadState = .idle
    @State private var runningTableId: String?
    @State private var pendingFull: VacuumCandidate?
    @State private var actionNote: String?

    private static let sessionId = "pg-maintenance"

    private enum LoadState: Equatable {
        case idle, loading, loaded, failed(String)
    }

    private var connectionId: String? { connectionManager.activeConnections[profile.id] }

    var body: some View {
        ZStack {
            MidnightColors.primaryBackground.ignoresSafeArea()

            if case .failed(let message) = loadState {
                errorState(message)
            } else if candidates.isEmpty {
                // Keep showing the spinner until the first scan resolves.
                if loadState == .loaded { cleanState } else { loadingState }
            } else {
                candidateList
            }
        }
        .task { await load() }
        .onDisappear {
            let connId = connectionId
            Task { if let connId { await BridgeManager.shared.pgReleaseSession(connectionId: connId, sessionId: Self.sessionId) } }
        }
        .alert(item: $pendingFull) { candidate in
            Alert(
                title: Text("VACUUM FULL \(candidate.table)?"),
                message: Text(
                    "Rewrites the whole table under an ACCESS EXCLUSIVE lock — reads and writes block until it finishes, and it needs free disk for a full copy. Reclaims the most space. Prefer plain VACUUM unless bloat is severe."
                ),
                primaryButton: .destructive(Text("VACUUM FULL")) {
                    Task { await runVacuum(candidate, full: true) }
                },
                secondaryButton: .cancel()
            )
        }
        .overlay(alignment: .bottom) {
            if let note = actionNote {
                Text(note)
                    .font(MidnightMobileDesign.FontToken.captionStrong)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(MidnightColors.cardBackground, in: Capsule())
                    .overlay(Capsule().stroke(MidnightColors.borderGray, lineWidth: 1))
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - List

    private var candidateList: some View {
        List {
            Section {
                ForEach(candidates) { candidate in
                    VacuumCandidateRow(
                        candidate: candidate,
                        isRunning: runningTableId == candidate.id,
                        onVacuum: { Task { await runVacuum(candidate, full: false) } },
                        onVacuumFull: { pendingFull = candidate }
                    )
                    .listRowBackground(MidnightColors.cardBackground)
                    .listRowSeparatorTint(MidnightColors.borderGray)
                }
            } header: {
                Text("\(candidates.count) table\(candidates.count == 1 ? "" : "s") with dead tuples · worst first")
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await load() }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(MidnightColors.accentCyan)
            Text("Scanning for bloat…")
                .font(MidnightMobileDesign.FontToken.label)
                .foregroundStyle(.secondary)
        }
    }

    private var cleanState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("No bloat to clean")
                .font(MidnightMobileDesign.FontToken.headline)
            Text("No user tables are carrying dead tuples right now.")
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(.secondary)
        }
        .padding(40)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Couldn't scan tables")
                .font(MidnightMobileDesign.FontToken.headline)
            Text(message)
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") { Task { await load() } }
                .buttonStyle(.borderedProminent)
                .tint(MidnightColors.accentCyan)
        }
        .padding(40)
    }

    // MARK: - Data + actions

    private func load() async {
        await connectionManager.connectIfNeeded(profile: profile)
        guard let connectionId else {
            loadState = .failed(connectionManager.connectionErrors[profile.id] ?? "Not connected")
            return
        }
        if candidates.isEmpty { loadState = .loading }
        do {
            let result = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId,
                sessionId: Self.sessionId,
                sql: MaintenanceQuery.bloatCandidates,
                pageSize: 100
            )
            candidates = vacuumCandidates(fromRows: result.rows.map(\.cells))
            loadState = .loaded
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private func runVacuum(_ candidate: VacuumCandidate, full: Bool) async {
        guard let connectionId, runningTableId == nil else { return }
        // VACUUM FULL takes an exclusive lock + rewrites the table — gate it.
        // Plain VACUUM (ANALYZE) is routine and safe, so it runs freely.
        if full {
            guard await BiometricGate.confirm(reason: "VACUUM FULL \(candidate.table) on \(profile.name)") else {
                await flash("Authentication failed — VACUUM FULL not run")
                return
            }
        }
        runningTableId = candidate.id
        defer { runningTableId = nil }
        // Lock-screen Live Activity for the duration of the vacuum — nil token
        // (activities disabled) makes every call below a silent no-op.
        let activityId = LiveActivityManager.shared.start(
            operationKind: full ? "VACUUM FULL" : "VACUUM ANALYZE",
            instanceName: profile.name,
            targetName: "\(candidate.schema).\(candidate.table)"
        )
        do {
            _ = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId,
                sessionId: Self.sessionId,
                sql: candidate.vacuumSQL(analyze: true, full: full),
                pageSize: 1
            )
            LiveActivityManager.shared.end(id: activityId, success: true)
            await flash("\(full ? "VACUUM FULL" : "VACUUM ANALYZE") \(candidate.table) done")
        } catch {
            LiveActivityManager.shared.end(id: activityId, success: false, detail: error.localizedDescription)
            await flash("Failed: \(error.localizedDescription)")
        }
        await load()
    }

    private func flash(_ message: String) async {
        withAnimation { actionNote = message }
        try? await Task.sleep(for: .seconds(2.5))
        withAnimation { actionNote = nil }
    }
}

// MARK: - Candidate row

private struct VacuumCandidateRow: View {
    let candidate: VacuumCandidate
    let isRunning: Bool
    let onVacuum: () -> Void
    let onVacuumFull: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(candidate.table)
                    .font(MidnightMobileDesign.FontToken.label)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(candidate.schema)
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                deadRatioBadge
            }

            HStack(spacing: 12) {
                metric("\(candidate.deadTuples)", "dead")
                metric("\(candidate.liveTuples)", "live")
                if let lastVacuum = candidate.lastVacuum {
                    metric(lastVacuum, "vacuumed", mono: true)
                } else if let lastAuto = candidate.lastAutovacuum {
                    metric(lastAuto, "auto", mono: true)
                } else {
                    metric("never", "vacuumed")
                }
            }

            HStack(spacing: 8) {
                Button(action: onVacuum) {
                    if isRunning {
                        ProgressView().controlSize(.small)
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("VACUUM ANALYZE", systemImage: "sparkles")
                            .font(MidnightMobileDesign.FontToken.captionStrong)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .tint(MidnightColors.accentCyan)
                .disabled(isRunning)

                Menu {
                    Button(role: .destructive, action: onVacuumFull) {
                        Label("VACUUM FULL", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 36, height: 30)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .disabled(isRunning)
            }
        }
        .padding(.vertical, 6)
    }

    private var deadRatioBadge: some View {
        let pct = Int((candidate.deadRatio * 100).rounded())
        let color: Color = candidate.deadRatio >= 0.2 ? .red : (candidate.deadRatio >= 0.05 ? .orange : .secondary)
        return Text("\(pct)% dead")
            .font(MidnightMobileDesign.FontToken.captionStrong)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private func metric(_ value: String, _ label: String, mono: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(mono ? MidnightMobileDesign.FontToken.metadataMono : MidnightMobileDesign.FontToken.captionStrong)
                .foregroundStyle(.primary)
            Text(label)
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(.secondary)
        }
    }
}
