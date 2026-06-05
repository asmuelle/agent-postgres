import XCTest
@testable import PgAgentApp

// Behavioural tests for the AI stores using an injected fake assistant. The
// factory seam bypasses FoundationModels entirely, so these run anywhere — they
// cover the store state machines (thinking → result/failed, streaming → done,
// blank-input guard) without needing the on-device model.

private enum TestError: Error { case boom }

private struct FakePgAIAssistant: PgAIAssisting {
    var diagnosis = PgErrorDiagnosisResult(
        diagnosis: "Column does not exist",
        likelyCause: "Typo in column name",
        suggestedFix: "Use the correct column",
        correctedSql: "SELECT id FROM users"
    )
    var generated = PgGeneratedSQLResult(
        sql: "SELECT * FROM users",
        explanation: "Returns all users",
        tablesUsed: ["users"]
    )
    var partials: [PgExplanationResult] = []
    var thrownError: TestError?

    func explainError(sql: String, errorMessage: String) async throws -> PgErrorDiagnosisResult {
        if let thrownError { throw thrownError }
        return diagnosis
    }

    func generateSQL(request: String) async throws -> PgGeneratedSQLResult {
        if let thrownError { throw thrownError }
        return generated
    }

    func streamExplanation(
        sql: String,
        resultSample: String?,
        onPartial: @MainActor @Sendable (PgExplanationResult) -> Void
    ) async throws -> PgExplanationResult {
        if let thrownError { throw thrownError }
        for partial in partials { await onPartial(partial) }
        return partials.last ?? .empty
    }
}

@MainActor
final class PgAIErrorExplainStoreTests: XCTestCase {
    func testSuccessMovesToResult() async {
        let fake = FakePgAIAssistant()
        let store = PgAIErrorExplainStore(makeAssistant: { _, _ in fake })

        await store.explain(
            sql: "SELECT idd FROM users",
            errorMessage: "column \"idd\" does not exist",
            connectionId: "c",
            defaultSchema: "public"
        ).value

        XCTAssertEqual(store.phase, .result(fake.diagnosis))
        XCTAssertTrue(store.isPresented)
        XCTAssertEqual(store.sourceSql, "SELECT idd FROM users")
    }

    func testFailureMovesToFailed() async {
        var fake = FakePgAIAssistant()
        fake.thrownError = .boom
        let store = PgAIErrorExplainStore(makeAssistant: { _, _ in fake })

        await store.explain(sql: "x", errorMessage: "y", connectionId: "c", defaultSchema: "public").value

        guard case .failed = store.phase else {
            return XCTFail("expected .failed, got \(store.phase)")
        }
    }

    func testDismissResets() async {
        let store = PgAIErrorExplainStore(makeAssistant: { _, _ in FakePgAIAssistant() })
        await store.explain(sql: "x", errorMessage: "y", connectionId: "c", defaultSchema: "public").value
        store.dismiss()
        XCTAssertEqual(store.phase, .idle)
        XCTAssertFalse(store.isPresented)
        XCTAssertEqual(store.sourceSql, "")
    }
}

@MainActor
final class PgAINLToSQLStoreTests: XCTestCase {
    func testBlankInputIsNoOp() {
        let store = PgAINLToSQLStore(makeAssistant: { _, _ in FakePgAIAssistant() })
        store.naturalLanguage = "   "
        let task = store.generate(connectionId: "c", defaultSchema: "public")
        XCTAssertNil(task)
        XCTAssertEqual(store.phase, .composing)
    }

    func testValidInputProducesResult() async {
        let fake = FakePgAIAssistant()
        let store = PgAINLToSQLStore(makeAssistant: { _, _ in fake })
        store.naturalLanguage = "all users"

        await store.generate(connectionId: "c", defaultSchema: "public")?.value

        XCTAssertEqual(store.phase, .result(fake.generated))
    }

    func testFailureMovesToFailed() async {
        var fake = FakePgAIAssistant()
        fake.thrownError = .boom
        let store = PgAINLToSQLStore(makeAssistant: { _, _ in fake })
        store.naturalLanguage = "all users"

        await store.generate(connectionId: "c", defaultSchema: "public")?.value

        guard case .failed = store.phase else {
            return XCTFail("expected .failed, got \(store.phase)")
        }
    }
}

@MainActor
final class PgAIExplainStoreTests: XCTestCase {
    func testStreamingEndsAtDoneWithFinalSnapshot() async {
        let p1 = PgExplanationResult(summary: "Counting…", points: [])
        let p2 = PgExplanationResult(summary: "Counts active users.", points: ["filters by status", "groups by day"])
        let fake = FakePgAIAssistant(partials: [p1, p2])
        let store = PgAIExplainStore(makeAssistant: { _, _ in fake })

        await store.explain(
            sql: "SELECT count(*) FROM users",
            resultSample: "count\n42",
            title: "Explain query & results",
            connectionId: "c",
            defaultSchema: "public"
        ).value

        XCTAssertEqual(store.phase, .done(p2))
        XCTAssertEqual(store.title, "Explain query & results")
    }

    func testEmptyStreamStillCompletes() async {
        let store = PgAIExplainStore(makeAssistant: { _, _ in FakePgAIAssistant(partials: []) })
        await store.explain(sql: "SELECT 1", resultSample: nil, title: "T", connectionId: "c", defaultSchema: "public").value
        XCTAssertEqual(store.phase, .done(.empty))
    }

    func testFailureMovesToFailed() async {
        var fake = FakePgAIAssistant()
        fake.thrownError = .boom
        let store = PgAIExplainStore(makeAssistant: { _, _ in fake })
        await store.explain(sql: "SELECT 1", resultSample: nil, title: "T", connectionId: "c", defaultSchema: "public").value
        guard case .failed = store.phase else {
            return XCTFail("expected .failed, got \(store.phase)")
        }
    }
}
