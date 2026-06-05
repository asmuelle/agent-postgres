import Foundation

public enum ServerDoctorReportValidator {
    public static func validate(
        report: ServerDoctorReport,
        evidence: [ServerDoctorEvidence]
    ) -> ServerDoctorReportValidationResult {
        let evidenceIds = Set(evidence.map(\.id))
        var errors: [String] = []

        for finding in report.findings {
            if finding.evidenceIds.isEmpty {
                errors.append("Finding '\(finding.title)' has no evidence.")
            }
            for id in finding.evidenceIds where !evidenceIds.contains(id) {
                errors.append("Finding '\(finding.title)' cites missing evidence '\(id)'.")
            }
            for action in finding.safeNextSteps where isMutating(action.title) || isMutating(action.target ?? "") {
                errors.append("Finding '\(finding.title)' contains a mutating action '\(action.title)'.")
            }
        }

        return ServerDoctorReportValidationResult(isValid: errors.isEmpty, errors: errors)
    }

    public static func filteredReadOnlyReport(
        _ report: ServerDoctorReport,
        evidence: [ServerDoctorEvidence]
    ) -> ServerDoctorReport {
        let evidenceIds = Set(evidence.map(\.id))
        let findings = report.findings.filter { finding in
            !finding.evidenceIds.isEmpty
                && finding.evidenceIds.allSatisfy { evidenceIds.contains($0) }
                && finding.safeNextSteps.allSatisfy { !isMutating($0.title) && !isMutating($0.target ?? "") }
        }
        var copy = report
        copy.findings = findings
        copy.overallSeverity = findings.map(\.severity).max() ?? .info
        return copy
    }

    public static func isMutating(_ text: String) -> Bool {
        let lower = text.lowercased()
        let blocked = [
            " rm ", " rm -", "delete ", "remove ",
            "restart", "reload", "stop ", "start ",
            "chmod", "chown", "kill ", "pkill",
            "apt install", "apt upgrade", "apt remove",
            "dnf install", "yum install", "brew install",
            "drop table", "truncate table", "update ", "insert ", "delete from",
        ]
        let padded = " \(lower) "
        return blocked.contains { padded.contains($0) }
    }
}

