// Tests for the schema-aware SQL completion engine — context detection
// (FROM/JOIN/WHERE/INSERT/qualifier), alias resolution, ranking, quoting,
// and suppression inside literals/comments. All pure: a fixed catalog in,
// ranked completions out.

import XCTest

@testable import PgAgentApp

final class SQLCompletionEngineTests: XCTestCase {

    // Catalog: public.users(id, email, name), public."Order Items"(id, qty),
    // app.events(id, kind), app.users(id, tenant) — plus an unloaded-columns
    // relation public.empty_cols.
    private let catalog = SQLCompletionCatalog(
        schemas: ["public", "app"],
        relations: [
            .init(schema: "public", name: "users", isView: false,
                  columns: ["id", "email", "name"]),
            .init(schema: "public", name: "Order Items", isView: false,
                  columns: ["id", "qty"]),
            .init(schema: "public", name: "empty_cols", isView: false, columns: []),
            .init(schema: "app", name: "events", isView: true,
                  columns: ["id", "kind"]),
            .init(schema: "app", name: "users", isView: false,
                  columns: ["id", "tenant"]),
        ],
        searchPath: ["public"]
    )

    private func complete(_ sql: String, cursor: Int? = nil) -> SQLCompletionResult {
        SQLCompletionEngine.complete(
            sql: sql,
            cursorUTF16: cursor ?? sql.utf16.count,
            catalog: catalog
        )
    }

    private func inserts(_ sql: String, cursor: Int? = nil) -> [String] {
        complete(sql, cursor: cursor).items.map(\.insertText)
    }

    // MARK: - Relation contexts

    func testFromSuggestsMatchingTables() {
        let out = inserts("SELECT * FROM us")
        XCTAssertTrue(out.contains("users"), "prefix `us` should offer public.users, got \(out)")
        XCTAssertTrue(out.contains("app.users"), "foreign-schema match inserts qualified")
        XCTAssertFalse(out.contains("app.events"), "`us` must not match events")
    }

    func testFromRanksSearchPathFirst() {
        let out = inserts("SELECT * FROM users u JOIN us")
        guard let bare = out.firstIndex(of: "users"),
              let qualified = out.firstIndex(of: "app.users")
        else {
            return XCTFail("both users relations expected, got \(out)")
        }
        XCTAssertLessThan(bare, qualified, "search-path relation must rank first")
    }

    func testInsertIntoSuggestsTables() {
        let out = inserts("INSERT INTO ev")
        XCTAssertEqual(out.first, "app.events")
    }

    func testJoinSuggestsTablesAndViews() {
        let out = inserts("SELECT * FROM users u JOIN eve")
        XCTAssertTrue(out.contains("app.events"), "views complete after JOIN, got \(out)")
    }

    // MARK: - Qualifier (dot) contexts

    func testAliasDotSuggestsColumnsUsingFromClauseAfterCursor() {
        // Cursor right after `u.` — the FROM clause lives *after* the cursor.
        let sql = "SELECT u. FROM users u"
        let out = inserts(sql, cursor: 9)
        XCTAssertEqual(out, ["email", "id", "name"])
    }

    func testJoinAliasDotResolvesToJoinedRelation() {
        let sql = "SELECT * FROM users u JOIN app.events e ON e."
        XCTAssertEqual(inserts(sql), ["id", "kind"])
    }

    func testTableNameDotWithoutAliasResolves() {
        let sql = "SELECT * FROM users WHERE users."
        XCTAssertEqual(inserts(sql), ["email", "id", "name"])
    }

    func testSchemaDotSuggestsThatSchemasRelations() {
        let out = inserts("SELECT * FROM app.")
        XCTAssertEqual(out.sorted(), ["events", "users"])
    }

    func testSchemaQualifiedTableDotSuggestsColumns() {
        let sql = "SELECT app.users. FROM app.users"
        XCTAssertEqual(inserts(sql, cursor: 17), ["id", "tenant"])
    }

    func testQualifierPrefixFiltersColumns() {
        let sql = "SELECT * FROM users u WHERE u.em"
        XCTAssertEqual(inserts(sql), ["email"])
    }

    // MARK: - Column contexts

    func testWhereSuggestsInScopeColumns() {
        let out = inserts("SELECT * FROM users u WHERE ema")
        XCTAssertEqual(out.first, "email")
    }

    func testAmbiguousColumnsInsertAliasQualified() {
        let sql = "SELECT * FROM users u JOIN app.events e ON i"
        let out = inserts(sql)
        XCTAssertTrue(out.contains("u.id"), "ambiguous `id` must qualify, got \(out)")
        XCTAssertTrue(out.contains("e.id"), "ambiguous `id` must qualify, got \(out)")
        XCTAssertFalse(out.contains("id"), "bare ambiguous column must not be offered")
    }

    func testUpdateSetSuggestsTargetColumns() {
        let out = inserts("UPDATE users SET ema")
        XCTAssertEqual(out.first, "email")
    }

    func testInsertColumnListSuggestsTargetColumns() {
        let out = inserts("INSERT INTO users (")
        XCTAssertEqual(out, ["email", "id", "name"])
    }

    func testColumnContextIncludesFunctionsAndKeywords() {
        let out = inserts("SELECT cou")
        XCTAssertTrue(out.contains("count"), "functions complete in column context, got \(out)")
        let kw = inserts("SELECT id FROM users WHERE id = 1 OR")
        XCTAssertFalse(kw.isEmpty)
    }

    // MARK: - Case-insensitivity & quoting

    func testMatchingIsCaseInsensitive() {
        let out = inserts("select * from users u where u.EM")
        XCTAssertEqual(out, ["email"])
    }

    func testMixedCaseIdentifierInsertsQuoted() {
        let out = inserts("SELECT * FROM ord")
        XCTAssertTrue(out.contains("\"Order Items\""), "mixed-case name must quote, got \(out)")
    }

    func testReservedWordColumnInsertsQuoted() {
        let reserved = SQLCompletionCatalog(
            schemas: ["public"],
            relations: [.init(schema: "public", name: "t", isView: false, columns: ["user", "plain"])]
        )
        let out = SQLCompletionEngine.complete(
            sql: "SELECT * FROM t WHERE t.",
            cursorUTF16: 24,
            catalog: reserved
        ).items.map(\.insertText)
        XCTAssertEqual(out, ["plain", "\"user\""])
    }

    func testKeywordsInsertUppercase() {
        let out = inserts("sel")
        XCTAssertEqual(out.first, "SELECT")
    }

    // MARK: - Suppression

    func testNoCompletionInsideStringLiteral() {
        XCTAssertTrue(inserts("SELECT 'us").isEmpty)
        XCTAssertTrue(inserts("SELECT 'a''us").isEmpty, "'' escape must not close the literal")
    }

    func testCompletionResumesAfterClosedStringLiteral() {
        let out = inserts("SELECT 'x' FROM us")
        XCTAssertTrue(out.contains("users"))
    }

    func testNoCompletionInsideLineComment() {
        XCTAssertTrue(inserts("SELECT 1 -- from us").isEmpty)
    }

    func testNoCompletionInsideBlockComment() {
        XCTAssertTrue(inserts("SELECT 1 /* from us").isEmpty)
        XCTAssertTrue(inserts("SELECT 1 /* x */ FROM us").contains("users"))
    }

    func testNoCompletionInsideDollarQuotedString() {
        XCTAssertTrue(inserts("SELECT $body$ from us").isEmpty)
    }

    // MARK: - Prefetch reporting & fallback

    func testReportsRelationsNeedingColumns() {
        let result = complete("SELECT * FROM empty_cols e WHERE e.")
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.relationsNeedingColumns.map(\.name), ["empty_cols"])
    }

    func testBareContextOffersKeywordsSchemasAndTables() {
        let out = inserts("us")
        XCTAssertTrue(out.contains("USER"), "keyword fallback expected, got \(out)")
        XCTAssertTrue(out.contains("users"), "tables offered in bare context")
    }

    func testCastSuggestsTypes() {
        let out = inserts("SELECT id::time")
        XCTAssertTrue(out.contains("timestamp"), "types complete after ::, got \(out)")
        XCTAssertFalse(out.contains("users"))
    }

    func testStatementIsolationAcrossSemicolons() {
        // Aliases from a previous statement must not leak into this one.
        let sql = "SELECT * FROM users u; SELECT * FROM app.events e WHERE e."
        XCTAssertEqual(inserts(sql), ["id", "kind"])
    }
}
