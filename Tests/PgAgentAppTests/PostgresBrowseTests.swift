// Tests for server-side browse state: SQL generation (ORDER BY /
// LIMIT / OFFSET), sort cycling, page moves, and the tab store's
// browse behaviors (dedupe, auto-run consumption, hasNextPage).

import XCTest
@testable import PgAgentApp

final class PostgresBrowseStateTests: XCTestCase {

    private func makeState(
        schema: String = "public",
        table: String = "users"
    ) -> PostgresBrowseState {
        PostgresBrowseState(schema: schema, table: table)
    }

    // MARK: - SQL generation

    func testBaseSQLHasRowidLimitAndNoOffset() {
        let sql = makeState().sql()
        XCTAssertEqual(
            sql,
            "SELECT *, ctid AS __pg_rowid__ FROM \"public\".\"users\" LIMIT 500;"
        )
    }

    func testWhereClauseLandsBeforeOrderAndLimit() {
        var state = makeState()
        state.whereClause = "\"org_id\" = '42'"
        state.sortColumn = "name"
        XCTAssertEqual(
            state.sql(),
            "SELECT *, ctid AS __pg_rowid__ FROM \"public\".\"users\" WHERE \"org_id\" = '42' ORDER BY \"name\" ASC LIMIT 500;"
        )
    }

    func testDescendingSort() {
        var state = makeState()
        state.sortColumn = "created_at"
        state.sortAscending = false
        XCTAssertTrue(state.sql().contains("ORDER BY \"created_at\" DESC"))
    }

    func testOffsetAppearsOnLaterPages() {
        var state = makeState()
        state.page = 3
        state.pageSize = 200
        XCTAssertTrue(state.sql().hasSuffix("LIMIT 200 OFFSET 600;"))
    }

    func testIdentifiersAreQuotedAndEscaped() {
        var state = makeState(schema: "Sales", table: "weird\"name")
        state.sortColumn = "Order"
        let sql = state.sql()
        XCTAssertTrue(sql.contains("FROM \"Sales\".\"weird\"\"name\""))
        XCTAssertTrue(sql.contains("ORDER BY \"Order\" ASC"))
    }

    // MARK: - Sort cycling

    func testSortCycleAscendingThenDescendingThenClear() {
        let unsorted = makeState()

        let ascending = unsorted.cyclingSort(by: "name")
        XCTAssertEqual(ascending.sortColumn, "name")
        XCTAssertTrue(ascending.sortAscending)

        let descending = ascending.cyclingSort(by: "name")
        XCTAssertEqual(descending.sortColumn, "name")
        XCTAssertFalse(descending.sortAscending)

        let cleared = descending.cyclingSort(by: "name")
        XCTAssertNil(cleared.sortColumn)
        XCTAssertTrue(cleared.sortAscending)
    }

    func testSwitchingSortColumnStartsAscending() {
        var state = makeState()
        state.sortColumn = "name"
        state.sortAscending = false

        let next = state.cyclingSort(by: "email")
        XCTAssertEqual(next.sortColumn, "email")
        XCTAssertTrue(next.sortAscending)
    }

    func testSortChangeRewindsToFirstPage() {
        var state = makeState()
        state.page = 7

        XCTAssertEqual(state.cyclingSort(by: "name").page, 0)
    }

    // MARK: - Page moves

    func testMovingToPageClampsAtZero() {
        let state = makeState()
        XCTAssertEqual(state.movingToPage(-3).page, 0)
        XCTAssertEqual(state.movingToPage(5).page, 5)
    }

    func testFirstRowNumber() {
        var state = makeState()
        state.pageSize = 100
        XCTAssertEqual(state.firstRowNumber, 1)
        state.page = 4
        XCTAssertEqual(state.firstRowNumber, 401)
    }
}

@MainActor
final class PostgresQueryTabsStoreBrowseTests: XCTestCase {

    private func makeResult(rowCount: Int, cursorId: String? = nil) -> FfiPgExecutionResult {
        FfiPgExecutionResult(
            columns: [FfiPgColumn(name: "id", typeOid: 23, typeName: "int4")],
            rows: (0..<rowCount).map { FfiPgRow(cells: ["\($0)"]) },
            rowsAffected: nil,
            cursorId: cursorId
        )
    }

    // MARK: - openRelationTab

    func testOpenRelationTabCreatesBrowseStateAndSQL() {
        let store = PostgresQueryTabsStore()
        let id = store.openRelationTab(schema: "public", name: "users")

        let tab = store.tabs.first { $0.id == id }
        XCTAssertNotNil(tab?.browse)
        XCTAssertEqual(tab?.browse?.schema, "public")
        XCTAssertEqual(tab?.browse?.table, "users")
        XCTAssertEqual(tab?.browse?.pageSize, Int(store.pageSize))
        XCTAssertEqual(tab?.sql, tab?.browse?.sql())
        XCTAssertEqual(tab?.editTarget, PostgresEditTarget(schema: "public", table: "users"))
        XCTAssertFalse(tab?.pendingAutoRun ?? true)
    }

    func testOpenRelationTabReusesExistingTabForSameTarget() {
        let store = PostgresQueryTabsStore()
        let first = store.openRelationTab(schema: "public", name: "users")
        let second = store.openRelationTab(schema: "public", name: "users", autoRun: true)

        XCTAssertEqual(first, second)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.activeTabId, first)
        // The autoRun re-open flags the existing tab.
        XCTAssertTrue(store.tabs[0].pendingAutoRun)
    }

    func testOpenRelationTabKeepsDistinctTabsPerWhereClause() {
        let store = PostgresQueryTabsStore()
        let plain = store.openRelationTab(schema: "public", name: "users")
        let filtered = store.openRelationTab(
            schema: "public", name: "users", whereClause: "\"id\" = '1'"
        )

        XCTAssertNotEqual(plain, filtered)
        XCTAssertEqual(store.tabs.count, 2)
    }

    func testReuseWithAutoRunResyncsHandEditedSQL() {
        let store = PostgresQueryTabsStore()
        let id = store.openRelationTab(schema: "public", name: "users")
        store.setSQL("SELECT 1", forTab: id)

        _ = store.openRelationTab(schema: "public", name: "users", autoRun: true)
        XCTAssertEqual(store.tabs[0].sql, store.tabs[0].browse?.sql())
    }

    // MARK: - Auto-run consumption

    func testConsumeAutoRunFiresExactlyOnce() {
        let store = PostgresQueryTabsStore()
        let id = store.openRelationTab(schema: "public", name: "users", autoRun: true)

        XCTAssertTrue(store.consumeAutoRun(forTab: id))
        XCTAssertFalse(store.consumeAutoRun(forTab: id))
        XCTAssertFalse(store.tabs[0].pendingAutoRun)
    }

    // MARK: - Browse results

    func testFullPageSetsHasNextPageAndDropsCursor() {
        let store = PostgresQueryTabsStore()
        let id = store.openRelationTab(schema: "public", name: "users")
        let pageSize = Int(store.pageSize)

        store.setBrowseResult(makeResult(rowCount: pageSize, cursorId: "c1"), forTab: id)

        let tab = store.tabs[0]
        XCTAssertEqual(tab.browse?.hasNextPage, true)
        XCTAssertNil(tab.lastResult?.cursorId, "browse paging owns pagination; no Load-more cursor")
        XCTAssertFalse(tab.hasMore)
    }

    func testPartialPageClearsHasNextPage() {
        let store = PostgresQueryTabsStore()
        let id = store.openRelationTab(schema: "public", name: "users")

        store.setBrowseResult(makeResult(rowCount: 12), forTab: id)
        XCTAssertEqual(store.tabs[0].browse?.hasNextPage, false)
        XCTAssertEqual(store.tabs[0].fetchedRowCount, 12)
    }

    func testSetBrowseClearsBrowseState() {
        let store = PostgresQueryTabsStore()
        let id = store.openRelationTab(schema: "public", name: "users")

        store.setBrowse(nil, forTab: id)
        XCTAssertNil(store.tabs[0].browse)
    }
}
