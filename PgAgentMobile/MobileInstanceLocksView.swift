import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// MobileInstanceLocksView — pg_locks wait relationships rendered as
// blocker → waiters groups. This is the on-call money screen (roadmap 1.2):
//
// - Alert deep links land here with the offending blocker highlighted and
//   scrolled into view. If the push didn't carry a pid (or it's stale), the
//   current root blocker — head of the biggest chain — is highlighted after
//   the first fetch instead (highlight-by-refetch).
// - "Resolve…" on a blocker opens a blast-radius preview sheet (who dies,
//   who gets unblocked) with two escalation levels: cancel query, then
//   terminate backend. Both run behind BiometricGate and are audit-logged.
// - After an action the chain is re-polled (retrying once if the blocker
//   lingers) and an inline banner reports cleared / partial / still-present.
// =============================================================================
struct MobileInstanceLocksView: View {
    let profile: PostgresProfile
    /// Blocker pid from a tapped alert; highlighted if still present.
    var focusPid: Int32? = nil
    /// Arrived via a blocked-locks alert: highlight the current root blocker
    /// after the first fetch even when `focusPid` is nil or stale.
    var focusRootBlockerOnLoad: Bool = false

    @ObservedObject private var connectionManager = PostgresConnectionManager.shared
    @State private var groups: [LockWaitGroup] = []
    @State private var loadError: String?
    @State private var hasLoaded = false
    @State private var highlightedPid: Int32?
    @State private var didConsumeFocus = false
    @State private var resolveTarget: BlockerResolveTarget?
    @State private var isResolving = false
    @State private var resolutionBanner: ResolutionBanner?
    @State private var actionNote: String?

    private static let refreshInterval: Duration = .seconds(3)
    /// First re-poll after an action lands ~1s later; if the blocker is still
    /// there (cancel can take a moment to bite) we check once more after ~2s.
    private static let verifyDelay: Duration = .seconds(1)
    private static let verifyRetryDelay: Duration = .seconds(2)

    private var connectionId: String? { connectionManager.activeConnections[profile.id] }

    var body: some View {
        ZStack {
            MidnightColors.primaryBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                if let banner = resolutionBanner {
                    bannerView(banner)
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Group {
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
                .frame(maxHeight: .infinity)
            }
        }
        .task {
            await connectionManager.acquire(profile: profile)
            defer { connectionManager.release(profileId: profile.id) }
            while !Task.isCancelled {
                // Pause the auto-poll while verification owns the refresh
                // cadence, so the banner verdict reflects its own re-polls.
                if !isResolving { await refresh() }
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
        .sheet(item: $resolveTarget) { target in
            MobileBlockerResolveSheet(target: target, instanceName: profile.name) { action in
                Task { await perform(action, on: target) }
            }
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
        ScrollViewReader { proxy in
            List {
                ForEach(groups) { group in
                    LockGroupCard(
                        group: group,
                        isHighlighted: group.blockerPid == highlightedPid
                    ) {
                        Task { await beginResolve(group) }
                    }
                    .id(group.blockerPid)
                    .listRowBackground(
                        group.blockerPid == highlightedPid
                            ? MidnightColors.accentCyan.opacity(0.10)
                            : MidnightColors.cardBackground
                    )
                    .listRowSeparatorTint(MidnightColors.borderGray)
                }
            }
            .scrollContentBackground(.hidden)
            .refreshable { await refresh() }
            .onChange(of: highlightedPid, initial: true) { _, pid in
                guard let pid else { return }
                withAnimation { proxy.scrollTo(pid, anchor: .center) }
            }
        }
    }

    private func bannerView(_ banner: ResolutionBanner) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: banner.symbol)
                .foregroundStyle(banner.color)
            Text(banner.message)
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                withAnimation { resolutionBanner = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(banner.color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(banner.color.opacity(0.4), lineWidth: 1))
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

    // MARK: - Data

    private func refresh() async {
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
            hasLoaded = true
            consumeFocusIfNeeded()
            // A highlight only makes sense while its group exists.
            if let pid = highlightedPid, !groups.contains(where: { $0.blockerPid == pid }) {
                highlightedPid = nil
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Resolve the alert deep link's focus exactly once, against fresh data:
    /// prefer the pid the alert carried; fall back to the current root
    /// blocker (head of the biggest chain — `groups` is sorted that way).
    private func consumeFocusIfNeeded() {
        guard !didConsumeFocus, hasLoaded else { return }
        guard focusPid != nil || focusRootBlockerOnLoad else { return }
        didConsumeFocus = true
        if let pid = focusPid, groups.contains(where: { $0.blockerPid == pid }) {
            highlightedPid = pid
        } else if focusRootBlockerOnLoad {
            highlightedPid = groups.first?.blockerPid
        }
    }

    // MARK: - Resolve flow

    /// "Resolve…" tapped: look up the blocker's live session row so the sheet
    /// can preview the blast radius, then present it.
    private func beginResolve(_ group: LockWaitGroup) async {
        guard let connectionId else { return }
        let session = (try? await BridgeManager.shared.pgListSessions(connectionId: connectionId))?
            .first { $0.pid == group.blockerPid }
        resolveTarget = BlockerResolveTarget(group: group, session: session)
    }

    private func perform(_ action: BlockerResolveAction, on target: BlockerResolveTarget) async {
        guard let connectionId else { return }
        let pid = target.group.blockerPid
        let statement = "\(action.statement)(\(pid))"

        // Biometric gate for BOTH levels: on this screen even a cancel is an
        // intervention against someone else's production session.
        let reason = action == .cancelQuery
            ? "Cancel the query of blocker PID \(pid) on \(profile.name)"
            : "Terminate blocker PID \(pid) on \(profile.name)"
        guard await BiometricGate.confirm(reason: reason) else {
            await flash("Authentication failed — PID \(pid) untouched")
            return
        }

        isResolving = true
        defer { isResolving = false }
        withAnimation { resolutionBanner = nil }

        let formerWaiters = Set(target.group.waiters.map(\.pid))
        do {
            let ok: Bool
            switch action {
            case .cancelQuery:
                ok = try await BridgeManager.shared.pgCancelBackend(connectionId: connectionId, pid: pid)
            case .terminateBackend:
                ok = try await BridgeManager.shared.pgTerminateBackend(connectionId: connectionId, pid: pid)
            }
            audit(action, statement: statement, error: ok ? nil : "backend not found")
            await verify(action: action, blockerPid: pid, formerWaiters: formerWaiters)
        } catch {
            audit(action, statement: statement, error: error.localizedDescription)
            withAnimation {
                resolutionBanner = ResolutionBanner(
                    kind: .failure,
                    message: "\(statement) failed: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Re-poll the chain and report what actually happened. Cancel signals
    /// are asynchronous on the server, so a lingering blocker gets one more
    /// chance before we call it "still present".
    private func verify(action: BlockerResolveAction, blockerPid: Int32, formerWaiters: Set<Int32>) async {
        try? await Task.sleep(for: Self.verifyDelay)
        await refresh()
        if groups.contains(where: { $0.blockerPid == blockerPid }) {
            try? await Task.sleep(for: Self.verifyRetryDelay)
            await refresh()
        }

        let banner: ResolutionBanner
        switch blockerResolutionOutcome(
            blockerPid: blockerPid, formerWaiterPids: formerWaiters, groupsAfter: groups
        ) {
        case .cleared(let released):
            banner = ResolutionBanner(
                kind: .success,
                message: "Chain cleared — \(released) session\(released == 1 ? "" : "s") released."
            )
        case .partiallyCleared(let stillWaiting):
            banner = ResolutionBanner(
                kind: .partial,
                message: "Blocker gone — \(stillWaiting) session\(stillWaiting == 1 ? "" : "s") still waiting on other locks."
            )
        case .blockerStillPresent:
            highlightedPid = blockerPid
            banner = ResolutionBanner(
                kind: .failure,
                message: action == .cancelQuery
                    ? "Blocker PID \(blockerPid) still present — a cancel can take a moment; if it persists, try Terminate."
                    : "Blocker PID \(blockerPid) still present — re-check the chain and try again."
            )
        }
        withAnimation { resolutionBanner = banner }
    }

    /// Fire-and-forget audit trail — same policy as every other write path:
    /// an audit failure never surfaces into the action.
    private func audit(_ action: BlockerResolveAction, statement: String, error: String?) {
        let auditAction: PostgresAuditRecord.Action =
            action == .cancelQuery ? .cancelBackend : .terminateBackend
        let profile = self.profile
        Task.detached(priority: .utility) {
            await PostgresAuditLog.shared.record(
                profileName: profile.name,
                host: profile.host,
                database: profile.database,
                user: profile.user,
                action: auditAction,
                statement: statement,
                error: error,
                rowsAffected: nil
            )
        }
    }

    private func flash(_ message: String) async {
        withAnimation { actionNote = message }
        try? await Task.sleep(for: .seconds(2.5))
        withAnimation { actionNote = nil }
    }
}

// MARK: - Post-action banner

private struct ResolutionBanner: Equatable {
    enum Kind { case success, partial, failure }
    let kind: Kind
    let message: String

    var color: Color {
        switch kind {
        case .success: return .green
        case .partial: return .orange
        case .failure: return .red
        }
    }

    var symbol: String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }
}

// MARK: - Lock group card

private struct LockGroupCard: View {
    let group: LockWaitGroup
    let isHighlighted: Bool
    let onResolve: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                    .foregroundStyle(.red)
                Text("Blocker PID \(group.blockerPid)")
                    .font(MidnightMobileDesign.FontToken.captionStrong)
                    .foregroundStyle(.primary)
                if isHighlighted {
                    Text("FROM ALERT")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(MidnightColors.accentCyan.opacity(0.18))
                        .foregroundStyle(MidnightColors.accentCyan)
                        .clipShape(Capsule())
                }
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

            Button(action: onResolve) {
                Label("Resolve…", systemImage: "cross.case.fill")
                    .font(MidnightMobileDesign.FontToken.captionStrong)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(isHighlighted ? MidnightColors.accentCyan : .red)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .leading) {
            if isHighlighted {
                Rectangle()
                    .fill(MidnightColors.accentCyan)
                    .frame(width: 3)
                    .clipShape(Capsule())
                    .padding(.vertical, 2)
                    .offset(x: -12)
            }
        }
    }
}
