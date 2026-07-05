import Foundation

/// Platform-neutral state machine behind the "Add from provider…" sheets
/// (macOS and iOS render their own chrome around it). Owns the token
/// (loaded from / saved to the keychain), the fetch lifecycle, and the
/// selection set.
@MainActor
final class ProviderImportModel: ObservableObject {

    enum FetchState {
        case idle
        case loading
        case loaded([ProviderDatabase])
        case failed(String)
    }

    @Published var provider: PostgresProvider {
        didSet {
            guard provider != oldValue else { return }
            token = ProviderTokenStore.load(provider) ?? ""
            state = .idle
            selectedIds = []
        }
    }
    @Published var token: String
    @Published private(set) var state: FetchState = .idle
    @Published var selectedIds: Set<String> = []

    /// Injectable for tests; defaults to the real clients.
    var clientFactory: (PostgresProvider, String) -> any ProviderClient

    init(
        provider: PostgresProvider = .supabase,
        clientFactory: @escaping (PostgresProvider, String) -> any ProviderClient = { provider, token in
            provider.makeClient(token: token)
        }
    ) {
        self.provider = provider
        self.token = ProviderTokenStore.load(provider) ?? ""
        self.clientFactory = clientFactory
    }

    var databases: [ProviderDatabase] {
        if case .loaded(let dbs) = state { return dbs }
        return []
    }

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    var selectedDatabases: [ProviderDatabase] {
        databases.filter { selectedIds.contains($0.id) }
    }

    func toggle(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    /// Fetch the database list. The token is persisted to the keychain
    /// first (so a typo'd token is also what gets stored — matching what
    /// the user sees in the field) and never anywhere else.
    func fetch() async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .failed(ProviderImportError.emptyToken.localizedDescription)
            return
        }
        ProviderTokenStore.save(provider, token: trimmed)
        state = .loading
        selectedIds = []
        do {
            let databases = try await clientFactory(provider, trimmed).listDatabases()
            state = .loaded(databases)
            // Preselect everything not already imported — the common case
            // is "bring my fleet in".
            selectedIds = Set(databases.map(\.id))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Import the current selection; returns a human-readable summary.
    func importSelection(into store: PostgresProfileStore) -> String {
        let result = ProviderProfileImporter.importDatabases(selectedDatabases, into: store)
        var parts = ["Imported \(result.importedCount)."]
        if result.skippedExistingCount > 0 {
            parts.append("\(result.skippedExistingCount) already existed.")
        }
        if !result.needingPassword.isEmpty {
            parts.append("Password needed on first connect: \(result.needingPassword.joined(separator: ", ")).")
        }
        return parts.joined(separator: " ")
    }
}
