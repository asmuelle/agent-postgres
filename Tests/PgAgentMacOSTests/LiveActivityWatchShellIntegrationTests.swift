import XCTest
@testable import PgAgentMacOS

final class LiveActivitySnapshotTests: XCTestCase {
    func testBackgroundOperationMapsToLiveActivitySnapshot() {
        let operation = BackgroundSSHOperationRecord(
            id: "op-1",
            profileId: "profile-1",
            kind: .sftpUpload,
            requester: .shareExtension,
            status: .running,
            title: "Upload report",
            progress: BackgroundSSHOperationProgress(completedUnitCount: 50, totalUnitCount: 200),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            remotePath: "/var/tmp/report.csv"
        )

        let snapshot = LiveActivitySnapshot.backgroundOperation(operation)

        XCTAssertEqual(snapshot.id, "background:op-1")
        XCTAssertEqual(snapshot.kind, .transfer)
        XCTAssertEqual(snapshot.state, .running)
        XCTAssertEqual(snapshot.progress ?? -1, 0.25, accuracy: 0.001)
        XCTAssertEqual(snapshot.subtitle, "/var/tmp/report.csv")
    }

    func testPortForwardMapsToTunnelLiveActivity() {
        let record = PortForwardRuntimeRecord(
            id: "pg",
            profileId: "profile-1",
            connectionId: "conn-1",
            name: "Postgres",
            kind: .local,
            state: .running,
            bindHost: "127.0.0.1",
            requestedBindPort: 15432,
            boundPort: 49152,
            destinationHost: "localhost",
            destinationPort: 5432,
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 120)
        )

        let snapshot = LiveActivitySnapshot.portForward(record)

        XCTAssertEqual(snapshot.id, "tunnel:pg")
        XCTAssertEqual(snapshot.kind, .tunnel)
        XCTAssertEqual(snapshot.state, .running)
        XCTAssertEqual(snapshot.subtitle, "127.0.0.1:49152 -> localhost:5432")
        XCTAssertEqual(snapshot.metadata["boundPort"], "49152")
    }
}

final class ShellIntegrationCommandTests: XCTestCase {
    func testParsesNotifyURLCommand() throws {
        let command = try XCTUnwrap(
            ShellIntegrationCommand.parse(
                "pgAgent://notify?id=deploy&title=Deploy&body=Finished&severity=success"
            )
        )

        XCTAssertEqual(command.id, "deploy")
        XCTAssertEqual(command.kind, .notify)
        XCTAssertEqual(command.title, "Deploy")
        XCTAssertEqual(command.body, "Finished")
        XCTAssertEqual(command.metadata["severity"], "success")
    }

    func testStreamParserHandlesBellTerminatedCommand() {
        var parser = ShellIntegrationCommandStreamParser()

        XCTAssertTrue(parser.append("prefix pgAgent://widget?id=api&title=API&state=up").isEmpty)
        let commands = parser.append("\u{7}")

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.kind, .widget)
        XCTAssertEqual(commands.first?.state, "up")
    }
}

final class WatchStatusSnapshotTests: XCTestCase {
    func testWatchBuilderCreatesGuardedActionsForApprovalAndTunnel() {
        let monitorFile = WidgetMonitorSnapshotFile(
            generatedAt: Date(timeIntervalSince1970: 50),
            snapshots: [
                WidgetMonitorSnapshot(
                    id: "api",
                    displayName: "API",
                    kind: .host,
                    state: .down,
                    lastCheckedAt: Date(timeIntervalSince1970: 45),
                    summary: "Connection failed",
                    openURL: "pgAgent://monitoring/api"
                ),
            ]
        )
        let liveFile = LiveActivitySnapshotFile(
            generatedAt: Date(timeIntervalSince1970: 60),
            snapshots: [
                LiveActivitySnapshot(
                    id: "background:op-1",
                    profileId: "profile-1",
                    kind: .command,
                    title: "Deploy",
                    state: .waitingForApproval,
                    updatedAt: Date(timeIntervalSince1970: 60)
                ),
                LiveActivitySnapshot(
                    id: "tunnel:pg",
                    profileId: "profile-1",
                    kind: .tunnel,
                    title: "Postgres",
                    state: .running,
                    updatedAt: Date(timeIntervalSince1970: 55)
                ),
            ]
        )

        let snapshot = WatchStatusSnapshotBuilder.snapshot(
            monitoringSnapshotFile: monitorFile,
            liveActivitySnapshotFile: liveFile,
            now: Date(timeIntervalSince1970: 70)
        )

        XCTAssertEqual(snapshot.summary, "1 needs attention")
        XCTAssertTrue(snapshot.guardedQuickActions.contains { $0.kind == .approveOperation && $0.policy == .requiresBiometricApproval })
        XCTAssertTrue(snapshot.guardedQuickActions.contains { $0.kind == .stopTunnel && $0.policy == .requiresConfirmation })
        XCTAssertTrue(snapshot.guardedQuickActions.contains { $0.kind == .openInApp && $0.policy == .opensApp })
    }
}
