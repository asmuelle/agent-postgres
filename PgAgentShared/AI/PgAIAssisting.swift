import Foundation

// =============================================================================
// PgAIAssisting — SDK-free seam over the on-device assistant.
//
// The concrete `PgAIAssistant` calls the on-device model, which makes the
// stores that drive the UI hard to unit-test (the model isn't available in
// CI). This protocol exposes the same operations in terms of
// SDK-free result types, so:
//   • production resolves the real `PgAIAssistant` via `PgAIAssistantResolver`,
//   • tests inject a fake conforming type through a store's factory.
//
// No FoundationModels import here — tests depend only on this file.
// =============================================================================

protocol PgAIAssisting: Sendable {
    func explainError(sql: String, errorMessage: String) async throws -> PgErrorDiagnosisResult

    func generateSQL(request: String) async throws -> PgGeneratedSQLResult

    func streamExplanation(
        sql: String,
        resultSample: String?,
        onPartial: @MainActor @Sendable (PgExplanationResult) -> Void
    ) async throws -> PgExplanationResult
}

/// Builds an assistant for a given connection. Production uses the default
/// resolver; tests inject a closure returning a fake.
typealias PgAIAssistantFactory = @Sendable (_ connectionId: String, _ defaultSchema: String) -> any PgAIAssisting

enum PgAIAssistantResolver {
    /// Resolve the assistant. When `factory` is non-nil (tests), it wins and
    /// the SDK path is skipped entirely.
    static func resolve(
        connectionId: String,
        defaultSchema: String,
        factory: PgAIAssistantFactory?
    ) -> any PgAIAssisting {
        if let factory {
            return factory(connectionId, defaultSchema)
        }
        return PgAIAssistant(connectionId: connectionId, defaultSchema: defaultSchema)
    }
}
