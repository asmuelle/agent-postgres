import Foundation

// =============================================================================
// PgAIAssisting — SDK-free seam over the on-device assistant.
//
// The concrete `PgAIAssistant` is gated on the FoundationModels SDK, which
// makes the stores that drive the UI hard to unit-test (the model isn't
// available in CI). This protocol exposes the same operations in terms of
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

/// Why no assistant could be resolved, carrying a user-facing message.
struct PgAIUnavailable: Error, Equatable {
    let message: String
}

enum PgAIAssistantResolver {
    /// Resolve a ready assistant, or a user-facing reason it's unavailable.
    /// When `factory` is non-nil (tests), it wins and the SDK path is skipped
    /// entirely. Otherwise the real assistant is created only when the
    /// FoundationModels SDK is present and the OS is new enough.
    static func resolve(
        connectionId: String,
        defaultSchema: String,
        factory: PgAIAssistantFactory?
    ) -> Result<any PgAIAssisting, PgAIUnavailable> {
        if let factory {
            return .success(factory(connectionId, defaultSchema))
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            return .success(PgAIAssistant(connectionId: connectionId, defaultSchema: defaultSchema))
        } else {
            return .failure(PgAIUnavailable(message: PgAIAvailability.osTooOld.userMessage ?? "On-device AI is unavailable."))
        }
        #else
        return .failure(PgAIUnavailable(message: PgAIAvailability.frameworkMissing.userMessage ?? "On-device AI is unavailable."))
        #endif
    }
}
