import OSLog
import PgAgentMacOS
import SwiftUI

// =============================================================================
// PostgresQueryTabView transaction control — explicit BEGIN / COMMIT /
// ROLLBACK driven by the PostgresTransactionBar buttons.
//
// Extracted from PostgresQueryTabView.swift; behavior-preserving.
// =============================================================================

extension PostgresQueryTabView {
    func beginTransaction(tab: PostgresQueryTab) {
        guard let connectionId else { return }
        let sessionId = tab.id.uuidString
        let tabId = tab.id
        Task { @MainActor in
            do {
                try await BridgeManager.shared.pgBegin(connectionId: connectionId, sessionId: sessionId)
                store.setTransactionState(.open, forTab: tabId)
            } catch {
                logger.error("BEGIN failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func commitTransaction(tab: PostgresQueryTab) {
        guard let connectionId else { return }
        let sessionId = tab.id.uuidString
        let tabId = tab.id
        Task { @MainActor in
            do {
                try await BridgeManager.shared.pgCommit(connectionId: connectionId, sessionId: sessionId)
                store.setTransactionState(.none, forTab: tabId)
            } catch {
                logger.error("COMMIT failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func rollbackTransaction(tab: PostgresQueryTab) {
        guard let connectionId else { return }
        let sessionId = tab.id.uuidString
        let tabId = tab.id
        Task { @MainActor in
            do {
                try await BridgeManager.shared.pgRollback(connectionId: connectionId, sessionId: sessionId)
                store.setTransactionState(.none, forTab: tabId)
            } catch {
                // Rollback is the user's escape hatch — never leave the banner
                // stuck. A failure here is almost always a dropped connection,
                // which itself ends the server-side transaction, so clear it.
                logger.error("ROLLBACK failed: \(error.localizedDescription, privacy: .public)")
                store.setTransactionState(.none, forTab: tabId)
            }
        }
    }
}
