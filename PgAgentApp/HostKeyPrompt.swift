import AppKit
import Foundation
import OSLog

/// Surface a host-key mismatch to the user and let them decide whether
/// to trust the new fingerprint.
///
/// `ssh-commander-core` formats the failure as:
/// ```
/// Host key verification failed for HOST:PORT.
/// Expected fingerprint (stored): SHA256:<stored>
/// Offered fingerprint (server):  SHA256:<offered>
/// If the remote host legitimately rotated its key, remove the entry from:
///   <tofu_path>
/// ```
/// We parse out the two fingerprints for an aligned NSAlert presentation,
/// then on confirm forget the stored key through `BridgeManager` so the next connect
/// TOFU-trusts the new key.
enum HostKeyPrompt {
    private static let logger = Logger(subsystem: "com.mc-ssh", category: "host-key")

    /// Result of the user's decision. `.trust` means the stored entry
    /// has already been evicted on the Rust side; the caller can retry
    /// the connect immediately.
    enum Outcome {
        case trust
        case cancel
    }

    /// Show the dialog and (if confirmed) forget the stored key.
    /// Synchronous modal presentation on main thread, then asynchronous FFI eviction.
    @MainActor
    static func presentMismatch(
        host: String,
        port: UInt16,
        detail: String
    ) async -> Outcome {
        let parsed = parseFingerprints(from: detail)

        let alert = NSAlert()
        alert.messageText = "Host key has changed"
        alert.alertStyle = .warning
        alert.informativeText = formattedBody(host: host, port: port, parsed: parsed)
        alert.addButton(withTitle: "Trust New Key")
        alert.addButton(withTitle: "Cancel")
        // Cancel is the safe default — protects against accidentally
        // accepting a MITM by mashing Return.
        alert.window.defaultButtonCell = nil

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return .cancel
        }

        do {
            try await BridgeManager.shared.forgetHostKey(host: host, port: port)
            logger.info("Forgot host-key entry for \(host, privacy: .public):\(port)")
        } catch {
            logger.error("Failed to forget host key: \(error.localizedDescription, privacy: .public)")
            // Even on failure we return .trust — the user said yes;
            // surfacing a second dialog about the storage write would
            // be confusing. The retry will fail again with the same
            // mismatch and we'll surface the underlying error there.
        }
        return .trust
    }

    // MARK: - Detail parsing

    private struct ParsedDetail {
        let stored: String?
        let offered: String?
    }

    private static func parseFingerprints(from detail: String) -> ParsedDetail {
        var stored: String?
        var offered: String?
        for line in detail.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Expected fingerprint"),
               let fp = trimmed.components(separatedBy: "SHA256:").last?.trimmingCharacters(in: .whitespaces) {
                stored = "SHA256:" + fp
            } else if trimmed.hasPrefix("Offered fingerprint"),
                      let fp = trimmed.components(separatedBy: "SHA256:").last?.trimmingCharacters(in: .whitespaces) {
                offered = "SHA256:" + fp
            }
        }
        return ParsedDetail(stored: stored, offered: offered)
    }

    private static func formattedBody(
        host: String,
        port: UInt16,
        parsed: ParsedDetail
    ) -> String {
        var lines: [String] = [
            "The SSH server at \(host):\(port) presented a different host key than the one trusted last time.",
            ""
        ]
        if let stored = parsed.stored {
            lines.append("Stored:  \(stored)")
        }
        if let offered = parsed.offered {
            lines.append("Offered: \(offered)")
        }
        if parsed.stored == nil && parsed.offered == nil {
            // Fallback: show the raw ssh-commander-core message.
            lines.append("(unable to extract fingerprints from the server response)")
        }
        lines.append("")
        lines.append("Trust the new key only if you know the host has rotated its key. Otherwise this could indicate a man-in-the-middle attack.")
        return lines.joined(separator: "\n")
    }
}
