import Foundation

// =============================================================================
// PulseSummary — the spoken answer to "Check my databases" (Siri, Shortcuts):
// the Pulse tiles' words, problems first, the healthy ones summed up. Pure;
// unit-tested in PgAgentMobileTests.
// =============================================================================
enum PulseSummary {
    static func spoken(_ databases: [(name: String, status: PulseStatus)]) -> String {
        guard !databases.isEmpty else { return "You haven't added a database yet." }

        let healthy = databases.filter { $0.status.tone == .good }
        let problems = databases.filter { $0.status.tone != .good }

        if problems.isEmpty {
            return healthy.count == 1
                ? "\(healthy[0].name) is healthy."
                : "All \(healthy.count) databases are healthy."
        }

        var sentences = problems.map { "\($0.name): \($0.status.title)." }
        switch healthy.count {
        case 0: break
        case 1: sentences.append("\(healthy[0].name) is healthy.")
        default: sentences.append("The other \(healthy.count) are healthy.")
        }
        return sentences.joined(separator: " ")
    }
}
