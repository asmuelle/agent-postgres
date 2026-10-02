import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// MobileQueryTab — the SQL workspace for the current database. The database
// is chosen (and switched) from the navigation title; History is one toolbar
// button away instead of a third segment.
// =============================================================================
struct MobileQueryTab: View {
    @State private var historyProfile: PostgresProfile?

    var body: some View {
        NavigationStack {
            MobileDatabaseScope { profile in
                MobileConnectionGate(profile: profile) { connectionId, schemaStore in
                    MobileQueryWorkspaceView(
                        store: MobileQueryStores.store(for: profile.id),
                        connectionId: connectionId,
                        profileId: profile.id,
                        schemaStore: schemaStore
                    )
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            historyProfile = profile
                        } label: {
                            Label("History", systemImage: "clock.arrow.circlepath")
                        }
                    }
                }
            }
            .navigationTitle("Query")
        }
        .sheet(item: $historyProfile) { profile in
            NavigationStack {
                MobileConsoleMetricsView(
                    profileId: profile.id,
                    queryStore: MobileQueryStores.store(for: profile.id)
                )
                .navigationTitle("History")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { historyProfile = nil }
                    }
                }
            }
        }
    }
}
