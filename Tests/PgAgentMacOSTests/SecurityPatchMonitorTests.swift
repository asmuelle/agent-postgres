import XCTest
@testable import PgAgentMacOS

final class SecurityPatchMonitorModelTests: XCTestCase {
    func testScanResultCodableRoundTrip() throws {
        let bundle = SecurityPatchScanBundle(
            id: "scan-1",
            connectionId: "root@example:22#tab",
            hostLabel: "example",
            scannedAt: Date(timeIntervalSince1970: 1_700_000_000),
            profiles: [.os, .packageManager, .reboot, .sshd],
            commandAudits: [],
            evidence: [
                evidence(id: "os", collectorId: "os-release", profile: .os, output: "ID=ubuntu\nVERSION_ID=\"24.04\""),
                evidence(id: "pm", collectorId: "pm-detect", profile: .packageManager, output: "/usr/bin/apt-get"),
                evidence(id: "sshd", collectorId: "sshd-effective-config", profile: .sshd, output: "permitrootlogin no\npasswordauthentication no")
            ]
        )
        let result = SecurityPatchMonitorScoring.buildResult(bundle: bundle)

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(SecurityPatchScanResult.self, from: data)

        XCTAssertEqual(decoded.connectionId, result.connectionId)
        XCTAssertEqual(decoded.packageSummary.packageManager, .apt)
        XCTAssertEqual(decoded.osInfo.id, "ubuntu")
    }

    func testScanResultDecodesLegacyPayloadWithoutAdvisoryMatches() throws {
        let result = SecurityPatchMonitorScoring.buildResult(bundle: SecurityPatchScanBundle(
            id: "scan-legacy",
            connectionId: "host",
            hostLabel: "host",
            profiles: [.packageManager],
            commandAudits: [],
            evidence: [
                evidence(id: "pm", collectorId: "pm-detect", profile: .packageManager, output: "/usr/bin/apt-get")
            ]
        ))

        let data = try JSONEncoder().encode(result)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "advisoryMatches")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(SecurityPatchScanResult.self, from: legacyData)

        XCTAssertEqual(decoded.advisoryMatches, [])
    }

    func testSeverityOrdering() {
        XCTAssertGreaterThan(SecurityPatchSeverity.critical, .high)
        XCTAssertGreaterThan(SecurityPatchSeverity.high, .warning)
        XCTAssertGreaterThan(SecurityPatchSeverity.info, .unknown)
    }
}

final class SecurityPatchMonitorParserTests: XCTestCase {
    func testOsReleaseParserHandlesQuotedValues() {
        let values = SecurityPatchMonitorParsers.parseOsRelease("""
        ID=ubuntu
        PRETTY_NAME="Ubuntu 24.04.1 LTS"
        VERSION_ID="24.04"
        """)

        XCTAssertEqual(values["ID"], "ubuntu")
        XCTAssertEqual(values["PRETTY_NAME"], "Ubuntu 24.04.1 LTS")
        XCTAssertEqual(values["VERSION_ID"], "24.04")
    }

    func testAptCheckSecurityCount() {
        let summary = SecurityPatchMonitorParsers.parsePackageSummary(evidence: [
            evidence(id: "pm", collectorId: "pm-detect", profile: .packageManager, output: "/usr/bin/apt-get"),
            evidence(id: "apt-check", collectorId: "apt-check", profile: .packageManager, output: "5;2"),
            evidence(
                id: "apt-list",
                collectorId: "apt-list-upgradable",
                profile: .packageManager,
                output: """
                Listing...
                openssl/jammy-updates 3.0 amd64 [upgradable from: 1.1]
                curl/jammy-updates 8.0 amd64 [upgradable from: 7.0]
                """
            )
        ])

        XCTAssertEqual(summary.packageManager, .apt)
        XCTAssertEqual(summary.totalUpdateCount, 2)
        XCTAssertEqual(summary.securityUpdateCount, 2)
        XCTAssertTrue(summary.supportsSecurityUpdateCount)
    }

    func testDnfSecurityOutputCountsPackages() {
        let summary = SecurityPatchMonitorParsers.parsePackageSummary(evidence: [
            evidence(id: "pm", collectorId: "pm-detect", profile: .packageManager, output: "/usr/bin/dnf"),
            evidence(
                id: "dnf-security",
                collectorId: "dnf-security-check",
                profile: .packageManager,
                output: """
                Last metadata expiration check: 0:03:21 ago.
                openssl.x86_64 1:3.0.7-25.el9 updates
                kernel-core.x86_64 5.14.0-427.el9 updates
                """
            )
        ])

        XCTAssertEqual(summary.packageManager, .dnf)
        XCTAssertEqual(summary.securityUpdateCount, 2)
        XCTAssertEqual(summary.securityUpdatePackages, ["openssl", "kernel-core"])
        XCTAssertTrue(summary.supportsSecurityUpdateCount)
    }

    func testYumSecurityPluginUnavailableKeepsMetadataUnknown() {
        let summary = SecurityPatchMonitorParsers.parsePackageSummary(evidence: [
            evidence(id: "pm", collectorId: "pm-detect", profile: .packageManager, output: "/usr/bin/yum"),
            evidence(
                id: "yum-security",
                collectorId: "yum-security-check",
                profile: .packageManager,
                output: "Error: No such command: updateinfo. Please install yum-plugin-security.",
                exitStatus: 1
            )
        ])

        XCTAssertEqual(summary.packageManager, .yum)
        XCTAssertNil(summary.securityUpdateCount)
        XCTAssertFalse(summary.supportsSecurityUpdateCount)
        XCTAssertFalse(summary.notes.isEmpty)
    }

    func testZypperSecurityPatchRows() {
        let summary = SecurityPatchMonitorParsers.parsePackageSummary(evidence: [
            evidence(id: "pm", collectorId: "pm-detect", profile: .packageManager, output: "/usr/bin/zypper"),
            evidence(
                id: "zypper-security",
                collectorId: "zypper-security-patches",
                profile: .packageManager,
                output: """
                v | update | SUSE-SU-2026:1234-1 | security | important | --- | needed | openssl
                v | update | SUSE-SU-2026:5678-1 | security | moderate | --- | needed | curl
                """
            )
        ])

        XCTAssertEqual(summary.packageManager, .zypper)
        XCTAssertEqual(summary.totalUpdateCount, 2)
        XCTAssertEqual(summary.securityUpdatePackages, ["openssl", "curl"])
        XCTAssertTrue(summary.supportsSecurityUpdateCount)
    }

    func testPacmanUpdatesAreNormalUpdateSignals() {
        let summary = SecurityPatchMonitorParsers.parsePackageSummary(evidence: [
            evidence(id: "pm", collectorId: "pm-detect", profile: .packageManager, output: "/usr/bin/pacman"),
            evidence(
                id: "pacman",
                collectorId: "pacman-updates",
                profile: .packageManager,
                output: """
                openssl 3.0.0-1 -> 3.0.1-1
                linux 6.1-1 -> 6.2-1
                """
            )
        ])

        XCTAssertEqual(summary.packageManager, .pacman)
        XCTAssertEqual(summary.totalUpdateCount, 2)
        XCTAssertNil(summary.securityUpdateCount)
        XCTAssertEqual(summary.updatePackages, ["openssl", "linux"])
        XCTAssertFalse(summary.supportsSecurityUpdateCount)
    }

    func testApkVersionOutputStripsVersionSuffixes() {
        let summary = SecurityPatchMonitorParsers.parsePackageSummary(evidence: [
            evidence(id: "pm", collectorId: "pm-detect", profile: .packageManager, output: "/sbin/apk"),
            evidence(
                id: "apk",
                collectorId: "apk-updates",
                profile: .packageManager,
                output: """
                openssl-3.1.4-r0 < 3.1.5-r0
                busybox-1.36.1-r2 < 1.36.1-r3
                """
            )
        ])

        XCTAssertEqual(summary.packageManager, .apk)
        XCTAssertEqual(summary.totalUpdateCount, 2)
        XCTAssertEqual(summary.updatePackages, ["openssl", "busybox"])
        XCTAssertFalse(summary.supportsSecurityUpdateCount)
    }

    func testHomebrewOutdatedJsonCountsFormulaeAndCasks() {
        let summary = SecurityPatchMonitorParsers.parsePackageSummary(evidence: [
            evidence(id: "pm", collectorId: "pm-detect", profile: .packageManager, output: "/opt/homebrew/bin/brew"),
            evidence(
                id: "brew",
                collectorId: "brew-outdated",
                profile: .packageManager,
                output: """
                {"formulae":[{"name":"openssl@3"},{"name":"git"}],"casks":[{"name":"iterm2"}]}
                """
            )
        ])

        XCTAssertEqual(summary.packageManager, .homebrew)
        XCTAssertEqual(summary.totalUpdateCount, 3)
        XCTAssertEqual(summary.updatePackages, ["openssl@3", "git", "iterm2"])
        XCTAssertFalse(summary.supportsSecurityUpdateCount)
    }

    func testSshdParserFlagsRootPasswordLogin() {
        let summary = SecurityPatchMonitorParsers.parseSshdSummary(evidence: [
            evidence(
                id: "sshd-effective",
                collectorId: "sshd-effective-config",
                profile: .sshd,
                output: """
                permitrootlogin yes
                passwordauthentication yes
                maxauthtries 10
                ciphers aes128-ctr,aes128-cbc
                """
            )
        ])

        XCTAssertTrue(summary.effectiveConfigAvailable)
        XCTAssertTrue(summary.riskySettings.contains { $0.id == "root-password-login" })
        XCTAssertFalse(summary.riskySettings.contains { $0.key == "permitrootlogin" })
        XCTAssertFalse(summary.riskySettings.contains { $0.key == "passwordauthentication" })
        XCTAssertTrue(summary.weakAlgorithms.contains { $0.key == "ciphers" })
    }

    func testSshdPasswordAuthAloneStaysWarning() {
        let summary = SecurityPatchMonitorParsers.parseSshdSummary(evidence: [
            evidence(
                id: "sshd-effective",
                collectorId: "sshd-effective-config",
                profile: .sshd,
                output: """
                permitrootlogin no
                passwordauthentication yes
                maxauthtries 6
                """
            )
        ])

        let setting = summary.riskySettings.first { $0.key == "passwordauthentication" }
        XCTAssertEqual(setting?.severity, .warning)
        XCTAssertFalse(summary.riskySettings.contains { $0.id == "root-password-login" })
    }

    func testSshdEffectiveOutputMissingMaxAuthTriesIsWarning() {
        let summary = SecurityPatchMonitorParsers.parseSshdSummary(evidence: [
            evidence(
                id: "sshd-effective",
                collectorId: "sshd-effective-config",
                profile: .sshd,
                output: """
                permitrootlogin no
                passwordauthentication no
                """
            )
        ])

        let setting = summary.riskySettings.first { $0.id == "maxauthtries=missing" }
        XCTAssertEqual(setting?.severity, .warning)
    }

    func testWeakAlgorithmClassificationSeparatesWarningAndHigh() {
        let summary = SecurityPatchMonitorParsers.parseSshdSummary(evidence: [
            evidence(
                id: "sshd-effective",
                collectorId: "sshd-effective-config",
                profile: .sshd,
                output: """
                maxauthtries 6
                ciphers aes256-gcm@openssh.com,aes128-cbc
                macs hmac-sha1-etm@openssh.com
                hostkeyalgorithms rsa-sha2-512,ssh-rsa
                """
            )
        ])

        XCTAssertEqual(summary.weakAlgorithms.first { $0.key == "ciphers" }?.severity, .high)
        XCTAssertEqual(summary.weakAlgorithms.first { $0.key == "macs" }?.severity, .warning)
        XCTAssertEqual(summary.weakAlgorithms.first { $0.key == "hostkeyalgorithms" }?.severity, .warning)
    }

    func testRebootRequiredFile() {
        let status = SecurityPatchMonitorParsers.parseRebootStatus(evidence: [
            evidence(
                id: "reboot",
                collectorId: "reboot-required-file",
                profile: .reboot,
                output: "*** System restart required ***"
            )
        ])

        XCTAssertEqual(status, .required)
    }
}

final class SecurityPatchMonitorAdvisoryCorrelationTests: XCTestCase {
    func testExtractCveIdsDeduplicatesCaseInsensitively() {
        let cves = SecurityPatchMonitorAdvisoryCorrelation.extractCveIds(evidence: [
            evidence(
                id: "dnf",
                collectorId: "dnf-updateinfo-security",
                profile: .packageManager,
                output: "CVE-2024-3094 cve-2024-3094 CVE-2023-12345 not-a-cve-2024"
            )
        ])

        XCTAssertEqual(cves, ["CVE-2024-3094", "CVE-2023-12345"])
    }

    func testCisaKevCatalogDecodesRepresentativeJson() throws {
        let json = """
        {
          "title": "CISA Known Exploited Vulnerabilities Catalog",
          "catalogVersion": "2026.05.15",
          "dateReleased": "2026-05-15T16:55:06Z",
          "count": 1,
          "vulnerabilities": [
            {
              "cveID": "CVE-2024-3094",
              "vendorProject": "XZ Utils",
              "product": "XZ Utils",
              "vulnerabilityName": "XZ Utils Backdoor Vulnerability",
              "dateAdded": "2024-04-01",
              "shortDescription": "Malicious code was discovered in XZ Utils.",
              "requiredAction": "Apply mitigations per vendor instructions.",
              "dueDate": "2024-04-22",
              "knownRansomwareCampaignUse": "Unknown",
              "notes": "Example"
            }
          ]
        }
        """

        let decoded = try JSONDecoder().decode(SecurityPatchKevCatalog.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.vulnerabilities.first?.cveID, "CVE-2024-3094")
    }

    func testKevCorrelationAddsCriticalFinding() {
        let base = SecurityPatchMonitorScoring.buildResult(bundle: SecurityPatchScanBundle(
            id: "scan-kev",
            connectionId: "host",
            hostLabel: "host",
            profiles: [.packageManager, .sshd],
            commandAudits: [],
            evidence: [
                evidence(id: "pm", collectorId: "pm-detect", profile: .packageManager, output: "/usr/bin/dnf"),
                evidence(
                    id: "dnf-updateinfo",
                    collectorId: "dnf-updateinfo-security",
                    profile: .packageManager,
                    output: "FEDORA-2024-1234 Important/Sec. xz.x86_64 CVE-2024-3094"
                ),
                evidence(id: "sshd", collectorId: "sshd-effective-config", profile: .sshd, output: "permitrootlogin no\nmaxauthtries 6")
            ]
        ))
        let catalog = SecurityPatchKevCatalog(vulnerabilities: [
            SecurityPatchKevVulnerability(
                cveID: "CVE-2024-3094",
                vendorProject: "XZ Utils",
                product: "XZ Utils",
                vulnerabilityName: "XZ Utils Backdoor Vulnerability",
                requiredAction: "Apply mitigations per vendor instructions.",
                dueDate: "2024-04-22",
                knownRansomwareCampaignUse: "Unknown"
            )
        ])

        let correlated = SecurityPatchMonitorAdvisoryCorrelation.correlate(result: base, kevCatalog: catalog)

        XCTAssertEqual(correlated.advisoryMatches.count, 1)
        XCTAssertEqual(correlated.advisoryMatches.first?.evidenceIds, ["dnf-updateinfo"])
        XCTAssertEqual(correlated.overallSeverity, .critical)
        XCTAssertEqual(correlated.hostSummary.badge, .critical)
        XCTAssertTrue(correlated.findings.contains { $0.kind == .knownExploitedVulnerability })
    }

    func testKevCorrelationDoesNotCreateMatchWithoutCatalogEntry() {
        let base = SecurityPatchMonitorScoring.buildResult(bundle: SecurityPatchScanBundle(
            id: "scan-no-kev",
            connectionId: "host",
            hostLabel: "host",
            profiles: [.packageManager],
            commandAudits: [],
            evidence: [
                evidence(id: "pm", collectorId: "pm-detect", profile: .packageManager, output: "/usr/bin/dnf"),
                evidence(id: "dnf-updateinfo", collectorId: "dnf-updateinfo-security", profile: .packageManager, output: "CVE-2099-12345")
            ]
        ))

        let correlated = SecurityPatchMonitorAdvisoryCorrelation.correlate(
            result: base,
            kevCatalog: SecurityPatchKevCatalog(vulnerabilities: [])
        )

        XCTAssertEqual(correlated.advisoryMatches, [])
        XCTAssertFalse(correlated.findings.contains { $0.kind == .knownExploitedVulnerability })
    }
}

final class SecurityPatchMonitorScoringTests: XCTestCase {
    func testUnsupportedPackageManagerDoesNotBecomeSecure() {
        let result = SecurityPatchMonitorScoring.buildResult(bundle: SecurityPatchScanBundle(
            id: "scan",
            connectionId: "host",
            hostLabel: "host",
            profiles: [.os, .packageManager],
            commandAudits: [],
            evidence: [
                evidence(id: "pm", collectorId: "pm-detect", profile: .packageManager, output: "")
            ]
        ))

        XCTAssertEqual(result.packageSummary.packageManager, .unknown)
        XCTAssertEqual(result.hostSummary.badge, .unsupported)
        XCTAssertNotEqual(result.hostSummary.badge, .secure)
    }

    func testImportantSecurityPackageEscalatesToCritical() {
        let result = SecurityPatchMonitorScoring.buildResult(bundle: SecurityPatchScanBundle(
            id: "scan",
            connectionId: "host",
            hostLabel: "host",
            profiles: [.packageManager, .sshd],
            commandAudits: [],
            evidence: [
                evidence(id: "pm", collectorId: "pm-detect", profile: .packageManager, output: "/usr/bin/apt-get"),
                evidence(id: "apt-check", collectorId: "apt-check", profile: .packageManager, output: "1;1"),
                evidence(
                    id: "apt-list",
                    collectorId: "apt-list-upgradable",
                    profile: .packageManager,
                    output: "openssl/jammy-security 3.0 amd64 [upgradable from: 1.1]"
                ),
                evidence(
                    id: "sshd",
                    collectorId: "sshd-effective-config",
                    profile: .sshd,
                    output: "permitrootlogin no\npasswordauthentication no"
                )
            ]
        ))

        XCTAssertEqual(result.overallSeverity, .critical)
        XCTAssertEqual(result.hostSummary.badge, .critical)
    }

    func testNormalUpdatesRankBelowSecurityUpdates() {
        let normal = SecurityPatchMonitorScoring.buildResult(bundle: SecurityPatchScanBundle(
            id: "normal",
            connectionId: "host",
            hostLabel: "host",
            profiles: [.packageManager, .sshd],
            commandAudits: [],
            evidence: [
                evidence(id: "pm", collectorId: "pm-detect", profile: .packageManager, output: "/usr/bin/pacman"),
                evidence(id: "pacman", collectorId: "pacman-updates", profile: .packageManager, output: "jq 1.0 -> 1.1"),
                evidence(id: "sshd", collectorId: "sshd-effective-config", profile: .sshd, output: "permitrootlogin no")
            ]
        ))
        let security = SecurityPatchMonitorScoring.buildResult(bundle: SecurityPatchScanBundle(
            id: "security",
            connectionId: "host",
            hostLabel: "host",
            profiles: [.packageManager, .sshd],
            commandAudits: [],
            evidence: [
                evidence(id: "pm", collectorId: "pm-detect", profile: .packageManager, output: "/usr/bin/apt-get"),
                evidence(id: "apt-check", collectorId: "apt-check", profile: .packageManager, output: "1;1"),
                evidence(id: "apt-list", collectorId: "apt-list-upgradable", profile: .packageManager, output: "curl/jammy-security 8.0 amd64"),
                evidence(id: "sshd", collectorId: "sshd-effective-config", profile: .sshd, output: "permitrootlogin no")
            ]
        ))

        XCTAssertGreaterThan(security.overallSeverity, normal.overallSeverity)
    }

    func testEffectiveSshdFallbackConfigProducesExplicitWarning() {
        let result = SecurityPatchMonitorScoring.buildResult(bundle: SecurityPatchScanBundle(
            id: "fallback",
            connectionId: "host",
            hostLabel: "host",
            profiles: [.packageManager, .sshd],
            commandAudits: [],
            evidence: [
                evidence(id: "pm", collectorId: "pm-detect", profile: .packageManager, output: "/usr/bin/apt-get"),
                evidence(id: "apt-check", collectorId: "apt-check", profile: .packageManager, output: "0;0"),
                evidence(id: "apt-list", collectorId: "apt-list-upgradable", profile: .packageManager, output: ""),
                evidence(
                    id: "sshd-effective",
                    collectorId: "sshd-effective-config",
                    profile: .sshd,
                    output: "sshd unavailable"
                ),
                evidence(
                    id: "sshd-config",
                    collectorId: "sshd-config-file",
                    profile: .sshd,
                    output: """
                    PermitRootLogin no
                    PasswordAuthentication no
                    """
                )
            ]
        ))

        XCTAssertTrue(result.findings.contains { $0.title == "Effective sshd configuration unavailable" })
        XCTAssertNotEqual(result.hostSummary.badge, .secure)
    }

    func testRootPasswordLoginEscalatesToCriticalFinding() {
        let result = SecurityPatchMonitorScoring.buildResult(bundle: SecurityPatchScanBundle(
            id: "ssh-risk",
            connectionId: "host",
            hostLabel: "host",
            profiles: [.packageManager, .sshd],
            commandAudits: [],
            evidence: [
                evidence(id: "pm", collectorId: "pm-detect", profile: .packageManager, output: "/usr/bin/apt-get"),
                evidence(id: "apt-check", collectorId: "apt-check", profile: .packageManager, output: "0;0"),
                evidence(id: "apt-list", collectorId: "apt-list-upgradable", profile: .packageManager, output: ""),
                evidence(
                    id: "sshd",
                    collectorId: "sshd-effective-config",
                    profile: .sshd,
                    output: """
                    permitrootlogin yes
                    passwordauthentication yes
                    maxauthtries 6
                    """
                )
            ]
        ))

        XCTAssertEqual(result.overallSeverity, .critical)
        XCTAssertTrue(result.findings.contains { $0.title == "Root password SSH login is possible" })
    }
}

private func evidence(
    id: String,
    collectorId: String,
    profile: SecurityPatchCollectorProfile,
    output: String,
    exitStatus: Int? = 0
) -> SecurityPatchEvidence {
    SecurityPatchEvidence(
        id: id,
        collectorId: collectorId,
        profile: profile,
        kind: .commandOutput,
        title: collectorId,
        source: collectorId,
        collectedAt: Date(timeIntervalSince1970: 1_700_000_000),
        exitStatus: exitStatus,
        excerpt: output,
        rawOutput: output,
        rawRef: "security-patch://scan/\(id)",
        byteCount: output.utf8.count,
        lineCount: output.split(whereSeparator: \.isNewline).count,
        truncated: false,
        permissionLimited: false
    )
}
