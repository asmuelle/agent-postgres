// Tests for the Safe-Apply plan builder: in-place vs DROP+CREATE plans, ACL
// regeneration (with the leading REVOKE so a non-default ACL is reconstructed
// exactly), the drop probe, and the return-type-change classifier.

import XCTest
@testable import PgAgentApp

final class PostgresSafeApplyTests: XCTestCase {

    private let createText = "CREATE OR REPLACE FUNCTION \"public\".\"f\"(a integer) RETURNS integer LANGUAGE sql AS $$ SELECT a $$;"

    func testInPlacePlanIsJustTheCreate() {
        XCTAssertEqual(
            PostgresSafeApply.inPlacePlan(createText: createText),
            [createText])
    }

    func testDropCreatePlanOrdersDropThenCreateThenGrants() {
        let grants = [
            "REVOKE ALL ON ROUTINE \"public\".\"f\"(a integer) FROM PUBLIC;",
            "GRANT EXECUTE ON ROUTINE \"public\".\"f\"(a integer) TO \"reader\";",
        ]
        let plan = PostgresSafeApply.dropCreatePlan(
            schema: "public", name: "f", signature: "a integer", isProcedure: false,
            createText: createText, grants: grants)
        XCTAssertEqual(plan.count, 4)
        XCTAssertEqual(plan[0], "DROP FUNCTION \"public\".\"f\"(a integer) CASCADE;")
        XCTAssertEqual(plan[1], createText)         // recreate before granting
        XCTAssertEqual(plan[2], grants[0])
        XCTAssertEqual(plan[3], grants[1])
    }

    func testDropCreatePlanUsesProcedureKeyword() {
        let plan = PostgresSafeApply.dropCreatePlan(
            schema: "app", name: "p", signature: "x integer", isProcedure: true,
            createText: "CREATE OR REPLACE PROCEDURE app.p(x integer) ...", grants: [])
        XCTAssertEqual(plan[0], "DROP PROCEDURE \"app\".\"p\"(x integer) CASCADE;")
    }

    func testGrantStatementsRebuildAclWithLeadingRevoke() {
        // privilege, grantee_label, is_grantable
        let acl: [[String?]] = [
            ["EXECUTE", "PUBLIC", "false"],
            ["EXECUTE", "reader", "false"],
            ["EXECUTE", "admin", "true"],
        ]
        let grants = PostgresSafeApply.grantStatements(
            schema: "public", name: "f", signature: "a integer", isProcedure: false, aclRows: acl)
        XCTAssertEqual(grants.first, "REVOKE ALL ON ROUTINE \"public\".\"f\"(a integer) FROM PUBLIC;")
        XCTAssertTrue(grants.contains("GRANT EXECUTE ON ROUTINE \"public\".\"f\"(a integer) TO PUBLIC;"))
        XCTAssertTrue(grants.contains("GRANT EXECUTE ON ROUTINE \"public\".\"f\"(a integer) TO \"reader\";"))
        XCTAssertTrue(grants.contains(
            "GRANT EXECUTE ON ROUTINE \"public\".\"f\"(a integer) TO \"admin\" WITH GRANT OPTION;"))
    }

    func testGrantStatementsEmptyForDefaultAcl() {
        // aclexplode returns no rows for a default (NULL) ACL → nothing to restore.
        XCTAssertTrue(PostgresSafeApply.grantStatements(
            schema: "public", name: "f", signature: "a integer", isProcedure: false, aclRows: []).isEmpty)
    }

    func testDropProbeHasNoCascade() {
        let probe = PostgresSafeApply.dropProbe(
            schema: "public", name: "f", signature: "a integer", isProcedure: false)
        XCTAssertEqual(probe, "DROP FUNCTION \"public\".\"f\"(a integer);")
        XCTAssertFalse(probe.contains("CASCADE"))
    }

    func testRequiresDropCreateClassification() {
        XCTAssertTrue(PostgresSafeApply.requiresDropCreate(sqlstate: "42P13", message: nil))
        XCTAssertTrue(PostgresSafeApply.requiresDropCreate(
            sqlstate: nil, message: "cannot change return type of existing function"))
        XCTAssertTrue(PostgresSafeApply.requiresDropCreate(
            sqlstate: nil, message: "cannot change name of input parameter \"a\""))
        // A plain syntax error is NOT a drop-create situation.
        XCTAssertFalse(PostgresSafeApply.requiresDropCreate(sqlstate: "42601", message: "syntax error"))
        XCTAssertFalse(PostgresSafeApply.requiresDropCreate(sqlstate: nil, message: nil))
    }

    func testAclQueryEscapesLiterals() {
        let q = PostgresSafeApply.aclQuery(schema: "we'ird", name: "f'n", signature: "a integer")
        XCTAssertTrue(q.contains("'we''ird'"))
        XCTAssertTrue(q.contains("'f''n'"))
        XCTAssertTrue(q.contains("aclexplode"))
    }
}
