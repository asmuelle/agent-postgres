import XCTest

// `BrowseSchemaChoice.swift` is compiled directly into this logic-test target
// (see project.yml): which schema Browse opens on.

final class BrowseSchemaChoiceTests: XCTestCase {

    func testPrefersPublic() {
        XCTAssertEqual(BrowseSchemaChoice.initial(from: ["analytics", "public", "audit"]), "public")
    }

    func testFallsBackToFirstAlphabetically() {
        XCTAssertEqual(BrowseSchemaChoice.initial(from: ["sales", "billing"]), "billing")
    }

    func testEmptyHasNoChoice() {
        XCTAssertNil(BrowseSchemaChoice.initial(from: []))
    }

    func testKeepsAStillValidSelection() {
        XCTAssertEqual(
            BrowseSchemaChoice.resolve(current: "audit", available: ["public", "audit"]),
            "audit"
        )
    }

    func testReplacesAVanishedSelection() {
        XCTAssertEqual(
            BrowseSchemaChoice.resolve(current: "gone", available: ["public", "audit"]),
            "public"
        )
    }
}
