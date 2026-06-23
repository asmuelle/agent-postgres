import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// MobileInstanceDetailView — per-instance monitoring container. Hosts the
// Activity and Locks tabs behind a segmented control, mirroring the macOS
// activity monitor. (Maintenance/vacuum lands in Slice 3.) Both child views
// share the instance's pooled connection via PostgresConnectionManager.
// =============================================================================
struct MobileInstanceDetailView: View {
    let profile: PostgresProfile

    private enum Tab: Int, CaseIterable {
        case activity, locks

        var title: String {
            switch self {
            case .activity: return "Activity"
            case .locks: return "Locks"
            }
        }

        var icon: String {
            switch self {
            case .activity: return "bolt.horizontal"
            case .locks: return "lock"
            }
        }
    }

    @State private var selectedTab: Tab = .activity

    var body: some View {
        ZStack {
            MidnightColors.primaryBackground.ignoresSafeArea()

            VStack(spacing: 0) {
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
                    MobileInstanceLocksView(profile: profile)
                }
            }
        }
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
