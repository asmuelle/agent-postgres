import Foundation
import XCTest
@testable import PgAgentOperatorCore

final class PostgresBackupCoreTests: XCTestCase {
    private let backup = PostgresBackupRequest(
        profileId: "p1", profileName: "prod", host: "db.internal", port: 5432,
        user: "backup", database: "orders", destinationPath: "/backups/orders.dump",
        format: .custom, dataOnly: false, schemaOnly: false, clean: false)

    func testPreflightEnforcesPostgres14AndToolCompatibilityWithoutEmbeddingPassword() {
        let command = PostgresBackupCommandBuilder.preflight(for: backup)
        XCTAssertTrue(command.contains("server_version_num"))
        XCTAssertTrue(command.contains("test \"$server_major\" -ge 14"))
        XCTAssertTrue(command.contains("test \"$tool_major\" -ge \"$server_major\""))
        XCTAssertTrue(command.contains(".pgpass"))
        XCTAssertTrue(command.contains("test \"$pgpass_mode\" = '600'"))
        XCTAssertTrue(command.contains("test ! -e '/backups/orders.dump'"))
        XCTAssertTrue(command.contains("pg_database_size(current_database())"))
        XCTAssertTrue(command.contains("available_kb"))
        XCTAssertFalse(command.contains("PGPASSWORD"))
    }

    func testBackupIsAtomicVerifiedAndEmitsEvidence() {
        let command = PostgresBackupCommandBuilder.backup(for: backup)
        XCTAssertTrue(command.contains(".partial.$$") )
        XCTAssertTrue(command.contains("pg_restore --list"))
        XCTAssertTrue(command.contains("sha256sum"))
        XCTAssertTrue(command.contains("PGAGENT_EVIDENCE"))
        XCTAssertTrue(command.contains("mv --"))
        XCTAssertFalse(command.contains("PGPASSWORD"))
    }

    func testPlainRestoreUsesCleanPsqlAndStopsOnFirstError() {
        let restore = PostgresRestoreRequest(
            profileId: "p1", profileName: "stage", host: "db.internal", port: 5432,
            user: "restore", database: "orders_restore", sourcePath: "/backups/orders.sql",
            format: .plain, clean: false, singleTransaction: true)
        let command = PostgresBackupCommandBuilder.restore(for: restore)
        XCTAssertTrue(command.contains("psql --no-psqlrc"))
        XCTAssertTrue(command.contains("ON_ERROR_STOP=1"))
        XCTAssertTrue(command.contains("--single-transaction"))
    }

    func testProductionRestoreRequiresDatabaseSpecificPhrase() {
        let challenge = PostgresRestorePolicy.challenge(database: "orders", isProduction: true)
        XCTAssertEqual(challenge.requiredPhrase, "RESTORE orders")
        XCTAssertFalse(challenge.accepts("restore orders"))
        XCTAssertTrue(challenge.accepts("RESTORE orders"))
    }

    func testEvidenceParserReadsSizeChecksumAndVersions() throws {
        let evidence = try PostgresBackupEvidenceParser.parse(
            "noise\nPGAGENT_EVIDENCE\t1048576\tabc123\t14\t16\n")
        XCTAssertEqual(evidence.sizeBytes, 1_048_576)
        XCTAssertEqual(evidence.sha256, "abc123")
        XCTAssertEqual(evidence.serverMajorVersion, 14)
        XCTAssertEqual(evidence.toolMajorVersion, 16)
    }

    func testRemoteJobWrapperAndCancellationAreScopedToToken() {
        let launch = PostgresRemoteJobProtocol.launch(
            token: "abc-123", command: "pg_dump --version")
        XCTAssertTrue(launch.contains("pgagent-backup-abc-123"))
        XCTAssertTrue(launch.contains("status"))
        XCTAssertTrue(launch.contains("pid"))

        let cancel = PostgresRemoteJobProtocol.cancel(token: "abc-123")
        XCTAssertTrue(cancel.contains("pgagent-backup-abc-123"))
        XCTAssertTrue(cancel.contains("TERM"))
        XCTAssertFalse(cancel.contains("killall"))
    }

    func testBackupJobStorePersistsEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PostgresBackupJobStore(
            fileURL: directory.appendingPathComponent("backup-jobs.jsonl"))
        let job = PostgresBackupJobRecord(
            id: "job-1", profileId: "p1", profileName: "prod", database: "orders",
            kind: .backup, path: "/backups/orders.dump", startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2), state: .succeeded,
            evidence: PostgresBackupEvidence(
                sizeBytes: 10, sha256: "abc", serverMajorVersion: 14,
                toolMajorVersion: 16, verifiedAt: Date(timeIntervalSince1970: 2)),
            message: nil)

        try await store.append(job)
        let recent = try await store.recent(profileId: "p1", limit: 10)
        XCTAssertEqual(recent, [job])
    }
}
