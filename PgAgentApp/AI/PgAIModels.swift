import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// =============================================================================
// Guided-generation output types for the on-device assistant.
//
// `@Generable` requires the FoundationModels SDK (macOS 26 / iOS 26), so each
// type is gated. The plain `PgErrorDiagnosisResult` struct below is the
// SDK-free value the rest of the app passes around — the assistant maps the
// generated type into it, keeping FoundationModels out of the UI layer.
// =============================================================================

/// SDK-free diagnosis the UI binds to. Decoupled from `@Generable` so views,
/// stores, and tests never need the FoundationModels import.
struct PgErrorDiagnosisResult: Equatable, Sendable {
    let diagnosis: String
    let likelyCause: String
    let suggestedFix: String
    /// A corrected query, or `nil` when the model couldn't confidently produce
    /// one. Empty strings from the model are normalized to `nil`.
    let correctedSql: String?
}

/// SDK-free result of a natural-language → SQL generation. The UI binds to this.
struct PgGeneratedSQLResult: Equatable, Sendable {
    let sql: String
    let explanation: String
    /// The tables / views the query references, as reported by the model.
    let tablesUsed: [String]
}

/// SDK-free explanation snapshot the streaming UI binds to. Filled
/// incrementally — `summary` and `points` grow as the model streams.
struct PgExplanationResult: Equatable, Sendable {
    let summary: String
    let points: [String]

    static let empty = PgExplanationResult(summary: "", points: [])
}

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, *)
@Generable(description: "A diagnosis of a failed PostgreSQL statement with a concrete fix")
struct PgErrorDiagnosis {
    @Guide(description: "One sentence, plain English: what went wrong")
    var diagnosis: String

    @Guide(description: "The most likely root cause, referencing the user's SQL or schema when relevant")
    var likelyCause: String

    @Guide(description: "A concrete, actionable fix the user can apply")
    var suggestedFix: String

    @Guide(description: "A corrected version of the SQL if one can be confidently produced; otherwise an empty string")
    var correctedSql: String

    /// Map into the SDK-free value the app uses. Blank corrected SQL → `nil`.
    func toResult() -> PgErrorDiagnosisResult {
        let trimmed = correctedSql.trimmingCharacters(in: .whitespacesAndNewlines)
        return PgErrorDiagnosisResult(
            diagnosis: diagnosis,
            likelyCause: likelyCause,
            suggestedFix: suggestedFix,
            correctedSql: trimmed.isEmpty ? nil : trimmed
        )
    }
}

@available(macOS 26.0, iOS 26.0, *)
@Generable(description: "A PostgreSQL query generated from a natural-language request")
struct PgGeneratedSQL {
    @Guide(description: "A single, valid PostgreSQL statement that fulfils the request. No markdown fences.")
    var sql: String

    @Guide(description: "One or two sentences explaining what the query does")
    var explanation: String

    @Guide(description: "Names of the tables or views the query references")
    var tablesUsed: [String]

    /// Map into the SDK-free value the app uses, stripping any stray markdown
    /// fences the model may have added despite instructions.
    func toResult() -> PgGeneratedSQLResult {
        PgGeneratedSQLResult(
            sql: PgAIContext.stripSQLFences(sql),
            explanation: explanation.trimmingCharacters(in: .whitespacesAndNewlines),
            tablesUsed: tablesUsed
        )
    }
}

@available(macOS 26.0, iOS 26.0, *)
@Generable(description: "A plain-English explanation of a SQL query and/or its results")
struct PgQueryExplanation {
    @Guide(description: "A one or two sentence summary of what the query does and what its results show")
    var summary: String

    @Guide(description: "Three to six short bullet points covering the key steps, filters, joins, or notable patterns in the data")
    var bulletPoints: [String]
}
#endif
