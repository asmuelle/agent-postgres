import SwiftUI

// =============================================================================
// MobileMonitorSettingsView — tune Fleet Monitor thresholds and toggle
// background alerts. Persists through FleetMonitorSettings; enabling background
// alerts requests notification permission and schedules the first refresh.
// =============================================================================
struct MobileMonitorSettingsView: View {
    @ObservedObject private var settings = FleetMonitorSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $settings.longRunningSeconds, in: 1...600) {
                        labeledValue("Slow query after", "\(settings.longRunningSeconds)s")
                    }
                } header: {
                    Text("Thresholds")
                } footer: {
                    Text("A query active longer than this counts as slow in the fleet glance and activity list.")
                }

                Section {
                    Stepper(value: $settings.longRunningCountAlert, in: 0...50) {
                        labeledValue("Slow queries", alertCountLabel(settings.longRunningCountAlert))
                    }
                    Stepper(value: $settings.blockedLockAlert, in: 0...50) {
                        labeledValue("Blocked backends", alertCountLabel(settings.blockedLockAlert))
                    }
                    Toggle("Instance unreachable", isOn: $settings.alertOnUnreachable)
                } header: {
                    Text("Alert when")
                } footer: {
                    Text("Set a count to 0 to disable that alert. Alerts fire once per condition until it clears.")
                }

                Section {
                    Toggle("Background alerts", isOn: $settings.backgroundAlertsEnabled)
                        .onChange(of: settings.backgroundAlertsEnabled) { _, enabled in
                            Task {
                                if enabled {
                                    await FleetBackgroundMonitor.shared.requestAuthorizationIfNeeded()
                                    FleetBackgroundMonitor.shared.schedule()
                                } else {
                                    FleetBackgroundMonitor.shared.cancel()
                                }
                            }
                        }
                } footer: {
                    Text("When enabled, pgAgent periodically checks your instances in the background (about every 15 minutes, at the system's discretion) and notifies you when a threshold is crossed.")
                }
            }
            .navigationTitle("Monitor Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func alertCountLabel(_ count: Int) -> String {
        count == 0 ? "off" : "≥ \(count)"
    }
}
