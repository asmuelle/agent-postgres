import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// MobilePulseView — the home tab. Answers "is my database OK?" for every
// saved connection: one tile each, led by a single status word (PulseStatus).
// Tap a tile for its Activity / Locks / Maintenance; long-press to open it in
// Query or Browse, edit, duplicate or delete. It is also where connections
// are added — Pulse is the library.
//
// Polls with FleetHealthStore's dedicated probe connections while visible and
// closes them when the tab goes away. Consumes alert deep links by pushing
// the alerted instance's detail on the matching tab.
// =============================================================================
struct MobilePulseView: View {
    @Environment(MobileAppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @EnvironmentObject private var profileStore: PostgresProfileStore
    @EnvironmentObject private var entitlementsStore: MobileEntitlementsStore
    @StateObject private var store = FleetHealthStore.withWidgetPublishing()
    @State private var path: [PulseRoute] = []
    @State private var pendingDelete: PostgresProfile?

    private static let refreshInterval: Duration = .seconds(5)
    private static let tileMinimumWidth: CGFloat = 280

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if profileStore.profiles.isEmpty {
                    MobileNoConnectionsView()
                } else {
                    tiles
                }
            }
            .background(MidnightColors.primaryBackground)
            .navigationTitle("Pulse")
            .toolbar { MobileLibraryToolbar(app: app, isPro: entitlementsStore.isPro) }
            .navigationDestination(for: PulseRoute.self) { route in
                destination(for: route)
            }
            .confirmationDialog(
                "Delete \(pendingDelete?.name ?? "Connection")?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { profile in
                Button("Delete", role: .destructive) {
                    profileStore.delete(profile)
                }
            } message: { _ in
                Text("Its saved password, query history and saved queries are removed from this device.")
            }
        }
        // Tapped-alert deep link (Mac-hub push or local background alert)
        // this window claimed (MobileContentView): land on the alerted
        // instance, on the tab matching the alert kind. `initial: true`
        // consumes a route set before this view existed.
        .onChange(of: app.alertRoute, initial: true) { _, route in
            guard let route else { return }
            app.alertRoute = nil
            guard route.kind != .unreachable else {
                path = [] // the tile already shows why it's unreachable
                return
            }
            path = [PulseRoute(
                profileId: route.instanceId,
                // Unknown kind (old hub / truncated push): default to Activity.
                alertKind: route.kind ?? .longRunning,
                blockerPid: route.blockerPid
            )]
        }
        .task {
            while !Task.isCancelled {
                await store.refresh(profiles: profileStore.profiles)
                try? await Task.sleep(for: Self.refreshInterval)
            }
            // Left the tab: close the probe connections until we're back.
            await store.shutdown()
        }
    }

    private var tiles: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Self.tileMinimumWidth), spacing: 16, alignment: .top)],
                spacing: 16
            ) {
                ForEach(profileStore.profiles) { profile in
                    NavigationLink(value: PulseRoute(profileId: profile.id)) {
                        PulseTile(
                            profile: profile,
                            status: PulseStatus.make(
                                from: store.health(for: profile.id),
                                isProduction: profile.effectiveEnvironment == .production
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu { tileMenu(for: profile) }
                    .accessibilityAction(named: "Open in Query") {
                        app.open(profileId: profile.id, in: .query)
                    }
                    .accessibilityAction(named: "Browse") {
                        app.open(profileId: profile.id, in: .browse)
                    }
                    .accessibilityAction(named: "Edit") {
                        app.present(.editConnection(profileId: profile.id))
                    }
                }
            }
            .padding()
        }
        .refreshable {
            await store.refresh(profiles: profileStore.profiles)
        }
    }

    @ViewBuilder
    private func tileMenu(for profile: PostgresProfile) -> some View {
        Section {
            Button {
                app.open(profileId: profile.id, in: .query)
            } label: {
                Label("Open in Query", systemImage: "terminal")
            }
            Button {
                app.open(profileId: profile.id, in: .browse)
            } label: {
                Label("Browse", systemImage: "square.stack.3d.up")
            }
            if supportsMultipleWindows {
                Button {
                    openWindow(value: MobileWindowTarget(profileId: profile.id))
                } label: {
                    Label("Open in New Window", systemImage: "macwindow.badge.plus")
                }
            }
        }
        Section {
            Button {
                app.present(.editConnection(profileId: profile.id))
            } label: {
                Label("Edit…", systemImage: "pencil")
            }
            Button {
                // The password is keyed by profile id and doesn't carry over,
                // so open the editor on the copy right away.
                let copy = profile.duplicated()
                profileStore.saveOrUpdate(copy)
                app.present(.editConnection(profileId: copy.id))
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
        }
        Button(role: .destructive) {
            pendingDelete = profile
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func destination(for route: PulseRoute) -> some View {
        if let profile = profileStore.profile(withId: route.profileId) {
            MobileInstanceDetailView(
                profile: profile,
                alertKind: route.alertKind,
                alertBlockerPid: route.blockerPid
            )
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        app.open(profileId: profile.id, in: .query)
                    } label: {
                        Label("Open in Query", systemImage: "terminal")
                    }
                }
            }
        } else {
            ContentUnavailableView("Connection Removed", systemImage: "cylinder.split.1x2")
        }
    }
}

/// Navigation value for an instance's detail. Alert fields pick the opening
/// tab (blocked locks → Locks, with the blocker highlighted).
struct PulseRoute: Hashable {
    let profileId: String
    var alertKind: FleetAlertKind? = nil
    var blockerPid: Int32? = nil
}

// MARK: - Tile

private struct PulseTile: View {
    let profile: PostgresProfile
    let status: PulseStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(profile.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                PostgresEnvironmentBadge(profile: profile, compact: true)
            }

            Label(status.title, systemImage: status.systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(toneColor)
                .lineLimit(2)

            VStack(alignment: .leading, spacing: 2) {
                if let detail = status.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(profile.endpointSummary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(MidnightColors.cardBackground, in: .rect(cornerRadius: 20))
        .contentShape(.rect(cornerRadius: 20))
        .hoverEffect(.highlight)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows activity, locks and maintenance")
    }

    private var toneColor: Color {
        status.tone.color
    }
}
