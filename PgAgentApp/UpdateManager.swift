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
        return URL(string: "https://github.com/asmuelle/mc-ssh/releases/latest/download/appcast.xml")!
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

    /// Generate the appcast XML for a new release.
    /// Called by the CI/release script, not at runtime.
    static func generateAppcast(version: String, build: String, downloadURL: String, size: UInt64) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
            <channel>
                <title>pgAgent Changelog</title>
                <item>
                    <title>Version \(version)</title>
                    <sparkle:version>\(build)</sparkle:version>
                    <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
                    <enclosure url="\(downloadURL)"
                               length="\(size)"
                               type="application/octet-stream"
                               sparkle:edSignature=""/>
                    <description><![CDATA[
                        <h2>pgAgent \(version)</h2>
                        <p>See the full changelog on GitHub.</p>
                    ]]></description>
                </item>
            </channel>
        </rss>
        """
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
