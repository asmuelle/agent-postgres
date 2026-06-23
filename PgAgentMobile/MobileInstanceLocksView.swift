import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// MobileInstanceLocksView — pg_locks wait relationships rendered as
// blocker → waiters groups. The quick fix is "Terminate the blocker" on the
// head of a wait chain (pg_terminate_backend), gated by a confirmation alert.
// =============================================================================
struct MobileInstanceLocksView: View {
    let profile: PostgresProfile

    @ObservedObject private var connectionManager = PostgresConnectionManager.shared
    @State private var groups: [LockWaitGroup] = []
    @State private var loadError: String?
    @State private var pendingBlocker: LockWaitGroup?
    @State private var actionNote: String?

    private static let refreshInterval: Duration = .seconds(3)

    private var connectionId: String? { connectionManager.activeConnections[profile.id] }

    var body: some View {
        ZStack {
            MidnightColors.primaryBackground.ignoresSafeArea()

            if connectionId == nil && connectionManager.isConnecting[profile.id] == true {
                connectingState
            } else if let error = loadError ?? connectionManager.connectionErrors[profile.id] {
                errorState(error)
            } else if groups.isEmpty {
                clearState
            } else {
                chainList
            }
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
        .alert(item: $pendingBlocker) { group in
            Alert(
                title: Text("Terminate the blocker?"),
                message: Text(
                    "Runs pg_terminate_backend(\(group.blockerPid)). Frees \(group.waiterCount) waiting backend\(group.waiterCount == 1 ? "" : "s")."
                    + (group.blockerIsAlsoBlocked
                       ? " This blocker is itself blocked — contention may move up the chain."
                       : "")
                    + " This cannot be undone."
                ),
                primaryButton: .destructive(Text("Terminate")) {
                    Task { await terminate(group.blockerPid) }
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

    // MARK: - Chain list

    private var chainList: some View {
        List {
            ForEach(groups) { group in
                LockGroupCard(group: group) {
                    pendingBlocker = group
                }
                .listRowBackground(MidnightColors.cardBackground)
                .listRowSeparatorTint(MidnightColors.borderGray)
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await refresh() }
    }

    // MARK: - States

    private var connectingState: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(MidnightColors.accentCyan)
            Text("Connecting…")
                .font(MidnightMobileDesign.FontToken.label)
                .foregroundStyle(.secondary)
        }
    }

    private var clearState: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.open.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("No lock contention")
                .font(MidnightMobileDesign.FontToken.headline)
            Text("Nothing is waiting on a blocked lock right now.")
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
            Text("Couldn't read locks")
                .font(MidnightMobileDesign.FontToken.headline)
            Text(message)
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") { Task { await refresh() } }
                .buttonStyle(.borderedProminent)
                .tint(MidnightColors.accentCyan)
        }
        .padding(40)
    }

    // MARK: - Data + actions

    private func refresh() async {
        await connectionManager.connectIfNeeded(profile: profile)
        guard let connectionId else { return }
        do {
            let locks = try await BridgeManager.shared.pgListLocks(connectionId: connectionId)
            let edges = locks.compactMap { lock -> LockEdge? in
                guard let blocker = lock.blockedByPid else { return nil }
                return LockEdge(
                    waiterPid: lock.pid,
                    blockerPid: blocker,
                    relation: lock.relation,
                    mode: lock.mode
                )
            }
            groups = lockWaitGroups(from: edges)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func terminate(_ pid: Int32) async {
        guard let connectionId else { return }
        do {
            let ok = try await BridgeManager.shared.pgTerminateBackend(connectionId: connectionId, pid: pid)
            await flash(ok ? "Terminated blocker PID \(pid)" : "PID \(pid) was already gone")
        } catch {
            await flash("Failed: \(error.localizedDescription)")
        }
        await refresh()
    }

    private func flash(_ message: String) async {
        withAnimation { actionNote = message }
        try? await Task.sleep(for: .seconds(2.5))
        withAnimation { actionNote = nil }
    }
}

// MARK: - Lock group card

private struct LockGroupCard: View {
    let group: LockWaitGroup
    let onTerminate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                    .foregroundStyle(.red)
                Text("Blocker PID \(group.blockerPid)")
                    .font(MidnightMobileDesign.FontToken.captionStrong)
                    .foregroundStyle(.primary)
                if group.blockerIsAlsoBlocked {
                    Text("CHAIN")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                Spacer()
                Text("\(group.waiterCount) waiting")
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(group.waiters) { waiter in
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("PID \(waiter.pid)")
                            .font(MidnightMobileDesign.FontToken.caption)
                            .foregroundStyle(.primary)
                        Text(waiter.mode)
                            .font(MidnightMobileDesign.FontToken.metadataMono)
                            .foregroundStyle(.secondary)
                        if let relation = waiter.relation {
                            Text("on \(relation)")
                                .font(MidnightMobileDesign.FontToken.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                }
            }

            Button(role: .destructive, action: onTerminate) {
                Label("Terminate blocker", systemImage: "xmark.octagon.fill")
                    .font(MidnightMobileDesign.FontToken.captionStrong)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
        .padding(.vertical, 6)
    }
}
