import Foundation
import SwiftUI

// =============================================================================
// FleetMonitorSettings — user-tunable thresholds + background-alert toggle for
// the Fleet Monitor, persisted in UserDefaults. Shared by the live
// FleetHealthStore (long-running tally), the background monitor (notification
// thresholds), and the settings UI.
// =============================================================================
@MainActor
final class FleetMonitorSettings: ObservableObject {
    static let shared = FleetMonitorSettings()

    private enum Key {
        static let longRunningSeconds = "fleet.longRunningSeconds"
        static let longRunningCountAlert = "fleet.longRunningCountAlert"
        static let blockedLockAlert = "fleet.blockedLockAlert"
        static let alertOnUnreachable = "fleet.alertOnUnreachable"
        static let backgroundAlertsEnabled = "fleet.backgroundAlertsEnabled"
    }

    private let defaults: UserDefaults

    @Published var longRunningSeconds: Int { didSet { defaults.set(longRunningSeconds, forKey: Key.longRunningSeconds) } }
    @Published var longRunningCountAlert: Int { didSet { defaults.set(longRunningCountAlert, forKey: Key.longRunningCountAlert) } }
    @Published var blockedLockAlert: Int { didSet { defaults.set(blockedLockAlert, forKey: Key.blockedLockAlert) } }
    @Published var alertOnUnreachable: Bool { didSet { defaults.set(alertOnUnreachable, forKey: Key.alertOnUnreachable) } }
    @Published var backgroundAlertsEnabled: Bool { didSet { defaults.set(backgroundAlertsEnabled, forKey: Key.backgroundAlertsEnabled) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = FleetMonitorThresholds.defaults
        longRunningSeconds = (defaults.object(forKey: Key.longRunningSeconds) as? Int) ?? d.longRunningSeconds
        longRunningCountAlert = (defaults.object(forKey: Key.longRunningCountAlert) as? Int) ?? d.longRunningCountAlert
        blockedLockAlert = (defaults.object(forKey: Key.blockedLockAlert) as? Int) ?? d.blockedLockAlert
        alertOnUnreachable = (defaults.object(forKey: Key.alertOnUnreachable) as? Bool) ?? d.alertOnUnreachable
        backgroundAlertsEnabled = (defaults.object(forKey: Key.backgroundAlertsEnabled) as? Bool) ?? false
    }

    var thresholds: FleetMonitorThresholds {
        FleetMonitorThresholds(
            longRunningSeconds: longRunningSeconds,
            longRunningCountAlert: longRunningCountAlert,
            blockedLockAlert: blockedLockAlert,
            alertOnUnreachable: alertOnUnreachable
        )
    }

    /// Seconds, as a TimeInterval, for the live long-running computation.
    var longRunningThreshold: TimeInterval { TimeInterval(longRunningSeconds) }
}
