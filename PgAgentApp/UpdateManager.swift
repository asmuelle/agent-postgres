import AppKit
import Foundation
import OSLog

#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    private let logger = Logger(subsystem: "com.mc-ssh", category: "updater")

    @Published private(set) var status: UpdateIntegrationStatus

    #if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController?
    #endif

    /// URL to the appcast feed. Sparkle reads the same value through
    /// `SUFeedURL`; exposing it here keeps Settings and diagnostics typed.
    var feedURL: URL {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "https://github.com/asmuelle/agent-postgres/releases/latest/download/appcast.xml")!
    }

    /// Current app version from Info.plist.
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Current build number.
    var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    var publicKeyConfigured: Bool {
        Self.publicKeyConfiguredInBundle
    }

    private static var publicKeyConfiguredInBundle: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            return false
        }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canCheckForUpdates: Bool {
        status == .ready
    }

    private init() {
        #if canImport(Sparkle)
        if Self.publicKeyConfiguredInBundle {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            status = .ready
        } else {
            status = .missingPublicKey
        }
        #else
        status = .frameworkUnavailable
        #endif
    }

    /// Check for updates manually (menu item action).
    func checkForUpdates() {
        logger.info("Checking for updates (feed: \(self.feedURL.absoluteString, privacy: .public))")

        #if canImport(Sparkle)
        guard let updaterController else {
            presentConfigurationAlert()
            return
        }
        updaterController.checkForUpdates(nil)
        #else
        presentConfigurationAlert()
        #endif
    }

    // MARK: - Appcast generation helper

    enum AppcastError: LocalizedError, Equatable {
        case missingSignature
        case malformedSignature

        var errorDescription: String? {
            switch self {
            case .missingSignature:
                return "Appcast needs the enclosure's EdDSA signature. Run Sparkle's `sign_update <dmg>` (or `just mac-sparkle-appcast <dir>`) and pass its sparkle:edSignature value."
            case .malformedSignature:
                return "The EdDSA signature must be the base64 value printed by Sparkle's `sign_update`."
            }
        }
    }

    /// Generate the appcast XML for a new release.
    /// Called by the CI/release script, not at runtime.
    ///
    /// Sparkle 2 rejects any enclosure without a valid `sparkle:edSignature`
    /// once `SUPublicEDKey` is set, so an unsigned appcast is a release
    /// that silently never installs — refuse to generate one. Pass the
    /// base64 signature printed by Sparkle's `sign_update <dmg>`.
    nonisolated static func generateAppcast(
        version: String,
        build: String,
        downloadURL: String,
        size: UInt64,
        edSignature: String
    ) throws -> String {
        let signature = edSignature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !signature.isEmpty else { throw AppcastError.missingSignature }
        // Ed25519 signatures are 64 bytes → 88 base64 characters.
        guard let raw = Data(base64Encoded: signature), raw.count == 64 else {
            throw AppcastError.malformedSignature
        }
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
            <channel>
                <title>pgAgent Changelog</title>
                <item>
                    <title>Version \(xmlEscaped(version))</title>
                    <sparkle:version>\(xmlEscaped(build))</sparkle:version>
                    <sparkle:shortVersionString>\(xmlEscaped(version))</sparkle:shortVersionString>
                    <enclosure url="\(xmlEscaped(downloadURL))"
                               length="\(size)"
                               type="application/octet-stream"
                               sparkle:edSignature="\(signature)"/>
                    <description><![CDATA[
                        <h2>pgAgent \(xmlEscaped(version))</h2>
                        <p>See the full changelog on GitHub.</p>
                    ]]></description>
                </item>
            </channel>
        </rss>
        """
    }

    private nonisolated static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func presentConfigurationAlert() {
        let alert = NSAlert()
        alert.messageText = "Updates are not configured"
        alert.informativeText = status.userMessage
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

enum UpdateIntegrationStatus: Equatable {
    case ready
    case missingPublicKey
    case frameworkUnavailable

    var label: String {
        switch self {
        case .ready:
            return "Ready"
        case .missingPublicKey:
            return "Sparkle key missing"
        case .frameworkUnavailable:
            return "Sparkle not linked"
        }
    }

    var symbolName: String {
        switch self {
        case .ready:
            return "checkmark.circle.fill"
        case .missingPublicKey:
            return "key.slash"
        case .frameworkUnavailable:
            return "exclamationmark.triangle.fill"
        }
    }

    var tint: NSColor {
        switch self {
        case .ready:
            return .systemGreen
        case .missingPublicKey:
            return .systemOrange
        case .frameworkUnavailable:
            return .systemRed
        }
    }

    var userMessage: String {
        switch self {
        case .ready:
            return "Sparkle is linked and the app has a public EdDSA key."
        case .missingPublicKey:
            return "Sparkle is linked, but SUPublicEDKey is empty. Run `just mac-sparkle-keygen`, add the printed public key to Info.plist, and keep the private key safe."
        case .frameworkUnavailable:
            return "The Sparkle framework is not linked in this build. Regenerate the Xcode project and build the macOS app target."
        }
    }
}
