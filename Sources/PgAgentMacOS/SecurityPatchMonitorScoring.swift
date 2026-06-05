import Foundation

public enum SecurityPatchMonitorScoring {
    public static func buildResult(bundle: SecurityPatchScanBundle) -> SecurityPatchScanResult {
        let osInfo = SecurityPatchMonitorParsers.parseOsInfo(evidence: bundle.evidence)
        let packageSummary = SecurityPatchMonitorParsers.parsePackageSummary(evidence: bundle.evidence)
        let rebootStatus = SecurityPatchMonitorParsers.parseRebootStatus(evidence: bundle.evidence)
        let sshdSummary = SecurityPatchMonitorParsers.parseSshdSummary(evidence: bundle.evidence)
        let permissionLimited = bundle.evidence.contains(where: { $0.permissionLimited })
            || bundle.commandAudits.contains(where: { $0.permissionLimited })

        var findings = buildFindings(
            packageSummary: packageSummary,
            rebootStatus: rebootStatus,
            sshdSummary: sshdSummary,
            evidence: bundle.evidence,
            permissionLimited: permissionLimited
        )

        if findings.isEmpty {
            findings.append(noImmediateIssueFinding(bundle: bundle, packageSummary: packageSummary, sshdSummary: sshdSummary))
        }

        findings.sort { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }

        let overallSeverity = findings.map { $0.severity }.max() ?? .unknown
        return SecurityPatchScanResult(
            id: bundle.id,
            connectionId: bundle.connectionId,
            profileId: bundle.profileId,
            hostLabel: bundle.hostLabel,
            scannedAt: bundle.scannedAt,
            osInfo: osInfo,
            packageSummary: packageSummary,
            rebootStatus: rebootStatus,
            sshdSummary: sshdSummary,
            findings: findings,
            evidence: bundle.evidence,
            commandAudits: bundle.commandAudits,
            warnings: bundle.warnings,
            overallSeverity: overallSeverity,
            summaryLabel: summaryLabel(
                findings: findings,
                packageSummary: packageSummary,
                rebootStatus: rebootStatus
            ),
            isPermissionLimited: permissionLimited
        )
    }

    public static func badge(
        severity: SecurityPatchSeverity,
        packageSummary: SecurityPatchPackageSummary,
        rebootStatus: SecurityPatchRebootStatus
    ) -> SecurityPatchHostBadge {
        if severity == .critical { return .critical }
        if rebootStatus == .required { return .rebootNeeded }
        if (packageSummary.securityUpdateCount ?? 0) > 0 { return .securityUpdates }
        if (packageSummary.totalUpdateCount ?? 0) > 0 { return .updatesAvailable }
        if packageSummary.packageManager == .unknown { return .unsupported }
        if severity == .high || severity == .warning { return .unknown }
        if severity == .unknown { return .unknown }
        return .secure
    }

    private static func buildFindings(
        packageSummary: SecurityPatchPackageSummary,
        rebootStatus: SecurityPatchRebootStatus,
        sshdSummary: SecurityPatchSshdSummary,
        evidence: [SecurityPatchEvidence],
        permissionLimited: Bool
    ) -> [SecurityPatchFinding] {
        var findings: [SecurityPatchFinding] = []

        if packageSummary.packageManager == .unknown {
            findings.append(SecurityPatchFinding(
                kind: .scannerUnsupported,
                title: "Package manager not supported",
                summary: "The scan could not identify a supported package manager on this host.",
                severity: .unknown,
                evidenceIds: evidenceIds(evidence, collectorIds: ["pm-detect", "os-release"]),
                recommendation: "Use the command evidence to confirm the operating system and package manager."
            ))
        }

        if let securityCount = packageSummary.securityUpdateCount, securityCount > 0 {
            let important = packageSummary.securityUpdatePackages.filter(SecurityPatchMonitorParsers.isImportantSecurityPackage)
            findings.append(SecurityPatchFinding(
                kind: .securityUpdatesAvailable,
                title: securityCount == 1 ? "Security update available" : "\(securityCount) security updates available",
                summary: securitySummary(count: securityCount, importantPackages: important),
                severity: important.isEmpty ? .high : .critical,
                evidenceIds: packageEvidenceIds(evidence),
                recommendation: "Review a patch plan before applying security updates."
            ))
        }

        let total = packageSummary.totalUpdateCount ?? 0
        let security = packageSummary.securityUpdateCount ?? 0
        let normalUpdates = max(total - security, packageSummary.supportsSecurityUpdateCount ? 0 : total)
        if normalUpdates > 0, security == 0 {
            findings.append(SecurityPatchFinding(
                kind: .normalUpdatesAvailable,
                title: normalUpdates == 1 ? "Package update available" : "\(normalUpdates) package updates available",
                summary: "\(packageSummary.packageManager.displayName) reports packages that can be updated.",
                severity: .warning,
                evidenceIds: packageEvidenceIds(evidence),
                recommendation: "Review available updates and decide whether they belong in the next maintenance window."
            ))
        }

        if rebootStatus == .required {
            findings.append(SecurityPatchFinding(
                kind: .rebootRequired,
                title: "Reboot required",
                summary: "The host reports that a reboot is required to complete previous maintenance.",
                severity: security > 0 ? .high : .warning,
                evidenceIds: evidenceIds(evidence, profiles: [.reboot]),
                recommendation: "Schedule a reboot window and reconnect after the host is back online."
            ))
        }

        if packageSummary.metadataStatus == .stale {
            findings.append(SecurityPatchFinding(
                kind: .stalePackageMetadata,
                title: "Package metadata may be stale",
                summary: "The package manager cache appears old, so update status may be incomplete.",
                severity: .warning,
                evidenceIds: packageEvidenceIds(evidence),
                recommendation: "Refresh package metadata explicitly before relying on the scan result."
            ))
        }

        for setting in sshdSummary.riskySettings {
            findings.append(SecurityPatchFinding(
                kind: .riskySshdSetting,
                title: sshdTitle(for: setting),
                summary: setting.summary,
                severity: setting.severity,
                evidenceIds: setting.evidenceId.map { [$0] } ?? evidenceIds(evidence, profiles: [.sshd]),
                recommendation: "Review effective sshd settings before changing authentication or forwarding policy."
            ))
        }

        for setting in sshdSummary.weakAlgorithms {
            findings.append(SecurityPatchFinding(
                kind: .weakSshAlgorithm,
                title: weakAlgorithmTitle(for: setting.key),
                summary: setting.summary,
                severity: setting.severity,
                evidenceIds: setting.evidenceId.map { [$0] } ?? evidenceIds(evidence, profiles: [.sshd]),
                recommendation: "Remove legacy algorithms only after confirming client compatibility."
            ))
        }

        if !sshdSummary.effectiveConfigAvailable && sshdSummary.configFileReadable {
            findings.append(SecurityPatchFinding(
                kind: .permissionLimited,
                title: "Effective sshd configuration unavailable",
                summary: "The scan fell back to the readable sshd_config file. Match blocks and daemon defaults may differ from this static file view.",
                severity: .warning,
                evidenceIds: evidenceIds(evidence, profiles: [.sshd]),
                recommendation: "Use sshd -T on the host to confirm the effective daemon configuration before making changes."
            ))
        }

        if !sshdSummary.effectiveConfigAvailable && !sshdSummary.configFileReadable {
            findings.append(SecurityPatchFinding(
                kind: .permissionLimited,
                title: "SSH daemon configuration unavailable",
                summary: "The scan could not read effective sshd settings.",
                severity: .warning,
                evidenceIds: evidenceIds(evidence, profiles: [.sshd]),
                recommendation: "Run the scan with an account that can inspect sshd configuration, or review it manually."
            ))
        }

        if permissionLimited {
            findings.append(SecurityPatchFinding(
                kind: .permissionLimited,
                title: "Some checks were permission-limited",
                summary: "At least one read-only check returned permission-related output.",
                severity: .warning,
                evidenceIds: evidence.filter(\.permissionLimited).map(\.id),
                recommendation: "Treat the scan as partial and inspect the permission-limited evidence."
            ))
        }

        return findings
    }

    private static func noImmediateIssueFinding(
        bundle: SecurityPatchScanBundle,
        packageSummary: SecurityPatchPackageSummary,
        sshdSummary: SecurityPatchSshdSummary
    ) -> SecurityPatchFinding {
        let hasPackageEvidence = packageSummary.packageManager != .unknown
        let hasSshEvidence = sshdSummary.effectiveConfigAvailable || sshdSummary.configFileReadable || sshdSummary.version != nil
        let severity: SecurityPatchSeverity = hasPackageEvidence && hasSshEvidence ? .info : .unknown
        let title = severity == .info ? "No immediate security issue found" : "Security state is unknown"
        let summary = severity == .info
            ? "The read-only scan did not find pending security updates, reboot requirements, or high-risk sshd settings."
            : "The scan did not collect enough evidence to make a security claim."
        return SecurityPatchFinding(
            kind: .noImmediateIssue,
            title: title,
            summary: summary,
            severity: severity,
            evidenceIds: Array(bundle.evidence.prefix(3).map(\.id)),
            recommendation: "Re-run the scan after package metadata is refreshed if you need stronger assurance."
        )
    }

    private static func securitySummary(count: Int, importantPackages: [String]) -> String {
        guard !importantPackages.isEmpty else {
            return "The package manager reports \(count) security update\(count == 1 ? "" : "s")."
        }
        let shown = importantPackages.prefix(4).joined(separator: ", ")
        return "Security updates include infrastructure-sensitive packages: \(shown)."
    }

    private static func summaryLabel(
        findings: [SecurityPatchFinding],
        packageSummary: SecurityPatchPackageSummary,
        rebootStatus: SecurityPatchRebootStatus
    ) -> String {
        if let first = findings.first, first.kind != .noImmediateIssue {
            return first.title
        }
        if rebootStatus == .required { return "Reboot needed" }
        if (packageSummary.securityUpdateCount ?? 0) > 0 { return "Security updates available" }
        if (packageSummary.totalUpdateCount ?? 0) > 0 { return "Updates available" }
        if packageSummary.packageManager == .unknown { return "Unsupported package manager" }
        return "No immediate issue found"
    }

    private static func sshdTitle(for setting: SecurityPatchSshdSetting) -> String {
        switch setting.key {
        case "permitrootlogin":
            return "Root SSH login is enabled"
        case "passwordauthentication":
            return "SSH password authentication is enabled"
        case "kbdinteractiveauthentication":
            return "Keyboard-interactive SSH auth is enabled"
        case "permitemptypasswords":
            return "Empty-password SSH login is enabled"
        case "allowtcpforwarding":
            return "SSH TCP forwarding is enabled"
        case "maxauthtries":
            return "SSH MaxAuthTries is high"
        case "permitrootlogin+passwordauthentication":
            return "Root password SSH login is possible"
        default:
            return "Risky sshd setting: \(setting.key)"
        }
    }

    private static func weakAlgorithmTitle(for key: String) -> String {
        switch key {
        case "ciphers":
            return "Legacy SSH ciphers enabled"
        case "macs":
            return "Legacy SSH MACs enabled"
        case "kexalgorithms":
            return "Legacy SSH key exchange enabled"
        case "hostkeyalgorithms":
            return "Legacy SSH host key algorithms enabled"
        case "pubkeyacceptedalgorithms":
            return "Legacy SSH public key algorithms accepted"
        default:
            return "Legacy SSH algorithms enabled"
        }
    }

    private static func packageEvidenceIds(_ evidence: [SecurityPatchEvidence]) -> [String] {
        evidenceIds(evidence, profiles: [.packageManager])
    }

    private static func evidenceIds(
        _ evidence: [SecurityPatchEvidence],
        profiles: Set<SecurityPatchCollectorProfile>
    ) -> [String] {
        evidence.filter { profiles.contains($0.profile) }.map(\.id)
    }

    private static func evidenceIds(
        _ evidence: [SecurityPatchEvidence],
        collectorIds: Set<String>
    ) -> [String] {
        evidence.filter { collectorIds.contains($0.collectorId) }.map(\.id)
    }
}
