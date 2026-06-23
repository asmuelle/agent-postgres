import SwiftUI

@main
struct PgAgentMobileApp: App {
    @StateObject private var entitlementsStore = MobileEntitlementsStore.shared
    @StateObject private var profileStore = PostgresProfileStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MobilePrivacyGateView {
                MobileContentView()
            }
            .environmentObject(entitlementsStore)
            .environmentObject(profileStore)
            .task {
                BridgeManager.shared.initialize()
                entitlementsStore.start()
                FleetBackgroundMonitor.shared.schedule()
            }
            .onChange(of: scenePhase) { _, phase in
                // Re-arm the background poll each time we leave the foreground.
                if phase == .background {
                    FleetBackgroundMonitor.shared.schedule()
                }
            }
        }
        .backgroundTask(.appRefresh(FleetBackgroundMonitor.taskId)) {
            await FleetBackgroundMonitor.shared.runBackgroundRefresh()
            await FleetBackgroundMonitor.shared.schedule()
        }
    }
}

