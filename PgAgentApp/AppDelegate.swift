import Cocoa
import OSLog

/// NSApplicationDelegate for the macOS app lifecycle.
///
/// - Initializes the Rust bridge on launch (`applicationDidFinishLaunching`)
/// - Tears it down on termination (`applicationWillTerminate`)
/// - Uses `os_log` for structured logging
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
