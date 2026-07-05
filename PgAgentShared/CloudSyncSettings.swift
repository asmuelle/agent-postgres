import Foundation
import SwiftUI

// =============================================================================
// CloudSyncSettings — the user's iCloud-sync toggles (roadmap 2.3), persisted
// in UserDefaults. Sync is OFF by default; the master toggle plus per-category
// toggles are surfaced in macOS Settings → Sync and the iOS settings sheet.
//
// These are *preferences only* — CloudSyncEngine reads them and does the
// actual work. Flipping the master toggle off stops syncing but deletes
// nothing, locally or remotely (see the engine's safety rails).
// =============================================================================
@MainActor
final class CloudSyncSettings: ObservableObject {
    static let shared = CloudSyncSettings()

    private enum Key {
        static let syncEnabled = "cloudsync.enabled"
        static let syncConnections = "cloudsync.connections"
        static let syncSavedQueries = "cloudsync.savedQueries"
    }

    private let defaults: UserDefaults

    /// Master switch. Default OFF — sync is strictly opt-in.
    @Published var syncEnabled: Bool { didSet { defaults.set(syncEnabled, forKey: Key.syncEnabled) } }
    /// Sync connection profiles (sans secrets) + environment tags.
    @Published var syncConnections: Bool { didSet { defaults.set(syncConnections, forKey: Key.syncConnections) } }
    /// Sync saved queries.
    @Published var syncSavedQueries: Bool { didSet { defaults.set(syncSavedQueries, forKey: Key.syncSavedQueries) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        syncEnabled = (defaults.object(forKey: Key.syncEnabled) as? Bool) ?? false
        syncConnections = (defaults.object(forKey: Key.syncConnections) as? Bool) ?? true
        syncSavedQueries = (defaults.object(forKey: Key.syncSavedQueries) as? Bool) ?? true
    }
}
