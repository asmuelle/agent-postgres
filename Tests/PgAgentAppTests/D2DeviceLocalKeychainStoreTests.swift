import Foundation
import Security
import XCTest
@testable import PgAgentApp

/// Two-tier in-memory keychain. `dataProtectionEntitled == false` mimics an
/// unsigned build (`errSecMissingEntitlement` from the data-protection tier).
private final class FakeTieredBackend: GenericPasswordKeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    var items: [MacKeychainTier: [String: Data]] = [.dataProtection: [:], .legacyFile: [:]]
    var dataProtectionEntitled = true
    var readStatusOverride: [MacKeychainTier: OSStatus] = [:]
    var corruptDataProtectionReadBack = false

    func copy(service: String, account: String, tier: MacKeychainTier) -> (status: OSStatus, data: Data?) {
        lock.lock(); defer { lock.unlock() }
        if tier == .dataProtection && !dataProtectionEntitled { return (errSecMissingEntitlement, nil) }
        if let status = readStatusOverride[tier] { return (status, nil) }
        guard var data = items[tier]?[account] else { return (errSecItemNotFound, nil) }
        if tier == .dataProtection && corruptDataProtectionReadBack { data.append(0) }
        return (errSecSuccess, data)
    }

    func add(service: String, account: String, data: Data, tier: MacKeychainTier) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        if tier == .dataProtection && !dataProtectionEntitled { return errSecMissingEntitlement }
        if items[tier]?[account] != nil { return errSecDuplicateItem }
        items[tier, default: [:]][account] = data
        return errSecSuccess
    }

    func delete(service: String, account: String, tier: MacKeychainTier) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        if tier == .dataProtection && !dataProtectionEntitled { return errSecMissingEntitlement }
        return items[tier]?.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
    }
}

final class D2DeviceLocalKeychainStoreTests: XCTestCase {
    private let key = Data((0..<32).map { UInt8($0) })

    private func store(_ backend: FakeTieredBackend) -> DeviceLocalKeychainStore {
        DeviceLocalKeychainStore(service: "test.service", backend: backend)
    }

    func testLegacyItemIsMigratedThenDeleted() throws {
        let backend = FakeTieredBackend()
        backend.items[.legacyFile]?["master"] = key
        XCTAssertEqual(try store(backend).read(account: "master"), key)
        XCTAssertEqual(backend.items[.dataProtection]?["master"], key)
        XCTAssertNil(backend.items[.legacyFile]?["master"])
    }

    func testUnverifiedMigrationKeepsLegacyCopy() throws {
        let backend = FakeTieredBackend()
        backend.items[.legacyFile]?["master"] = key
        backend.corruptDataProtectionReadBack = true
        XCTAssertEqual(try store(backend).read(account: "master"), key)
        XCTAssertEqual(backend.items[.legacyFile]?["master"], key, "legacy copy must survive a failed verify")
    }

    func testUnsignedBuildFallsBackToLegacy() throws {
        let backend = FakeTieredBackend()
        backend.dataProtectionEntitled = false
        backend.items[.legacyFile]?["master"] = key
        let s = store(backend)
        XCTAssertEqual(try s.read(account: "master"), key)
        XCTAssertEqual(backend.items[.legacyFile]?["master"], key)

        let other = Data(repeating: 7, count: 32)
        try s.write(account: "other", data: other)
        XCTAssertEqual(backend.items[.legacyFile]?["other"], other)
        XCTAssertNil(try s.read(account: "absent"))
    }

    func testWritePrefersDataProtectionAndDropsLegacy() throws {
        let backend = FakeTieredBackend()
        backend.items[.legacyFile]?["master"] = Data([1])
        try store(backend).write(account: "master", data: key)
        XCTAssertEqual(backend.items[.dataProtection]?["master"], key)
        XCTAssertNil(backend.items[.legacyFile]?["master"])
    }

    func testReadFailureThrowsInsteadOfReportingAbsent() {
        let backend = FakeTieredBackend()
        backend.readStatusOverride[.dataProtection] = errSecInteractionNotAllowed
        XCTAssertThrowsError(try store(backend).read(account: "master")) { error in
            XCTAssertEqual(error as? KeychainStatusError, KeychainStatusError(status: errSecInteractionNotAllowed))
        }

        let legacyLocked = FakeTieredBackend()
        legacyLocked.readStatusOverride[.legacyFile] = errSecAuthFailed
        XCTAssertThrowsError(try store(legacyLocked).read(account: "master"))
    }

    func testDeleteClearsBothTiers() throws {
        let backend = FakeTieredBackend()
        backend.items[.legacyFile]?["a"] = key
        backend.items[.dataProtection]?["a"] = key
        try store(backend).delete(account: "a")
        XCTAssertNil(backend.items[.legacyFile]?["a"])
        XCTAssertNil(backend.items[.dataProtection]?["a"])
    }
}
