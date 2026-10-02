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
        // Extra iPad windows: `openWindow(value: MobileWindowTarget(…))`
        // opens a new window, optionally on one database. The launch window
        // has no value.
        WindowGroup(for: MobileWindowTarget.self) { $target in
            MobilePrivacyGateView {
                MobileContentView(opening: target)
            }
            .tint(MidnightColors.accentCyan)
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
        // The app lock follows the whole app, not one window: the scene
        // phase read here is the app-wide one (background only once every
        // window is), reported once per change.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: MobileAppLock.shared.appDidEnterBackground()
            case .active: MobileAppLock.shared.appDidBecomeActive()
            default: break
            }
        }
        // Spotlight and the Siri phrases follow your connections (names
        // only — see DatabaseEntity). Once per change, not per window.
        .onChange(of: profileStore.profiles.map(DatabaseEntity.init), initial: true) { _, databases in
            MobileSpotlightIndexer.reindex(databases)
        }
        // Hardware-keyboard shortcuts (⌘↩ run, ⌘T/⌘W tabs, ⌘⇧E sidebar…);
        // see MobileKeyboardShortcuts.swift.
        .commands { MobileKeyboardCommands() }
        .backgroundTask(.appRefresh(FleetBackgroundMonitor.taskId)) {
            await FleetBackgroundMonitor.shared.runBackgroundRefresh()
            await FleetBackgroundMonitor.shared.schedule()
        }
    }
}

