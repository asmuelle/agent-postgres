import Foundation
import LocalAuthentication
import PgAgentMacOS

final class PreparedSSHKey {
    let keyPath: String?
    let useAgent: Bool
    let agentIdentityHint: String?

    private var cleanup: (() -> Void)?

    init(
        keyPath: String?,
        useAgent: Bool = false,
        agentIdentityHint: String? = nil,
        cleanup: (() -> Void)? = nil
    ) {
        self.keyPath = keyPath
        self.useAgent = useAgent
        self.agentIdentityHint = agentIdentityHint
        self.cleanup = cleanup
    }

    func stop() {
        cleanup?()
        cleanup = nil
    }

    deinit {
        stop()
    }
}

enum SSHKeyAccessError: LocalizedError {
    case missingKey
    case bookmarkInvalid(String)
    case bookmarkDenied(String)
    case vaultKeyUnavailable(String)
    case advancedIdentityMissing(String)
    case advancedIdentityUnsupported(String)
    case agentApprovalDenied

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Choose, import, generate, or select an SSH agent identity before connecting."
        case .bookmarkInvalid(let detail):
            return "The saved SSH key access grant is no longer valid. Choose the key again or import it into the app key vault. \(detail)"
        case .bookmarkDenied(let path):
            return "pgAgent does not currently have access to \(path). Choose the key again to renew access."
        case .vaultKeyUnavailable(let detail):
            return "The SSH key in the app key vault could not be prepared for connection. \(detail)"
        case .advancedIdentityMissing(let id):
            return "Advanced authentication identity \(id) was not found."
        case .advancedIdentityUnsupported(let detail):
            return detail
        case .agentApprovalDenied:
            return "SSH agent use was not approved."
        }
    }
}

enum SSHKeyAccessCoordinator {
    @MainActor
    static func prepare(
        _ reference: SSHKeyReference?,
        profile: ConnectionProfile? = nil,
        sessionId: String? = nil
    ) async throws -> PreparedSSHKey {
        guard let reference else { throw SSHKeyAccessError.missingKey }

        switch reference {
        case .plainPath(let path):
            return PreparedSSHKey(keyPath: path)

        case .securityScopedBookmark(let data):
            var isStale = false
            let url: URL
            do {
                url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            } catch {
                let scopedError = error.localizedDescription
                do {
                    url = try URL(
                        resolvingBookmarkData: data,
                        options: [],
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )
                } catch {
                    throw SSHKeyAccessError.bookmarkInvalid(
                        "\(scopedError) Fallback path resolution also failed: \(error.localizedDescription)"
                    )
                }
            }
            let didStartAccess = url.startAccessingSecurityScopedResource()
            guard didStartAccess || FileManager.default.isReadableFile(atPath: url.path) else {
                throw SSHKeyAccessError.bookmarkDenied(url.path)
            }
            return PreparedSSHKey(keyPath: url.path) {
                if didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

        case .importedVaultKey(let id), .generatedVaultKey(let id):
            let materializedURL: URL
            do {
                materializedURL = try SSHKeyVault.shared.materializeKey(id: id)
            } catch {
                throw SSHKeyAccessError.vaultKeyUnavailable(error.localizedDescription)
            }
            return PreparedSSHKey(keyPath: materializedURL.path) {
                try? FileManager.default.removeItem(at: materializedURL)
            }

        case .agent(let identityHint):
            // A plain agent reference has no policy record of its own; the
            // `requiresBiometricApproval` flag lives on
            // AdvancedAuthIdentityRecord. When the hint resolves to a stored
            // advanced identity, honor that identity's flag — otherwise no
            // approval is required and background reconnects stay silent.
            let matchedIdentity = AdvancedAuthenticationStore.shared.identities
                .first { $0.identityHint != nil && $0.identityHint == identityHint }
            if let matchedIdentity, matchedIdentity.requiresBiometricApproval {
                try await requireDeviceOwnerApproval(
                    identityName: matchedIdentity.displayName,
                    profileName: profile?.name
                )
            }
            return PreparedSSHKey(
                keyPath: nil,
                useAgent: true,
                agentIdentityHint: identityHint
            )

        case .advancedAuthIdentity(let id):
            let persistedIdentity = (try? PlatformIntegrationStore().load())?.authIdentity(id: id)
            let identity = AdvancedAuthenticationStore.shared.identity(id: id) ?? persistedIdentity
            guard let identity else {
                throw SSHKeyAccessError.advancedIdentityMissing(id)
            }
            switch identity.kind {
            case .securityKey, .sshCertificate:
                let hint = identity.identityHint
                if identity.requiresBiometricApproval {
                    try await requireDeviceOwnerApproval(
                        identityName: identity.displayName,
                        profileName: profile?.name
                    )
                }
                return PreparedSSHKey(
                    keyPath: nil,
                    useAgent: true,
                    agentIdentityHint: hint
                )
            case .secureEnclaveKey:
                throw SSHKeyAccessError.advancedIdentityUnsupported(
                    "Secure Enclave identities can be generated and biometric-tested, but SSH authentication needs an agent signer bridge before this identity can connect."
                )
            case .certificateAuthority:
                throw SSHKeyAccessError.advancedIdentityUnsupported(
                    "Certificate authority records issue identities; select an SSH certificate identity for this connection."
                )
            }
        }
    }

    /// The real approval gate behind identities whose
    /// `requiresBiometricApproval` flag is set (the UI advertises them as
    /// "Biometric approval" protected). `.deviceOwnerAuthentication` falls
    /// back to the account password on Macs without Touch ID. The check is
    /// await-based end to end — no semaphores — so a background reconnect
    /// that lands here suspends on the system prompt instead of blocking
    /// the main actor.
    ///
    /// Mirrors the mobile `BiometricGate` policy: fails open only when the
    /// device has no evaluatable authentication at all (effectively never
    /// on macOS, where the login password always qualifies); any cancel or
    /// failure denies agent use.
    private static func requireDeviceOwnerApproval(
        identityName: String,
        profileName: String?
    ) async throws {
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            return
        }
        let target = profileName.map { " for “\($0)”" } ?? ""
        let reason = "approve SSH agent use of “\(identityName)”\(target)"
        let approved = (try? await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: reason
        )) ?? false
        guard approved else { throw SSHKeyAccessError.agentApprovalDenied }
    }
}
