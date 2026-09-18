import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// MARK: - Connection List View
struct MobileConnectionListView: View {
    @Binding var selectedProfileId: String?
    var onAddProfile: () -> Void
    var onEditProfile: (PostgresProfile) -> Void
    var onShowCSVImport: () -> Void
    var onShowProviderImport: () -> Void
    var onShowProUpgrade: () -> Void
    var onShowMonitor: () -> Void
    var onShowSSHIdentities: () -> Void

    @EnvironmentObject private var profileStore: PostgresProfileStore
    @EnvironmentObject private var entitlementsStore: MobileEntitlementsStore
    @ObservedObject private var statusStore = PostgresConnectionStatusStore.shared
    
    @State private var searchField: String = ""
    
    private var filteredProfiles: [PostgresProfile] {
        let needle = searchField.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if needle.isEmpty {
            return profileStore.profiles
        }
        return profileStore.profiles.filter {
            $0.name.lowercased().contains(needle) ||
            $0.host.lowercased().contains(needle) ||
            $0.database.lowercased().contains(needle)
        }
    }
    
    private var folderGroups: [String: [PostgresProfile]] {
        Dictionary(grouping: filteredProfiles) { profile in
            profile.folderPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? profile.folderPath!
                : "Unfiled Favorites"
        }
    }
    
    var body: some View {
        ZStack {
            MidnightColors.primaryBackground.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Search Bar
                searchBar
                
                if filteredProfiles.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(folderGroups.keys.sorted(), id: \.self) { folderName in
                            Section(header: Text(folderName).font(MidnightMobileDesign.FontToken.label).foregroundStyle(MidnightColors.accentCyan)) {
                                ForEach(folderGroups[folderName] ?? []) { profile in
                                    profileRow(profile)
                                        .listRowBackground(MidnightColors.cardBackground)
                                        .listRowSeparatorTint(MidnightColors.borderGray)
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
                
                // Bottom Pro Upgrade Gating banner
                proGatingBanner
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    Button(action: onShowMonitor) {
                        Label("Fleet Monitor", systemImage: "waveform.path.ecg")
                    }
                    Menu {
                        Button(action: onShowCSVImport) {
                            Label("Import CSV", systemImage: "square.and.arrow.down")
                        }
                        Button(action: onShowProviderImport) {
                            Label("Add from Provider…", systemImage: "cloud")
                        }
                        Divider()
                        Button(action: onShowSSHIdentities) {
                            Label("SSH Identities…", systemImage: "key.horizontal")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    Button(action: onAddProfile) {
                        Label("Add Profile", systemImage: "plus")
                    }
                }
            }
        }
    }
    
    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search hosts or databases...", text: $searchField)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchField.isEmpty {
                Button(action: { searchField = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(MidnightColors.borderGray, lineWidth: 1))
        .padding()
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "cylinder.split.1x2.fill")
                .font(.system(size: 48))
                .foregroundStyle(MidnightColors.borderGray)
            Text("No Database Connections")
                .font(MidnightMobileDesign.FontToken.headline)
            Text("Tap the + button to save your first Postgres profile, or import a CSV profile list.")
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxHeight: .infinity)
    }
    
    @ViewBuilder
    private func profileRow(_ profile: PostgresProfile) -> some View {
        let status = statusStore.statusByProfile[profile.id] ?? .disconnected
        
        Button {
            selectedProfileId = profile.id
        } label: {
            HStack(spacing: 14) {
                // Connection indicator
                Circle()
                    .fill(MidnightMobileDesign.statusColor(status))
                    .frame(width: 8, height: 8)
                    .shadow(color: MidnightMobileDesign.statusColor(status).opacity(0.5), radius: 4)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(profile.name)
                            .font(MidnightMobileDesign.FontToken.label)
                            .foregroundStyle(.primary)

                        PostgresEnvironmentBadge(profile: profile, compact: true)
                    }
                    Text("\(profile.user)@\(profile.host):\(profile.port)/\(profile.database)")
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                
                // Ellipsis settings action
                Menu {
                    Button {
                        onEditProfile(profile)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button {
                        let dup = PostgresProfile(
                            name: "\(profile.name) Copy",
                            host: profile.host,
                            port: profile.port,
                            database: profile.database,
                            user: profile.user,
                            auth: profile.auth,
                            tls: profile.tls,
                            folderPath: profile.folderPath,
                            color: profile.color,
                            notes: profile.notes,
                            environment: profile.environment,
                            isReadOnly: profile.isReadOnly
                        )
                        profileStore.saveOrUpdate(dup)
                    } label: {
                        Label("Duplicate", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        profileStore.delete(profile)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .midnightMobileMinimumTapTarget()
        }
        .buttonStyle(.plain)
    }
    
    private var proGatingBanner: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entitlementsStore.isPro ? "PRO LIFETIME ACTIVE" : "FREE PLAN LIMIT")
                    .font(MidnightMobileDesign.FontToken.captionStrong)
                    .foregroundStyle(entitlementsStore.isPro ? MidnightColors.accentCyan : .orange)
                Text(entitlementsStore.limitSummary)
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !entitlementsStore.isPro {
                Button(action: onShowProUpgrade) {
                    Text("Unlock Pro")
                        .font(MidnightMobileDesign.FontToken.captionStrong)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            LinearGradient(
                                colors: [MidnightColors.accentCyan, MidnightColors.accentPurple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .padding()
        .background(Color.black.opacity(0.3))
        .overlay(Rectangle().stroke(MidnightColors.borderGray, margins: 0))
    }
}

// Custom stroke helper
extension View {
    func stroke(_ color: Color, margins: CGFloat) -> some View {
        overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(color),
            alignment: .top
        )
    }
}

