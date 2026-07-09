import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// =============================================================================
// Guided-generation output types for the activity-monitor AI analyses.
//
// Same layering as PgAIModels: each `@Generable` type is gated on the
// FoundationModels SDK, and maps into a plain SDK-free result struct that
// views, stores, and tests use without ever importing the framework.
// =============================================================================

/// What Cancel/Terminate action, if any, the model judged safest for a session.
enum PgSessionActionAdvice: String, Equatable, Sendable {
    case cancel
    case terminate
    case none
}

/// SDK-free insight about a single backend session.
struct PgSessionInsightResult: Equatable, Sendable {
    let summary: String
    let points: [String]
    /// Guidance on intervening (or tuning, for long-running queries).
    let advice: String
    /// The safest intervention, normalized; `.none` when leaving it alone is best.
    let saferAction: PgSessionActionAdvice
}

/// SDK-free result of a blocking-chain root-cause analysis.
struct PgBlockingInsightResult: Equatable, Sendable {
    /// PID of the backend the model identified as the root blocker, or `nil`
    /// when it couldn't name one confidently.
    let rootBlockerPid: Int32?
    let explanation: String
    let recommendation: String
}

/// SDK-free digest of an activity snapshot or trend — a headline plus
/// supporting points. Used by both the triage digest and trend narration.
struct PgActivityDigestResult: Equatable, Sendable {
    let headline: String
    let points: [String]
}

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, *)
@Generable(description: "An analysis of one PostgreSQL backend session")
struct PgSessionInsight {
    @Guide(description: "One or two sentences: what this backend is doing and whether it is healthy")
    var summary: String

    @Guide(description: "Two to four short points: why it may be slow or waiting, what it is touching, notable risks")
    var points: [String]

    @Guide(description: "One or two sentences advising whether and how to intervene, including what would be lost")
    var advice: String

    @Guide(description: "The safest intervention: exactly one of cancel, terminate, or none")
    var saferAction: String

    func toResult() -> PgSessionInsightResult {
        PgSessionInsightResult(
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            points: points,
            advice: advice.trimmingCharacters(in: .whitespacesAndNewlines),
            saferAction: PgSessionActionAdvice(
                rawValue: saferAction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ) ?? .none
        )
    }
}

@available(macOS 26.0, iOS 26.0, *)
@Generable(description: "A root-cause analysis of a PostgreSQL lock-blocking chain")
struct PgBlockingInsight {
    @Guide(description: "The pid of the backend at the root of the blocking chain, or 0 if it cannot be determined")
    var rootBlockerPid: Int

    @Guide(description: "Two or three sentences explaining who blocks whom and why, referencing pids and relations")
    var explanation: String

    @Guide(description: "One sentence recommending the single safest action to unblock the chain")
    var recommendation: String

    func toResult() -> PgBlockingInsightResult {
        PgBlockingInsightResult(
            rootBlockerPid: rootBlockerPid > 0 ? Int32(clamping: rootBlockerPid) : nil,
            explanation: explanation.trimmingCharacters(in: .whitespacesAndNewlines),
            recommendation: recommendation.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

@available(macOS 26.0, iOS 26.0, *)
@Generable(description: "A one-glance digest of PostgreSQL instance activity")
struct PgActivityDigest {
    @Guide(description: "One sentence a DBA would want first: the most important thing happening right now")
    var headline: String

    @Guide(description: "Zero to three short supporting points; empty when the headline says it all")
    var points: [String]

    func toResult() -> PgActivityDigestResult {
        PgActivityDigestResult(
            headline: headline.trimmingCharacters(in: .whitespacesAndNewlines),
            points: points
        )
    }
}
#endif
