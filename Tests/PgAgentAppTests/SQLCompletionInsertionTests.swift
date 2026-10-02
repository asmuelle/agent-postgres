import XCTest
@testable import PgAgentApp

/// `SQLCompletionInsertion` turns a picked completion into one text edit
/// (shared by the iPad suggestion bar), and decides when suggestions are
/// worth showing at all.
final class SQLCompletionInsertionTests: XCTestCase {

    // MARK: - Edits

    func testRelationReplacesThePartialWordAndAddsASpace() {
        let text = "SELECT * FROM cus"
        let edit = SQLCompletionInsertion.edit(
            for: SQLCompletionItem(insertText: "customers", kind: .relation),
            in: text, cursorUTF16: text.utf16.count
        )
        XCTAssertEqual(edit.range, NSRange(location: 14, length: 3))
        XCTAssertEqual(edit.replacement, "customers ")
    }

    func testKeywordAddsASpace() {
        let edit = SQLCompletionInsertion.edit(
            for: SQLCompletionItem(insertText: "SELECT", kind: .keyword),
            in: "sel", cursorUTF16: 3
        )
        XCTAssertEqual(edit.range, NSRange(location: 0, length: 3))
        XCTAssertEqual(edit.replacement, "SELECT ")
    }

    func testSchemaIsFollowedByADot() {
        let text = "SELECT * FROM pub"
        let edit = SQLCompletionInsertion.edit(
            for: SQLCompletionItem(insertText: "public", kind: .schema),
            in: text, cursorUTF16: text.utf16.count
        )
        XCTAssertEqual(edit.replacement, "public.")
    }

    func testColumnAfterADotReplacesOnlyTheMemberName() {
        let text = "SELECT c.na"
        let edit = SQLCompletionInsertion.edit(
            for: SQLCompletionItem(insertText: "name", kind: .column),
            in: text, cursorUTF16: text.utf16.count
        )
        XCTAssertEqual(edit.range, NSRange(location: 9, length: 2))
        XCTAssertEqual(edit.replacement, "name")
    }

    func testInsertsAtTheCaretWhenNothingIsTyped() {
        let text = "SELECT * FROM "
        let edit = SQLCompletionInsertion.edit(
            for: SQLCompletionItem(insertText: "orders", kind: .relation),
            in: text, cursorUTF16: text.utf16.count
        )
        XCTAssertEqual(edit.range, NSRange(location: 14, length: 0))
        XCTAssertEqual(edit.replacement, "orders ")
    }

    /// Mid-text, only the word behind the caret is replaced, and no second
    /// space is added when one already follows.
    func testMidTextKeepsWhatFollowsTheCaret() {
        let text = "SELECT * FROM cu WHERE id = 1"
        let edit = SQLCompletionInsertion.edit(
            for: SQLCompletionItem(insertText: "customers", kind: .relation),
            in: text, cursorUTF16: 16
        )
        XCTAssertEqual(edit.range, NSRange(location: 14, length: 2))
        XCTAssertEqual(edit.replacement, "customers")
    }

    // MARK: - When to offer suggestions

    func testOffersWhileTypingAWord() {
        XCTAssertTrue(SQLCompletionInsertion.shouldOffer(
            [SQLCompletionItem(insertText: "SELECT", kind: .keyword)], in: "se", cursorUTF16: 2
        ))
    }

    func testOffersMembersRightAfterADot() {
        XCTAssertTrue(SQLCompletionInsertion.shouldOffer(
            [SQLCompletionItem(insertText: "name", kind: .column)], in: "SELECT c.", cursorUTF16: 9
        ))
    }

    func testOffersTablesRightAfterFrom() {
        XCTAssertTrue(SQLCompletionInsertion.shouldOffer(
            [SQLCompletionItem(insertText: "orders", kind: .relation)], in: "SELECT * FROM ", cursorUTF16: 14
        ))
    }

    /// After a space in a neutral spot the engine only has keywords — noise.
    func testStaysQuietWhenOnlyKeywordsFitABlankSpot() {
        XCTAssertFalse(SQLCompletionInsertion.shouldOffer(
            [SQLCompletionItem(insertText: "SELECT", kind: .keyword)], in: "", cursorUTF16: 0
        ))
    }

    func testStaysQuietWithNothingToOffer() {
        XCTAssertFalse(SQLCompletionInsertion.shouldOffer([], in: "se", cursorUTF16: 2))
    }

    // MARK: - Caret inside a word

    /// Picking a completion mid-word replaces the whole word, not just the
    /// part behind the caret, and adds no space before what follows.
    func testCaretInsideAWordReplacesTheWholeWord() {
        let text = "SELECT * FROM cu" + "stomers"
        let edit = SQLCompletionInsertion.edit(
            for: SQLCompletionItem(insertText: "customers", kind: .relation),
            in: text, cursorUTF16: 16
        )
        XCTAssertEqual(edit.range, NSRange(location: 14, length: 9))
        XCTAssertEqual(edit.replacement, "customers")
    }

    // MARK: - Text with emoji

    func testOffsetsAfterAnEmojiStayAligned() {
        let text = "SELECT '😀' FROM cus"
        let edit = SQLCompletionInsertion.edit(
            for: SQLCompletionItem(insertText: "customers", kind: .relation),
            in: text, cursorUTF16: text.utf16.count
        )
        XCTAssertEqual(edit.range, NSRange(location: text.utf16.count - 3, length: 3))
    }

    /// A caret offset between the two halves of a surrogate pair is rounded
    /// down to the character boundary instead of splitting the emoji.
    func testCaretInsideASurrogatePairIsRoundedToTheCharacter() {
        let text = "SELECT 😀"
        let edit = SQLCompletionInsertion.edit(
            for: SQLCompletionItem(insertText: "customers", kind: .relation),
            in: text, cursorUTF16: 8
        )
        XCTAssertEqual(edit.range, NSRange(location: 7, length: 0))
    }
}
