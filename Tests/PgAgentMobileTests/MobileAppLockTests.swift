import XCTest

// `MobileAppLock.swift` is compiled directly into this logic-test target
// (see project.yml). One lock for the whole app: every window — including
// one opened while the app is locked — shows the lock, and one unlock
// clears them all.

@MainActor
final class MobileAppLockTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testLocksAfterBeingAwayLongEnough() {
        let lock = MobileAppLock(lockAfter: 120)
        lock.appDidEnterBackground(at: start)
        lock.appDidBecomeActive(at: start.addingTimeInterval(120))
        XCTAssertTrue(lock.isLocked)
    }

    func testStaysUnlockedAfterAShortTrip() {
        let lock = MobileAppLock(lockAfter: 120)
        lock.appDidEnterBackground(at: start)
        lock.appDidBecomeActive(at: start.addingTimeInterval(119))
        XCTAssertFalse(lock.isLocked)
    }

    func testBecomingActiveWithoutLeavingDoesNotLock() {
        let lock = MobileAppLock(lockAfter: 120)
        lock.appDidBecomeActive(at: start.addingTimeInterval(500))
        XCTAssertFalse(lock.isLocked)
    }

    /// The away time counts from the first report, however often it's repeated.
    func testRepeatedBackgroundReportsKeepTheFirstTime() {
        let lock = MobileAppLock(lockAfter: 120)
        lock.appDidEnterBackground(at: start)
        lock.appDidEnterBackground(at: start.addingTimeInterval(100))
        lock.appDidBecomeActive(at: start.addingTimeInterval(130))
        XCTAssertTrue(lock.isLocked)
    }

    func testUnlockClearsTheLockAndALaterActivationKeepsItCleared() {
        let lock = MobileAppLock(lockAfter: 120)
        lock.appDidEnterBackground(at: start)
        lock.appDidBecomeActive(at: start.addingTimeInterval(300))

        lock.unlock()
        lock.appDidBecomeActive(at: start.addingTimeInterval(301))

        XCTAssertFalse(lock.isLocked)
    }
}
