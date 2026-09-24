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
    @Environment(\.dismiss) private var dismiss

    // Segment tab state for compact iOS screens
    @State private var compactTabSelected: Int = 1 // 0: Explorer, 1: Query, 2: Console

    private var connectionId: String? { connectionManager.activeConnections[profile.id] }
    private var schemaStore: PgSchemaStore? { connectionManager.schemaStores[profile.id] }
    private var isConnecting: Bool { connectionManager.isConnecting[profile.id] == true }
    private var connectionError: String? { connectionManager.connectionErrors[profile.id] }

    var body: some View {
        ZStack {
            MidnightColors.primaryBackground.ignoresSafeArea()
            
            if isConnecting {
                connectingOverlay
            } else if let error = connectionError {
                connectionErrorPanel(error)
            } else if connectionId != nil, let store = schemaStore {
                if horizontalSizeClass == .compact && !forceRegularMode {
                    // iPhone Tabbed Workspace
                    VStack(spacing: 0) {
                        customSegmentControl
                        Divider().background(MidnightColors.borderGray)
                        
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
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(connectionId != nil ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(profile.name)
                        .font(MidnightMobileDesign.FontToken.label)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                // Toggle with the live connection state: Disconnect while
                // connected, Connect once closed. Hidden mid-connect.
                if connectionId != nil {
                    Button(action: { Task { await disconnect() } }) {
                        Text("Disconnect")
                            .font(MidnightMobileDesign.FontToken.captionStrong)
                            .foregroundStyle(.red)
                    }
                } else if !isConnecting {
                    Button(action: { Task { await connectIfNeeded() } }) {
                        Text("Connect")
                            .font(MidnightMobileDesign.FontToken.captionStrong)
                            .foregroundStyle(MidnightColors.accentCyan)
                    }
                }
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

    private var disconnectedState: some View {
        VStack(spacing: 20) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 48))
                .foregroundStyle(MidnightColors.borderGray)
            Text("Disconnected")
                .font(MidnightMobileDesign.FontToken.headline)
            Text("The session to \(profile.name) is closed.")
                .font(MidnightMobileDesign.FontToken.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)

            Button(action: {
                Task { await connectIfNeeded() }
            }) {
                Text("Connect")
                    .font(MidnightMobileDesign.FontToken.label)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                    .background(MidnightColors.accentCyan)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // Custom Segmented Pill Control with Premium aesthetics
    private var customSegmentControl: some View {
        HStack(spacing: 4) {
            segmentButton("Explorer", index: 0, icon: "cylinder.split.1x2")
            segmentButton("Query", index: 1, icon: "terminal")
            segmentButton("Console", index: 2, icon: "chart.bar")
        }
        .padding(4)
        .background(Color.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(MidnightColors.borderGray, lineWidth: 1))
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private func segmentButton(_ title: String, index: Int, icon: String) -> some View {
        let isSelected = compactTabSelected == index
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                compactTabSelected = index
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                Text(title)
                    .font(MidnightMobileDesign.FontToken.captionStrong)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(isSelected ? MidnightColors.accentCyan.opacity(0.15) : Color.clear)
            .foregroundStyle(isSelected ? MidnightColors.accentCyan : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
    
    private var connectingOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(MidnightColors.accentCyan)
            Text("Establishing Postgres Session...")
                .font(MidnightMobileDesign.FontToken.label)
                .foregroundStyle(MidnightColors.accentCyan)
            Text("\(profile.user)@\(profile.host)")
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @ViewBuilder
    private func connectionErrorPanel(_ msg: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Connection Failed")
                .font(MidnightMobileDesign.FontToken.headline)
            Text(msg)
                .font(MidnightMobileDesign.FontToken.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            
            HStack(spacing: 16) {
                Button(action: {
                    dismiss()
                }) {
                    Text("Go Back")
                        .font(MidnightMobileDesign.FontToken.label)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                
                Button(action: {
                    Task { await connectIfNeeded() }
                }) {
                    Text("Retry")
                        .font(MidnightMobileDesign.FontToken.label)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(MidnightColors.accentCyan)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // Connection lifecycle is owned entirely by the shared manager — the
    // manager guards against duplicate connects, so the sidebar and this
    // workspace connecting the same profile resolve to one pool + one
    // schema store. `connectIfNeeded` already no-ops when connected, so a
    // stale error simply retries (the manager clears the error on entry).
    private func connectIfNeeded() async {
        await connectionManager.connectIfNeeded(profile: profile)
    }

    private func disconnect() async {
        // Releasing here flips the workspace to `disconnectedState` (Connect
        // button) rather than dismissing — on iPad the workspace lives in the
        // split-view detail pane where `dismiss()` is a no-op — and keeps the
        // Object Explorer sidebar (same manager) in sync automatically.
        await connectionManager.disconnect(profileId: profile.id)
    }
}

