import Combine
import Foundation

/// Type-safe inner-app event bus. Replaces the loose `NotificationCenter`
/// userInfo dictionaries so the compiler verifies event shapes at each
/// send/receive site.
enum PgAgentEvent: Equatable {
    case connectionStatus(connectionId: String, payload: String)
    case transferProgress(connectionId: String, payload: String)
    case terminalTitleChanged(connectionId: String, title: String)
    case tcpdumpLine(captureId: UInt64, line: String, isStderr: Bool)
    case showCommandPalette
    case showDashboard
}

final class PgAgentEventBus {
    static let shared = PgAgentEventBus()
    let events = PassthroughSubject<PgAgentEvent, Never>()
    private init() {}
}
