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
/// Layout is an explicit outer `HSplitView` (sidebar | detail). The
/// detail column embeds the unified workspace when a database profile
/// is active, or a premium glassmorphic placeholder when idle.
///
/// `LayoutManager` is the source of truth for which panels are visible
/// and at what size.
struct ContentView: View {
    @EnvironmentObject var layoutManager: LayoutManager
    @StateObject private var connectionStore = ConnectionStoreManager.shared
    @StateObject private var postgresStore = PostgresProfileStore.shared
    @State private var selectedPostgresProfileId: String?
    @State private var selectedNode: PgSchemaNode? = nil
    @State private var activeConnectionId: String? = nil
    @State private var activeSchemaStore: PgSchemaStore? = nil

    var body: some View {
        HSplitView {
            if layoutManager.layout.sidebarVisible {
                SidebarColumn(
                    layoutManager: layoutManager,
                    storeManager: connectionStore,
                    postgresStore: postgresStore,
                    selectedPostgresProfileId: $selectedPostgresProfileId,
                    selectedNode: $selectedNode,
                    activeConnectionId: $activeConnectionId,
                    activeSchemaStore: $activeSchemaStore
                )
            }

            DetailColumn(
                layoutManager: layoutManager,
                selectedPostgresProfileId: $selectedPostgresProfileId,
                selectedNode: $selectedNode,
                activeConnectionId: $activeConnectionId,
                activeSchemaStore: $activeSchemaStore
            )
        }
        .frame(minWidth: 900, minHeight: 600)
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
        .finderSidebarBackground()
        .frame(
            minWidth: LayoutConstants.minSidebarWidth,
            idealWidth: layoutManager.layout.sidebarWidth,
            maxWidth: LayoutConstants.maxSidebarWidth
        )
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: SidebarWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(SidebarWidthKey.self, perform: persistSidebarWidth)
    }

    private func persistSidebarWidth(_ measured: CGFloat) {
        sidebarWidthDebounce?.cancel()
        sidebarWidthDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }

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
        .materialBackground(.contentBackground, blendingMode: .withinWindow)
    }
}

// MARK: - Preference keys for split-pane dimensions

private struct SidebarWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
