import CryptoKit
import Foundation

enum AppLicenseTier: String, CaseIterable, Identifiable, Codable {
    case free
    case pro
    case team

    var id: String { rawValue }

    var label: String {
        switch self {
        case .free: return "Free"
        case .pro: return "Pro"
        case .team: return "Team"
        }
    }
}

enum AppFeature: String, CaseIterable, Identifiable, Hashable, Codable {
    case savedConnections
    case terminal
    case sftp
    case basicMonitor
    case multiServerDashboard
    case deepDiagnostics
    case serviceVisualizations
    case remoteFileEditor
    case securityMap
    case serviceMonitoring

    var id: String { rawValue }

    var label: String {
        switch self {
        case .savedConnections: return "Saved connections"
        case .terminal: return "SSH terminal"
        case .sftp: return "SFTP browser"
        case .basicMonitor: return "Basic monitor"
        case .multiServerDashboard: return "Multi-server dashboard"
        case .deepDiagnostics: return "Deep diagnostics"
        case .serviceVisualizations: return "Service visualizations"
        case .remoteFileEditor: return "Remote file editor"
        case .securityMap: return "UFW/IP map"
        case .serviceMonitoring: return "Service monitoring"
        }
    }

    var isPremium: Bool {
        !Self.freeFeatures.contains(self)
    }

    static let freeFeatures: Set<AppFeature> = [
        .savedConnections,
        .terminal,
        .sftp,
        .basicMonitor,
    ]
}

enum AppLicenseStatus: Equatable {
    case preview
    case free
    case trialActive(endsAt: Date)
    case trialExpired
    case licensed(licenseId: String)
    case licenseNeedsPublicKey
    case invalidLicense(String)

    var label: String {
        switch self {
        case .preview: return "Pre-release preview"
        case .free: return "Free"
        case .trialActive: return "Trial active"
        case .trialExpired: return "Trial expired"
        case .licensed: return "Licensed"
        case .licenseNeedsPublicKey: return "License verifier not configured"
        case .invalidLicense: return "Invalid license"
        }
    }

    var detail: String {
        switch self {
        case .preview:
            return "All Pro features are enabled while commercial enforcement is disabled for pre-release builds."
        case .free:
            return "Free features are available. Start a trial or add a license key to unlock Pro."
        case .trialActive(let endsAt):
            return "Pro features are available until \(Self.dateFormatter.string(from: endsAt))."
        case .trialExpired:
            return "The local trial has ended. Add a license key to unlock Pro again."
        case .licensed(let licenseId):
            return "Offline license \(licenseId) is valid for this build."
        case .licenseNeedsPublicKey:
            return "A license key is stored, but MSSHLicenseP256PublicKey is not configured in Info.plist."
        case .invalidLicense(let reason):
            return reason
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

struct AppEntitlementsSnapshot: Equatable {
    let tier: AppLicenseTier
    let status: AppLicenseStatus
    let enabledFeatures: Set<AppFeature>
    let savedConnectionLimit: Int?
    let trialEndsAt: Date?
    let licenseKeyHash: String?

    func includes(_ feature: AppFeature) -> Bool {
        enabledFeatures.contains(feature)
    }
}

protocol EntitlementsProviding {
    func snapshot(now: Date) -> AppEntitlementsSnapshot
}

@MainActor
final class EntitlementsStore: ObservableObject {
    static let shared = EntitlementsStore()

    nonisolated static let freeSavedConnectionLimit = 3
    nonisolated static let trialLengthDays = 14

    @Published private(set) var snapshot: AppEntitlementsSnapshot

    private let defaults: UserDefaults
    private let provider: EntitlementsProviding

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.provider = LocalTrialEntitlementsProvider(defaults: defaults)
        self.snapshot = provider.snapshot(now: Date())
    }

    func refresh(now: Date = Date()) {
        snapshot = provider.snapshot(now: now)
    }

    func isEnabled(_ feature: AppFeature) -> Bool {
        snapshot.includes(feature)
    }

    func canCreateConnection(currentCount: Int) -> Bool {
        guard let limit = snapshot.savedConnectionLimit else { return true }
        return currentCount < limit
    }

    func startTrial(now: Date = Date()) {
        guard defaults.object(forKey: EntitlementDefaults.trialStartedAt) == nil else {
            refresh(now: now)
            return
        }
        defaults.set(now.timeIntervalSince1970, forKey: EntitlementDefaults.trialStartedAt)
        refresh(now: now)
    }

    func saveLicenseKey(_ rawKey: String) throws {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw LicenseKeyError.empty
        }
        guard key.hasPrefix("mssh1.") else {
            throw LicenseKeyError.unsupportedFormat
        }
        defaults.set(key, forKey: EntitlementDefaults.licenseKey)
        refresh()
    }

    func clearLicenseKey() {
        defaults.removeObject(forKey: EntitlementDefaults.licenseKey)
        refresh()
    }
}

private enum EntitlementDefaults {
    static let trialStartedAt = "licensing.trial.startedAt"
    static let licenseKey = "licensing.license.key"
}

private struct LocalTrialEntitlementsProvider: EntitlementsProviding {
    let defaults: UserDefaults
    private let licenseProvider = LicenseKeyEntitlementsProvider()

    func snapshot(now: Date) -> AppEntitlementsSnapshot {
        if !Self.enforcesEntitlements {
            return AppEntitlementsSnapshot(
                tier: .pro,
                status: .preview,
                enabledFeatures: Set(AppFeature.allCases),
                savedConnectionLimit: nil,
                trialEndsAt: nil,
                licenseKeyHash: licenseKeyHash
            )
        }

        if let key = defaults.string(forKey: EntitlementDefaults.licenseKey) {
            switch licenseProvider.validate(key, now: now) {
            case .valid(let payload):
                return AppEntitlementsSnapshot(
                    tier: payload.tier,
                    status: .licensed(licenseId: payload.licenseId),
                    enabledFeatures: Set(payload.features),
                    savedConnectionLimit: payload.tier == .free ? EntitlementsStore.freeSavedConnectionLimit : nil,
                    trialEndsAt: nil,
                    licenseKeyHash: licenseKeyHash
                )
            case .missingPublicKey:
                return freeSnapshot(status: .licenseNeedsPublicKey)
            case .invalid(let reason):
                return freeSnapshot(status: .invalidLicense(reason))
            }
        }

        guard let startedAt = defaults.object(forKey: EntitlementDefaults.trialStartedAt) as? Double else {
            return freeSnapshot(status: .free)
        }

        let start = Date(timeIntervalSince1970: startedAt)
        guard let endsAt = Calendar.current.date(
            byAdding: .day,
            value: EntitlementsStore.trialLengthDays,
            to: start
        ) else {
            return freeSnapshot(status: .trialExpired)
        }

        if now < endsAt {
            return AppEntitlementsSnapshot(
                tier: .pro,
                status: .trialActive(endsAt: endsAt),
                enabledFeatures: Set(AppFeature.allCases),
                savedConnectionLimit: nil,
                trialEndsAt: endsAt,
                licenseKeyHash: licenseKeyHash
            )
        }

        return freeSnapshot(status: .trialExpired)
    }

    private var licenseKeyHash: String? {
        guard let key = defaults.string(forKey: EntitlementDefaults.licenseKey),
              !key.isEmpty
        else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    private func freeSnapshot(status: AppLicenseStatus) -> AppEntitlementsSnapshot {
        AppEntitlementsSnapshot(
            tier: .free,
            status: status,
            enabledFeatures: AppFeature.freeFeatures,
            savedConnectionLimit: EntitlementsStore.freeSavedConnectionLimit,
            trialEndsAt: nil,
            licenseKeyHash: licenseKeyHash
        )
    }

    private static var enforcesEntitlements: Bool {
        Bundle.main.object(forInfoDictionaryKey: "MSSHEnforceEntitlements") as? Bool ?? false
    }
}

private struct LicenseKeyEntitlementsProvider {
    enum ValidationResult {
        case valid(LicensePayload)
        case missingPublicKey
        case invalid(String)
    }

    func validate(_ key: String, now: Date) -> ValidationResult {
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "mssh1" else {
            return .invalid("License keys must use the mssh1 payload/signature format.")
        }

        guard let publicKey = Self.publicKey else {
            return .missingPublicKey
        }

        let signedBytes = Data(parts[1].utf8)
        guard let signatureData = Self.decodeBase64URL(parts[2]),
              let payloadData = Self.decodeBase64URL(parts[1])
        else {
            return .invalid("License key contains invalid base64url data.")
        }

        do {
            let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
            guard publicKey.isValidSignature(signature, for: signedBytes) else {
                return .invalid("License signature verification failed.")
            }

            let payload = try JSONDecoder().decode(LicensePayload.self, from: payloadData)
            if let expiresAt = payload.expiresAt, now >= expiresAt {
                return .invalid("License expired on \(payload.displayExpiry).")
            }
            return .valid(payload.normalized())
        } catch {
            return .invalid("License could not be decoded: \(error.localizedDescription)")
        }
    }

    private static var publicKey: P256.Signing.PublicKey? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "MSSHLicenseP256PublicKey") as? String,
              let data = Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return try? P256.Signing.PublicKey(x963Representation: data)
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = base64.count % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: 4 - padding)
        }

        return Data(base64Encoded: base64)
    }
}

private struct LicensePayload: Codable {
    let licenseId: String
    let tier: AppLicenseTier
    let features: [AppFeature]
    let issuedAt: Date?
    let expiresAt: Date?

    var displayExpiry: String {
        guard let expiresAt else { return "unknown date" }
        return DateFormatter.localizedString(from: expiresAt, dateStyle: .medium, timeStyle: .none)
    }

    func normalized() -> LicensePayload {
        guard tier != .free else {
            return LicensePayload(
                licenseId: licenseId,
                tier: tier,
                features: Array(AppFeature.freeFeatures),
                issuedAt: issuedAt,
                expiresAt: expiresAt
            )
        }

        let normalizedFeatures = features.isEmpty ? AppFeature.allCases : features
        return LicensePayload(
            licenseId: licenseId,
            tier: tier,
            features: normalizedFeatures,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
    }
}

enum LicenseKeyError: LocalizedError {
    case empty
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter a license key first."
        case .unsupportedFormat:
            return "License keys must start with mssh1."
        }
    }
}
