import XCTest
@testable import PgAgentApp

// Tests for the role-editor DDL diff builder — the pure logic that turns
// property-sheet edits into ALTER ROLE / GRANT / REVOKE / COMMENT statements.
final class PostgresRoleDDLTests: XCTestCase {

    private func base(
        name: String = "app_user",
        memberships: [PostgresRoleMembership] = []
    ) -> PostgresRoleAttributes {
        PostgresRoleAttributes(
            name: name,
            canLogin: true,
            superuser: false,
            createDB: false,
            createRole: false,
            replication: false,
            bypassRLS: false,
            inherit: true,
            connectionLimit: -1,
            validUntil: "",
            comment: "",
            memberships: memberships
        )
    }

    // MARK: - No changes

    func testNoChangesEmitsNothing() {
        let attrs = base(memberships: [PostgresRoleMembership(role: "readers", adminOption: false)])
        XCTAssertEqual(PostgresRoleDDL.alterStatements(from: attrs, to: attrs), [])
    }

    // MARK: - Attribute flags

    func testFlagChangesFoldIntoOneAlter() {
        var edited = base()
        edited.canLogin = false
        edited.createDB = true
        edited.superuser = true
        XCTAssertEqual(
            PostgresRoleDDL.alterStatements(from: base(), to: edited),
            [#"ALTER ROLE "app_user" WITH NOLOGIN SUPERUSER CREATEDB;"#]
        )
    }

    func testConnectionLimitAndValidUntilJoinTheAlter() {
        var edited = base()
        edited.connectionLimit = 25
        edited.validUntil = "2027-01-01"
        XCTAssertEqual(
            PostgresRoleDDL.alterStatements(from: base(), to: edited),
            [#"ALTER ROLE "app_user" WITH CONNECTION LIMIT 25 VALID UNTIL '2027-01-01';"#]
        )
    }

    func testClearingValidUntilSetsInfinity() {
        var original = base()
        original.validUntil = "2027-01-01"
        let edited = base()
        XCTAssertEqual(
            PostgresRoleDDL.alterStatements(from: original, to: edited),
            [#"ALTER ROLE "app_user" WITH VALID UNTIL 'infinity';"#]
        )
    }

    // MARK: - Memberships

    func testGrantAndRevokeMemberships() {
        let original = base(memberships: [PostgresRoleMembership(role: "old_group", adminOption: false)])
        let edited = base(memberships: [PostgresRoleMembership(role: "new_group", adminOption: true)])
        XCTAssertEqual(
            PostgresRoleDDL.alterStatements(from: original, to: edited),
            [
                #"GRANT "new_group" TO "app_user" WITH ADMIN OPTION;"#,
                #"REVOKE "old_group" FROM "app_user";"#,
            ]
        )
    }

    func testAdminOptionUpgradeIsRegrant() {
        let original = base(memberships: [PostgresRoleMembership(role: "readers", adminOption: false)])
        let edited = base(memberships: [PostgresRoleMembership(role: "readers", adminOption: true)])
        XCTAssertEqual(
            PostgresRoleDDL.alterStatements(from: original, to: edited),
            [#"GRANT "readers" TO "app_user" WITH ADMIN OPTION;"#]
        )
    }

    func testAdminOptionDowngradeRevokesOnlyTheOption() {
        let original = base(memberships: [PostgresRoleMembership(role: "readers", adminOption: true)])
        let edited = base(memberships: [PostgresRoleMembership(role: "readers", adminOption: false)])
        XCTAssertEqual(
            PostgresRoleDDL.alterStatements(from: original, to: edited),
            [#"REVOKE ADMIN OPTION FOR "readers" FROM "app_user";"#]
        )
    }

    // MARK: - Comment & rename

    func testCommentSetAndClear() {
        var edited = base()
        edited.comment = "ETL service account"
        XCTAssertEqual(
            PostgresRoleDDL.alterStatements(from: base(), to: edited),
            [#"COMMENT ON ROLE "app_user" IS 'ETL service account';"#]
        )
        XCTAssertEqual(
            PostgresRoleDDL.alterStatements(from: edited, to: base()),
            [#"COMMENT ON ROLE "app_user" IS NULL;"#]
        )
    }

    func testRenameComesLastAndUsesOriginalName() {
        var edited = base(memberships: [PostgresRoleMembership(role: "readers", adminOption: false)])
        edited.name = "app_user_v2"
        edited.createRole = true
        let statements = PostgresRoleDDL.alterStatements(from: base(), to: edited)
        XCTAssertEqual(
            statements,
            [
                #"ALTER ROLE "app_user" WITH CREATEROLE;"#,
                #"GRANT "readers" TO "app_user";"#,
                #"ALTER ROLE "app_user" RENAME TO "app_user_v2";"#,
            ]
        )
    }

    func testQuotingOfHostileNames() {
        var edited = base(name: #"weird"role"#)
        edited.comment = "it's quoted"
        let statements = PostgresRoleDDL.alterStatements(from: base(name: #"weird"role"#), to: edited)
        XCTAssertEqual(
            statements,
            [#"COMMENT ON ROLE "weird""role" IS 'it''s quoted';"#]
        )
    }

    // MARK: - Parsing

    func testParseMapsFlagsLimitsAndMemberships() {
        let attrs = PostgresRoleDDL.parse(
            name: "app_user",
            attributeRow: ["true", "false", "true", "false", "false", "true", "true", "10", "2027-01-01 00:00:00+00", "note"],
            membershipRows: [["readers", "false"], ["admins", "true"]]
        )
        XCTAssertEqual(
            attrs,
            PostgresRoleAttributes(
                name: "app_user",
                canLogin: true,
                superuser: false,
                createDB: true,
                createRole: false,
                replication: false,
                bypassRLS: true,
                inherit: true,
                connectionLimit: 10,
                validUntil: "2027-01-01 00:00:00+00",
                comment: "note",
                memberships: [
                    PostgresRoleMembership(role: "readers", adminOption: false),
                    PostgresRoleMembership(role: "admins", adminOption: true),
                ]
            )
        )
    }

    func testParseNormalizesInfinityAndNulls() {
        let attrs = PostgresRoleDDL.parse(
            name: "r",
            attributeRow: ["true", "false", "false", "false", "false", "false", "true", "-1", "infinity", nil],
            membershipRows: []
        )
        XCTAssertEqual(attrs?.validUntil, "")
        XCTAssertEqual(attrs?.comment, "")
        XCTAssertEqual(attrs?.connectionLimit, -1)
    }

    func testParseMissingRoleReturnsNil() {
        XCTAssertNil(PostgresRoleDDL.parse(name: "gone", attributeRow: nil, membershipRows: []))
    }

    // MARK: - CREATE reconstruction

    func testCreateStatementCoversOptionsMembershipsAndComment() {
        var attrs = base(memberships: [PostgresRoleMembership(role: "admins", adminOption: true)])
        attrs.connectionLimit = 5
        attrs.validUntil = "2027-06-30"
        attrs.comment = "svc"
        let sql = PostgresRoleDDL.createStatement(attrs)
        XCTAssertTrue(sql.hasPrefix(#"CREATE ROLE "app_user" WITH"#))
        XCTAssertTrue(sql.contains("LOGIN"))
        XCTAssertTrue(sql.contains("CONNECTION LIMIT 5"))
        XCTAssertTrue(sql.contains("VALID UNTIL '2027-06-30'"))
        XCTAssertTrue(sql.contains(#"GRANT "admins" TO "app_user" WITH ADMIN OPTION;"#))
        XCTAssertTrue(sql.contains(#"COMMENT ON ROLE "app_user" IS 'svc';"#))
    }
}
