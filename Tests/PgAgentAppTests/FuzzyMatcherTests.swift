// Tests for the palette's subsequence scorer — the ordering contract
// (prefix > word boundary > scattered), case-insensitivity, and rejection
// of out-of-order / missing characters.

import XCTest

@testable import PgAgentApp

final class FuzzyMatcherTests: XCTestCase {

    func testNoMatchReturnsNil() {
        XCTAssertNil(FuzzyMatcher.score(query: "xyz", candidate: "users"))
        XCTAssertNil(FuzzyMatcher.score(query: "toolong", candidate: "tool"))
    }

    func testOutOfOrderSubsequenceReturnsNil() {
        XCTAssertNil(FuzzyMatcher.score(query: "ba", candidate: "ab"))
    }

    func testEmptyQueryMatchesEverythingNeutrally() {
        XCTAssertEqual(FuzzyMatcher.score(query: "", candidate: "anything"), 0)
    }

    func testPrefixBeatsWordBoundary() {
        let prefix = FuzzyMatcher.score(query: "nq", candidate: "nq tools")
        let boundary = FuzzyMatcher.score(query: "nq", candidate: "new query")
        XCTAssertNotNil(prefix)
        XCTAssertNotNil(boundary)
        XCTAssertGreaterThan(prefix!, boundary!)
    }

    func testWordBoundaryBeatsScattered() {
        let boundary = FuzzyMatcher.score(query: "qt", candidate: "query tab")
        let scattered = FuzzyMatcher.score(query: "qt", candidate: "aqtz")
        XCTAssertNotNil(boundary)
        XCTAssertNotNil(scattered)
        XCTAssertGreaterThan(boundary!, scattered!)
    }

    func testCamelCaseHumpCountsAsBoundary() {
        let hump = FuzzyMatcher.score(query: "ot", candidate: "openTable")
        let flat = FuzzyMatcher.score(query: "ot", candidate: "oxxxtxxxx")
        XCTAssertNotNil(hump)
        XCTAssertNotNil(flat)
        XCTAssertGreaterThan(hump!, flat!)
    }

    func testExactMatchBeatsLongerPrefixMatch() {
        let exact = FuzzyMatcher.score(query: "run", candidate: "run")
        let longer = FuzzyMatcher.score(query: "run", candidate: "runner")
        XCTAssertGreaterThan(exact!, longer!)
    }

    func testMatchingIsCaseInsensitive() {
        let lower = FuzzyMatcher.score(query: "new", candidate: "New Query Tab")
        let upper = FuzzyMatcher.score(query: "NEW", candidate: "New Query Tab")
        XCTAssertNotNil(lower)
        XCTAssertEqual(lower, upper)
    }
}
