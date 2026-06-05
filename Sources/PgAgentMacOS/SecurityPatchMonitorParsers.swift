import Foundation

public enum SecurityPatchMonitorParsers {
    public static func parseOsInfo(evidence: [SecurityPatchEvidence]) -> SecurityPatchOsInfo {
        let osRelease = evidence.first { $0.collectorId == "os-release" }
            .map { parseOsRelease($0.rawOutput) } ?? [:]
        let kernel = evidence.first { $0.collectorId == "os-uname" }?.rawOutput
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmedForSecurityPatch

        return SecurityPatchOsInfo(
            prettyName: osRelease["PRETTY_NAME"] ?? osRelease["NAME"],
            id: osRelease["ID"],
            versionId: osRelease["VERSION_ID"],
            kernel: kernel?.isEmpty == false ? kernel : nil
        )
    }

    public static func parseOsRelease(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmedForSecurityPatch
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else {
                continue
            }
            let key = String(line[..<separator])
            var value = String(line[line.index(after: separator)...]).trimmedForSecurityPatch
            if value.count >= 2,
               value.first == "\"",
               value.last == "\"" {
                value.removeFirst()
                value.removeLast()
                value = value.replacingOccurrences(of: "\\\"", with: "\"")
            }
            values[key] = value
        }
        return values
    }

    public static func detectPackageManager(evidence: [SecurityPatchEvidence]) -> SecurityPatchPackageManager {
        let commandOutput = evidence.first { $0.collectorId == "pm-detect" }?.rawOutput.lowercased() ?? ""
        let candidates: [(String, SecurityPatchPackageManager)] = [
            ("apt-get", .apt),
            ("dnf", .dnf),
            ("yum", .yum),
            ("zypper", .zypper),
            ("pacman", .pacman),
            ("apk", .apk),
            ("brew", .homebrew)
        ]
        for (needle, manager) in candidates where commandOutput.contains(needle) {
            return manager
        }

        let osInfo = parseOsInfo(evidence: evidence)
        switch osInfo.id?.lowercased() {
        case "ubuntu", "debian":
            return .apt
        case "fedora":
            return .dnf
        case "rhel", "centos", "rocky", "almalinux", "amzn":
            return .yum
        case "opensuse", "opensuse-leap", "sles":
            return .zypper
        case "arch", "manjaro":
            return .pacman
        case "alpine":
            return .apk
        case "darwin", "macos":
            return .homebrew
        default:
            return .unknown
        }
    }

    public static func parsePackageSummary(evidence: [SecurityPatchEvidence]) -> SecurityPatchPackageSummary {
        let manager = detectPackageManager(evidence: evidence)
        switch manager {
        case .apt:
            return parseAptSummary(evidence: evidence)
        case .dnf:
            return parseDnfYumSummary(evidence: evidence, manager: .dnf)
        case .yum:
            return parseDnfYumSummary(evidence: evidence, manager: .yum)
        case .zypper:
            return parseZypperSummary(evidence: evidence)
        case .pacman:
            return parseLineBasedUpdateSummary(evidence: evidence, manager: .pacman, collectorIds: ["pacman-updates"])
        case .apk:
            return parseLineBasedUpdateSummary(evidence: evidence, manager: .apk, collectorIds: ["apk-updates"])
        case .homebrew:
            return parseHomebrewSummary(evidence: evidence)
        case .unknown:
            return SecurityPatchPackageSummary(
                packageManager: .unknown,
                metadataStatus: .unsupported,
                notes: ["No supported package manager was detected."]
            )
        }
    }

    public static func parseRebootStatus(evidence: [SecurityPatchEvidence]) -> SecurityPatchRebootStatus {
        let rebootEvidence = evidence.filter { $0.profile == .reboot }
        guard !rebootEvidence.isEmpty else { return .unknown }

        for item in rebootEvidence {
            let text = item.rawOutput.lowercased()
            if text.contains("system restart required")
                || text.contains("reboot is required")
                || text.contains("reboot required")
                || text.contains("/var/run/reboot-required")
                || (item.collectorId == "reboot-required-file" && !text.contains("absent")) {
                return .required
            }
        }

        if rebootEvidence.contains(where: { $0.rawOutput.lowercased().contains("unavailable") }) {
            return .unknown
        }
        return .notRequired
    }

    public static func parseSshdSummary(evidence: [SecurityPatchEvidence]) -> SecurityPatchSshdSummary {
        let version = parseOpenSSHVersion(
            evidence.first { $0.collectorId == "sshd-version" }?.rawOutput ?? ""
        )
        let effectiveConfig = evidence.first { $0.collectorId == "sshd-effective-config" }
        let fileConfig = evidence.first { $0.collectorId == "sshd-config-file" }
        let effectiveConfigAvailable = effectiveConfig.map {
            !$0.rawOutput.lowercased().contains("unavailable") && !$0.permissionLimited
        } ?? false
        let configFileReadable = fileConfig.map {
            !$0.rawOutput.lowercased().contains("unreadable") && !$0.permissionLimited
        } ?? false
        let effective = effectiveConfig.map { parseKeyValueLines($0.rawOutput) } ?? [:]
        let fallback = fileConfig.map { parseSshdConfigFile($0.rawOutput) } ?? [:]
        let settings = effective.isEmpty ? fallback : effective
        let evidenceId = effectiveConfig?.id ?? fileConfig?.id

        let risky = riskySshdSettings(
            settings: settings,
            evidenceId: evidenceId,
            effectiveConfigAvailable: effectiveConfigAvailable
        )
        let weak = weakAlgorithmSettings(settings: settings, evidenceId: evidenceId)

        return SecurityPatchSshdSummary(
            version: version,
            effectiveConfigAvailable: effectiveConfigAvailable,
            configFileReadable: configFileReadable,
            riskySettings: risky,
            weakAlgorithms: weak
        )
    }

    public static func parseOpenSSHVersion(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        guard let range = line.range(of: "OpenSSH") else {
            let trimmed = line.trimmedForSecurityPatch
            return trimmed.isEmpty || trimmed.lowercased().contains("unavailable") ? nil : trimmed
        }
        return String(line[range.lowerBound...]).trimmedForSecurityPatch
    }

    public static func parseKeyValueLines(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmedForSecurityPatch
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            values[String(parts[0]).lowercased()] = String(parts[1]).trimmedForSecurityPatch.lowercased()
        }
        return values
    }

    public static func parseSshdConfigFile(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = String(rawLine).trimmedForSecurityPatch
            if let comment = line.firstIndex(of: "#") {
                line = String(line[..<comment]).trimmedForSecurityPatch
            }
            guard !line.isEmpty else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            values[String(parts[0]).lowercased()] = String(parts[1]).trimmedForSecurityPatch.lowercased()
        }
        return values
    }

    private static func parseAptSummary(evidence: [SecurityPatchEvidence]) -> SecurityPatchPackageSummary {
        let aptList = evidence.first { $0.collectorId == "apt-list-upgradable" }?.rawOutput ?? ""
        let aptSim = evidence.first { $0.collectorId == "apt-simulated-upgrade" }?.rawOutput ?? ""
        let aptCheck = evidence.first { $0.collectorId == "apt-check" }?.rawOutput ?? ""
        let listPackages = aptListPackages(aptList)
        let simulatedPackages = aptSimulatedPackages(aptSim)
        let packages = uniqueSecurityPatchValues(listPackages + simulatedPackages)
        var securityPackages = packages.filter(isLikelySecurityPackageLine)
        var securityCount: Int?

        if let aptCheckCounts = parseAptCheckCounts(aptCheck) {
            securityCount = aptCheckCounts.security
        } else if !securityPackages.isEmpty {
            securityCount = securityPackages.count
        }

        if securityPackages.isEmpty, let securityCount, securityCount > 0 {
            securityPackages = packages.filter(isImportantSecurityPackage)
        }

        return SecurityPatchPackageSummary(
            packageManager: .apt,
            totalUpdateCount: packages.isEmpty ? nilIfNoUsableOutput([aptList, aptSim]) : packages.count,
            securityUpdateCount: securityCount,
            updatePackages: packages,
            securityUpdatePackages: securityPackages,
            supportsSecurityUpdateCount: true,
            metadataStatus: .unknown,
            notes: aptCheck.isEmpty ? ["apt security count uses package output heuristics when apt-check is unavailable."] : []
        )
    }

    private static func parseDnfYumSummary(
        evidence: [SecurityPatchEvidence],
        manager: SecurityPatchPackageManager
    ) -> SecurityPatchPackageSummary {
        let ids = manager == .dnf
            ? ["dnf-security-check", "dnf-updateinfo-security"]
            : ["yum-security-check", "yum-updateinfo-security"]
        let relevant = evidence.filter { ids.contains($0.collectorId) }
        let packages = uniqueSecurityPatchValues(relevant.flatMap { packageNamesFromWhitespaceRows($0.rawOutput) })
        let unsupported = relevant.contains {
            let lower = $0.rawOutput.lowercased()
            return lower.contains("no such command")
                || lower.contains("unrecognized")
                || lower.contains("unknown option")
                || lower.contains("security plugin")
        }
        return SecurityPatchPackageSummary(
            packageManager: manager,
            totalUpdateCount: packages.isEmpty ? nilIfNoUsableOutput(relevant.map(\.rawOutput)) : packages.count,
            securityUpdateCount: unsupported ? nil : packages.count,
            updatePackages: packages,
            securityUpdatePackages: packages,
            supportsSecurityUpdateCount: !unsupported,
            metadataStatus: .unknown,
            notes: unsupported ? ["Security update metadata is not available on this host."] : []
        )
    }

    private static func parseZypperSummary(evidence: [SecurityPatchEvidence]) -> SecurityPatchPackageSummary {
        let relevant = evidence.filter { ["zypper-security-patches", "zypper-patch-check"].contains($0.collectorId) }
        let packages = uniqueSecurityPatchValues(relevant.flatMap { zypperPackageNames($0.rawOutput) })
        return SecurityPatchPackageSummary(
            packageManager: .zypper,
            totalUpdateCount: packages.isEmpty ? nilIfNoUsableOutput(relevant.map(\.rawOutput)) : packages.count,
            securityUpdateCount: packages.count,
            updatePackages: packages,
            securityUpdatePackages: packages,
            supportsSecurityUpdateCount: true,
            metadataStatus: .unknown
        )
    }

    private static func parseLineBasedUpdateSummary(
        evidence: [SecurityPatchEvidence],
        manager: SecurityPatchPackageManager,
        collectorIds: Set<String>
    ) -> SecurityPatchPackageSummary {
        let relevant = evidence.filter { collectorIds.contains($0.collectorId) }
        let packages = uniqueSecurityPatchValues(relevant.flatMap { packageNamesFromWhitespaceRows($0.rawOutput) })
        return SecurityPatchPackageSummary(
            packageManager: manager,
            totalUpdateCount: packages.isEmpty ? nilIfNoUsableOutput(relevant.map(\.rawOutput)) : packages.count,
            securityUpdateCount: nil,
            updatePackages: packages,
            securityUpdatePackages: [],
            supportsSecurityUpdateCount: false,
            metadataStatus: .unknown,
            notes: ["\(manager.displayName) output does not distinguish security updates in the first scanner version."]
        )
    }

    private static func parseHomebrewSummary(evidence: [SecurityPatchEvidence]) -> SecurityPatchPackageSummary {
        guard let item = evidence.first(where: { $0.collectorId == "brew-outdated" }) else {
            return SecurityPatchPackageSummary(packageManager: .homebrew, metadataStatus: .unknown)
        }
        let data = Data(item.rawOutput.utf8)
        let decoded = try? JSONDecoder().decode(HomebrewOutdated.self, from: data)
        let formulae = decoded?.formulae.map(\.name) ?? []
        let casks = decoded?.casks.map(\.name) ?? []
        let packages = uniqueSecurityPatchValues(formulae + casks)
        return SecurityPatchPackageSummary(
            packageManager: .homebrew,
            totalUpdateCount: packages.count,
            securityUpdateCount: nil,
            updatePackages: packages,
            securityUpdatePackages: [],
            supportsSecurityUpdateCount: false,
            metadataStatus: .unknown,
            notes: ["Homebrew outdated output does not distinguish security updates."]
        )
    }

    private static func aptListPackages(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine).trimmedForSecurityPatch
            guard !line.isEmpty, !line.lowercased().hasPrefix("listing") else { return nil }
            return line.components(separatedBy: "/").first?.trimmedForSecurityPatch
        }
    }

    private static func aptSimulatedPackages(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine).trimmedForSecurityPatch
            guard line.hasPrefix("Inst ") else { return nil }
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { return nil }
            return String(parts[1])
        }
    }

    private static func parseAptCheckCounts(_ text: String) -> (total: Int, security: Int)? {
        let trimmed = text.trimmedForSecurityPatch
        let parts = trimmed.split(separator: ";")
        guard parts.count >= 2,
              let total = Int(String(parts[0]).trimmedForSecurityPatch),
              let security = Int(String(parts[1]).trimmedForSecurityPatch) else {
            return nil
        }
        return (total, security)
    }

    private static func packageNamesFromWhitespaceRows(_ text: String) -> [String] {
        let ignoredPrefixes = [
            "loaded", "last metadata", "security", "update", "updates", "advisory",
            "available", "no packages", "no updates", "name", "repository", "loading", "error"
        ]
        return text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine).trimmedForSecurityPatch
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let lower = line.lowercased()
            guard !ignoredPrefixes.contains(where: { lower.hasPrefix($0) }) else { return nil }
            return line
                .split(whereSeparator: \.isWhitespace)
                .compactMap { normalizedPackageToken(String($0)) }
                .first
        }
    }

    private static func normalizedPackageToken(_ token: String) -> String? {
        let trimSet = CharacterSet(charactersIn: "[](),;")
            .union(.whitespacesAndNewlines)
        var value = token.trimmingCharacters(in: trimSet)
        let lower = value.lowercased()

        guard !value.isEmpty,
              lower != "installing",
              lower != "upgrading",
              !lower.contains("/sec"),
              !lower.hasPrefix("fedora-"),
              !lower.hasPrefix("rhsa-"),
              !lower.hasPrefix("elsa-"),
              !lower.hasPrefix("almalinux-"),
              !lower.hasPrefix("rlsa-"),
              value.rangeOfCharacter(from: .letters) != nil else {
            return nil
        }

        if let dot = value.lastIndex(of: ".") {
            let suffix = String(value[value.index(after: dot)...]).lowercased()
            let rpmArchitectures: Set<String> = [
                "x86_64", "noarch", "aarch64", "i386", "i586", "i686",
                "armv6hl", "armv7hl", "ppc64le", "s390x", "src"
            ]
            if rpmArchitectures.contains(suffix) {
                value = String(value[..<dot])
            }
        }

        if let versionRange = value.range(of: #"-[0-9]"#, options: .regularExpression) {
            value = String(value[..<versionRange.lowerBound])
        }

        let normalized = value.trimmedForSecurityPatch
        return normalized.isEmpty ? nil : normalized
    }

    private static func zypperPackageNames(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            guard line.contains("|"), line.lowercased().contains("security") else { return nil }
            let fields = line.split(separator: "|").map { String($0).trimmedForSecurityPatch }
            return fields.last(where: { !$0.isEmpty && !$0.lowercased().contains("security") })
        }
    }

    private static func riskySshdSettings(
        settings: [String: String],
        evidenceId: String?,
        effectiveConfigAvailable: Bool
    ) -> [SecurityPatchSshdSetting] {
        var out: [SecurityPatchSshdSetting] = []
        func append(_ key: String, _ severity: SecurityPatchSeverity, _ summary: String) {
            if let value = settings[key] {
                out.append(SecurityPatchSshdSetting(
                    key: key,
                    value: value,
                    severity: severity,
                    summary: summary,
                    evidenceId: evidenceId
                ))
            }
        }

        let rootLoginAllowed = settings["permitrootlogin"] == "yes"
        let passwordAuthEnabled = settings["passwordauthentication"] == "yes"

        if rootLoginAllowed, passwordAuthEnabled {
            out.append(SecurityPatchSshdSetting(
                id: "root-password-login",
                key: "permitrootlogin+passwordauthentication",
                value: "yes",
                severity: .critical,
                summary: "Root login and password authentication are both enabled, so a password-authenticated root SSH login may be possible.",
                evidenceId: evidenceId
            ))
        } else {
            if rootLoginAllowed {
                append("permitrootlogin", .high, "Root SSH login is explicitly allowed.")
            }
            if passwordAuthEnabled {
                append("passwordauthentication", .warning, "Password authentication is enabled for SSH users.")
            }
        }
        if settings["kbdinteractiveauthentication"] == "yes" {
            append("kbdinteractiveauthentication", .warning, "Keyboard-interactive authentication is enabled.")
        }
        if settings["permitemptypasswords"] == "yes" {
            append("permitemptypasswords", .critical, "Empty-password SSH login is allowed.")
        }
        if settings["allowtcpforwarding"] == "yes" {
            append("allowtcpforwarding", .warning, "SSH TCP forwarding is permitted; this can be intentional, but it expands what a compromised SSH account can reach.")
        }
        if let value = settings["maxauthtries"],
           let tries = Int(value),
           tries > 6 {
            append("maxauthtries", .warning, "MaxAuthTries is higher than the common default of 6.")
        }
        if effectiveConfigAvailable, settings["maxauthtries"] == nil {
            out.append(SecurityPatchSshdSetting(
                id: "maxauthtries=missing",
                key: "maxauthtries",
                value: "missing",
                severity: .warning,
                summary: "The effective sshd output did not report MaxAuthTries, so the scan cannot confirm the authentication retry limit.",
                evidenceId: evidenceId
            ))
        }
        return out
    }

    private static func weakAlgorithmSettings(
        settings: [String: String],
        evidenceId: String?
    ) -> [SecurityPatchSshdSetting] {
        return ["ciphers", "macs", "kexalgorithms", "hostkeyalgorithms", "pubkeyacceptedalgorithms"].compactMap { key in
            guard let value = settings[key] else {
                return nil
            }
            let matches = weakAlgorithmMatches(value)
            guard !matches.isEmpty else { return nil }
            let severity = matches.map(\.severity).max() ?? .warning
            let shown = matches.map(\.name).prefix(5).joined(separator: ", ")
            return SecurityPatchSshdSetting(
                key: key,
                value: value,
                severity: severity,
                summary: "Legacy SSH algorithm entries are enabled for \(key): \(shown).",
                evidenceId: evidenceId
            )
        }
    }

    private static func weakAlgorithmMatches(_ value: String) -> [(name: String, severity: SecurityPatchSeverity)] {
        let algorithms = value
            .split { $0 == "," || $0.isWhitespace }
            .map { String($0).lowercased() }
        var matches: [(name: String, severity: SecurityPatchSeverity)] = []

        for algorithm in algorithms {
            if algorithm.contains("3des")
                || algorithm.contains("arcfour")
                || algorithm.hasSuffix("-cbc")
                || algorithm.hasPrefix("hmac-md5")
                || algorithm.hasPrefix("diffie-hellman-group1")
                || algorithm == "ssh-dss" {
                matches.append((algorithm, .high))
            } else if algorithm.hasPrefix("hmac-sha1")
                || algorithm == "diffie-hellman-group14-sha1"
                || algorithm == "ssh-rsa" {
                matches.append((algorithm, .warning))
            }
        }

        return matches
    }

    private static func nilIfNoUsableOutput(_ outputs: [String]) -> Int? {
        let hasUsableOutput = outputs.contains { output in
            let lower = output.lowercased()
            return !output.trimmedForSecurityPatch.isEmpty
                && !lower.contains("unavailable")
                && !lower.contains("command not found")
        }
        return hasUsableOutput ? 0 : nil
    }

    private static func isLikelySecurityPackageLine(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("security") || isImportantSecurityPackage(value)
    }

    static func isImportantSecurityPackage(_ value: String) -> Bool {
        let lower = value.lowercased()
        return [
            "openssh", "ssh", "openssl", "libssl", "kernel", "linux-image",
            "linux-kernel", "sudo", "nginx", "apache", "postgres", "docker",
            "containerd", "systemd", "curl", "git"
        ].contains { lower.contains($0) }
    }

    private static func uniqueSecurityPatchValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for rawValue in values {
            let value = rawValue.trimmedForSecurityPatch
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            out.append(value)
        }
        return out
    }
}

private struct HomebrewOutdated: Decodable {
    var formulae: [HomebrewItem]
    var casks: [HomebrewItem]

    private enum CodingKeys: String, CodingKey {
        case formulae
        case casks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formulae = try container.decodeIfPresent([HomebrewItem].self, forKey: .formulae) ?? []
        casks = try container.decodeIfPresent([HomebrewItem].self, forKey: .casks) ?? []
    }
}

private struct HomebrewItem: Decodable {
    var name: String
}

private extension String {
    var trimmedForSecurityPatch: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
