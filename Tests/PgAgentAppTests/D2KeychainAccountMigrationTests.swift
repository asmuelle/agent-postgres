import Foundation
import Security
import XCTest
@testable import PgAgentApp

/// In-memory stand-in for the Postgres password keychain. `failingAccounts`
/// simulate unreadable entries (locked keychain / denied prompt).
private final class FakePasswordKeychain: PostgresPasswordKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]
    private(set) var synchronizable: [String: Bool] = [:]
    var failingAccounts: Set<String> = []
    var failSaves = false

    init(_ initial: [String: String] = [:]) { secrets = initial }

    func secret(_ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return secrets[account]
    }

    func lookup(account: String) -> KeychainLookup {
        lock.lock(); defer { lock.unlock() }
        if failingAccounts.contains(account) { return .failed }
        return secrets[account].map(KeychainLookup.found) ?? .notFound
    }

    func save(account: String, secret: String, synchronizable sync: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !failSaves else { return false }
        secrets[account] = secret
        synchronizable[account] = sync
        return true
    }

    @discardableResult
    func delete(account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        secrets.removeValue(forKey: account)
        return true
    }
}

final class D2KeychainAccountMigrationTests: XCTestCase {
    private func profile(
        id: String, host: String = "db.example.com", database: String = "app",
        auth: PostgresAuthMethod = .keychain, syncPassword: Bool = false
    ) -> PostgresProfile {
        PostgresProfile(
            id: id, name: id, host: host, port: 5432, database: database,
            user: "alice", auth: auth, syncPassword: syncPassword
        )
    }

    // MARK: - Account derivation

    func testKeychainAccountIsScopedToProfileId() {
        let a = profile(id: "A")
        let b = profile(id: "B")
        XCTAssertEqual(a.endpointIdentity, b.endpointIdentity)
        XCTAssertNotEqual(a.keychainAccount, b.keychainAccount)
        XCTAssertEqual(a.keychainAccount, "pgprofile:A")
        XCTAssertEqual(a.legacyKeychainAccount, "alice@db.example.com:5432/app")
    }

    func testFfiConfigUsesIdScopedAccount() {
        let config = profile(id: "A").toFfiConfig()
        guard case .keychain(let account) = config.auth else {
            return XCTFail("expected keychain auth")
        }
        XCTAssertEqual(account, "pgprofile:A")
    }

    func testEditingEndpointDoesNotChangeAccount() {
        var p = profile(id: "A")
        let before = p.keychainAccount
        p.host = "other.example.com"
        XCTAssertEqual(p.keychainAccount, before)
    }

    // MARK: - Migration

    func testCopiesLegacySecretAndLeavesLegacyInPlace() {
        let p = profile(id: "A", syncPassword: true)
        let keychain = FakePasswordKeychain([p.legacyKeychainAccount: "s3cret"])

        XCTAssertEqual(PostgresKeychainAccountMigration.migrate(p, keychain: keychain), .copied)
        XCTAssertEqual(keychain.secret(p.keychainAccount), "s3cret")
        XCTAssertEqual(keychain.synchronizable[p.keychainAccount], true)
        // Other profiles at the same endpoint may still need it.
        XCTAssertEqual(keychain.secret(p.legacyKeychainAccount), "s3cret")
    }

    func testTwoProfilesSharingEndpointBothMigrate() {
        let a = profile(id: "A")
        let b = profile(id: "B")
        let keychain = FakePasswordKeychain([a.legacyKeychainAccount: "shared"])
        XCTAssertEqual(PostgresKeychainAccountMigration.migrate(a, keychain: keychain), .copied)
        XCTAssertEqual(PostgresKeychainAccountMigration.migrate(b, keychain: keychain), .copied)
        XCTAssertEqual(keychain.secret(a.keychainAccount), "shared")
        XCTAssertEqual(keychain.secret(b.keychainAccount), "shared")
    }

    func testExistingIdScopedEntryIsNotOverwritten() {
        let p = profile(id: "A")
        let keychain = FakePasswordKeychain([
            p.keychainAccount: "new", p.legacyKeychainAccount: "old",
        ])
        XCTAssertEqual(PostgresKeychainAccountMigration.migrate(p, keychain: keychain), .alreadyMigrated)
        XCTAssertEqual(keychain.secret(p.keychainAccount), "new")
    }

    func testFailedReadIsNeverTreatedAsAbsent() {
        let p = profile(id: "A")
        let keychain = FakePasswordKeychain([p.legacyKeychainAccount: "old"])
        keychain.failingAccounts = [p.keychainAccount]
        XCTAssertEqual(PostgresKeychainAccountMigration.migrate(p, keychain: keychain), .failed)
        XCTAssertNil(keychain.secret(p.keychainAccount))

        keychain.failingAccounts = [p.legacyKeychainAccount]
        XCTAssertEqual(PostgresKeychainAccountMigration.migrate(p, keychain: keychain), .failed)
        XCTAssertNil(keychain.secret(p.keychainAccount))
    }

    func testFailedSaveReportsFailure() {
        let p = profile(id: "A")
        let keychain = FakePasswordKeychain([p.legacyKeychainAccount: "old"])
        keychain.failSaves = true
        XCTAssertEqual(PostgresKeychainAccountMigration.migrate(p, keychain: keychain), .failed)
    }

    func testNothingToMigrateAndNonKeychainAuth() {
        let keychain = FakePasswordKeychain()
        XCTAssertEqual(
            PostgresKeychainAccountMigration.migrate(profile(id: "A"), keychain: keychain),
            .nothingToMigrate)
        XCTAssertEqual(
            PostgresKeychainAccountMigration.migrate(
                profile(id: "B", auth: .ephemeralPassword("x")), keychain: keychain),
            .notApplicable)
    }

    // MARK: - Legacy cleanup

    func testDeletingOneOfTwoSharedProfilesKeepsLegacyEntry() {
        let a = profile(id: "A")
        let b = profile(id: "B")
        XCTAssertNil(PostgresKeychainAccountMigration.legacyAccountToDelete(removing: a, remaining: [b]))
        XCTAssertEqual(
            PostgresKeychainAccountMigration.legacyAccountToDelete(removing: b, remaining: []),
            b.legacyKeychainAccount)
    }

    func testEditingEndpointPurgesOldLegacyOnlyWhenUnshared() {
        let a = profile(id: "A")
        var edited = a
        edited.host = "moved.example.com"
        let b = profile(id: "B")

        XCTAssertEqual(
            PostgresKeychainAccountMigration.legacyAccountToDelete(editing: a, into: edited, among: [a]),
            a.legacyKeychainAccount)
        XCTAssertNil(
            PostgresKeychainAccountMigration.legacyAccountToDelete(editing: a, into: edited, among: [a, b]))
        // Unchanged endpoint + still keychain auth: nothing to purge.
        XCTAssertNil(
            PostgresKeychainAccountMigration.legacyAccountToDelete(editing: a, into: a, among: [a]))
        // Dropping keychain auth purges even if the endpoint is unchanged.
        var ephemeral = a
        ephemeral.auth = .ephemeralPassword("x")
        XCTAssertEqual(
            PostgresKeychainAccountMigration.legacyAccountToDelete(editing: a, into: ephemeral, among: [a]),
            a.legacyKeychainAccount)
    }

    func testPurgeWaitsForMigratedCopyOfKeychainSurvivor() {
        let a = profile(id: "A")
        let keychain = FakePasswordKeychain([a.legacyKeychainAccount: "only-copy"])

        XCTAssertFalse(PostgresKeychainAccountMigration.purgeLegacyAccount(
            a.legacyKeychainAccount, survivor: a, keychain: keychain))
        XCTAssertEqual(keychain.secret(a.legacyKeychainAccount), "only-copy")

        _ = PostgresKeychainAccountMigration.migrate(a, keychain: keychain)
        XCTAssertTrue(PostgresKeychainAccountMigration.purgeLegacyAccount(
            a.legacyKeychainAccount, survivor: a, keychain: keychain))
        XCTAssertNil(keychain.secret(a.legacyKeychainAccount))
        XCTAssertEqual(keychain.secret(a.keychainAccount), "only-copy")
    }

    // MARK: - Shared access group

    func testAccessGroupPrefixParsing() {
        XCTAssertEqual(
            KeychainAccessGroup.prefix(ofAccessGroup: "9QFT5JP875.com.pgagent.mobile"), "9QFT5JP875.")
        XCTAssertNil(KeychainAccessGroup.prefix(ofAccessGroup: "nodots"))
        XCTAssertNil(KeychainAccessGroup.prefix(ofAccessGroup: ".leading"))
    }
}
