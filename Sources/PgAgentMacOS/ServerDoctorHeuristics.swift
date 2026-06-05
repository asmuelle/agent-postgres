import Foundation

public enum ServerDoctorHeuristics {
    public static func generateReport(
        bundle: ServerDoctorCollectionBundle,
        redaction: ServerDoctorRedactionSummary
    ) -> ServerDoctorReport {
        var findings: [ServerDoctorFinding] = []
        findings.append(contentsOf: nginxFindings(bundle.evidence))
        findings.append(contentsOf: systemdFindings(bundle.evidence))
        findings.append(contentsOf: diskFindings(bundle.evidence))
        findings.append(contentsOf: journalFindings(bundle.evidence))
        findings.append(contentsOf: permissionFindings(bundle.evidence))

        if findings.isEmpty {
            if bundle.evidence.isEmpty {
                findings.append(ServerDoctorFinding(
                    title: "No diagnostic evidence collected",
                    summary: "The read-only collectors did not return usable evidence for this host.",
                    severity: .unknown,
                    confidence: .medium,
                    affectedSubsystem: "Collection",
                    evidenceIds: bundle.warnings.map(\.id),
                    safeNextSteps: [],
                    explanation: "This usually means the host rejected the commands, the connection closed, or the selected profile does not have shell access."
                ))
            } else {
                let first = bundle.evidence.first?.id ?? ""
                findings.append(ServerDoctorFinding(
                    title: "No high-signal issue found",
                    summary: "The first-pass read-only checks did not find a clear service, disk, or configuration failure.",
                    severity: .info,
                    confidence: .medium,
                    affectedSubsystem: "Summary",
                    evidenceIds: first.isEmpty ? [] : [first],
                    safeNextSteps: [
                        ServerDoctorSuggestedAction(kind: .inspectEvidence, title: "Review collected evidence")
                    ],
                    explanation: "This does not prove the server is healthy. It means the bounded collectors did not find a strong known pattern."
                ))
            }
        }

        findings.sort { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }

        let overallSeverity = findings.map(\.severity).max() ?? .info
        let confidence: ServerDoctorConfidence = findings.contains { $0.confidence == .high } ? .high : .medium
        return ServerDoctorReport(
            hostLabel: bundle.hostLabel,
            reportTitle: reportTitle(for: findings),
            summary: summary(for: findings, evidenceCount: bundle.evidence.count),
            overallSeverity: overallSeverity,
            overallConfidence: confidence,
            collectedAt: bundle.collectedAt,
            findings: findings,
            questionsToResolve: bundle.warnings.map(\.message),
            provider: .localHeuristics,
            redaction: redaction
        )
    }

    private static func nginxFindings(_ evidence: [ServerDoctorEvidence]) -> [ServerDoctorFinding] {
        guard let nginxTest = evidence.first(where: { $0.source.contains("nginx -t") }) else { return [] }
        let text = searchable(nginxTest)
        guard nginxTest.exitStatus != 0 || text.contains("test failed") || text.contains("[emerg]") else { return [] }

        var title = "nginx configuration test failed"
        var summary = "nginx reported that its active configuration is not valid."
        if text.contains("certificate") && (text.contains("no such file") || text.contains("cannot load")) {
            title = "nginx references a missing certificate"
            summary = "The nginx config test points at a certificate file that cannot be loaded."
        } else if text.contains("bind()") || text.contains("address already in use") {
            title = "nginx cannot bind to a configured port"
            summary = "nginx reported a port binding failure, often caused by another process using the same port."
        }

        return [ServerDoctorFinding(
            title: title,
            summary: summary,
            severity: .high,
            confidence: .high,
            affectedSubsystem: "Web",
            affectedService: "nginx",
            evidenceIds: [nginxTest.id],
            safeNextSteps: [
                ServerDoctorSuggestedAction(kind: .inspectEvidence, title: "Review nginx test output", target: nginxTest.id)
            ],
            unsafeActionsToAvoid: ["Do not reload nginx until the config test passes."],
            explanation: "The config test is authoritative for syntax and file-reference errors. A failed test means a reload would not safely apply the current configuration."
        )]
    }

    private static func systemdFindings(_ evidence: [ServerDoctorEvidence]) -> [ServerDoctorFinding] {
        let matches = evidence.filter { $0.source.contains("systemctl") && searchable($0).contains("failed") }
        return matches.compactMap { item in
            let lower = searchable(item)
            guard !lower.contains("0 loaded units listed") && !lower.contains("0 unit files listed") else { return nil }
            return ServerDoctorFinding(
                title: "Failed systemd units reported",
                summary: "systemd returned one or more failed units in the read-only scan.",
                severity: .warning,
                confidence: .medium,
                affectedSubsystem: "Services",
                affectedService: nil,
                evidenceIds: [item.id],
                safeNextSteps: [
                    ServerDoctorSuggestedAction(kind: .inspectEvidence, title: "Review failed units", target: item.id)
                ],
                explanation: "A failed unit is not always the root cause, but it is usually the best next place to inspect service logs and recent state."
            )
        }
    }

    private static func diskFindings(_ evidence: [ServerDoctorEvidence]) -> [ServerDoctorFinding] {
        evidence
            .filter { $0.source.contains("df -") }
            .flatMap { item -> [ServerDoctorFinding] in
                parseDiskPercents(item).compactMap { mount, percent in
                    guard percent >= 80 else { return nil }
                    return ServerDoctorFinding(
                        title: percent >= 92 ? "Disk pressure on \(mount)" : "Disk usage is high on \(mount)",
                        summary: "\(mount) is \(percent)% full.",
                        severity: percent >= 92 ? .high : .warning,
                        confidence: .high,
                        affectedSubsystem: "Disk",
                        evidenceIds: [item.id],
                        safeNextSteps: [
                            ServerDoctorSuggestedAction(kind: .inspectEvidence, title: "Review disk usage evidence", target: item.id)
                        ],
                        unsafeActionsToAvoid: ["Do not delete files until you know which service owns them."],
                        explanation: "High disk usage can cause services to fail writes, prevent logins, and break databases. The read-only scan only identifies pressure; cleanup should be planned separately."
                    )
                }
            }
    }

    private static func journalFindings(_ evidence: [ServerDoctorEvidence]) -> [ServerDoctorFinding] {
        evidence.compactMap { item in
            let text = searchable(item)
            if text.contains("out of memory") || text.contains("oom-kill") || text.contains("killed process") {
                return ServerDoctorFinding(
                    title: "Recent memory pressure or OOM event",
                    summary: "Recent logs contain out-of-memory or process-kill signals.",
                    severity: .high,
                    confidence: .medium,
                    affectedSubsystem: "Memory",
                    evidenceIds: [item.id],
                    safeNextSteps: [
                        ServerDoctorSuggestedAction(kind: .inspectEvidence, title: "Review memory-related logs", target: item.id)
                    ],
                    explanation: "OOM events mean the kernel or service manager killed work because memory was exhausted. The next inspection should identify which process grew and whether this is recurring."
                )
            }
            return nil
        }
    }

    private static func permissionFindings(_ evidence: [ServerDoctorEvidence]) -> [ServerDoctorFinding] {
        let limited = evidence.filter(\.permissionLimited)
        guard !limited.isEmpty else { return [] }
        return [ServerDoctorFinding(
            title: "Some diagnostics were permission-limited",
            summary: "\(limited.count) read-only check\(limited.count == 1 ? "" : "s") returned permission-related output.",
            severity: .unknown,
            confidence: .high,
            affectedSubsystem: "Collection",
            evidenceIds: limited.map(\.id),
            safeNextSteps: [
                ServerDoctorSuggestedAction(kind: .inspectEvidence, title: "Review permission-limited evidence")
            ],
            explanation: "The report may be incomplete because the current account could not read every log or status source. The scan continued with the evidence it could collect."
        )]
    }

    private static func parseDiskPercents(_ evidence: ServerDoctorEvidence) -> [(String, Int)] {
        evidence.rawOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard fields.count >= 6 else { return nil }
                guard let percentToken = fields.first(where: { $0.hasSuffix("%") }),
                      let percent = Int(percentToken.dropLast()) else { return nil }
                let mount = fields.last ?? "unknown"
                return (mount, percent)
            }
    }

    private static func searchable(_ evidence: ServerDoctorEvidence) -> String {
        "\(evidence.redactedExcerpt)\n\(evidence.rawOutput)".lowercased()
    }

    private static func reportTitle(for findings: [ServerDoctorFinding]) -> String {
        guard let first = findings.first else { return "Server Doctor report" }
        return first.title
    }

    private static func summary(for findings: [ServerDoctorFinding], evidenceCount: Int) -> String {
        guard let first = findings.first else {
            return "Collected \(evidenceCount) evidence item\(evidenceCount == 1 ? "" : "s")."
        }
        return first.summary
    }
}

