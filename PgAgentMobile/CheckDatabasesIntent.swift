import AppIntents
import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// CheckDatabasesIntent — "Check my databases" (Siri, Shortcuts, Spotlight):
// the same live check as Pulse, answered in Pulse's words. Runs in the app
// without opening it; needs the device unlocked, since the answer names your
// databases. Never connects for anything but the read-only health probe.
// =============================================================================
struct CheckDatabasesIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Databases"
    static let description = IntentDescription(
        "Checks whether your databases are healthy — the same check as Pulse."
    )
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Database", description: "Leave empty to check them all.")
    var database: DatabaseEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Check \(\.$database)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        BridgeManager.shared.initialize()
        let all = PostgresProfileStore.shared.profiles
        let profiles = database.map { database in all.filter { $0.id == database.id } } ?? all
        let results = await DatabaseHealthCheck.run(profiles, isWholeFleet: database == nil)
        let summary = PulseSummary.spoken(results.map { ($0.name, $0.status) })
        return .result(dialog: "\(summary)", view: CheckDatabasesSnippet(results: results))
    }
}

/// One live Pulse check outside the Pulse screen.
@MainActor
enum DatabaseHealthCheck {
    struct Result: Identifiable {
        let id: String
        let name: String
        let status: PulseStatus
    }

    /// - Parameter isWholeFleet: a check of every database also refreshes
    ///   the widgets and the Control Center control; a single database
    ///   mustn't, or they'd describe only that one.
    static func run(_ profiles: [PostgresProfile], isWholeFleet: Bool) async -> [Result] {
        guard !profiles.isEmpty else { return [] }
        let store = isWholeFleet ? FleetHealthStore.withWidgetPublishing() : FleetHealthStore()
        await store.refresh(profiles: profiles)
        let results = profiles.map { profile in
            Result(
                id: profile.id,
                name: profile.name,
                status: PulseStatus.make(
                    from: store.health(for: profile.id),
                    isProduction: profile.effectiveEnvironment == .production
                )
            )
        }
        await store.shutdown()
        return results
    }
}

/// The answer on screen: one line per database, as on its Pulse tile.
struct CheckDatabasesSnippet: View {
    let results: [DatabaseHealthCheck.Result]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(results) { result in
                HStack(spacing: 10) {
                    Image(systemName: result.status.systemImage)
                        .foregroundStyle(result.status.tone.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.name)
                            .font(.headline)
                        if let detail = result.status.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(result.status.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(result.status.tone.color)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding()
    }
}

extension PulseStatus.Tone {
    var color: Color {
        switch self {
        case .good: return .green
        case .warning: return .orange
        case .critical: return .red
        case .muted: return .secondary
        }
    }
}
