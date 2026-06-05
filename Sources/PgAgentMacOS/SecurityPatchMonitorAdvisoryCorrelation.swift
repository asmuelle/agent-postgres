import Foundation

public enum SecurityPatchMonitorAdvisoryCorrelation {
    public static func extractCveIds(evidence: [SecurityPatchEvidence]) -> [String] {
        uniqueCves(
            evidence.flatMap { item in
                extractCveIds(from: item.rawOutput) + extractCveIds(from: item.excerpt)
            }
        )
    }

    public static func extractCveIds(from text: String) -> [String] {
        guard !text.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"\bCVE-\d{4}-\d{4,}\b"#, options: [.caseInsensitive]) else {
            return []
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range]).uppercased()
        }
    }

    public static func correlate(
        result: SecurityPatchScanResult,
        kevCatalog: SecurityPatchKevCatalog
    ) -> SecurityPatchScanResult {
        let matches = matches(evidence: result.evidence, kevCatalog: kevCatalog)
        var updated = result
        updated.advisoryMatches = matches
        updated.findings.removeAll { $0.kind == .knownExploitedVulnerability }

        guard !matches.isEmpty else {
            updated.overallSeverity = updated.findings.map(\.severity).max() ?? .unknown
            return updated
        }

        let evidenceIds = uniqueValues(matches.flatMap(\.evidenceIds))
        updated.findings.append(SecurityPatchFinding(
            kind: .knownExploitedVulnerability,
            title: matches.count == 1
                ? "Known exploited CVE referenced"
                : "\(matches.count) known exploited CVEs referenced",
            summary: advisorySummary(matches),
            severity: .critical,
            evidenceIds: evidenceIds,
            recommendation: "Prioritize remediation for CISA KEV matches. Confirm package-manager vendor status before applying changes."
        ))

        updated.findings.sort { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        updated.overallSeverity = updated.findings.map(\.severity).max() ?? .unknown
        if let first = updated.findings.first, first.kind != .noImmediateIssue {
            updated.summaryLabel = first.title
        }
        return updated
    }

    public static func matches(
        evidence: [SecurityPatchEvidence],
        kevCatalog: SecurityPatchKevCatalog
    ) -> [SecurityPatchAdvisoryMatch] {
        var catalog: [String: SecurityPatchKevVulnerability] = [:]
        for vulnerability in kevCatalog.vulnerabilities {
            catalog[vulnerability.cveID.uppercased()] = vulnerability
        }
        let evidenceByCve = evidenceIdsByCve(evidence)

        return evidenceByCve.keys.sorted().compactMap { cveId in
            guard let vulnerability = catalog[cveId] else { return nil }
            return SecurityPatchAdvisoryMatch(
                source: .cisaKev,
                cveId: cveId,
                title: vulnerability.vulnerabilityName,
                vendorProject: vulnerability.vendorProject,
                product: vulnerability.product,
                dueDate: vulnerability.dueDate,
                knownRansomwareCampaignUse: vulnerability.knownRansomwareCampaignUse,
                requiredAction: vulnerability.requiredAction,
                notes: vulnerability.notes,
                evidenceIds: evidenceByCve[cveId] ?? []
            )
        }
    }

    private static func evidenceIdsByCve(_ evidence: [SecurityPatchEvidence]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for item in evidence {
            let cves = uniqueCves(extractCveIds(from: item.rawOutput) + extractCveIds(from: item.excerpt))
            for cve in cves {
                out[cve, default: []].append(item.id)
            }
        }
        return out.mapValues(uniqueValues)
    }

    private static func advisorySummary(_ matches: [SecurityPatchAdvisoryMatch]) -> String {
        let shown = matches
            .prefix(4)
            .map { "\($0.cveId) (\($0.vendorProject) \($0.product))" }
            .joined(separator: ", ")
        let suffix = matches.count > 4 ? " and \(matches.count - 4) more" : ""
        return "Scan evidence references CISA Known Exploited Vulnerabilities: \(shown)\(suffix)."
    }

    private static func uniqueCves(_ values: [String]) -> [String] {
        uniqueValues(values.map { $0.uppercased() })
    }

    private static func uniqueValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values where seen.insert(value).inserted {
            out.append(value)
        }
        return out
    }
}
