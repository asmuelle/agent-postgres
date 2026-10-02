import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// Database scoping shared by the Query and Browse tabs.
//
// MobileDatabaseScope  — asks for a database while none is current; once one
//                        is, titles the screen with its name and a title menu
//                        to switch databases.
// MobileConnectionGate — connecting / can't-connect states until the current
//                        database's connection is ready, then hands the
//                        content its connection. The connection itself is
//                        claimed (and opened) app-wide by MobileContentView,
//                        so switching tabs never drops it; the gate only
//                        connects when the user asks it to retry.
// =============================================================================

struct MobileDatabaseScope<Content: View>: View {
    @Environment(MobileAppModel.self) private var app
    @EnvironmentObject private var profileStore: PostgresProfileStore
    @ViewBuilder var content: (PostgresProfile) -> Content

    private var currentProfile: PostgresProfile? {
        app.currentProfileId.flatMap { profileStore.profile(withId: $0) }
    }

    var body: some View {
        if let profile = currentProfile {
            content(profile)
                // Fresh view state per database, even when the next one is
                // already connected (tasks keyed on names like "public"
                // wouldn't re-fire otherwise).
                .id(profile.id)
                .navigationTitle(profile.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarTitleMenu { MobileDatabaseMenuItems() }
        } else if profileStore.profiles.isEmpty {
            MobileNoConnectionsView()
        } else {
            MobileChooseDatabaseView()
        }
    }
}

/// Title-menu contents: every connection, the current one checked.
struct MobileDatabaseMenuItems: View {
    @Environment(MobileAppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @EnvironmentObject private var profileStore: PostgresProfileStore

    var body: some View {
        Section {
            ForEach(profileStore.profiles) { profile in
                Button {
                    app.currentProfileId = profile.id
                } label: {
                    if profile.id == app.currentProfileId {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
        }
        Button {
            app.selectedTab = .pulse
        } label: {
            Label("All Databases", systemImage: "square.grid.2x2")
        }
        if supportsMultipleWindows, let current = app.currentProfileId {
            Button {
                openWindow(value: MobileWindowTarget(profileId: current))
            } label: {
                Label("Open in New Window", systemImage: "macwindow.badge.plus")
            }
        }
    }
}

/// Query and Browse before a database is chosen: one tap picks it.
struct MobileChooseDatabaseView: View {
    @Environment(MobileAppModel.self) private var app
    @EnvironmentObject private var profileStore: PostgresProfileStore

    var body: some View {
        List {
            Section {
                ForEach(profileStore.profiles) { profile in
                    Button {
                        app.currentProfileId = profile.id
                    } label: {
                        MobileProfileRowLabel(profile: profile)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Choose a Database")
            }
        }
    }
}

/// Name, environment badge and endpoint — one line of identity for a
/// connection wherever it is listed.
struct MobileProfileRowLabel: View {
    let profile: PostgresProfile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cylinder.split.1x2")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(MidnightMobileDesign.FontToken.label)
                    PostgresEnvironmentBadge(profile: profile, compact: true)
                }
                Text(profile.endpointSummary)
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .midnightMobileMinimumTapTarget()
    }
}

struct MobileConnectionGate<Content: View>: View {
    let profile: PostgresProfile
    @ViewBuilder var content: (_ connectionId: String, _ schemaStore: PgSchemaStore) -> Content

    @Environment(MobileAppModel.self) private var app
    @ObservedObject private var connectionManager = PostgresConnectionManager.shared
    /// Offer a retry if "Connecting…" outlasts this without a connect in
    /// flight (e.g. the connection was closed from elsewhere).
    @State private var offerRetry = false
    private let retryDelay: Duration = .seconds(4)

    var body: some View {
        if let error = connectionManager.connectionErrors[profile.id] {
            failed(error)
        } else if let connectionId = connectionManager.activeConnections[profile.id],
                  let schemaStore = connectionManager.schemaStores[profile.id] {
            content(connectionId, schemaStore)
        } else {
            connecting
        }
    }

    private var connecting: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting…")
                .font(MidnightMobileDesign.FontToken.headline)
            Text(profile.endpointSummary)
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(.secondary)
            if offerRetry, connectionManager.isConnecting[profile.id] != true {
                Button("Try Again", action: retry)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: retryDelay)
            offerRetry = true
        }
    }

    private func retry() {
        Task { await connectionManager.connectIfNeeded(profile: profile) }
    }

    private func failed(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Can't Connect", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button(action: retry) {
                Text("Try Again").foregroundStyle(MidnightColors.onAccent)
            }
            .buttonStyle(.borderedProminent)
            // Most failures are a wrong or missing password, host or port.
            Button("Edit Connection…") {
                app.present(.editConnection(profileId: profile.id))
            }
        }
    }
}
