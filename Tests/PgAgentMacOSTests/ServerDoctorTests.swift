import XCTest
@testable import PgAgentMacOS

final class ServerDoctorRedactorTests: XCTestCase {
    func testBalancedRedactsSecretsButKeepsOperationalPaths() {
        let input = """
        password=hunter2
        /etc/nginx/sites-enabled/app.conf
        Authorization: Bearer abc123
        """

        let result = ServerDoctorRedactor.redact(input, preset: .balanced)

        XCTAssertFalse(result.text.contains("hunter2"))
        XCTAssertFalse(result.text.contains("abc123"))
        XCTAssertTrue(result.text.contains("/etc/nginx/sites-enabled/app.conf"))
        XCTAssertGreaterThanOrEqual(result.replacementCount, 2)
    }

    func testStrictRedactsIpAndEmail() {
        let input = "failed login from 192.0.2.10 for admin@example.com"

        let result = ServerDoctorRedactor.redact(input, preset: .strict)

        XCTAssertFalse(result.text.contains("192.0.2.10"))
        XCTAssertFalse(result.text.contains("admin@example.com"))
    }

    func testPrivateKeyBlockIsRedacted() {
        let input = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        secret material
        -----END OPENSSH PRIVATE KEY-----
        """

        let result = ServerDoctorRedactor.redact(input, preset: .balanced)

        XCTAssertFalse(result.text.contains("secret material"))
        XCTAssertTrue(result.text.contains("[redacted private key]"))
    }
}

final class ServerDoctorReportValidatorTests: XCTestCase {
    func testFindingMustCiteExistingEvidence() {
        let evidence = sampleEvidence(id: "evidence-a", source: "nginx -t", output: "ok")
        let report = ServerDoctorReport(
            hostLabel: "web",
            reportTitle: "Bad finding",
            summary: "Missing evidence.",
            overallSeverity: .warning,
            overallConfidence: .medium,
            collectedAt: Date(),
            findings: [
                ServerDoctorFinding(
                    title: "Missing evidence",
                    summary: "This cites evidence that does not exist.",
                    severity: .warning,
                    confidence: .medium,
                    affectedSubsystem: "Test",
                    evidenceIds: ["missing"]
                )
            ],
            redaction: ServerDoctorRedactionSummary(preset: .balanced)
        )

        let validation = ServerDoctorReportValidator.validate(report: report, evidence: [evidence])

        XCTAssertFalse(validation.isValid)
        XCTAssertTrue(validation.errors.contains { $0.contains("missing") })
    }

    func testMutatingActionIsRejected() {
        let evidence = sampleEvidence(id: "evidence-a", source: "nginx -t", output: "failed")
        let report = ServerDoctorReport(
            hostLabel: "web",
            reportTitle: "Unsafe",
            summary: "Unsafe action.",
            overallSeverity: .high,
            overallConfidence: .medium,
            collectedAt: Date(),
            findings: [
                ServerDoctorFinding(
                    title: "Unsafe",
                    summary: "Unsafe action.",
                    severity: .high,
                    confidence: .medium,
                    affectedSubsystem: "Web",
                    evidenceIds: [evidence.id],
                    safeNextSteps: [
                        ServerDoctorSuggestedAction(
                            kind: .runReadOnlyFollowup,
                            title: "restart nginx"
                        )
                    ]
                )
            ],
            redaction: ServerDoctorRedactionSummary(preset: .balanced)
        )

        let validation = ServerDoctorReportValidator.validate(report: report, evidence: [evidence])

        XCTAssertFalse(validation.isValid)
        XCTAssertTrue(validation.errors.contains { $0.contains("mutating") })
    }
}

final class ServerDoctorHeuristicsTests: XCTestCase {
    func testNginxMissingCertificateCreatesHighConfidenceFinding() {
        let evidence = sampleEvidence(
            id: "evidence-nginx",
            source: "nginx -t 2>&1",
            output: #"cannot load certificate "/etc/letsencrypt/live/app/fullchain.pem": BIO_new_file() failed (No such file)"#,
            exitStatus: 1
        )
        let bundle = ServerDoctorCollectionBundle(
            id: "bundle",
            hostLabel: "web",
            profiles: [.nginx],
            commandAudits: [],
            evidence: [evidence]
        )

        let report = ServerDoctorHeuristics.generateReport(
            bundle: bundle,
            redaction: ServerDoctorRedactionSummary(preset: .balanced)
        )

        XCTAssertEqual(report.findings.first?.title, "nginx references a missing certificate")
        XCTAssertEqual(report.findings.first?.severity, .high)
        XCTAssertEqual(report.findings.first?.confidence, .high)
        XCTAssertEqual(report.findings.first?.evidenceIds, [evidence.id])
    }
}

private func sampleEvidence(
    id: String,
    source: String,
    output: String,
    exitStatus: Int? = 0
) -> ServerDoctorEvidence {
    ServerDoctorEvidence(
        id: id,
        kind: .commandOutput,
        title: "Sample",
        source: source,
        collectedAt: Date(),
        exitStatus: exitStatus,
        excerpt: output,
        rawOutput: output,
        rawRef: "doctor://sample/\(id)",
        byteCount: output.utf8.count,
        lineCount: output.split(whereSeparator: \.isNewline).count,
        truncated: false,
        permissionLimited: false
    )
}
