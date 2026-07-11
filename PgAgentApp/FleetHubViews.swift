import SwiftUI
import PgAgentMacOS

// =============================================================================
// FleetHubViews — macOS UI for the monitoring hub: the menu bar dropdown
// (per-instance health at a glance) and the Settings pane that turns hub
// mode on/off and shows relay status.
// =============================================================================

// MARK: - Menu bar dropdown

struct FleetHubMenuView: View {
    @ObservedObject private var hub = FleetMonitorHub.shared
    @ObservedObject private var relay = FleetMonitorHub.shared.relay
    @ObservedObject private var lifecycle = FleetAlertLifecycleStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if hub.healths.isEmpty {
                Text("No instances polled yet")
            } else {
                ForEach(hub.healths) { health in
                    Text(instanceLine(health))
                }
            }

            if !hub.activeAlerts.isEmpty {
                Divider()
                Text("Active alerts")
                ForEach(Array(hub.activeAlerts.prefix(8))) { alert in
                    Menu(alert.title) {
                        Button("Acknowledge") { lifecycle.acknowledge(alert) }
                        Button("Snooze 1 hour") {
                            lifecycle.snooze(
                                alert, until: Date().addingTimeInterval(3_600))
                        }
                        Button("Maintenance 1 hour") {
                            lifecycle.beginMaintenance(
                                profileId: alert.profileId,
                                until: Date().addingTimeInterval(3_600))
                        }
                    }
                }
            }

            if !hub.driftFindings.isEmpty {
                Divider()
                Text("Fleet drift")
                ForEach(hub.driftFindings.prefix(8)) { finding in
                    let name = hub.instanceNames[finding.profileId] ?? finding.profileId
                    Text("⚠️ \(name): \(finding.detail)")
                }
            }

            Divider()

            Text(lastCheckedLine)
            Text(relay.status.label)
            if relay.relayedCount > 0 {
                Text("Alerts relayed: \(relay.relayedCount)")
            }

            Divider()

            Button("Open pgAgent") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private var lastCheckedLine: String {
        guard let at = hub.lastPollAt else { return "Last checked: —" }
        return "Last checked: \(at.formatted(date: .omitted, time: .standard))"
    }

    private func instanceLine(_ health: FleetInstanceHealth) -> String {
        let name = hub.instanceNames[health.profileId] ?? health.profileId
        return "\(statusGlyph(health.severity)) \(name) — \(statusText(health))"
    }

    private func statusGlyph(_ severity: FleetInstanceHealth.Severity) -> String {
        switch severity {
        case .offline, .blocked: return "🔴"
        case .slow: return "🟠"
        case .busy, .healthy: return "🟢"
        }
    }

    private func statusText(_ health: FleetInstanceHealth) -> String {
        switch health.severity {
        case .offline: return health.errorMessage ?? "unreachable"
        case .blocked:
            if health.blockedLockCount > 0 { return "\(health.blockedLockCount) blocked" }
            return postureText(health.metrics) ?? "critical posture"
        case .slow:
            if health.longRunningCount > 0 { return "\(health.longRunningCount) slow" }
            return postureText(health.metrics) ?? "posture warning"
        case .busy: return "\(health.activeBackends) active"
        case .healthy: return "healthy"
        }
    }

    private func postureText(_ metrics: FleetProbeMetrics?) -> String? {
        guard let metrics else { return nil }
        if (metrics.xidAge ?? 0) >= 1_500_000_000 { return "XID age \(metrics.xidAge ?? 0)" }
        if (metrics.connectionUtilizationPercent ?? 0) >= 80 {
            return String(format: "%.0f%% connections", metrics.connectionUtilizationPercent ?? 0)
        }
        if (metrics.replicationLagSeconds ?? 0) >= 60 {
            return String(format: "%.0fs replication lag", metrics.replicationLagSeconds ?? 0)
        }
        if (metrics.archiveFailureCount ?? 0) > 0 { return "WAL archive failing" }
        return nil
    }
}

// MARK: - Settings pane

struct FleetHubSettingsView: View {
    @ObservedObject private var settings = FleetMonitorSettings.shared
    @ObservedObject private var hub = FleetMonitorHub.shared
    @ObservedObject private var relay = FleetMonitorHub.shared.relay

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Act as monitoring hub for your other devices",
                    isOn: $settings.hubModeEnabled
                )
                .onChange(of: settings.hubModeEnabled) { enabled in
                    FleetMonitorHub.shared.applyHubMode(enabled: enabled)
                }

                Picker("Check instances every", selection: $settings.hubPollIntervalSeconds) {
                    ForEach([15, 30, 60, 120, 300], id: \.self) { seconds in
                        Text(intervalLabel(seconds)).tag(seconds)
                    }
                }
                .disabled(!settings.hubModeEnabled)
            } footer: {
                Text(
                    """
                    While this Mac is running, pgAgent polls every saved instance and \
                    relays threshold alerts to your iPhone and iPad through your private \
                    iCloud database. No data ever leaves your Apple ID. Alert thresholds \
                    are shared with the fleet monitor.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Status") {
                statusRow("Hub", hub.isRunning ? "Running" : "Off")
                statusRow("iCloud", relay.status.label)
                statusRow("Last poll", lastPollLabel)
                statusRow("Alerts relayed", "\(relay.relayedCount)")
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            if settings.hubModeEnabled {
                await FleetMonitorHub.shared.relay.refreshAccountStatus()
            }
        }
    }

    private var lastPollLabel: String {
        guard let at = hub.lastPollAt else { return "—" }
        return at.formatted(date: .omitted, time: .standard)
    }

    private func intervalLabel(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) seconds" : "\(seconds / 60) minute\(seconds == 60 ? "" : "s")"
    }

    private func statusRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}
