import SwiftUI

@main
struct PgAgentMobileApp: App {
    @StateObject private var entitlementsStore = MobileEntitlementsStore.shared
    @StateObject private var profileStore = PostgresProfileStore.shared

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
            }
        }
    }
}

