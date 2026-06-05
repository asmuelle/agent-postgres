import XCTest
@testable import PgAgentApp

// Tests for the prompt-budget helpers that keep AI input inside the on-device
// model's ~4,096-token window.
final class PgAIContextTests: XCTestCase {

    func testClampLeavesShortTextUnchanged() {
        let text = "SELECT 1"
        XCTAssertEqual(PgAIContext.clamp(text, maxChars: 100), text)
    }

    func testClampTruncatesLongTextWithMarker() {
        let text = String(repeating: "x", count: 50)
        let clamped = PgAIContext.clamp(text, maxChars: 10)
        XCTAssertTrue(clamped.hasPrefix(String(repeating: "x", count: 10)))
        XCTAssertTrue(clamped.contains("truncated"))
        XCTAssertTrue(clamped.contains("40 more"))
    }

    func testClampAtExactBoundaryIsUnchanged() {
        let text = String(repeating: "y", count: 10)
        XCTAssertEqual(PgAIContext.clamp(text, maxChars: 10), text)
    }

    // MARK: - stripSQLFences

    func testStripFencesLeavesPlainSQLUnchanged() {
        XCTAssertEqual(PgAIContext.stripSQLFences("SELECT 1"), "SELECT 1")
    }

    func testStripFencesRemovesSqlFence() {
        let fenced = "```sql\nSELECT * FROM users\n```"
        XCTAssertEqual(PgAIContext.stripSQLFences(fenced), "SELECT * FROM users")
    }

    func testStripFencesRemovesBarePlainFence() {
        let fenced = "```\nSELECT 1\n```"
        XCTAssertEqual(PgAIContext.stripSQLFences(fenced), "SELECT 1")
    }

    func testStripFencesTrimsSurroundingWhitespace() {
        let fenced = "  ```sql\nSELECT 1\n```  "
        XCTAssertEqual(PgAIContext.stripSQLFences(fenced), "SELECT 1")
    }

    func testStripFencesPreservesMultilineBody() {
        let fenced = "```sql\nSELECT a,\n  b\nFROM t\n```"
        XCTAssertEqual(PgAIContext.stripSQLFences(fenced), "SELECT a,\n  b\nFROM t")
    }
}
