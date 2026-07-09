import XCTest
@testable import PgAgentApp

final class PostgresAuditLogTests: XCTestCase {
    func testAuditRedactionRemovesLiteralSecretsAndComments() {
        let sql = "INSERT INTO users (email, token) VALUES ('alice@example.com', 'super-secret') -- bearer super-secret"

        let redacted = PostgresAuditLog.redactedStatement(sql)

        XCTAssertTrue(redacted.contains("INSERT INTO users"))
        XCTAssertFalse(redacted.contains("alice@example.com"))
        XCTAssertFalse(redacted.contains("super-secret"))
        XCTAssertFalse(redacted.contains("bearer"))
    }

    func testAuditRedactionRemovesDollarQuotedBodies() {
        let sql = "DO $body$ BEGIN PERFORM set_config('app.secret', 'hidden', false); END $body$"

        let redacted = PostgresAuditLog.redactedStatement(sql)

        XCTAssertTrue(redacted.contains("DO"))
        XCTAssertFalse(redacted.contains("hidden"))
        XCTAssertFalse(redacted.contains("app.secret"))
    }

    func testAuditRedactionRemovesNumericConstants() {
        let redacted = PostgresAuditLog.redactedStatement(
            "SELECT * FROM customers WHERE ssn = 123456789 AND balance = 42.50"
        )

        XCTAssertFalse(redacted.contains("123456789"))
        XCTAssertFalse(redacted.contains("42.50"))
    }
}
