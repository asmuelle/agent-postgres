import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// MARK: - Workspace Detail Workspace View
struct MobileProfileWorkspaceView: View {
    let profile: PostgresProfile
    let queryStore: PostgresQueryTabsStore
    var forceRegularMode: Bool

    // Single source of truth for connection + schema state (shared with the
    // Object Explorer sidebar and macOS). No local connection state here.
    @ObservedObject private var connectionManager = PostgresConnectionManager.shared

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // Segment tab state for compact iOS screens
    @State private var compactTabSelected: Int = 1 // 0: Browse, 1: Query, 2: History

    private var connectionId: String? { connectionManager.activeConnections[profile.id] }
    private var schemaStore: PgSchemaStore? { connectionManager.schemaStores[profile.id] }
    private var isConnecting: Bool { connectionManager.isConnecting[profile.id] == true }
    private var connectionError: String? { connectionManager.connectionErrors[profile.id] }

    var body: some View {
        ZStack {
            MidnightColors.canvas.ignoresSafeArea()
            
            if isConnecting {
                connectingOverlay
            } else if let error = connectionError {
                connectionErrorPanel(error)
            } else if connectionId != nil, let store = schemaStore {
                if horizontalSizeClass == .compact && !forceRegularMode {
                    // iPhone Tabbed Workspace
                    VStack(spacing: 0) {
                        compactSectionPicker
                        
                        TabView(selection: $compactTabSelected) {
                            MobileSchemaBrowserView(
                                profile: profile,
                                connectionId: connectionId,
                                schemaStore: store,
                                onOpenNodeTab: { node, details in
                                    let kind = details["kind"] ?? ""
                                    if kind == "relation" {
                                        let schema = details["schema"] ?? ""
                                        let name = details["name"] ?? ""
                                        queryStore.openRelationTab(
                                            schema: schema,
                                            name: name,
                                            relationKind: store.relationDisplayKind(schema: schema, name: name)
                                        )
                                    } else if kind == "properties" {
                                        queryStore.openPropertyTab(node: node)
                                    }
                                    // Smoothly snap to SQL/Properties tab on select
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                        compactTabSelected = 1
                                    }
                                }
                            )
                            .tag(0)
                            
                            MobileQueryWorkspaceView(
                                store: queryStore,
                                connectionId: connectionId,
                                profileId: profile.id,
                                schemaStore: store
                            )
                            .tag(1)
                            
                            MobileConsoleMetricsView(
                                profileId: profile.id,
                                queryStore: queryStore
                            )
                            .tag(2)
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                    }
                } else {
                    // iPadOS/Regular Full screen Query workspace
                    MobileQueryWorkspaceView(
                        store: queryStore,
                        connectionId: connectionId,
                        profileId: profile.id,
                        schemaStore: store
                    )
                }
            } else {
                disconnectedState
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Name + live status only: the workspace connects on appear and
            // releases on disappear, so there is no Connect/Disconnect button.
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(connectionId != nil ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(profile.name)
                        .font(MidnightMobileDesign.FontToken.label)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(connectionId != nil ? "Connected" : "Not connected")
            }
        }
        // Hold a connection claim while this workspace is on screen and release
        // it when it goes away, so navigating off / switching profiles frees
        // the pool once nothing else (e.g. the sidebar) still needs it.
        .task(id: profile.id) {
            // Claim before the first suspension so the release always pairs
            // with it, even when the task is cancelled mid-connect.
            let lease = connectionManager.claim(profile: profile)
            defer { connectionManager.release(lease) }
            await connectionManager.connectIfNeeded(profile: profile)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// Only reachable when something else closed the session (e.g. the
    /// sidebar's context menu) while this workspace stayed on screen.
    private var disconnectedState: some View {
        ContentUnavailableView {
            Label("Not Connected", systemImage: "bolt.horizontal.circle")
        } description: {
            Text(profile.name)
        } actions: {
            Button {
                Task { await connectIfNeeded() }
            } label: {
                Text("Connect").foregroundStyle(MidnightColors.onAccent)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var compactSectionPicker: some View {
        Picker("Section", selection: $compactTabSelected.animation(.snappy)) {
            Text("Browse").tag(0)
            Text("Query").tag(1)
            Text("History").tag(2)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var connectingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting…")
                .font(MidnightMobileDesign.FontToken.headline)
            Text(profile.endpointSummary)
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connectionErrorPanel(_ msg: String) -> some View {
        ContentUnavailableView {
            Label("Can't Connect", systemImage: "exclamationmark.triangle")
        } description: {
            Text(msg)
        } actions: {
            Button {
                Task { await connectIfNeeded() }
            } label: {
                Text("Try Again").foregroundStyle(MidnightColors.onAccent)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // Connection lifecycle is owned entirely by the shared manager — the
    // manager guards against duplicate connects, so the sidebar and this
    // workspace connecting the same profile resolve to one pool + one
    // schema store. `connectIfNeeded` already no-ops when connected, so a
    // stale error simply retries (the manager clears the error on entry).
    private func connectIfNeeded() async {
        await connectionManager.connectIfNeeded(profile: profile)
    }
}

