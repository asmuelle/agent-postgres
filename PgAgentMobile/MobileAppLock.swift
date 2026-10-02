import Foundation
import Observation

// =============================================================================
// MobileAppLock — "pgAgent Locked" after the app has been away for a while.
// One lock for the whole app, not one per window: a window opened while the
// app is locked starts locked, and one unlock clears every window. (Per-window
// state let any new window — Split View, Stage Manager, Handoff — skip it.)
//
// Fed by the app-wide scene phase (PgAgentMobileApp); MobilePrivacyGateView
// shows it and does the Face ID / passcode unlock. Foundation-only, so it
// compiles into the hostless PgAgentMobileTests target.
// =============================================================================
@MainActor
@Observable
final class MobileAppLock {
    static let shared = MobileAppLock()
    static let defaultLockAfter: TimeInterval = 2 * 60

    private(set) var isLocked = false
    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored private let lockAfter: TimeInterval

    init(lockAfter: TimeInterval = MobileAppLock.defaultLockAfter) {
        self.lockAfter = lockAfter
    }

    /// Every window has left the screen. Repeated reports keep the first time.
    func appDidEnterBackground(at date: Date = .now) {
        if backgroundedAt == nil {
            backgroundedAt = date
        }
    }

    /// The app is back; lock if it was away at least `lockAfter`.
    func appDidBecomeActive(at date: Date = .now) {
        defer { backgroundedAt = nil }
        guard let backgroundedAt, date.timeIntervalSince(backgroundedAt) >= lockAfter else { return }
        isLocked = true
    }

    /// Called after a successful Face ID / passcode check.
    func unlock() {
        isLocked = false
    }
}
