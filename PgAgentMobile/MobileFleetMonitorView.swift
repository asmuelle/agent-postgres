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
    @StateObject private var store = FleetHealthStore()
    @Environment(\.dismiss) private var dismiss

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
                Text(profile.name)
                    .font(MidnightMobileDesign.FontToken.label)
                    .foregroundStyle(.primary)
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
