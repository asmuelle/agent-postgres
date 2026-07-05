import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// MobileFleetMonitorView — the "monitor multiple instances" surface. One health
// card per saved profile, auto-refreshing on a timer. Tapping an instance opens
// its live Activity list. Presented as a sheet from the connection list.
// =============================================================================
struct MobileFleetMonitorView: View {
    @EnvironmentObject private var profileStore: PostgresProfileStore
    @StateObject private var store = FleetHealthStore.withWidgetPublishing()
    @ObservedObject private var alertRouter = MobileAlertRouter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingSettings = false
    /// Non-nil pushes the instance detail — set by tapped-alert deep links.
    @State private var routedDetail: RoutedInstanceDetail?

    /// How often the fleet glance auto-refreshes.
    private static let refreshInterval: Duration = .seconds(5)

    var body: some View {
        NavigationStack {
            ZStack {
                MidnightColors.primaryBackground.ignoresSafeArea()

                if profileStore.profiles.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(profileStore.profiles) { profile in
                            NavigationLink {
                                MobileInstanceDetailView(profile: profile)
                            } label: {
                                InstanceHealthCard(
                                    profile: profile,
                                    health: store.health(for: profile.id)
                                )
                            }
                            .listRowBackground(MidnightColors.cardBackground)
                            .listRowSeparatorTint(MidnightColors.borderGray)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .refreshable {
                        await store.refresh(profiles: profileStore.profiles)
                    }
                }
            }
            .navigationTitle("Fleet Monitor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small).tint(MidnightColors.accentCyan)
                    } else {
                        Button {
                            Task { await store.refresh(profiles: profileStore.profiles) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                MobileMonitorSettingsView()
            }
            // Tapped-alert deep link: consume the pending route and land on
            // the most relevant tab of the instance detail. Offline alerts
            // stay on this fleet overview (the card already shows the error).
            // `initial: true` covers a route set before this sheet existed.
            .onChange(of: alertRouter.pendingRoute, initial: true) { _, route in
                guard let route else { return }
                guard let profile = profileStore.profiles.first(where: { $0.id == route.instanceId })
                else { return } // root view validates + clears invalid routes
                alertRouter.pendingRoute = nil
                if let kind = route.kind, kind != .unreachable {
                    routedDetail = RoutedInstanceDetail(
                        profile: profile, kind: kind, blockerPid: route.blockerPid
                    )
                } else if route.kind == nil {
                    // Kind unknown (old hub / truncated push) — still land on
                    // the instance, defaulting to the activity tab.
                    routedDetail = RoutedInstanceDetail(
                        profile: profile, kind: .longRunning, blockerPid: nil
                    )
                }
            }
            .navigationDestination(item: $routedDetail) { detail in
                MobileInstanceDetailView(
                    profile: detail.profile,
                    alertKind: detail.kind,
                    alertBlockerPid: detail.blockerPid
                )
            }
            .task {
                // Poll until the sheet is dismissed (task is cancelled on teardown).
                while !Task.isCancelled {
                    await store.refresh(profiles: profileStore.profiles)
                    try? await Task.sleep(for: Self.refreshInterval)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 48))
                .foregroundStyle(MidnightColors.borderGray)
            Text("No Instances to Monitor")
                .font(MidnightMobileDesign.FontToken.headline)
            Text("Add a Postgres connection first, then return here to watch its activity and locks across your fleet.")
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Alert deep-link destination

/// navigationDestination payload for a tapped alert: which instance, which
/// alert kind (drives the initial tab), and the blocker pid when known.
private struct RoutedInstanceDetail: Hashable {
    let profile: PostgresProfile
    let kind: FleetAlertKind
    let blockerPid: Int32?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.profile.id == rhs.profile.id && lhs.kind == rhs.kind && lhs.blockerPid == rhs.blockerPid
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(profile.id)
        hasher.combine(kind)
        hasher.combine(blockerPid)
    }
}

// MARK: - Health Card

private struct InstanceHealthCard: View {
    let profile: PostgresProfile
    let health: FleetInstanceHealth

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .shadow(color: statusColor.opacity(0.5), radius: 4)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(MidnightMobileDesign.FontToken.label)
                        .foregroundStyle(.primary)
                    PostgresEnvironmentBadge(profile: profile, compact: true)
                }
                Text("\(profile.host):\(profile.port)/\(profile.database)")
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let error = health.errorMessage, !health.reachable {
                    Text(error)
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    metricsRow
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var metricsRow: some View {
        HStack(spacing: 8) {
            metricChip(
                value: health.activeBackends,
                label: "active",
                color: MidnightColors.accentCyan,
                alwaysShow: true
            )
            metricChip(
                value: health.longRunningCount,
                label: "slow",
                color: .orange,
                alwaysShow: false
            )
            metricChip(
                value: health.blockedLockCount,
                label: "blocked",
                color: .red,
                alwaysShow: false
            )
        }
    }

    @ViewBuilder
    private func metricChip(value: Int, label: String, color: Color, alwaysShow: Bool) -> some View {
        if value > 0 || alwaysShow {
            HStack(spacing: 4) {
                Text("\(value)")
                    .font(MidnightMobileDesign.FontToken.captionStrong)
                    .foregroundStyle(color)
                Text(label)
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
        }
    }

    private var statusColor: Color {
        switch health.severity {
        case .offline: return MidnightColors.borderGray
        case .blocked: return .red
        case .slow: return .orange
        case .busy: return MidnightColors.accentCyan
        case .healthy: return .green
        }
    }
}
