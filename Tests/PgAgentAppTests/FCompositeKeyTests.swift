// Tests for the escape-aware composite cache / expansion keys
// (`db.schema.table`): dotted names must not collide, keys must round-trip,
// and invalidation prefixes must match exactly the keys nested under them.
// Also covers completion quoting of reserved keywords.

import XCTest
@testable import PgAgentApp

final class FCompositeKeyTests: XCTestCase {

    func testPlainNamesKeepTheLegacyDottedForm() {
        XCTAssertEqual(PgCompositeKey.table(database: "app", schema: "public", table: "users"), "app.public.users")
        XCTAssertEqual(PgCompositeKey.schema(database: "app", schema: "public"), "app.public")
    }

    func testDottedNamesDoNotCollide() {
        let a = PgCompositeKey.table(database: "my.app", schema: "s", table: "t")
        let b = PgCompositeKey.table(database: "my", schema: "app.s", table: "t")
        let c = PgCompositeKey.table(database: "my", schema: "app", table: "s.t")
        XCTAssertEqual(Set([a, b, c]).count, 3)
    }

    func testRoundTrip() {
        let cases: [[String]] = [
            ["app", "public", "users"],
            ["my.app", "s", "v1.2"],
            ["back\\slash", "trailing\\", "."],
            ["", "..", "Ünïcødé.naïve"],
            ["uuid-1234", "db", "languages"],
        ]
        for components in cases {
            XCTAssertEqual(PgCompositeKey.parse(PgCompositeKey.make(components)), components)
        }
    }

    func testPrefixMatchesOnlyNestedKeys() {
        let prefix = PgCompositeKey.prefix("my")
        XCTAssertTrue(PgCompositeKey.table(database: "my", schema: "s", table: "t").hasPrefix(prefix))
        XCTAssertFalse(PgCompositeKey.table(database: "my.app", schema: "s", table: "t").hasPrefix(prefix))

        let schemaPrefix = PgCompositeKey.prefix("db", "a")
        XCTAssertTrue(PgCompositeKey.table(database: "db", schema: "a", table: "t").hasPrefix(schemaPrefix))
        XCTAssertFalse(PgCompositeKey.table(database: "db", schema: "a.b", table: "t").hasPrefix(schemaPrefix))
        XCTAssertFalse(PgCompositeKey.table(database: "db\\", schema: "a", table: "t").hasPrefix(PgCompositeKey.prefix("db")))
    }

    func testCompletionQuotesReservedKeywordsOutsideTheVocabulary() {
        // Reserved in Postgres but not in the completion keyword list.
        XCTAssertEqual(SQLCompletionVocabulary.quoteIfNeeded("analyse"), "\"analyse\"")
        XCTAssertEqual(SQLCompletionVocabulary.quoteIfNeeded("placing"), "\"placing\"")
        XCTAssertEqual(SQLCompletionVocabulary.quoteIfNeeded("symmetric"), "\"symmetric\"")
        XCTAssertEqual(SQLCompletionVocabulary.quoteIfNeeded("orders"), "orders")
    }
}
