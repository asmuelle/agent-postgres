import AppKit
import SwiftUI
import Combine
import PgAgentMacOS

/// Native macOS database workspace.
///
///   ┌────────────────┬───────────────────┐
///   │ Connections    │                   │
///   │ (Postgres)     │                   │
///   ├────────────────│ Postgres          │
///   │                │ Workspace         │
///   │ Connection     │ (Tabbed Editors   │
///   │ Details        │  & Results)       │
///   │                │                   │
///   └────────────────┴───────────────────┘
///
/// Layout is a two-column `NavigationSplitView` (sidebar | detail), so
/// the sidebar gets the system sidebar material — the floating Liquid
/// Glass sidebar on macOS 26+ with the toolbar extending over it — plus
/// the standard toolbar toggle and View ▸ Sidebar commands. The detail
/// column embeds the unified workspace when a database profile is
/// active, or a placeholder when idle.
///
/// `LayoutManager` is the source of truth for sidebar visibility and
/// width; the split view's column visibility is bound to it so the
/// toolbar toggle, ⌃⌘S and ⌘B all persist the same state.
struct ContentView: View {
    @EnvironmentObject var layoutManager: LayoutManager
    @StateObject private var connectionStore = ConnectionStoreManager.shared
    @StateObject private var postgresStore = PostgresProfileStore.shared
    @State private var selectedPostgresProfileId: String?
    @State private var selectedNode: PgSchemaNode? = nil
    @State private var activeConnectionId: String? = nil
    @State private var activeSchemaStore: PgSchemaStore? = nil
    /// ⌘K command palette. Items are snapshotted when the palette opens —
    /// cheap reads of already-loaded stores, rebuilt on every open so the
    /// list always reflects current connections/tables/saved queries.
    @State private var isCommandPaletteVisible = false
    @State private var commandPaletteItems: [CommandPaletteItem] = []

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarColumn(
                layoutManager: layoutManager,
                storeManager: connectionStore,
                postgresStore: postgresStore,
                selectedPostgresProfileId: $selectedPostgresProfileId,
                selectedNode: $selectedNode,
                activeConnectionId: $activeConnectionId,
                activeSchemaStore: $activeSchemaStore
            )
        } detail: {
            DetailColumn(
                layoutManager: layoutManager,
                selectedPostgresProfileId: $selectedPostgresProfileId,
                selectedNode: $selectedNode,
                activeConnectionId: $activeConnectionId,
                activeSchemaStore: $activeSchemaStore
            )
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 600)
        .overlay {
            if isCommandPaletteVisible {
                commandPaletteOverlay
            }
        }
        // The bus also carries Rust-callback events emitted on background
        // threads; filter there and hop to main so SwiftUI only ever sees
        // main-thread deliveries.
        .onReceive(
            PgAgentEventBus.shared.events
                .filter { @Sendable event in event == .showCommandPalette }
                .receive(on: DispatchQueue.main)
        ) { _ in
            toggleCommandPalette()
        }
        .registersSettingsOpener()
        .onOpenURL { url in
            applyDeepLink(PgAgentDeepLink(url: url))
        }
    }

    /// Maps the persisted `sidebarVisible` flag onto the split view.
    /// Writes are equality-guarded so the split view echoing the current
    /// value back doesn't re-publish (and re-save) the layout.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { layoutManager.layout.sidebarVisible ? .all : .detailOnly },
            set: { visibility in
                let visible = visibility != .detailOnly
                guard layoutManager.layout.sidebarVisible != visible else { return }
                layoutManager.layout.sidebarVisible = visible
            }
        )
    }

    // MARK: - Deep links (pgAgent://)

    /// Route a `pgAgent://` URL (widget tap, alert, Live Activity) onto the
    /// existing navigation state. Unknown profiles/URLs only activate the app.
    private func applyDeepLink(_ link: PgAgentDeepLink) {
        NSApp.activateFromUserAction()
        switch link {
        case .monitoring(let profileId), .profile(let profileId):
            guard postgresStore.profile(withId: profileId) != nil else { return }
            if selectedPostgresProfileId != profileId {
                selectedPostgresProfileId = profileId
                selectedNode = nil
            }
        case .monitoringOverview:
            // The fleet overview on macOS is the Monitoring Hub pane.
            SettingsWindowOpener.shared.open(tab: .monitoringHub)
        case .activate:
            break
        }
    }

    // MARK: - Command palette

    private var commandPaletteOverlay: some View {
        ZStack(alignment: .top) {
            // Dim + click-away scrim behind the panel.
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { isCommandPaletteVisible = false }
            CommandPaletteView(
                items: commandPaletteItems,
                onDismiss: { isCommandPaletteVisible = false }
            )
            .padding(.top, 88)
        }
        .transition(.opacity)
    }

    private func toggleCommandPalette() {
        if isCommandPaletteVisible {
            isCommandPaletteVisible = false
            return
        }
        commandPaletteItems = CommandPaletteItems.build(
            selectedProfileId: selectedPostgresProfileId,
            selectProfile: { profile in
                selectedPostgresProfileId = profile.id
                selectedNode = nil
            },
            openSettings: { tab in
                SettingsWindowOpener.shared.open(tab: tab)
            }
        )
        isCommandPaletteVisible = true
    }
}

// MARK: - Sidebar column

private struct SidebarColumn: View {
    @ObservedObject var layoutManager: LayoutManager
    @ObservedObject var storeManager: ConnectionStoreManager
    @ObservedObject var postgresStore: PostgresProfileStore
    @Binding var selectedPostgresProfileId: String?
    @Binding var selectedNode: PgSchemaNode?
    @Binding var activeConnectionId: String?
    @Binding var activeSchemaStore: PgSchemaStore?
    @State private var sidebarWidthDebounce: Task<Void, Never>?

    var body: some View {
        SidebarView(
            storeManager: storeManager,
            postgresStore: postgresStore,
            selectedPostgresProfileId: $selectedPostgresProfileId,
            selectedNode: $selectedNode,
            activeConnectionId: $activeConnectionId,
            activeSchemaStore: $activeSchemaStore
        )
        // No custom background: the split view's sidebar column supplies
        // the system material (Liquid Glass on macOS 26+), which adapts to
        // light/dark and the desktop behind the window.
        .navigationSplitViewColumnWidth(
            min: LayoutConstants.minSidebarWidth,
            // The zen preset stores width 0; never hand the split view
            // an ideal below the column minimum.
            ideal: min(
                max(layoutManager.layout.sidebarWidth, LayoutConstants.minSidebarWidth),
                LayoutConstants.maxSidebarWidth
            ),
            max: LayoutConstants.maxSidebarWidth
        )
        // Measured directly rather than via a PreferenceKey: the split view
        // hosts each column separately, so a preference raised inside the
        // sidebar never updates past its initial default value.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            persistSidebarWidth(width)
        }
    }

    private func persistSidebarWidth(_ measured: CGFloat) {
        sidebarWidthDebounce?.cancel()
        sidebarWidthDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            // The column stays mounted while collapsed (unlike the old
            // `if`-gated HSplitView pane), so ignore widths measured while
            // hidden or mid-collapse — they'd clobber the saved width.
            guard layoutManager.layout.sidebarVisible,
                  measured >= LayoutConstants.minSidebarWidth - 1 else { return }

            let clamped = min(
                max(measured, LayoutConstants.minSidebarWidth),
                LayoutConstants.maxSidebarWidth
            )
            if abs(clamped - layoutManager.layout.sidebarWidth) > 1 {
                layoutManager.layout.sidebarWidth = clamped
            }
        }
    }
}

// MARK: - Detail column

private struct DetailColumn: View {
    @ObservedObject var layoutManager: LayoutManager
    @Binding var selectedPostgresProfileId: String?
    @Binding var selectedNode: PgSchemaNode?
    @Binding var activeConnectionId: String?
    @Binding var activeSchemaStore: PgSchemaStore?

    private var selectedPostgresProfile: PostgresProfile? {
        guard let id = selectedPostgresProfileId else { return nil }
        return PostgresProfileStore.shared.profile(withId: id)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let profile = selectedPostgresProfile {
                PostgresWorkspaceView(
                    profile: profile,
                    connectionId: $activeConnectionId,
                    selectedNode: $selectedNode,
                    schemaStore: $activeSchemaStore
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DatabasePlaceholderView()
            }
        }
    }
}

// MARK: - Placeholder View

struct DatabasePlaceholderView: View {
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.15), Color.purple.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)
                    .blur(radius: 10)

                Image(systemName: "cylinder.split.1x2.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.accentColor, Color.purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .padding(.bottom, 10)

            Text("pgAgent")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            Text("Select a database profile from the sidebar to connect and start querying.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .padding(.horizontal, 20)

            Text("Premium Single-Window Workspace")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color.secondary.opacity(0.1))
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
