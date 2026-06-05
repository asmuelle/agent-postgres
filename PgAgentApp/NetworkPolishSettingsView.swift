import SwiftUI
import PgAgentMacOS

struct NetworkPolishSettingsView: View {
    private let report = NetworkPolishAuditReport.current

    var body: some View {
        Form {
            Section("Tailscale") {
                auditRow(
                    title: "Tailnet preflight",
                    value: "Available",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
                Text("Connection profiles can prefer or require addresses in Tailscale's 100.64.0.0/10 and fd7a:115c:a1e0::/48 ranges before opening SSH.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Multipath TCP") {
                auditRow(
                    title: "SSH",
                    value: report.sshMultipathTCP.state.displayName,
                    systemImage: report.sshMultipathTCP.isSupported ? "network" : "network.slash"
                )
                Text(report.sshMultipathTCP.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                auditRow(
                    title: "HTTP",
                    value: report.urlSessionMultipathTCP.state.displayName,
                    systemImage: "arrow.triangle.swap"
                )
                Text(report.urlSessionMultipathTCP.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("SSH Key Exchange") {
                auditRow(
                    title: "Post-quantum KEX",
                    value: report.postQuantumKex.exposesPostQuantumKex ? "Available" : "Blocked",
                    systemImage: report.postQuantumKex.exposesPostQuantumKex ? "lock.shield" : "lock.trianglebadge.exclamationmark"
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text("Supported")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(report.postQuantumKex.supportedAlgorithms.joined(separator: ", "))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)

                    Text("Missing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(report.postQuantumKex.missingPostQuantumAlgorithms.joined(separator: ", "))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .padding(20)
    }

    private func auditRow(title: String, value: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

private extension NetworkCapabilityState {
    var displayName: String {
        switch self {
        case .supported: return "Supported"
        case .unavailable: return "Unavailable"
        case .blocked: return "Blocked"
        }
    }
}
