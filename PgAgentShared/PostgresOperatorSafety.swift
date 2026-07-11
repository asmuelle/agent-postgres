import Foundation

enum PostgresExplainMode: Equatable, Sendable {
    case estimated
    case analyze(confirmed: Bool)
}

struct PostgresExplainExecutionPlan: Equatable, Sendable {
    let prelude: [String]
    let explainSQL: String
    let cleanup: String?
    let includesRuntimeMetrics: Bool
}

enum PostgresExplainPolicyError: LocalizedError, Equatable {
    case emptyQuery
    case multipleStatements
    case confirmationRequired
    case analyzeRequiresReadOnlyStatement

    var errorDescription: String? {
        switch self {
        case .emptyQuery:
            return "Enter one SQL statement to explain."
        case .multipleStatements:
            return "Explain accepts exactly one statement. Run statements separately."
        case .confirmationRequired:
            return "EXPLAIN ANALYZE executes the statement and requires explicit confirmation."
        case .analyzeRequiresReadOnlyStatement:
            return "EXPLAIN ANALYZE is limited to statements classified as read-only."
        }
    }
}

enum PostgresExplainPolicy {
    static let statementTimeout = "30s"
    static let lockTimeout = "3s"

    static func plan(
        for sql: String,
        mode: PostgresExplainMode
    ) throws -> PostgresExplainExecutionPlan {
        let statements = PostgresStatementSplitter.split(sql)
        guard !statements.isEmpty else { throw PostgresExplainPolicyError.emptyQuery }
        guard statements.count == 1 else { throw PostgresExplainPolicyError.multipleStatements }
        let statement = statements[0].text

        switch mode {
        case .estimated:
            return PostgresExplainExecutionPlan(
                prelude: [],
                explainSQL: "EXPLAIN (COSTS, VERBOSE, FORMAT JSON) \(statement)",
                cleanup: nil,
                includesRuntimeMetrics: false
            )
        case .analyze(let confirmed):
            guard confirmed else { throw PostgresExplainPolicyError.confirmationRequired }
            guard PostgresStatementClassifier.isReadOnly(statement) else {
                throw PostgresExplainPolicyError.analyzeRequiresReadOnlyStatement
            }
            return PostgresExplainExecutionPlan(
                prelude: [
                    "SET TRANSACTION READ ONLY",
                    "SET LOCAL statement_timeout = '\(statementTimeout)'",
                    "SET LOCAL lock_timeout = '\(lockTimeout)'",
                ],
                explainSQL: "EXPLAIN (ANALYZE, COSTS, VERBOSE, BUFFERS, FORMAT JSON) \(statement)",
                cleanup: "ROLLBACK",
                includesRuntimeMetrics: true
            )
        }
    }
}

enum PostgresSessionAction: String, Sendable {
    case cancel
    case terminate
}

struct PostgresSessionActionChallenge: Equatable, Sendable {
    let action: PostgresSessionAction
    let profileName: String
    let pid: Int32
    let requiredPhrase: String?

    var title: String {
        switch action {
        case .cancel: return "Cancel query on \(profileName)?"
        case .terminate: return "Terminate session on \(profileName)?"
        }
    }

    func accepts(_ input: String) -> Bool {
        guard let requiredPhrase else { return true }
        return input == requiredPhrase
    }
}

enum PostgresSessionActionPolicy {
    static func challenge(
        action: PostgresSessionAction,
        isProduction: Bool,
        profileName: String,
        pid: Int32
    ) -> PostgresSessionActionChallenge {
        let needsPhrase = isProduction || action == .terminate
        let phrase = needsPhrase ? "\(action.rawValue.uppercased()) \(pid)" : nil
        return PostgresSessionActionChallenge(
            action: action,
            profileName: profileName,
            pid: pid,
            requiredPhrase: phrase
        )
    }
}
