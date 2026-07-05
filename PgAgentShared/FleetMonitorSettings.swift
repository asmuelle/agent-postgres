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
        static let hubModeEnabled = "fleet.hubModeEnabled"
        static let hubPollIntervalSeconds = "fleet.hubPollIntervalSeconds"
        static let receiveHubAlertsEnabled = "fleet.receiveHubAlertsEnabled"
    }

    /// Default seconds between hub polls; the Mac hub is an always-on app so
    /// it can afford a much tighter loop than iOS BGAppRefresh.
    static let defaultHubPollIntervalSeconds = 30

    private let defaults: UserDefaults

    @Published var longRunningSeconds: Int { didSet { defaults.set(longRunningSeconds, forKey: Key.longRunningSeconds) } }
    @Published var longRunningCountAlert: Int { didSet { defaults.set(longRunningCountAlert, forKey: Key.longRunningCountAlert) } }
    @Published var blockedLockAlert: Int { didSet { defaults.set(blockedLockAlert, forKey: Key.blockedLockAlert) } }
    @Published var alertOnUnreachable: Bool { didSet { defaults.set(alertOnUnreachable, forKey: Key.alertOnUnreachable) } }
    @Published var backgroundAlertsEnabled: Bool { didSet { defaults.set(backgroundAlertsEnabled, forKey: Key.backgroundAlertsEnabled) } }
    /// macOS only: this Mac acts as the always-on monitoring hub and relays
    /// alerts to the user's other devices via CloudKit.
    @Published var hubModeEnabled: Bool { didSet { defaults.set(hubModeEnabled, forKey: Key.hubModeEnabled) } }
    /// macOS only: seconds between hub poll passes.
    @Published var hubPollIntervalSeconds: Int { didSet { defaults.set(hubPollIntervalSeconds, forKey: Key.hubPollIntervalSeconds) } }
    /// iOS only: subscribe to FleetAlert records published by a Mac hub.
    @Published var receiveHubAlertsEnabled: Bool { didSet { defaults.set(receiveHubAlertsEnabled, forKey: Key.receiveHubAlertsEnabled) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = FleetMonitorThresholds.defaults
        longRunningSeconds = (defaults.object(forKey: Key.longRunningSeconds) as? Int) ?? d.longRunningSeconds
        longRunningCountAlert = (defaults.object(forKey: Key.longRunningCountAlert) as? Int) ?? d.longRunningCountAlert
        blockedLockAlert = (defaults.object(forKey: Key.blockedLockAlert) as? Int) ?? d.blockedLockAlert
        alertOnUnreachable = (defaults.object(forKey: Key.alertOnUnreachable) as? Bool) ?? d.alertOnUnreachable
        backgroundAlertsEnabled = (defaults.object(forKey: Key.backgroundAlertsEnabled) as? Bool) ?? false
        hubModeEnabled = (defaults.object(forKey: Key.hubModeEnabled) as? Bool) ?? false
        hubPollIntervalSeconds = (defaults.object(forKey: Key.hubPollIntervalSeconds) as? Int) ?? Self.defaultHubPollIntervalSeconds
        receiveHubAlertsEnabled = (defaults.object(forKey: Key.receiveHubAlertsEnabled) as? Bool) ?? false
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
