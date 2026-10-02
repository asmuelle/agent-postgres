import AppIntents
import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// CheckDatabasesIntent — "Check my databases" (Siri, Shortcuts, Spotlight):
// the same live check as Pulse, answered in Pulse's words. Runs in the app
// without opening it. Since the answer names your databases it needs the
// device unlocked AND pgAgent's own lock open (MobileAppLock). Never connects
// for anything but the read-only health probe, and answers within a deadline.
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
        guard !MobileAppLock.shared.isEngaged() else { throw CheckDatabasesError.appLocked }
        BridgeManager.shared.initialize()
        let all = PostgresProfileStore.shared.profiles
        let profiles = database.map { database in all.filter { $0.id == database.id } } ?? all
        if database != nil, profiles.isEmpty { throw CheckDatabasesError.databaseNotFound }
        let results = await DatabaseHealthCheck.run(profiles, isWholeFleet: database == nil)
        let summary = PulseSummary.spoken(results.map { ($0.name, $0.status) })
        return .result(dialog: "\(summary)", view: CheckDatabasesSnippet(results: results))
    }
}

enum CheckDatabasesError: Error, CustomLocalizedStringResourceConvertible {
    case appLocked
    case databaseNotFound

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appLocked: return "pgAgent is locked. Open it and unlock it first."
        case .databaseNotFound: return "That database isn't in pgAgent anymore."
        }
    }
}

/// One live Pulse check outside the Pulse screen.
@MainActor
enum DatabaseHealthCheck {
    /// Background intents get about 30 seconds; answer well inside that.
    /// Databases still unanswered by then say so ("No Answer").
    static let deadline: Duration = .seconds(20)

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
        let refresh = Task { await store.refresh(profiles: profiles) }
        let finished = await finishes(refresh, within: deadline)
        let results = profiles.map { profile in
            let health = store.health(for: profile.id)
            let status = !finished && health.lastUpdated == nil
                ? PulseStatus.noAnswer
                : PulseStatus.make(from: health, isProduction: profile.effectiveEnvironment == .production)
            return Result(id: profile.id, name: profile.name, status: status)
        }
        if finished {
            await store.shutdown()
        } else {
            // Shutdown queues behind the hung refresh — don't wait for it.
            refresh.cancel()
            Task { await store.shutdown() }
        }
        return results
    }

    /// Whether `task` finishes within `limit`; doesn't wait any longer.
    private static func finishes(_ task: Task<Void, Never>, within limit: Duration) async -> Bool {
        let outcome = Outcome()
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                await task.value
                outcome.resolve(true, continuation)
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                outcome.resolve(false, continuation)
            }
        }
    }

    /// Resumes the race's continuation once, with whichever side wins.
    @MainActor
    private final class Outcome {
        private var isResolved = false

        func resolve(_ finished: Bool, _ continuation: CheckedContinuation<Bool, Never>) {
            guard !isResolved else { return }
            isResolved = true
            continuation.resume(returning: finished)
        }
    }
}

/// The answer on screen: one line per database — name and verdict only.
/// The tile's detail line is left out: connection errors can name the host
/// and user, which nothing outside the app shows.
struct CheckDatabasesSnippet: View {
    private static let maxRows = 8

    let results: [DatabaseHealthCheck.Result]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(results.prefix(Self.maxRows)) { result in
                HStack(spacing: 10) {
                    Image(systemName: result.status.systemImage)
                        .foregroundStyle(result.status.tone.color)
                    Text(result.name)
                        .font(.headline)
                    Spacer(minLength: 8)
                    Text(result.status.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(result.status.tone.color)
                }
                .accessibilityElement(children: .combine)
            }
            if results.count > Self.maxRows {
                Text("and \(results.count - Self.maxRows) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
