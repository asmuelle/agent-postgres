import XCTest
@testable import PgAgentMacOS

final class CloudSyncModelsTests: XCTestCase {
    func testMergeUsesTimestampsAndTombstones() {
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let localProfile = SyncedConnectionProfileRecord(
            id: "prod",
            name: "Prod",
            host: "old.example.com",
            port: 22,
            username: "deploy",
            authMethod: .password,
            kind: .ssh,
            updatedAt: older
        )
        let incomingProfile = SyncedConnectionProfileRecord(
            id: "prod",
            name: "Production",
            host: "new.example.com",
            port: 2222,
            username: "deploy",
            authMethod: .password,
            kind: .ssh,
            updatedAt: newer
        )
        let localSnippet = SharedSnippetRecord(
            id: "snippet",
            title: "Old",
            body: "uptime",
            updatedAt: older
        )
        let tombstone = CloudSyncTombstoneRecord(
            collection: .snippet,
            recordId: "snippet",
            deletedAt: newer
        )

        let (merged, report) = CloudSyncMergeEngine.merge(
            local: CloudSyncSnapshot(profiles: [localProfile], snippets: [localSnippet]),
            incoming: CloudSyncSnapshot(profiles: [incomingProfile], tombstones: [tombstone])
        )

        XCTAssertEqual(merged.profiles.first?.name, "Production")
        XCTAssertEqual(merged.profiles.first?.port, 2222)
        XCTAssertTrue(merged.snippets.isEmpty)
        XCTAssertEqual(report.updatedProfiles, 1)
        XCTAssertEqual(report.deletedRecords, 1)
    }

    func testSyncedProfilePreservesLocalKeyReference() {
        let existing = ConnectionProfile(
            id: "prod",
            name: "Prod",
            host: "prod.example.com",
            username: "deploy",
            authMethod: .publicKey,
            sshKeyReference: .plainPath("/Users/me/.ssh/id_prod")
        )
        let record = SyncedConnectionProfileRecord(profile: existing)
        let restored = record.connectionProfile(preserving: existing)

        XCTAssertEqual(record.keychainAccountHint, "deploy@prod.example.com:22")
        XCTAssertNil(record.sshKeyDisplayName)
        XCTAssertEqual(restored.sshKeyReference, existing.sshKeyReference)
        XCTAssertEqual(restored.keychainAccount, existing.keychainAccount)
    }

    func testCSVPlanUpdatesByStableIdAndPreservesCredentials() throws {
        let existing = ConnectionProfile(
            id: "prod",
            name: "Prod",
            host: "prod.example.com",
            username: "deploy",
            authMethod: .publicKey,
            sshKeyReference: .plainPath("/Users/me/.ssh/id_prod"),
            tags: ["old"]
        )
        let csv = """
        id,name,host,port,username,authMethod,kind,folder,tags,favorite,color,notes
        prod,Production,prod.example.com,22,deploy,publicKey,ssh,Work,api;blue,true,#00f,"has, comma"
        ,Staging,staging.example.com,2222,ubuntu,password,ssh,Work,stage,false,,
        """

        let plan = try ConnectionCSVImportPlanner.plan(existing: [existing], csv: csv)
        let applied = ConnectionCSVImportPlanner.apply(plan, to: [existing])
        let updated = try XCTUnwrap(applied.first { $0.id == "prod" })
        let inserted = try XCTUnwrap(applied.first { $0.host == "staging.example.com" })

        XCTAssertEqual(plan.updateCount, 1)
        XCTAssertEqual(plan.addCount, 1)
        XCTAssertEqual(updated.name, "Production")
        XCTAssertEqual(updated.folderPath, "Work")
        XCTAssertEqual(updated.notes, "has, comma")
        XCTAssertEqual(updated.sshKeyReference, existing.sshKeyReference)
        XCTAssertTrue(inserted.id.hasPrefix("csv-"))
    }

    func testCSVExportRoundTripsQuotedFields() throws {
        let profile = ConnectionProfile(
            id: "quoted",
            name: "Prod, Blue",
            host: "prod.example.com",
            username: "deploy",
            notes: "line 1\nline 2"
        )

        let csv = ConnectionCSVCodec.encode(profiles: [profile])
        let rows = try ConnectionCSVCodec.decode(csv)

        XCTAssertEqual(rows.first?.name, "Prod, Blue")
        XCTAssertEqual(rows.first?.notes, "line 1\nline 2")
    }
}
