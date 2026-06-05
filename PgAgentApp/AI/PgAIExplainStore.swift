import Foundation
import OSLog
import SwiftUI

// =============================================================================
// PgAIExplainStore — drives the streaming "Explain query & results" sheet.
//
// Unlike the other AI stores this one consumes a snapshot stream: each model
// snapshot maps to an SDK-free `PgExplanationResult` and lands in `.streaming`,
// so the UI fills in progressively. SDK-free surface; availability gated inside.
// =============================================================================

@MainActor
final class PgAIExplainStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case streaming(PgExplanationResult)
        case done(PgExplanationResult)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var isPresented: Bool = false
    @Published private(set) var title: String = "Explain"

    private var task: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.mc-ssh", category: "pg-ai")
    /// Test seam: when set, used instead of the real SDK-backed assistant.
    private let makeAssistant: PgAIAssistantFactory?

    init(makeAssistant: PgAIAssistantFactory? = nil) {
        self.makeAssistant = makeAssistant
    }

    /// Stream an explanation of `sql` and, optionally, a textual sample of its
    /// results. Presents the sheet immediately and fills it as snapshots arrive.
    /// Returns the running task so tests can await it.
    @discardableResult
    func explain(
        sql: String,
        resultSample: String?,
        title: String,
        connectionId: String,
        defaultSchema: String
    ) -> Task<Void, Never> {
        task?.cancel()
        self.title = title
        phase = .streaming(.empty)
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
                    let final = try await assistant.streamExplanation(
                        sql: sql,
                        resultSample: resultSample
                    ) { partial in
                        // Invoked on the main actor for each snapshot.
                        self.phase = .streaming(partial)
                    }
                    if Task.isCancelled { return }
                    self.phase = .done(final)
                } catch {
                    if Task.isCancelled { return }
                    self.logger.error("AI explain stream failed: \(error.localizedDescription, privacy: .public)")
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
    }
}
