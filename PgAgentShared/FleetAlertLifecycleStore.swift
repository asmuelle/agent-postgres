import Foundation
import SwiftUI

@MainActor
final class FleetAlertLifecycleStore: ObservableObject {
    static let shared = FleetAlertLifecycleStore()

    @Published private(set) var dispositions: [String: FleetAlertDisposition] = [:]
    @Published private(set) var maintenanceByProfile: [String: Date] = [:]

    private let defaults: UserDefaults
    private static let dispositionsKey = "fleet.alert.dispositions"
    private static let maintenanceKey = "fleet.alert.maintenance"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = defaults.data(forKey: Self.dispositionsKey),
           let decoded = try? decoder.decode([String: FleetAlertDisposition].self, from: data) {
            dispositions = decoded
        }
        if let data = defaults.data(forKey: Self.maintenanceKey),
           let decoded = try? decoder.decode([String: Date].self, from: data) {
            maintenanceByProfile = decoded
        }
    }

    func shouldDeliver(_ alert: FleetAlert, now: Date = Date()) -> Bool {
        if let until = maintenanceByProfile[alert.profileId], until > now { return false }
        return FleetAlertLifecyclePolicy.shouldDeliver(
            disposition: dispositions[alert.id] ?? .active, now: now)
    }

    func acknowledge(_ alert: FleetAlert, at date: Date = Date()) {
        dispositions[alert.id] = .acknowledged(at: date)
        persist()
    }

    func snooze(_ alert: FleetAlert, until: Date) {
        dispositions[alert.id] = .snoozed(until: until)
        persist()
    }

    func beginMaintenance(profileId: String, until: Date) {
        maintenanceByProfile[profileId] = until
        persist()
    }

    func noteResolved(alertIds: Set<String>, at date: Date = Date()) {
        var changed = false
        for id in alertIds where dispositions[id] != nil {
            dispositions[id] = .resolved(at: date)
            changed = true
        }
        if changed { persist() }
    }

    /// Reactivate a recurring resolved alert, an expired snooze, or an expired
    /// maintenance window. Returned ids bypass edge-triggering once.
    func prepareForPoll(
        alerts: [FleetAlert],
        previouslyFiring: Set<String>,
        now: Date = Date()
    ) -> Set<String> {
        var transitioned = Set<String>()
        var changed = false

        for alert in alerts {
            if !previouslyFiring.contains(alert.id),
               case .resolved(_)? = dispositions[alert.id] {
                dispositions.removeValue(forKey: alert.id)
                transitioned.insert(alert.id)
                changed = true
            } else if case .snoozed(let until)? = dispositions[alert.id], until <= now {
                dispositions.removeValue(forKey: alert.id)
                transitioned.insert(alert.id)
                changed = true
            }
        }

        let expiredProfiles = maintenanceByProfile.compactMap { profileId, until in
            until <= now ? profileId : nil
        }
        for profileId in expiredProfiles {
            maintenanceByProfile.removeValue(forKey: profileId)
            transitioned.formUnion(alerts.filter { $0.profileId == profileId }.map(\.id))
            changed = true
        }
        if changed { persist() }
        return transitioned
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try? encoder.encode(dispositions), forKey: Self.dispositionsKey)
        defaults.set(try? encoder.encode(maintenanceByProfile), forKey: Self.maintenanceKey)
    }
}
