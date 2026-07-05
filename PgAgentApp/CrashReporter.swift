import Foundation
import OSLog

/// Captures and persists crash/error reports locally.
///
/// Reports are stored in `Application Support/com.mc-ssh/crash_reports/`
/// as JSON files with a .crash extension. Each report includes:
/// - Timestamp and app version
/// - Error domain and code
/// - Call stack (if available from the error)
/// - Recent log entries from the in-memory buffer
///
/// Reports can be manually exported from the Settings > Support panel.
@MainActor
class CrashReporter {
    static let shared = CrashReporter()
    private let logger = Logger(subsystem: "com.mc-ssh", category: "crash-reporter")
    private var memoryLog = RingBuffer<String>(capacity: 500)

    private var reportsDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.mc-ssh/crash_reports")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {}

    // MARK: - Log capture

    /// All captured strings pass through `CrashLogRedactor` here — at the
    /// sink — so no call site can accidentally persist a secret into a
    /// user-exportable .crash file.
    func log(_ message: String) {
        memoryLog.write(CrashLogRedactor.redact(message))
    }

    // MARK: - Report generation

    struct CrashReport: Codable {
        var timestamp: Date
        var appVersion: String
        var appBuild: String
        var errorDomain: String
        var errorCode: Int
        var errorDescription: String
        var callStack: [String]
        var recentLogs: [String]
    }

    func report(error: Error, file: String = #file, line: Int = #line) {
        let nsError = error as NSError
        let report = CrashReport(
            timestamp: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
            errorDomain: CrashLogRedactor.redact(nsError.domain),
            errorCode: nsError.code,
            errorDescription: CrashLogRedactor.redact(nsError.localizedDescription),
            callStack: Thread.callStackSymbols,
            recentLogs: memoryLog.snapshot()
        )

        let fileName = "crash_\(ISO8601DateFormatter().string(from: Date()))_\(nsError.code).crash"
        let fileURL = reportsDir.appendingPathComponent(fileName)

        do {
            let data = try JSONEncoder().encode(report)
            try data.write(to: fileURL)
            logger.error("Crash report saved: \(fileURL.lastPathComponent)")
        } catch {
            logger.error("Failed to save crash report: \(error.localizedDescription)")
        }
    }

    func reportMessage(_ message: String, file: String = #file, line: Int = #line) {
        log("ERROR: \(message) at \(file):\(line)")
    }

    // MARK: - Report listing

    var reportURLs: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: reportsDir, includingPropertiesForKeys: [.contentModificationDateKey]))
            .map { $0.sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            }}
        ?? []
    }

    func deleteReport(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func deleteAll() {
        for url in reportURLs { deleteReport(url) }
    }
}

// MARK: - Secret redaction

/// Regex-redacts secret-bearing substrings before they are persisted by
/// `CrashReporter`. Covers the password/passphrase/secret/token/api_key/
/// private_key assignment family plus URL-embedded credentials
/// (`scheme://user:pass@host`). Values are replaced with `[REDACTED]`;
/// keys and structure are kept so reports stay diagnosable.
enum CrashLogRedactor {
    /// (pattern, replacement template) pairs. Templates keep the key and
    /// separator ($1) and drop only the secret value.
    private static let rules: [(regex: NSRegularExpression, template: String)] = {
        let raw: [(String, String)] = [
            // key: value / key=value / "key": "value" — quoted or bare values.
            (
                #"(?i)("?(?:password|passphrase|secret|token|api[_-]?key|private[_-]?key)"?\s*[:=]\s*)("[^"]*"|\S+)"#,
                "$1[REDACTED]"
            ),
            // URL credentials: scheme://user:secret@host
            (
                #"(://[^/\s:@]+:)([^@\s]+)(@)"#,
                "$1[REDACTED]$3"
            ),
        ]
        return raw.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
        }
    }()

    static func redact(_ message: String) -> String {
        var result = message
        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = rule.regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: rule.template
            )
        }
        return result
    }
}

// MARK: - Ring buffer for in-memory log

private struct RingBuffer<T> {
    private var buffer: [T]
    private var index = 0
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = []
        buffer.reserveCapacity(capacity)
    }

    mutating func write(_ element: T) {
        if buffer.count < capacity {
            buffer.append(element)
        } else {
            buffer[index % capacity] = element
        }
        index += 1
    }

    func snapshot() -> [T] {
        if buffer.count < capacity { return buffer }
        return Array(buffer[index % capacity..<capacity]) + Array(buffer[0..<index % capacity])
    }
}
