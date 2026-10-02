import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// MARK: - Connection List View

/// iPhone library: connections grouped by folder, system search, and per-row
/// swipe / context-menu actions. The toolbar and every sheet belong to
/// `MobileContentView`; this view only lists and selects.
struct MobileConnectionListView: View {
    @Binding var selectedProfileId: String?
    let actions: MobileLibraryActions
    var onEditProfile: (PostgresProfile) -> Void

    @EnvironmentObject private var profileStore: PostgresProfileStore
    @ObservedObject private var statusStore = PostgresConnectionStatusStore.shared

    @State private var searchField: String = ""

    /// One list section per folder; unfiled connections lead, without a header.
    private struct FolderSection: Identifiable {
        let folder: String?
        let profiles: [PostgresProfile]
        var id: String { folder ?? "" }
    }

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

    private var sections: [FolderSection] {
        let grouped = Dictionary(grouping: filteredProfiles) { profile -> String? in
            let folder = profile.folderPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return folder.isEmpty ? nil : folder
        }
        let unfiled = grouped[nil].map { [FolderSection(folder: nil, profiles: $0)] } ?? []
        let folders = grouped.keys
            .compactMap { $0 }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { FolderSection(folder: $0, profiles: grouped[$0] ?? []) }
        return unfiled + folders
    }

    var body: some View {
        Group {
            if profileStore.profiles.isEmpty {
                MobileNoConnectionsView(actions: actions)
            } else if filteredProfiles.isEmpty {
                ContentUnavailableView.search(text: searchField)
            } else {
                List {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.profiles) { profile in
                                profileRow(profile)
                            }
                        } header: {
                            if let folder = section.folder {
                                Text(folder)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $searchField, prompt: "Search")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    @ViewBuilder
    private func profileRow(_ profile: PostgresProfile) -> some View {
        let status = statusStore.statusByProfile[profile.id] ?? .disconnected

        Button {
            selectedProfileId = profile.id
        } label: {
            HStack(spacing: 14) {
                Circle()
                    .fill(MidnightMobileDesign.statusColor(status))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(profile.name)
                            .font(MidnightMobileDesign.FontToken.label)
                            .foregroundStyle(.primary)

                        PostgresEnvironmentBadge(profile: profile, compact: true)
                    }
                    Text(profile.endpointSummary)
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .midnightMobileMinimumTapTarget()
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                profileStore.delete(profile)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                onEditProfile(profile)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
        }
        .contextMenu {
            Button {
                onEditProfile(profile)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                let copy = profile.duplicated()
                profileStore.saveOrUpdate(copy)
                onEditProfile(copy)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Divider()
            Button(role: .destructive) {
                profileStore.delete(profile)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
