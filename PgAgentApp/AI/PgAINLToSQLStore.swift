import Foundation
import OSLog
import SwiftUI

// =============================================================================
// PgAINLToSQLStore — drives the "Generate SQL from a description" sheet.
//
// SDK-free like the error-explain store: the view binds to this without any
// `@available` annotation. Availability is gated internally before crossing
// into `PgAIAssistant`. The natural-language prompt is held here so it survives
// a regenerate.
// =============================================================================

@MainActor
final class PgAINLToSQLStore: ObservableObject {
    enum Phase: Equatable {
        case composing
        case thinking
        case result(PgGeneratedSQLResult)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .composing
    @Published var isPresented: Bool = false
    /// The natural-language request, bound to the sheet's text field.
    @Published var naturalLanguage: String = ""

    private var task: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.mc-ssh", category: "pg-ai")
    /// Test seam: when set, used instead of the real SDK-backed assistant.
    private let makeAssistant: PgAIAssistantFactory?

    init(makeAssistant: PgAIAssistantFactory? = nil) {
        self.makeAssistant = makeAssistant
    }

    /// Present a fresh sheet, preserving the previous prompt text so the user
    /// can iterate. Resets any prior result back to the compose state.
    func present() {
        task?.cancel()
        phase = .composing
        isPresented = true
    }

    /// Generate SQL for the current `naturalLanguage`. No-op (returns nil) for
    /// blank input. Returns the running task so tests can await it.
    @discardableResult
    func generate(connectionId: String, defaultSchema: String) -> Task<Void, Never>? {
        let request = naturalLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return nil }

        task?.cancel()
        phase = .thinking

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
                    let result = try await assistant.generateSQL(request: request)
                    if Task.isCancelled { return }
                    self.phase = .result(result)
                } catch {
                    if Task.isCancelled { return }
                    self.logger.error("AI generate SQL failed: \(error.localizedDescription, privacy: .public)")
                    self.phase = .failed("Couldn't generate SQL: \(error.localizedDescription)")
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
        phase = .composing
    }
}
