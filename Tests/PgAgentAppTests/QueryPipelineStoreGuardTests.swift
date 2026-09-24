import XCTest

@testable import PgAgentApp

/// Staleness guards on the query-tab store: a superseded run, a late
/// "Load more" page, an index-addressed write-back after the rows moved,
/// and an Apply finishing while more edits were staged must never touch the
/// newer state.
@MainActor
final class QueryPipelineStoreGuardTests: XCTestCase {

    private func makeResult(ids: [String], cursorId: String? = nil) -> FfiPgExecutionResult {
        FfiPgExecutionResult(
            columns: [
                FfiPgColumn(name: "v", typeOid: 25, typeName: "text"),
                FfiPgColumn(name: POSTGRES_ROWID_COLUMN, typeOid: 27, typeName: "tid"),
            ],
            rows: ids.map { FfiPgRow(cells: ["v-\($0)", "(0,\($0))"]) },
            rowsAffected: nil,
            cursorId: cursorId
        )
    }

    private func tab(_ store: PostgresQueryTabsStore, _ id: UUID) -> PostgresQueryTab {
        store.tabs.first { $0.id == id }!
    }

    // MARK: - Run generations

    func testOnlyLatestRunIsCurrent() throws {
        let store = PostgresQueryTabsStore()
        let id = store.openBlankTab()
        let first = try XCTUnwrap(store.beginRun(forTab: id))
        let second = try XCTUnwrap(store.beginRun(forTab: id))
        XCTAssertFalse(store.isCurrentRun(first, forTab: id))
        XCTAssertTrue(store.isCurrentRun(second, forTab: id))
    }

    func testBeginRunOnClosedTabReturnsNil() {
        let store = PostgresQueryTabsStore()
        let id = store.openBlankTab()
        store.closeTab(id: id)
        XCTAssertNil(store.beginRun(forTab: id))
    }

    func testRunGenerationsAreIndependentPerTab() throws {
        let store = PostgresQueryTabsStore()
        let a = store.openBlankTab()
        let b = store.openBlankTab()
        let genA = try XCTUnwrap(store.beginRun(forTab: a))
        _ = store.beginRun(forTab: b)
        XCTAssertTrue(store.isCurrentRun(genA, forTab: a), "a run in tab B must not supersede tab A")
    }

    // MARK: - Load more

    func testStalePageIsNotAppendedToNewerResult() {
        let store = PostgresQueryTabsStore()
        let id = store.openBlankTab()
        store.setResult(makeResult(ids: ["1"], cursorId: "c1"), forTab: id)
        let fetchGeneration = tab(store, id).resultGeneration

        // Re-run lands before the page — even with the same cursor name.
        store.setResult(makeResult(ids: ["9"], cursorId: "c1"), forTab: id)
        let applied = store.appendPage(
            FfiPgPageResult(rows: [FfiPgRow(cells: ["v-2", "(0,2)"])], hasMore: false),
            cursorId: "c1",
            resultGeneration: fetchGeneration,
            forTab: id
        )
        XCTAssertFalse(applied)
        XCTAssertEqual(tab(store, id).lastResult?.rows.count, 1)
        XCTAssertEqual(tab(store, id).lastResult?.cursorId, "c1", "the newer cursor stays usable")
    }

    func testStalePaginationErrorDoesNotFlagNewerResult() {
        let store = PostgresQueryTabsStore()
        let id = store.openBlankTab()
        store.setResult(makeResult(ids: ["1"], cursorId: "c1"), forTab: id)
        let fetchGeneration = tab(store, id).resultGeneration
        store.setResult(makeResult(ids: ["9"], cursorId: "c2"), forTab: id)

        store.setPaginationError("boom", cursorId: "c1", resultGeneration: fetchGeneration, forTab: id)
        XCTAssertNil(tab(store, id).paginationError)
        XCTAssertEqual(tab(store, id).lastResult?.cursorId, "c2")
    }

    func testCurrentPageIsAppended() {
        let store = PostgresQueryTabsStore()
        let id = store.openBlankTab()
        store.setResult(makeResult(ids: ["1"], cursorId: "c1"), forTab: id)
        let applied = store.appendPage(
            FfiPgPageResult(rows: [FfiPgRow(cells: ["v-2", "(0,2)"])], hasMore: false),
            cursorId: "c1",
            resultGeneration: tab(store, id).resultGeneration,
            forTab: id
        )
        XCTAssertTrue(applied)
        XCTAssertEqual(tab(store, id).lastResult?.rows.count, 2)
        XCTAssertNil(tab(store, id).lastResult?.cursorId)
    }

    // MARK: - Index-addressed write-backs

    func testCellWriteBackIsDroppedAfterRerun() {
        let store = PostgresQueryTabsStore()
        let id = store.openBlankTab()
        store.setResult(makeResult(ids: ["1", "2"]), forTab: id)
        let layout = tab(store, id).rowLayoutGeneration
        store.setResult(makeResult(ids: ["7", "8"]), forTab: id)

        store.setCellValue("edited", rowIndex: 0, columnIndex: 0, forTab: id, expectedRowLayout: layout)
        XCTAssertEqual(tab(store, id).lastResult?.rows[0].cells[0], "v-7")
    }

    func testCellWriteBackSurvivesPageAppend() {
        let store = PostgresQueryTabsStore()
        let id = store.openBlankTab()
        store.setResult(makeResult(ids: ["1"], cursorId: "c1"), forTab: id)
        let layout = tab(store, id).rowLayoutGeneration
        store.appendPage(
            FfiPgPageResult(rows: [FfiPgRow(cells: ["v-2", "(0,2)"])], hasMore: true),
            cursorId: "c1",
            resultGeneration: tab(store, id).resultGeneration,
            forTab: id
        )
        store.setCellValue("edited", rowIndex: 0, columnIndex: 0, forTab: id, expectedRowLayout: layout)
        XCTAssertEqual(tab(store, id).lastResult?.rows[0].cells[0], "edited")
    }

    func testRowRemovalInvalidatesRowLayout() {
        let store = PostgresQueryTabsStore()
        let id = store.openBlankTab()
        store.setResult(makeResult(ids: ["1", "2", "3"]), forTab: id)
        let layout = tab(store, id).rowLayoutGeneration
        store.removeRows(
            withRowIds: ["(0,1)"], rowIdColumn: 1,
            expectedResultGeneration: tab(store, id).resultGeneration, forTab: id
        )
        // Row 0 is now "2" — a write addressed to the old row 0 must not land.
        store.setCellValue("edited", rowIndex: 0, columnIndex: 0, forTab: id, expectedRowLayout: layout)
        XCTAssertEqual(tab(store, id).lastResult?.rows.map { $0.cells[0] }, ["v-2", "v-3"])
    }

    func testDeleteWriteBackRemovesByRowIdNotPosition() {
        let store = PostgresQueryTabsStore()
        let id = store.openBlankTab()
        store.setResult(makeResult(ids: ["1", "2", "3"]), forTab: id)
        let generation = tab(store, id).resultGeneration
        // A concurrent delete already removed row "1", shifting positions.
        store.removeRows(withRowIds: ["(0,1)"], rowIdColumn: 1, expectedResultGeneration: generation, forTab: id)
        store.removeRows(withRowIds: ["(0,3)"], rowIdColumn: 1, expectedResultGeneration: generation, forTab: id)
        XCTAssertEqual(tab(store, id).lastResult?.rows.map { $0.cells[0] }, ["v-2"])
    }

    func testDeleteWriteBackSkippedAfterRerun() {
        let store = PostgresQueryTabsStore()
        let id = store.openBlankTab()
        store.setResult(makeResult(ids: ["1", "2"]), forTab: id)
        let generation = tab(store, id).resultGeneration
        store.setResult(makeResult(ids: ["1", "2"]), forTab: id)
        store.removeRows(withRowIds: ["(0,1)"], rowIdColumn: 1, expectedResultGeneration: generation, forTab: id)
        XCTAssertEqual(tab(store, id).lastResult?.rows.count, 2)
    }

    func testInsertedRowNotAppendedToNewerResult() {
        let store = PostgresQueryTabsStore()
        let id = store.openBlankTab()
        store.setResult(makeResult(ids: ["1"]), forTab: id)
        let generation = tab(store, id).resultGeneration
        store.setResult(makeResult(ids: ["9"]), forTab: id)
        store.appendRow(FfiPgRow(cells: ["new", "(0,5)"]), forTab: id, expectedResultGeneration: generation)
        XCTAssertEqual(tab(store, id).lastResult?.rows.count, 1)
    }

    // MARK: - Apply staged edits

    private func edit(_ value: String?, original: String? = "o") -> PostgresPendingEdit {
        PostgresPendingEdit(columnName: "v", columnType: "text", originalValue: original, newValue: value, rowId: "(0,1)")
    }

    func testApplyClearsOnlyTheEditsItSubmitted() {
        let k1 = PostgresPendingEditKey(rowIndex: 0, columnIndex: 0)
        let k2 = PostgresPendingEditKey(rowIndex: 1, columnIndex: 0)
        let applied = [k1: edit("a")]
        // k2 was staged while the Apply ran.
        let current = [k1: edit("a"), k2: edit("b")]
        let remaining = PostgresQueryTabsStore.pendingEdits(current, removingApplied: applied)
        XCTAssertEqual(Array(remaining.keys), [k2])
    }

    func testRestagedCellSurvivesWithCommittedValueAsOriginal() {
        let key = PostgresPendingEditKey(rowIndex: 0, columnIndex: 0)
        let applied = [key: edit("a", original: "o")]
        let current = [key: edit("b", original: "o")]
        let remaining = PostgresQueryTabsStore.pendingEdits(current, removingApplied: applied)
        XCTAssertEqual(remaining[key]?.newValue, "b")
        XCTAssertEqual(remaining[key]?.originalValue, "a", "Discard must restore the committed value")
    }
}
