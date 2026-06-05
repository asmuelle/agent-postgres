import Foundation

public struct ServerDoctorRedactionResult: Codable, Equatable, Sendable {
    public var text: String
    public var replacementCount: Int
    public var categories: [String: Int]

    public init(text: String, replacementCount: Int = 0, categories: [String: Int] = [:]) {
        self.text = text
        self.replacementCount = replacementCount
        self.categories = categories
    }
}

public enum ServerDoctorRedactor {
    public static func redact(_ input: String, preset: ServerDoctorPrivacyPreset) -> ServerDoctorRedactionResult {
        var result = ServerDoctorRedactionResult(text: input)
        apply(&result, category: "private_key", pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----"#, template: "[redacted private key]", options: [.dotMatchesLineSeparators])
        apply(&result, category: "authorization", pattern: #"(?i)(authorization)\s*:\s*[^\r\n]+"#, template: "$1: [redacted]")
        apply(&result, category: "secret_kv", pattern: #"(?i)\b(password|passphrase|secret|token|api[_-]?key|private[_ -]?key)\s*[:=]\s*[^,\s;'"]+"#, template: "$1=[redacted]")
        apply(&result, category: "database_url", pattern: #"(?i)\b([a-z][a-z0-9+.-]*://)([^:\s/@]+):([^@\s]+)@([^\s]+)"#, template: "$1[redacted]@[redacted-host]")
        apply(&result, category: "aws_access_key", pattern: #"\bA(KIA|SIA)[A-Z0-9]{16}\b"#, template: "[redacted access key]")
        apply(&result, category: "cookie", pattern: #"(?i)(cookie|set-cookie)\s*:\s*[^\r\n]+"#, template: "$1: [redacted]")

        if preset == .strict || preset == .localOnly {
            apply(&result, category: "email", pattern: #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, template: "[redacted-email]", options: [.caseInsensitive])
            apply(&result, category: "ipv4", pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, template: "[redacted-ip]")
            apply(&result, category: "domain", pattern: #"\b(?:[A-Z0-9-]+\.)+[A-Z]{2,}\b"#, template: "[redacted-domain]", options: [.caseInsensitive])
        }

        return result
    }

    public static func redact(bundle: ServerDoctorCollectionBundle, preset: ServerDoctorPrivacyPreset) -> (ServerDoctorCollectionBundle, ServerDoctorRedactionSummary) {
        var replacementCount = 0
        var categories: [String: Int] = [:]

        let redactedEvidence = bundle.evidence.map { evidence in
            let excerpt = redact(evidence.excerpt, preset: preset)
            let raw = redact(evidence.rawOutput, preset: preset)
            replacementCount += excerpt.replacementCount + raw.replacementCount
            merge(excerpt.categories, into: &categories)
            merge(raw.categories, into: &categories)

            var copy = evidence
            copy.redactedExcerpt = excerpt.text
            copy.rawOutput = raw.text
            return copy
        }

        let redactedBundle = ServerDoctorCollectionBundle(
            id: bundle.id,
            hostLabel: preset == .strict || preset == .localOnly ? "[redacted-host]" : bundle.hostLabel,
            collectedAt: bundle.collectedAt,
            profiles: bundle.profiles,
            commandAudits: bundle.commandAudits,
            evidence: redactedEvidence,
            warnings: bundle.warnings
        )
        return (
            redactedBundle,
            ServerDoctorRedactionSummary(
                preset: preset,
                replacementCount: replacementCount,
                categories: categories
            )
        )
    }

    private static func apply(
        _ result: inout ServerDoctorRedactionResult,
        category: String,
        pattern: String,
        template: String,
        options: NSRegularExpression.Options = []
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let range = NSRange(result.text.startIndex..<result.text.endIndex, in: result.text)
        let count = regex.numberOfMatches(in: result.text, options: [], range: range)
        guard count > 0 else { return }
        result.text = regex.stringByReplacingMatches(
            in: result.text,
            options: [],
            range: range,
            withTemplate: template
        )
        result.replacementCount += count
        result.categories[category, default: 0] += count
    }

    private static func merge(_ source: [String: Int], into target: inout [String: Int]) {
        for (key, value) in source {
            target[key, default: 0] += value
        }
    }
}

