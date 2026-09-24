import Cocoa
import OSLog

/// NSApplicationDelegate for the macOS app lifecycle.
///
/// - Initializes the Rust bridge on launch (`applicationDidFinishLaunching`)
/// - Tears it down on termination (`applicationWillTerminate`)
/// - Uses `os_log` for structured logging
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.mc-ssh", category: "appdelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("pgAgent macOS app launching")
        BridgeManager.shared.initialize()
        logger.info("Rust bridge initialized — app ready")

        // No sessions are live yet, so any decrypted key file left in the
        // materialized-keys directory is a stranded artifact of a crash —
        // purge them before anything can connect.
        SSHKeyVault.shared.sweepStaleMaterializedKeys()

        // Resume opt-in iCloud sync (roadmap 2.3) if the user left it on.
        Task { @MainActor in
            CloudSyncEngine.shared.startIfEnabled()
        }

        // Mirror the monitoring hub's fleet health into the App Group so the
        // macOS widget has data, and push WidgetKit reloads on change.
        WidgetSnapshotPublisher.shared.start()

        // Persist the main window's frame across launches via AppKit's
        // built-in autosave. SwiftUI's WindowGroup doesn't expose a
        // direct frameAutosaveName binding, so we set it on the
        // first window once SwiftUI has materialised it. Defer to the
        // next runloop turn — at this point in the launch sequence
        // SwiftUI hasn't necessarily attached the window yet.
        DispatchQueue.main.async {
            for window in NSApp.windows {
                // Only persist the user's main app window — settings
                // panels and find-bar children open their own and
                // shouldn't share an autosave entry with the workspace.
                if window.contentViewController != nil
                    && window.styleMask.contains(.titled)
                    && window.frameAutosaveName.isEmpty
                {
                    window.setFrameAutosaveName("PgAgentMainWindow")
                }
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
    }

    /// Silent CloudKit push from the UserData zone subscription — another
    /// device changed synced profiles/queries; pull them. FleetAlert pushes
    /// are user-visible and don't route through the Mac (it's the hub).
    func application(
        _ application: NSApplication,
        didReceiveRemoteNotification userInfo: [String: Any]
    ) {
        guard CloudSyncEngine.isSyncPush(userInfo: userInfo) else { return }
        Task { @MainActor in
            await CloudSyncEngine.shared.handleRemotePush()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("pgAgent shutting down")
        BridgeManager.shared.shutdown()
    }

    /// Closing the main window quits the app — except in monitoring-hub
    /// mode, where the menu bar extra keeps polling and relaying alerts and
    /// its "Open pgAgent" item (`openWindow(id: "main")`) brings the window
    /// back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !FleetMonitorSettings.shared.hubModeEnabled
    }

    /// Dock-icon click while the app lingers windowless in hub mode: un-hide
    /// a minimised window if there is one; otherwise returning `true` lets
    /// SwiftUI's default handling re-open the `Window("main")` scene.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag, let minimised = sender.windows.first(where: { $0.isMiniaturized }) {
            minimised.deminiaturize(nil)
            return false
        }
        return true
    }
}
