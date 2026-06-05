import SwiftUI

/// Top-level window for one Postgres profile's schema browser.
///
/// Why a wrapper rather than hosting `PostgresBrowserView` directly in the
/// `WindowGroup`: the window scene resolves a profile *id* (String), not the
/// profile itself, because `for:` only accepts `Hashable & Codable` payloads
/// and we don't want the entire `PostgresProfile` to round-trip through the
/// window restoration plist. The wrapper looks the profile up by id at
/// render time, surfacing a friendly empty state if it has been deleted
/// since the window was last opened.
struct PostgresBrowserWindow: View {
    let profileId: String?
    @ObservedObject var store: PostgresProfileStore

    @State private var connectionId: String? = nil
    @State private var selectedNode: PgSchemaNode? = nil
    @State private var schemaStore: PgSchemaStore? = nil

    var body: some View {
        Group {
            if let id = profileId, let profile = store.profile(withId: id) {
                PostgresWorkspaceView(
                    profile: profile,
                    connectionId: $connectionId,
                    selectedNode: $selectedNode,
                    schemaStore: $schemaStore
                )
            } else {
                missingProfile
            }
        }
        .frame(minWidth: 700, minHeight: 480)
    }

    private var missingProfile: some View {
        VStack(spacing: 10) {
            Image(systemName: "questionmark.folder")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Profile not found")
                .font(.headline)
            Text("This Postgres profile may have been deleted. Close this window and reopen from the sidebar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
