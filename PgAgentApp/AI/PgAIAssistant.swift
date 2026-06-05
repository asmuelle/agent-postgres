import Foundation
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

// =============================================================================
// PgAIAssistant — builds on-device model sessions and runs the assistant's
// operations: explain-error, NL→SQL, and streaming explain.
//
// Grounding strategy: a compact schema snapshot is fetched up front
// (PgSchemaContextBuilder) and injected into the prompt — NOT agentic tool
// calls. On-device testing showed the small model loops on tools (re-calling
// describe_table dozens of times until the 4,096-token window overflows with
// `exceededContextWindowSize`). Single-shot generation with injected schema is
// loop-proof and produced correct SQL in testing.
//
// Fully gated on the FoundationModels SDK. Callers reach it only after
// `PgAIAvailabilityProbe.current().isAvailable` is true.
// =============================================================================

#if canImport(FoundationModels)

@available(macOS 26.0, iOS 26.0, *)
struct PgAIAssistant: PgAIAssisting {
    let connectionId: String
    let defaultSchema: String

    private static let logger = Logger(subsystem: "com.mc-ssh", category: "pg-ai")

    /// Conservative input clamps. Combined with the injected schema (~2,200
    /// chars) these keep instructions + prompt + generated output inside the
    /// ~4,096-token window.
    private static let maxSqlChars = 1_500
    private static let maxErrorChars = 1_000
    private static let maxResultSampleChars = 1_500

    private static let diagnoseInstructions = """
    You are a senior PostgreSQL engineer embedded in a database client. A user's
    SQL statement has failed; diagnose it using the schema provided in the prompt.

    Keep every field concise and specific to this user's SQL and schema. Only
    propose a corrected query when you are confident it is valid; otherwise leave
    the corrected SQL empty. Never suggest destructive or data-modifying changes.
    """

    private static let nlToSqlInstructions = """
    You are a senior PostgreSQL engineer embedded in a database client. Convert
    the user's request into a single, valid PostgreSQL statement using only the
    schema provided in the prompt.

    Rules:
    - Produce exactly one statement, no markdown fences, no commentary in the SQL.
    - Use only tables and columns that appear in the provided schema.
    - Prefer a read-only SELECT. Only write/modify data if explicitly asked.
    - Quote identifiers that are mixed-case or reserved.
    - If the request can't be met with the schema, return your best attempt and
      say why in the explanation.
    """

    private static let explainInstructions = """
    You are a senior PostgreSQL engineer embedded in a database client. Explain a
    SQL query (and, when provided, the data it returned) to a developer in clear,
    plain English, using the schema provided in the prompt.

    Be concrete and concise. Reference real table and column names. If a result
    sample is provided, describe what the data shows, not just what the query
    asks for. Do not restate the SQL verbatim.
    """

    private func schemaContext() async -> String {
        await PgSchemaContextBuilder.build(connectionId: connectionId, schema: defaultSchema)
    }

    /// Diagnose a failed statement. Throws if the model session errors.
    func explainError(sql: String, errorMessage: String) async throws -> PgErrorDiagnosisResult {
        let schema = await schemaContext()
        let session = LanguageModelSession(instructions: Self.diagnoseInstructions)

        let prompt = """
        \(schema)

        --- SQL ---
        \(PgAIContext.clamp(sql, maxChars: Self.maxSqlChars))

        --- POSTGRES ERROR ---
        \(PgAIContext.clamp(errorMessage, maxChars: Self.maxErrorChars))

        Diagnose why this failed and how to fix it.
        """

        let response = try await session.respond(to: prompt, generating: PgErrorDiagnosis.self)
        return response.content.toResult()
    }

    /// Generate a SQL statement from a natural-language request.
    func generateSQL(request: String) async throws -> PgGeneratedSQLResult {
        let schema = await schemaContext()
        let session = LanguageModelSession(instructions: Self.nlToSqlInstructions)

        let prompt = """
        \(schema)

        Request:
        \(PgAIContext.clamp(request, maxChars: Self.maxSqlChars))
        """

        let response = try await session.respond(to: prompt, generating: PgGeneratedSQL.self)
        return response.content.toResult()
    }

    /// Stream a plain-English explanation of `sql` and, optionally, a sample of
    /// the rows it returned. `onPartial` is invoked on the main actor for each
    /// snapshot so the UI can render progressively; the final complete value is
    /// also returned.
    @discardableResult
    func streamExplanation(
        sql: String,
        resultSample: String?,
        onPartial: @MainActor @Sendable (PgExplanationResult) -> Void
    ) async throws -> PgExplanationResult {
        let schema = await schemaContext()
        let session = LanguageModelSession(instructions: Self.explainInstructions)

        var prompt = """
        \(schema)

        --- SQL ---
        \(PgAIContext.clamp(sql, maxChars: Self.maxSqlChars))
        """
        if let resultSample, !resultSample.isEmpty {
            prompt += """


            --- RESULT SAMPLE ---
            \(PgAIContext.clamp(resultSample, maxChars: Self.maxResultSampleChars))
            """
        }

        let stream = session.streamResponse(to: prompt, generating: PgQueryExplanation.self)

        var last = PgExplanationResult.empty
        for try await snapshot in stream {
            // Each snapshot is a complete partial state; properties are optional
            // until generated.
            let partial = snapshot.content
            last = PgExplanationResult(
                summary: partial.summary ?? "",
                points: partial.bulletPoints ?? []
            )
            await onPartial(last)
        }
        return last
    }
}

#endif
