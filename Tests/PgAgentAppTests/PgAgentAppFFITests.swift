// Integration tests for the uniffi-generated FFI surface.
//
// These run inside the app's process so the universal Rust static library
// is linked and `rshellInit`, `rshellConnect`, etc. are reachable. The
// framework's test bundle can't run them — the bindings live in the app
// target.
//
// Bridge state is process-wide (`MacOsBridge::init()` uses a `OnceLock`),
// so the tests share a runtime across runs. They are intentionally
// independent of execution order.

import XCTest
@testable import PgAgentApp

final class PgAgentAppFFITests: XCTestCase {

    // MARK: - Init

    /// `rshellInit` should return true and be safe to call repeatedly.
    func testInitIsIdempotent() {
        XCTAssertTrue(rshellInit())
        XCTAssertTrue(rshellInit())
        XCTAssertTrue(rshellInit())
    }

    // MARK: - Connect — typed errors

    func testConnectWithNoAuthThrowsConfigInvalid() {
        _ = rshellInit()

        let config = FfiConnectConfig(
            host: "nonexistent.invalid",
            port: 22,
            username: "test",
            password: nil,
            keyPath: nil,
            passphrase: nil,
            useAgent: false,
            agentIdentityHint: nil,
            sessionId: nil
        )

        XCTAssertThrowsError(try rshellConnect(config: config)) { error in
            guard let err = error as? ConnectError else {
                return XCTFail("expected ConnectError, got \(type(of: error))")
            }
            switch err {
            case .ConfigInvalid(let detail):
                XCTAssertTrue(detail.contains("password") || detail.contains("key"))
            default:
                XCTFail("expected ConfigInvalid, got \(err)")
            }
        }
    }

    /// Bad host with credentials supplied should classify as Network or
    /// Other (not as auth failure or passphrase) — we don't want a
    /// misclassification to send the UI down a re-prompt loop on a
    /// network error.
    func testConnectToBadHostClassifiesAsNetworkOrOther() {
        _ = rshellInit()

        let config = FfiConnectConfig(
            // 192.0.2.0/24 is TEST-NET-1, guaranteed-unroutable.
            host: "192.0.2.1",
            port: 22,
            username: "test",
            password: "wrong",
            keyPath: nil,
            passphrase: nil,
            useAgent: false,
            agentIdentityHint: nil,
            sessionId: "test-bad-host"
        )

        XCTAssertThrowsError(try rshellConnect(config: config)) { error in
            guard let err = error as? ConnectError else {
                return XCTFail("expected ConnectError, got \(type(of: error))")
            }
            switch err {
            case .Network, .Other:
                break  // both acceptable
            default:
                XCTFail("expected Network or Other for unroutable host, got \(err)")
            }
        }
    }

    // MARK: - Disconnect / PTY operations on unknown ids

    /// Disconnect of an unknown id should succeed (no-op): ssh-commander-core's
    /// idempotent close avoids spurious failures during teardown.
    func testDisconnectUnknownIsOk() {
        _ = rshellInit()
        let result = rshellDisconnect(connectionId: "no-such-connection")
        XCTAssertTrue(result.success)
    }

    /// Starting a PTY on a non-existent connection must fail with an
    /// FfiResult error — bridge correctness depends on this so a
    /// crashed connection doesn't silently spawn a phantom PTY.
    func testPtyStartOnUnknownConnectionFails() {
        _ = rshellInit()
        let result = rshellPtyStart(
            connectionId: "no-such-connection",
            cols: 80,
            rows: 24
        )
        XCTAssertFalse(result.success)
        XCTAssertNotNil(result.error)
    }

    // MARK: - Keychain FFI

    func testKeychainIsSupportedOnMac() {
        XCTAssertTrue(rshellKeychainIsSupported())
    }

    /// Save → load → delete round-trip. Uses a unique account string to
    /// avoid collisions with anything a developer has stored locally.
    func testKeychainRoundTrip() {
        let account = "rshellapp-test-\(UUID().uuidString)"

        let saved = rshellKeychainSave(
            kind: .sshPassword,
            account: account,
            secret: "hunter2"
        )
        XCTAssertTrue(saved.success, "save failed: \(saved.error ?? "?")")

        let loaded = rshellKeychainLoad(kind: .sshPassword, account: account)
        XCTAssertTrue(loaded.success)
        XCTAssertEqual(loaded.value, "hunter2")

        let deleted = rshellKeychainDelete(kind: .sshPassword, account: account)
        XCTAssertTrue(deleted.success)

        // Loading after delete: success is still true (no error), but
        // value is nil (no entry).
        let afterDelete = rshellKeychainLoad(kind: .sshPassword, account: account)
        XCTAssertTrue(afterDelete.success)
        XCTAssertNil(afterDelete.value)
    }
}
