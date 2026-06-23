import Foundation
import LocalAuthentication

// =============================================================================
// BiometricGate — a Face/Touch ID (passcode-fallback) speed bump in front of
// destructive Fleet Monitor actions: terminating a backend and VACUUM FULL.
// Killing a prod connection from a phone is exactly the fat-finger risk worth a
// biometric confirm. Non-destructive actions (cancel query, VACUUM ANALYZE)
// never call this.
// =============================================================================
enum BiometricGate {
    /// Require device-owner authentication (biometrics, falling back to device
    /// passcode) before proceeding. Returns true to allow the action.
    ///
    /// Fails *open* only when the device has no biometrics AND no passcode
    /// configured (e.g. a fresh simulator) — `canEvaluatePolicy` is false there,
    /// and locking the user out of their own database with no recovery path is
    /// worse than relying on the action's own typed confirmation alert, which
    /// always runs first. On any real device with a passcode this is a true gate.
    @MainActor
    static func confirm(reason: String) async -> Bool {
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            return true
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            // User cancelled or authentication failed — block the action.
            return false
        }
    }
}
