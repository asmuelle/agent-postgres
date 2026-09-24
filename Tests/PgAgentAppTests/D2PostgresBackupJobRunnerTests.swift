import Foundation
import XCTest
@testable import PgAgentApp

private actor CommandLog {
    private(set) var commands: [String] = []
    func append(_ command: String) { commands.append(command) }
}

private enum Step: String {
    case preflight, launch, poll, cancel, cleanup

    init(_ command: String) {
        if command == "PREFLIGHT" { self = .preflight }
        else if command.contains("PGAGENT_JOB") { self = .launch }
        else if command.contains("PGAGENT_RUNNING") { self = .poll }
        else if command.contains("kill -TERM") { self = .cancel }
        else { self = .cleanup }
    }
}

private struct RemoteError: LocalizedError {
    var errorDescription: String? { "ssh dropped" }
}

/// Cancels the task the runner is executing in — i.e. simulates the operator
/// pressing "Cancel Job" while that step's (non-cancellable) command runs.
private func cancelCurrentTask() {
    withUnsafeCurrentTask { $0?.cancel() }
}

final class D2PostgresBackupJobRunnerTests: XCTestCase {
    private let plan = PostgresBackupJobPlan(
        kind: .restore, path: "/b.dump", preflight: "PREFLIGHT",
        command: "pg_restore --clean", token: "tok-1")

    private func run(
        cancelBeforeStart: Bool = false,
        respond: @escaping @Sendable (Step) throws -> String
    ) async -> (PostgresBackupJobOutcome, [Step]) {
        let log = CommandLog()
        let plan = plan
        let task = Task { () -> PostgresBackupJobOutcome in
            if cancelBeforeStart { cancelCurrentTask() }
            return await PostgresBackupJobRunner.run(
                plan: plan,
                resolveHost: { "ssh-1" },
                execute: { _, command in
                    await log.append(command)
                    return try respond(Step(command))
                },
                onEvent: { _ in },
                pollIntervalNanoseconds: 1_000_000
            )
        }
        let outcome = await task.value
        return (outcome, await log.commands.map(Step.init))
    }

    func testCancelDuringPreflightNeverLaunches() async {
        let (outcome, steps) = await run { step in
            if step == .preflight { cancelCurrentTask() }
            return "ok"
        }
        XCTAssertEqual(outcome, .cancelled(launched: false, remoteCancelError: nil))
        XCTAssertEqual(steps, [.preflight])
    }

    func testCancelledBeforeStartRunsNothing() async {
        let (outcome, steps) = await run(cancelBeforeStart: true) { _ in "ok" }
        XCTAssertEqual(outcome, .cancelled(launched: false, remoteCancelError: nil))
        XCTAssertEqual(steps, [])
    }

    func testCancelDuringLaunchSendsRemoteCancel() async {
        let (outcome, steps) = await run { step in
            if step == .launch { cancelCurrentTask() }
            return "ok"
        }
        XCTAssertEqual(outcome, .cancelled(launched: true, remoteCancelError: nil))
        XCTAssertEqual(steps, [.preflight, .launch, .cancel])
    }

    func testCancelWhilePollingSendsRemoteCancel() async {
        let (outcome, steps) = await run { step in
            if step == .poll { cancelCurrentTask(); return "PGAGENT_RUNNING" }
            return "ok"
        }
        XCTAssertEqual(outcome, .cancelled(launched: true, remoteCancelError: nil))
        XCTAssertEqual(steps, [.preflight, .launch, .poll, .cancel])
    }

    func testFailedRemoteCancelIsReported() async {
        let (outcome, _) = await run { step in
            switch step {
            case .launch: cancelCurrentTask(); return "ok"
            case .cancel: throw RemoteError()
            default: return "ok"
            }
        }
        XCTAssertEqual(outcome, .cancelled(launched: true, remoteCancelError: "ssh dropped"))
    }

    func testSuccessfulJobCleansUp() async {
        let (outcome, steps) = await run { step in
            step == .poll ? "PGAGENT_DONE\t0\nlog line" : "ok"
        }
        XCTAssertEqual(outcome, .finished(exitCode: 0, output: "PGAGENT_DONE\t0\nlog line", preflightOutput: "ok"))
        XCTAssertEqual(steps, [.preflight, .launch, .poll, .cleanup])
    }

    func testTransportFailureAfterLaunchFlagsPossiblyRunningJob() async {
        let (outcome, _) = await run { step in
            if step == .poll { throw RemoteError() }
            return "ok"
        }
        XCTAssertEqual(outcome, .failed(message: "ssh dropped", launched: true))
    }

    func testPollExitCodeParsing() {
        XCTAssertNil(PostgresRemoteJobProtocol.exitCode(fromPollOutput: "PGAGENT_RUNNING\n"))
        XCTAssertEqual(PostgresRemoteJobProtocol.exitCode(fromPollOutput: "PGAGENT_DONE\t0\nx"), 0)
        XCTAssertEqual(PostgresRemoteJobProtocol.exitCode(fromPollOutput: "PGAGENT_DONE\t130\n"), 130)
        XCTAssertEqual(PostgresRemoteJobProtocol.exitCode(fromPollOutput: "PGAGENT_DONE\tgarbage"), 1)
    }
}
