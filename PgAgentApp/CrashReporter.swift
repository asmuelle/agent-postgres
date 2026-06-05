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

    func log(_ message: String) {
        memoryLog.write(message)
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
            errorDomain: nsError.domain,
            errorCode: nsError.code,
            errorDescription: nsError.localizedDescription,
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
