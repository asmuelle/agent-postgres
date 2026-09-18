import XCTest

@testable import PgAgentApp

/// Keyboard tab navigation on the shared tabs store (⌘⇧] / ⌘⇧[ / ⌘1…9).
/// Pure state logic — no FFI, no connection.
@MainActor
final class PostgresQueryTabNavigationTests: XCTestCase {

    private func makeStore(tabCount: Int) -> (PostgresQueryTabsStore, [UUID]) {
        let store = PostgresQueryTabsStore()
        let ids = (0..<tabCount).map { _ in store.openBlankTab() }
        return (store, ids)
    }

    func testActivateNextTabAdvancesAndWraps() {
        let (store, ids) = makeStore(tabCount: 3)
        store.setActive(ids[0])

        store.activateNextTab()
        XCTAssertEqual(store.activeTabId, ids[1])

        store.activateNextTab()
        store.activateNextTab()
        XCTAssertEqual(store.activeTabId, ids[0], "wraps from last to first")
    }

    func testActivatePreviousTabRetreatsAndWraps() {
        let (store, ids) = makeStore(tabCount: 3)
        store.setActive(ids[0])

        store.activatePreviousTab()
        XCTAssertEqual(store.activeTabId, ids[2], "wraps from first to last")

        store.activatePreviousTab()
        XCTAssertEqual(store.activeTabId, ids[1])
    }

    func testActivateTabAtIndexSelectsZeroBasedPosition() {
        let (store, ids) = makeStore(tabCount: 4)

        store.activateTab(atIndex: 2)
        XCTAssertEqual(store.activeTabId, ids[2])
    }

    func testActivateTabAtOutOfRangeIndexKeepsSelection() {
        let (store, ids) = makeStore(tabCount: 2)
        store.setActive(ids[1])

        store.activateTab(atIndex: 5)
        XCTAssertEqual(store.activeTabId, ids[1])

        store.activateTab(atIndex: -1)
        XCTAssertEqual(store.activeTabId, ids[1])
    }

    func testActivateLastTabSelectsFinalTab() {
        let (store, ids) = makeStore(tabCount: 3)
        store.setActive(ids[0])

        store.activateLastTab()
        XCTAssertEqual(store.activeTabId, ids[2])
    }

    func testNavigationOnEmptyStoreIsNoOp() {
        let store = PostgresQueryTabsStore()

        store.activateNextTab()
        store.activatePreviousTab()
        store.activateTab(atIndex: 0)
        store.activateLastTab()

        XCTAssertNil(store.activeTabId)
    }
}
