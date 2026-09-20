import XCTest

@testable import PgAgentApp

/// Single-clicking a routine opens it in one reusable *preview* tab (VS Code
/// style); editing or double-clicking pins it so later clicks can't replace
/// unsaved work. Pure state logic — no FFI, no connection.
@MainActor
final class PostgresRoutinePreviewTabTests: XCTestCase {

    private func routine(_ tab: PostgresQueryTab?) -> String? {
        guard case .routine(let schema, let name, let signature)? = tab?.kind else { return nil }
        return "\(schema).\(name)(\(signature))"
    }

    private func tab(_ store: PostgresQueryTabsStore, _ id: UUID) -> PostgresQueryTab? {
        store.tabs.first { $0.id == id }
    }

    func testPreviewOpenReusesTheSinglePreviewTab() {
        let store = PostgresQueryTabsStore()

        let first = store.openRoutineTab(schema: "public", name: "a", signature: "", preview: true)
        let second = store.openRoutineTab(schema: "public", name: "b", signature: "int", preview: true)

        XCTAssertEqual(first, second, "second single-click replaces the preview")
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(routine(tab(store, second)), "public.b(int)")
        XCTAssertEqual(tab(store, second)?.isPreview, true)
        XCTAssertEqual(store.activeTabId, second)
    }

    func testPinnedPreviewIsNotReplaced() {
        let store = PostgresQueryTabsStore()
        let first = store.openRoutineTab(schema: "public", name: "a", signature: "", preview: true)

        store.pinTab(first)
        let second = store.openRoutineTab(schema: "public", name: "b", signature: "", preview: true)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(routine(tab(store, first)), "public.a()", "pinned tab keeps its routine")
        XCTAssertEqual(tab(store, first)?.isPreview, false)
        XCTAssertEqual(tab(store, second)?.isPreview, true)
    }

    func testDoubleClickPinsExistingPreviewOfSameRoutine() {
        let store = PostgresQueryTabsStore()
        let preview = store.openRoutineTab(schema: "public", name: "a", signature: "", preview: true)

        let pinned = store.openRoutineTab(schema: "public", name: "a", signature: "")

        XCTAssertEqual(preview, pinned, "no duplicate tab")
        XCTAssertEqual(tab(store, pinned)?.isPreview, false)
    }

    func testPreviewOfAlreadyOpenRoutineActivatesItWithoutUnpinning() {
        let store = PostgresQueryTabsStore()
        let pinned = store.openRoutineTab(schema: "public", name: "a", signature: "")
        _ = store.openBlankTab()

        let again = store.openRoutineTab(schema: "public", name: "a", signature: "", preview: true)

        XCTAssertEqual(again, pinned)
        XCTAssertEqual(tab(store, pinned)?.isPreview, false)
        XCTAssertEqual(store.activeTabId, pinned)
    }

    func testNonPreviewOpenStillCreatesSeparateTabs() {
        let store = PostgresQueryTabsStore()
        let a = store.openRoutineTab(schema: "public", name: "a", signature: "")
        let b = store.openRoutineTab(schema: "public", name: "b", signature: "")

        XCTAssertNotEqual(a, b)
        XCTAssertEqual(store.tabs.count, 2)
    }
}
