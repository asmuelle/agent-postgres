// Tests for the SQL/PL-pgSQL syntax highlighter — focused on the routine-editor
// additions: the plpgsql keyword vocabulary and dollar-quote *delimiter*
// coloring (which must mark the $tag$ boundaries without painting the body, so
// function bodies still highlight as code).

import AppKit
import XCTest
@testable import PgAgentApp

@MainActor
final class PostgresSQLSyntaxTests: XCTestCase {

    private func color(_ storage: NSTextStorage, at index: Int) -> NSColor? {
        storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    private func highlighted(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        PostgresSQLSyntax.highlight(storage, baseFont: .monospacedSystemFont(ofSize: 12, weight: .regular))
        return storage
    }

    // MARK: - Vocabulary

    func testPlpgsqlKeywordsInVocabulary() {
        let vocab = Set(PostgresSQLSyntax.completionVocabulary.map { $0.uppercased() })
        for kw in ["RETURN", "RETURNS", "RAISE", "EXCEPTION", "PERFORM", "ELSIF",
                   "FOREACH", "DIAGNOSTICS", "VOLATILE", "IMMUTABLE", "STABLE",
                   "PARALLEL", "DEFINER", "INVOKER", "LEAKPROOF", "SETOF"] {
            XCTAssertTrue(vocab.contains(kw), "missing plpgsql keyword \(kw)")
        }
    }

    func testVocabularyHasNoGarbageToken() {
        // Guard against a stray paste/typo in the keyword list — every entry
        // should be a plain identifier-shaped token.
        let re = try! NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_ ]*$")
        for kw in PostgresSQLSyntax.keywords {
            let range = NSRange(kw.startIndex..., in: kw)
            XCTAssertNotNil(
                re.firstMatch(in: kw, range: range), "suspicious keyword token: \(kw)")
        }
    }

    // MARK: - Highlighting

    func testKeywordColoredPurple() {
        let s = highlighted("SELECT 1")
        XCTAssertEqual(color(s, at: 0), .systemPurple)
    }

    func testSingleQuotedStringColoredRed() {
        let q = "SELECT 'hello'"
        let s = highlighted(q)
        let strIdx = (q as NSString).range(of: "'hello'").location
        XCTAssertEqual(color(s, at: strIdx), .systemRed)
    }

    func testDollarDelimiterColoredSecondaryButBodyHighlightsAsCode() {
        let body = "CREATE FUNCTION f() RETURNS int LANGUAGE sql AS $func$ SELECT 1 $func$;"
        let s = highlighted(body)
        let ns = body as NSString

        // The $func$ boundary token is dimmed…
        XCTAssertEqual(color(s, at: ns.range(of: "$func$").location), .secondaryLabelColor)
        // …but SELECT *inside* the body is still a keyword, not painted over.
        XCTAssertEqual(color(s, at: ns.range(of: "SELECT").location), .systemPurple)
    }

    func testEmptyTagDollarDelimiterColored() {
        let body = "AS $$ SELECT 1 $$;"
        let s = highlighted(body)
        XCTAssertEqual(color(s, at: (body as NSString).range(of: "$$").location), .secondaryLabelColor)
    }

    func testPositionalParameterNotTreatedAsDollarQuote() {
        // `$1` is a bind parameter, not a dollar-quote opener (no closing `$`),
        // so its `$` must not get the delimiter color.
        let q = "SELECT * FROM f WHERE id = $1"
        let s = highlighted(q)
        let dollarIdx = (q as NSString).range(of: "$1").location
        XCTAssertNotEqual(color(s, at: dollarIdx), .secondaryLabelColor)
    }
}
