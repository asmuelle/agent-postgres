import Foundation
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// SSHTunnelResolver (mobile stub) — the iOS app is a direct Postgres client and
// does not ship the SSH terminal subsystem (ConnectionStoreManager,
// CredentialResolver, SSHKeyAccessCoordinator, …) that the real macOS resolver
// in PgAgentApp/SSHTunnelResolver.swift depends on. That file is intentionally
// NOT in the PgAgentMobile target, so `BridgeManager+Postgres.swift` — which is
// shared with the mobile target — would otherwise fail to compile on iOS
// ("cannot find 'SSHTunnelResolver' in scope").
//
// This stub provides the same surface and fails closed: a tunnelled profile
// can't connect from iOS, with a message that tells the user why. Connecting
// directly (no tunnel) never reaches this path.
// =============================================================================
@MainActor
enum SSHTunnelResolver {
    enum ResolveError: LocalizedError {
        case unsupportedOnMobile

        var errorDescription: String? {
            "SSH-tunnelled connections aren't supported on iOS. Connect directly to the database, or use the macOS app for tunnelled profiles."
        }
    }

    /// Mobile never holds live SSH connections, so resolution always fails
    /// closed. Signature matches the macOS resolver for source compatibility.
    static func liveConnectionId(forSSHProfileReference reference: String) async throws -> String {
        throw ResolveError.unsupportedOnMobile
    }
}
