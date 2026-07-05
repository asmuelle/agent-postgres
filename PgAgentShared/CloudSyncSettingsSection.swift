import SwiftUI

// =============================================================================
// CloudSyncSettingsSection — the shared Form sections for opt-in iCloud sync
// (roadmap 2.3). Embedded in macOS Settings → Sync and the iOS settings
// sheet so both platforms present identical semantics: master toggle,
// per-category toggles, status + last-sync line, "Sync Now", and the
// "Remove My Data from iCloud" safety valve.
// =============================================================================
struct CloudSyncSettingsSection: View {
    @ObservedObject private var settings = CloudSyncSettings.shared
    @ObservedObject private var engine = CloudSyncEngine.shared
    @State private var confirmCloudRemoval = false

    var body: some View {
        Section {
            Toggle("Sync via iCloud", isOn: masterBinding)
            if settings.syncEnabled {
                Toggle("Connections", isOn: categoryBinding(\.syncConnections))
                Toggle("Saved queries", isOn: categoryBinding(\.syncSavedQueries))
            }
        } header: {
            Text("iCloud sync")
        } footer: {
            Text("Syncs connection profiles (names, hosts, environment tags, colors — never passwords) and saved queries across your devices through your private iCloud database. Passwords sync only if you enable “Sync password via iCloud Keychain” on a specific connection.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if settings.syncEnabled {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusColor)
                        .frame(width: 18)
                    Text("Status")
                    Spacer(minLength: 16)
                    Text(engine.status.label)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                if let lastSyncAt = engine.lastSyncAt {
                    HStack {
                        Text("Last sync")
                        Spacer()
                        Text(lastSyncAt, format: .dateTime.month().day().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Sync Now") {
                    Task { await engine.syncNow() }
                }
                .disabled(engine.status == .syncing)
            } footer: {
                Text("Turning sync off just stops syncing — nothing is deleted locally or in iCloud.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Remove My Data from iCloud", role: .destructive) {
                    confirmCloudRemoval = true
                }
                .confirmationDialog(
                    "Remove synced data from iCloud?",
                    isPresented: $confirmCloudRemoval,
                    titleVisibility: .visible
                ) {
                    Button("Remove from iCloud", role: .destructive) {
                        Task { await engine.removeCloudData() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Deletes the synced copies of your connection profiles and saved queries from your private iCloud database and turns sync off. Local data on every device stays untouched. Passwords synced via iCloud Keychain are not affected.")
                }
            }
        }
    }

    // MARK: - Bindings

    private var masterBinding: Binding<Bool> {
        Binding(
            get: { settings.syncEnabled },
            set: { enabled in
                guard settings.syncEnabled != enabled else { return }
                settings.syncEnabled = enabled
                engine.masterToggleChanged(enabled: enabled)
            }
        )
    }

    private func categoryBinding(
        _ keyPath: ReferenceWritableKeyPath<CloudSyncSettings, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { enabled in
                guard settings[keyPath: keyPath] != enabled else { return }
                settings[keyPath: keyPath] = enabled
                // Newly enabled category → sync it up; disabled → nothing
                // to do (existing remote copies stay, per the safety rails).
                if enabled {
                    Task { await engine.syncNow() }
                }
            }
        )
    }

    // MARK: - Status presentation

    private var statusSymbol: String {
        switch engine.status {
        case .disabled: return "icloud.slash"
        case .missingEntitlement, .restricted: return "exclamationmark.icloud"
        case .noAccount: return "person.icloud"
        case .temporarilyUnavailable: return "icloud.slash"
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .upToDate: return "checkmark.icloud"
        case .error: return "exclamationmark.icloud"
        }
    }

    private var statusColor: Color {
        switch engine.status {
        case .upToDate: return .green
        case .syncing: return .blue
        case .disabled: return .secondary
        case .noAccount, .temporarilyUnavailable: return .orange
        case .missingEntitlement, .restricted, .error: return .red
        }
    }
}
