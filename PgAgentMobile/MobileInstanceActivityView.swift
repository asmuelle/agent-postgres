import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// MobileInstanceActivityView — live pg_stat_activity for one instance, oldest
// query first. Swipe a row to Cancel (pg_cancel_backend) or Terminate
// (pg_terminate_backend); both route through a confirmation alert that names
// the exact effect and target. This is the Slice 1 "quick fix" surface.
// =============================================================================
struct MobileInstanceActivityView: View {
    let profile: PostgresProfile

    @ObservedObject private var connectionManager = PostgresConnectionManager.shared
    @State private var sessions: [FfiPgSessionDetail] = []
    @State private var loadError: String?
    @State private var pendingFix: PendingFix?
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
            } else if sessions.isEmpty {
                idleState
            } else {
                sessionList
            }
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
        .alert(item: $pendingFix) { fix in
            Alert(
                title: Text(fix.title),
                message: Text(fix.message),
                primaryButton: .destructive(Text(fix.confirmLabel)) {
                    Task { await apply(fix) }
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

    // MARK: - Session list

    private var sessionList: some View {
        List {
            Section {
                ForEach(sorted, id: \.pid) { session in
                    SessionRow(session: session)
                        .listRowBackground(MidnightColors.cardBackground)
                        .listRowSeparatorTint(MidnightColors.borderGray)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                pendingFix = .terminate(session)
                            } label: {
                                Label("Terminate", systemImage: "xmark.octagon.fill")
                            }
                            .tint(.red)

                            Button {
                                pendingFix = .cancel(session)
                            } label: {
                                Label("Cancel", systemImage: "stop.circle")
                            }
                            .tint(.orange)
                        }
                }
            } header: {
                Text("\(sorted.count) backend\(sorted.count == 1 ? "" : "s") · swipe a row to cancel or terminate")
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await refresh() }
    }

    /// Active, oldest-running queries first; idle backends sink to the bottom.
    private var sorted: [FfiPgSessionDetail] {
        sessions.sorted { lhs, rhs in
            let lhsActive = lhs.state == "active"
            let rhsActive = rhs.state == "active"
            if lhsActive != rhsActive { return lhsActive }
            return (lhs.queryStart ?? .max) < (rhs.queryStart ?? .max)
        }
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

    private var idleState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("No active backends")
                .font(MidnightMobileDesign.FontToken.headline)
            Text("Nothing is running on this instance right now.")
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
            Text("Couldn't read activity")
                .font(MidnightMobileDesign.FontToken.headline)
            Text(message)
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") { Task { await refresh(force: true) } }
                .buttonStyle(.borderedProminent)
                .tint(MidnightColors.accentCyan)
        }
        .padding(40)
    }

    // MARK: - Data + actions

    private func refresh(force: Bool = false) async {
        await connectionManager.connectIfNeeded(profile: profile)
        guard let connectionId else { return }
        do {
            sessions = try await BridgeManager.shared.pgListSessions(connectionId: connectionId)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func apply(_ fix: PendingFix) async {
        guard let connectionId else { return }
        let pid = fix.session.pid
        do {
            let ok: Bool
            switch fix {
            case .cancel:
                ok = try await BridgeManager.shared.pgCancelBackend(connectionId: connectionId, pid: pid)
            case .terminate:
                ok = try await BridgeManager.shared.pgTerminateBackend(connectionId: connectionId, pid: pid)
            }
            await flash(ok ? "\(fix.verb) PID \(pid)" : "PID \(pid) was already gone")
        } catch {
            await flash("Failed: \(error.localizedDescription)")
        }
        await refresh(force: true)
    }

    private func flash(_ message: String) async {
        withAnimation { actionNote = message }
        try? await Task.sleep(for: .seconds(2.5))
        withAnimation { actionNote = nil }
    }
}

// MARK: - Pending quick-fix

private enum PendingFix: Identifiable {
    case cancel(FfiPgSessionDetail)
    case terminate(FfiPgSessionDetail)

    var session: FfiPgSessionDetail {
        switch self {
        case .cancel(let s), .terminate(let s): return s
        }
    }

    // pid is unique per instance; sign distinguishes the two actions.
    var id: Int {
        switch self {
        case .cancel(let s): return Int(s.pid)
        case .terminate(let s): return -Int(s.pid) - 1
        }
    }

    var verb: String {
        switch self {
        case .cancel: return "Cancelled"
        case .terminate: return "Terminated"
        }
    }

    var title: String {
        switch self {
        case .cancel: return "Cancel query?"
        case .terminate: return "Terminate connection?"
        }
    }

    var confirmLabel: String {
        switch self {
        case .cancel: return "Cancel Query"
        case .terminate: return "Terminate"
        }
    }

    var message: String {
        let pid = session.pid
        switch self {
        case .cancel:
            return "Runs pg_cancel_backend(\(pid)) on \(session.datname). Stops the running statement; the connection stays open."
        case .terminate:
            return "Runs pg_terminate_backend(\(pid)) on \(session.datname). Kills the entire backend connection. This cannot be undone."
        }
    }
}

// MARK: - Session row

private struct SessionRow: View {
    let session: FfiPgSessionDetail

    private var isWaiting: Bool { session.waitEvent != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("PID \(session.pid)")
                    .font(MidnightMobileDesign.FontToken.captionStrong)
                    .foregroundStyle(MidnightColors.accentCyan)

                stateBadge

                Spacer()

                if session.state == "active" {
                    Label(FleetFormat.age(sinceEpoch: session.queryStart), systemImage: "clock")
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(isLong ? .orange : .secondary)
                }
            }

            Text("\(session.usename)@\(session.datname)")
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(.secondary)

            Text(queryPreview)
                .font(MidnightMobileDesign.FontToken.metadataMono)
                .foregroundStyle(session.query == nil ? .tertiary : .primary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private var isLong: Bool {
        guard session.state == "active", let start = session.queryStart else { return false }
        return Date().timeIntervalSince1970 - Double(start) >= FleetHealthStore.longRunningThreshold
    }

    private var stateBadge: some View {
        let color: Color = isWaiting ? .red : (session.state == "active" ? .green : MidnightColors.borderGray)
        let label = isWaiting ? "LOCK WAIT" : session.state.uppercased()
        return Text(label)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var queryPreview: String {
        guard let query = session.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return "— idle —"
        }
        return String(query.prefix(140))
    }
}
