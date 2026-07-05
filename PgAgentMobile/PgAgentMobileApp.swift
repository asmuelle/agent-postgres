import SwiftUI

@main
struct PgAgentMobileApp: App {
    // Remote-notification plumbing for the Mac-hub CloudKit alert relay.
    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var appDelegate
    @StateObject private var entitlementsStore = MobileEntitlementsStore.shared
    @StateObject private var profileStore = PostgresProfileStore.shared
    @StateObject private var alertRouter = MobileAlertRouter.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MobilePrivacyGateView {
                MobileContentView()
            }
            .environmentObject(entitlementsStore)
            .environmentObject(profileStore)
            .environmentObject(alertRouter)
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

