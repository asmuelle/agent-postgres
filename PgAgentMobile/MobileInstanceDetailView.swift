import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// MobileInstanceDetailView — per-instance monitoring container. Hosts the
// Activity, Locks, and Maintenance tabs behind a segmented control, mirroring
// the macOS activity monitor. Both child views share the instance's pooled
// connection via PostgresConnectionManager.
//
// Alert deep links (roadmap 1.2) land here with the alert kind: blocked-locks
// alerts open the Locks tab with the offending blocker highlighted, slow-query
// alerts open Activity. Offline alerts never reach this view (the fleet
// overview is the right surface for an unreachable instance).
// =============================================================================
struct MobileInstanceDetailView: View {
    let profile: PostgresProfile

    private enum Tab: Int, CaseIterable {
        case activity, locks, maintenance

        var title: String {
            switch self {
            case .activity: return "Activity"
            case .locks: return "Locks"
            case .maintenance: return "Maintenance"
            }
        }

        var icon: String {
            switch self {
            case .activity: return "bolt.horizontal"
            case .locks: return "lock"
            case .maintenance: return "wrench.and.screwdriver"
            }
        }
    }

    @State private var selectedTab: Tab
    /// Blocker to highlight/scroll to on the Locks tab, from the alert payload.
    private let alertBlockerPid: Int32?
    /// True when we arrived from a blocked-locks alert: even without a pid the
    /// Locks tab highlights the current root blocker after its first fetch.
    private let focusRootBlocker: Bool

    init(
        profile: PostgresProfile,
        alertKind: FleetAlertKind? = nil,
        alertBlockerPid: Int32? = nil
    ) {
        self.profile = profile
        let isLockAlert = alertKind == .blockedLocks
        self.alertBlockerPid = isLockAlert ? alertBlockerPid : nil
        self.focusRootBlocker = isLockAlert
        _selectedTab = State(initialValue: isLockAlert ? .locks : .activity)
    }

    var body: some View {
        ZStack {
            MidnightColors.primaryBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Environment badge + read-only lock in the detail header —
                // an on-call responder should never wonder whether the
                // instance they're staring at is production.
                if profile.effectiveEnvironment != .unspecified || profile.isReadOnly {
                    HStack(spacing: 8) {
                        PostgresEnvironmentBadge(profile: profile)
                        Text("\(profile.host):\(profile.port)/\(profile.database)")
                            .font(MidnightMobileDesign.FontToken.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                Picker("View", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Label(tab.title, systemImage: tab.icon).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                switch selectedTab {
                case .activity:
                    MobileInstanceActivityView(profile: profile)
                case .locks:
                    MobileInstanceLocksView(
                        profile: profile,
                        focusPid: alertBlockerPid,
                        focusRootBlockerOnLoad: focusRootBlocker
                    )
                case .maintenance:
                    MobileInstanceMaintenanceView(profile: profile)
                }
            }
        }
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
