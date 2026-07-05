import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// MobileBlockerResolveSheet — the "Resolve…" confirmation for the root blocker
// of a lock chain (roadmap 1.2). Shows the blast radius BEFORE any biometric
// prompt: exactly which session will be hit (pid, user, query, runtime) and
// how many waiting sessions terminating it unblocks. Two escalation levels:
// pg_cancel_backend (milder, try first) and pg_terminate_backend (destructive).
// The caller runs the chosen action through BiometricGate + audit + re-poll.
// =============================================================================

/// What the resolve sheet is aimed at: the wait group plus the blocker's
/// pg_stat_activity row when it could still be found (nil if the backend
/// vanished between render and tap — the sheet says so).
struct BlockerResolveTarget: Identifiable {
    let group: LockWaitGroup
    let session: FfiPgSessionDetail?
    var id: Int32 { group.blockerPid }
}

enum BlockerResolveAction {
    case cancelQuery
    case terminateBackend

    var statement: String { self == .cancelQuery ? "pg_cancel_backend" : "pg_terminate_backend" }
}

struct MobileBlockerResolveSheet: View {
    let target: BlockerResolveTarget
    let instanceName: String
    /// Invoked after the sheet dismisses itself with the chosen action.
    let onAction: (BlockerResolveAction) -> Void

    @Environment(\.dismiss) private var dismiss

    private var waiterCount: Int { target.group.waiterCount }

    var body: some View {
        NavigationStack {
            ZStack {
                MidnightColors.primaryBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        blastRadiusHeader
                        sessionCard
                        if target.group.blockerIsAlsoBlocked {
                            chainWarning
                        }
                        actionButtons
                    }
                    .padding()
                }
            }
            .navigationTitle("Resolve blocker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    // MARK: - Blast radius

    private var blastRadiusHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                    .foregroundStyle(.red)
                Text("Blocker PID \(target.group.blockerPid)")
                    .font(MidnightMobileDesign.FontToken.headline)
            }
            Text("Terminating this backend unblocks \(waiterCount) waiting session\(waiterCount == 1 ? "" : "s") on \(instanceName).")
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Session details

    @ViewBuilder
    private var sessionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let session = target.session {
                detailRow("Session", "\(session.usename)@\(session.datname)")
                if let client = session.clientAddr, !client.isEmpty {
                    detailRow("Client", client)
                }
                detailRow(
                    "State",
                    session.state
                        + (session.state == "active"
                            ? " · running \(FleetFormat.age(sinceEpoch: session.queryStart))"
                            : "")
                )
                if let wait = session.waitEvent {
                    detailRow("Wait event", wait)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("QUERY")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(queryPreview(session))
                        .font(MidnightMobileDesign.FontToken.metadataMono)
                        .foregroundStyle(session.query == nil ? .tertiary : .primary)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Label(
                    "Couldn't load this backend's session details — it may already be gone. The actions below still target PID \(target.group.blockerPid).",
                    systemImage: "questionmark.circle"
                )
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MidnightColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(MidnightColors.borderGray, lineWidth: 1))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
            Text(value)
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func queryPreview(_ session: FfiPgSessionDetail) -> String {
        guard let query = session.query?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty
        else { return "— no query text —" }
        return String(query.prefix(500))
    }

    private var chainWarning: some View {
        Label(
            "This blocker is itself waiting on another session — resolving it may only move the contention up the chain.",
            systemImage: "link"
        )
        .font(MidnightMobileDesign.FontToken.caption)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                dismiss()
                onAction(.cancelQuery)
            } label: {
                VStack(spacing: 2) {
                    Label("Cancel query", systemImage: "stop.circle")
                        .font(MidnightMobileDesign.FontToken.captionStrong)
                    Text("pg_cancel_backend — stops the statement, keeps the connection. Try this first.")
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .tint(.orange)

            Button(role: .destructive) {
                dismiss()
                onAction(.terminateBackend)
            } label: {
                VStack(spacing: 2) {
                    Label("Terminate backend", systemImage: "xmark.octagon.fill")
                        .font(MidnightMobileDesign.FontToken.captionStrong)
                    Text("pg_terminate_backend — kills the whole connection. Cannot be undone.")
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            Text("Both actions require Face ID / Touch ID.")
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
    }
}
