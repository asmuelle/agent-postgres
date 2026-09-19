// Tests for SQLSyntaxHighlighting.attributedString — the read-only SwiftUI
// rendering used by the Property Inspector's "DDL Source" tab. It must color
// exactly like the editor's NSTextStorage pass and never alter the text.

import AppKit
import SwiftUI
import XCTest
@testable import PgAgentApp

@MainActor
final class SQLAttributedHighlightTests: XCTestCase {

    private func color(_ attributed: AttributedString, at offset: Int) -> Color? {
        let index = attributed.characters.index(attributed.startIndex, offsetBy: offset)
        return attributed.runs[index].foregroundColor
    }

    func testPreservesTextExactly() {
        let ddl = "CREATE TABLE public.t (\n    id integer NOT NULL -- pk\n);\n"
        let attributed = SQLSyntaxHighlighting.attributedString(ddl)
        XCTAssertEqual(String(attributed.characters), ddl)
    }

    func testEmptyInputYieldsEmptyString() {
        XCTAssertTrue(SQLSyntaxHighlighting.attributedString("").characters.isEmpty)
    }

    func testColorsMatchEditorHighlighter() {
        let ddl = "CREATE TABLE t (n numeric DEFAULT 42, s text DEFAULT 'x'); -- note"
        let attributed = SQLSyntaxHighlighting.attributedString(ddl)

        XCTAssertEqual(color(attributed, at: 0), Color(nsColor: .systemPurple), "keyword CREATE")
        let number = (ddl as NSString).range(of: "42").location
        XCTAssertEqual(color(attributed, at: number), Color(nsColor: .systemOrange), "number")
        let string = (ddl as NSString).range(of: "'x'").location
        XCTAssertEqual(color(attributed, at: string), Color(nsColor: .systemRed), "string literal")
        let comment = (ddl as NSString).range(of: "-- note").location
        XCTAssertEqual(color(attributed, at: comment), Color(nsColor: .systemGray), "comment")
    }

    func testPlainIdentifierUsesDefaultTextColor() {
        let attributed = SQLSyntaxHighlighting.attributedString("SELECT my_column")
        XCTAssertEqual(color(attributed, at: 7), Color(nsColor: .textColor))
    }
}
