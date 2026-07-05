import PgAgentMacOS
import SwiftUI

// =============================================================================
// Sidebar details panels — the connection-details panel at the bottom
// of the sidebar (expanded + collapsed variants) and the lazy server
// version/extensions section.
//
// Extracted from SidebarView.swift; behavior-preserving.
// =============================================================================

// MARK: - Postgres Details Panel

struct PostgresDetailsPanel: View {
    let profile: PostgresProfile?
    let status: PostgresWorkspaceStatus?
    /// Schema store of the selected profile's live connection;
    /// `nil` while disconnected. Provides server version + extensions.
    let store: PgSchemaStore?
    let onCollapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Connection Details")
                    .font(MidnightMacDesign.FontToken.label)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button(action: onCollapse) {
                    Image(systemName: "chevron.down")
                        .font(MidnightMacDesign.FontToken.caption.weight(.semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Collapse connection details")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider()

            if let profile {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        detailRow("Name", profile.name)
                        detailRow("Host", profile.host)
                        detailRow("Port", "\(profile.port)")
                        detailRow("User", profile.user)
                        detailRow("Database", profile.database)
                        if let status {
                            statusRow(status)
                        }
                        if let tunnel = profile.tunnel {
                             if let sshProfile = ConnectionStoreManager.shared.connections.first(where: { $0.id == tunnel.sshConnectionId }) {
                                 detailRow("SSH Tunnel", sshProfile.name)
                             } else {
                                 detailRow("SSH Tunnel ID", tunnel.sshConnectionId)
                             }
                             detailRow("Remote Host", tunnel.remoteHost)
                             detailRow("Remote Port", "\(tunnel.remotePort)")
                         }
                        if let store {
                            PostgresServerInfoSection(store: store)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Select a database profile to see details.")
                        .font(MidnightMacDesign.FontToken.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(MidnightMacDesign.FontToken.metadataMono.monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusRow(_ status: PostgresWorkspaceStatus) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("State")
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 84, alignment: .leading)
            HStack(spacing: 5) {
                Image(systemName: statusSymbol(status))
                    .font(MidnightMacDesign.FontToken.caption)
                    .foregroundStyle(statusColor(status))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 12, height: 12)
                Text(statusLabel(status))
                    .font(MidnightMacDesign.FontToken.metadataMono.monospacedDigit())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusSymbol(_ status: PostgresWorkspaceStatus) -> String {
        switch status {
        case .connected:        return "checkmark.circle.fill"
        case .connecting:       return "clock.fill"
        case .error:            return "exclamationmark.circle.fill"
        case .disconnected:     return "circle"
        }
    }

    private func statusColor(_ status: PostgresWorkspaceStatus) -> Color {
        switch status {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .error:        return .red
        case .disconnected: return .secondary.opacity(0.4)
        }
    }

    private func statusLabel(_ status: PostgresWorkspaceStatus) -> String {
        switch status {
        case .connected:    return "Connected"
        case .connecting:   return "Connecting"
        case .disconnected: return "Disconnected"
        case .error(let m): return "Error: \(m)"
        }
    }
}

// MARK: - Server Info Section (version + extensions)

/// Lazy server-version + extensions block inside the details panel.
/// Separate view so it can `@ObservedObject` the (optional upstream)
/// schema store and trigger its own load — the panel itself stays a
/// plain value-driven view.
private struct PostgresServerInfoSection: View {
    @ObservedObject var store: PgSchemaStore

    var body: some View {
        Group {
            switch store.serverInfoState {
            case .idle, .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading server info…")
                        .font(MidnightMacDesign.FontToken.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle")
                    .font(MidnightMacDesign.FontToken.caption)
                    .foregroundStyle(.red)
            case .loaded(let info):
                infoRow("Server", "PostgreSQL \(info.version)")

                Text("Extensions (\(info.extensions.count))".uppercased())
                    .font(MidnightMacDesign.FontToken.label)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)

                if info.extensions.isEmpty {
                    Text("No extensions installed")
                        .font(MidnightMacDesign.FontToken.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(info.extensions) { ext in
                        infoRow(ext.name, ext.version)
                    }
                }
            }
        }
        // Keyed on the connection id: a reconnect produces a fresh
        // store (and id), so version/extensions re-fetch automatically.
        .task(id: store.connectionId) {
            if !store.serverInfoState.isLoaded {
                await store.loadServerInfo()
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(MidnightMacDesign.FontToken.metadataMono.monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Collapsed Details Bar

struct CollapsedPostgresDetailsBar: View {
    let profile: PostgresProfile?
    let status: PostgresWorkspaceStatus?
    let onCollapse: () -> Void = {} // Dummy for initialization matching
    let onExpand: () -> Void

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: 7) {
                if let status {
                    Image(systemName: statusSymbol(status))
                        .font(MidnightMacDesign.FontToken.caption)
                        .foregroundStyle(statusColor(status))
                        .symbolRenderingMode(.hierarchical)
                } else {
                    Image(systemName: "info.circle")
                        .font(MidnightMacDesign.FontToken.caption)
                        .foregroundStyle(.secondary)
                }
                Text(profile?.name ?? "Connection Details")
                    .font(MidnightMacDesign.FontToken.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up")
                    .font(MidnightMacDesign.FontToken.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show connection details")
    }

    private func statusSymbol(_ status: PostgresWorkspaceStatus) -> String {
        switch status {
        case .connected:        return "checkmark.circle.fill"
        case .connecting:       return "clock.fill"
        case .error:            return "exclamationmark.circle.fill"
        case .disconnected:     return "circle"
        }
    }

    private func statusColor(_ status: PostgresWorkspaceStatus) -> Color {
        switch status {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .error:        return .red
        case .disconnected: return .secondary.opacity(0.4)
        }
    }
}
