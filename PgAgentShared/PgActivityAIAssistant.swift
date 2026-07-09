import Foundation
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

// =============================================================================
// PgActivityAIAssistant — on-device model operations for the activity monitor:
// explain-session, long-running advisor, blocking root-cause, triage digest,
// and trend narration.
//
// Same architecture as PgAIAssistant (query editor AI): callers build compact
// context strings up front (PgActivityAIContext) and the assistant does
// single-shot guided generation — no tools, no schema fetch. The protocol
// seam keeps FoundationModels out of stores and tests.
// =============================================================================

protocol PgActivityAIAssisting: Sendable {
    /// Explain one backend session. `isLongRunning` switches to advisor
    /// instructions (tuning guidance grounded in an EXPLAIN plan when the
    /// context includes one).
    func explainSession(context: String, isLongRunning: Bool) async throws -> PgSessionInsightResult

    /// Name the root blocker in a lock-wait chain and the safest way out.
    func analyzeBlocking(context: String) async throws -> PgBlockingInsightResult

    /// One-glance digest of the current activity snapshot.
    func summarizeActivity(context: String) async throws -> PgActivityDigestResult

    /// Narrate how activity evolved across trend samples.
    func narrateTrend(context: String) async throws -> PgActivityDigestResult
}

/// Builds an assistant. Production uses the resolver's SDK path; tests inject
/// a closure returning a fake.
typealias PgActivityAIAssistantFactory = @Sendable () -> any PgActivityAIAssisting

enum PgActivityAIAssistantResolver {
    /// Resolve a ready assistant, or a user-facing reason it's unavailable.
    static func resolve(
        factory: PgActivityAIAssistantFactory?
    ) -> Result<any PgActivityAIAssisting, PgAIUnavailable> {
        if let factory {
            return .success(factory())
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            return .success(PgActivityAIAssistant())
        } else {
            return .failure(PgAIUnavailable(message: PgAIAvailability.osTooOld.userMessage ?? "On-device AI is unavailable."))
        }
        #else
        return .failure(PgAIUnavailable(message: PgAIAvailability.frameworkMissing.userMessage ?? "On-device AI is unavailable."))
        #endif
    }
}

#if canImport(FoundationModels)

@available(macOS 26.0, iOS 26.0, *)
struct PgActivityAIAssistant: PgActivityAIAssisting {
    private static let logger = Logger(subsystem: "com.mc-ssh", category: "pg-activity-ai")

    private static let explainSessionInstructions = """
    You are a senior PostgreSQL engineer looking at one row of pg_stat_activity
    on a production instance. Explain to an operator what this backend is doing,
    why it may be slow or waiting, and whether intervening is safe.

    Ground every statement in the provided session facts. pg_cancel_backend
    stops only the running statement (recoverable); pg_terminate_backend kills
    the whole connection and rolls back its transaction (destructive). Only
    recommend terminate when cancel cannot help (e.g. idle-in-transaction
    holding locks). When the backend is healthy, say so and advise none.
    """

    private static let advisorInstructions = """
    You are a senior PostgreSQL engineer analyzing a long-running query from
    pg_stat_activity on a production instance. Explain what makes it expensive
    and suggest concrete improvements: indexes to add, rewrites, or LIMIT /
    batching strategies. When an EXPLAIN plan is provided, ground your points
    in its nodes (seq scans, misestimates, sorts). Advise whether cancelling is
    safe; recommend terminate only when cancel cannot help.
    """

    private static let blockingInstructions = """
    You are a senior PostgreSQL engineer untangling a lock-wait chain from
    pg_stat_activity and pg_locks on a production instance. Identify the root
    blocker: the backend that holds what others wait on while waiting on nothing
    itself. Explain the chain plainly, naming pids and relations. Recommend the
    single safest action — usually terminating the root blocker if it is
    idle-in-transaction, or waiting if it is actively progressing.
    """

    private static let digestInstructions = """
    You are a senior PostgreSQL engineer glancing at pg_stat_activity on a
    production instance. Produce the one-sentence status a DBA wants first:
    lead with problems (blocked backends, long-running queries, idle-in-
    transaction pileups); when everything is healthy, say that briefly. Never
    invent numbers — use only the provided facts.
    """

    private static let trendInstructions = """
    You are a senior PostgreSQL engineer reviewing a short time series of
    activity samples from one instance. Describe how load evolved and call out
    anomalies: connection growth, idle-in-transaction accumulation, waiters
    appearing, long-running queries persisting across samples. If the trend is
    flat and healthy, say so briefly. Never invent numbers.
    """

    func explainSession(context: String, isLongRunning: Bool) async throws -> PgSessionInsightResult {
        let session = LanguageModelSession(
            instructions: isLongRunning ? Self.advisorInstructions : Self.explainSessionInstructions
        )
        let response = try await session.respond(to: context, generating: PgSessionInsight.self)
        return response.content.toResult()
    }

    func analyzeBlocking(context: String) async throws -> PgBlockingInsightResult {
        let session = LanguageModelSession(instructions: Self.blockingInstructions)
        let response = try await session.respond(to: context, generating: PgBlockingInsight.self)
        return response.content.toResult()
    }

    func summarizeActivity(context: String) async throws -> PgActivityDigestResult {
        let session = LanguageModelSession(instructions: Self.digestInstructions)
        let response = try await session.respond(to: context, generating: PgActivityDigest.self)
        return response.content.toResult()
    }

    func narrateTrend(context: String) async throws -> PgActivityDigestResult {
        let session = LanguageModelSession(instructions: Self.trendInstructions)
        let response = try await session.respond(to: context, generating: PgActivityDigest.self)
        return response.content.toResult()
    }
}

#endif
