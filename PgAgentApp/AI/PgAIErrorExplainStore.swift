import Foundation
import OSLog
import SwiftUI

// =============================================================================
// PgAIErrorExplainStore — drives the "Explain this error" sheet.
//
// SDK-free on purpose: the view binds to this without any `@available`
// annotation. The store gates on FoundationModels availability internally and
// only crosses into `PgAIAssistant` when the model is usable.
// =============================================================================

@MainActor
final class PgAIErrorExplainStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case thinking
        case result(PgErrorDiagnosisResult)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var isPresented: Bool = false
    /// The SQL the diagnosis was requested for — kept so the sheet can offer
    /// "Apply fix" relative to the originating tab.
    @Published private(set) var sourceSql: String = ""

    private var task: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.mc-ssh", category: "pg-ai")
    /// Test seam: when set, used instead of the real SDK-backed assistant.
    private let makeAssistant: PgAIAssistantFactory?

    init(makeAssistant: PgAIAssistantFactory? = nil) {
        self.makeAssistant = makeAssistant
    }

    /// Begin a diagnosis. Cancels any in-flight request first. Presents the
    /// sheet immediately and moves the phase from `.thinking` to a terminal
    /// state. Returns the running task so callers (and tests) can await it.
    @discardableResult
    func explain(
        sql: String,
        errorMessage: String,
        connectionId: String,
        defaultSchema: String
    ) -> Task<Void, Never> {
        task?.cancel()
        sourceSql = sql
        phase = .thinking
        isPresented = true

        let t = Task { [weak self] in
            guard let self else { return }
            switch PgAIAssistantResolver.resolve(
                connectionId: connectionId,
                defaultSchema: defaultSchema,
                factory: self.makeAssistant
            ) {
            case .failure(let reason):
                self.phase = .failed(reason.message)
            case .success(let assistant):
                do {
                    let result = try await assistant.explainError(sql: sql, errorMessage: errorMessage)
                    if Task.isCancelled { return }
                    self.phase = .result(result)
                } catch {
                    if Task.isCancelled { return }
                    self.logger.error("AI explain failed: \(error.localizedDescription, privacy: .public)")
                    self.phase = .failed("Couldn't generate an explanation: \(error.localizedDescription)")
                }
            }
        }
        task = t
        return t
    }

    func dismiss() {
        task?.cancel()
        task = nil
        isPresented = false
        phase = .idle
        sourceSql = ""
    }
}
