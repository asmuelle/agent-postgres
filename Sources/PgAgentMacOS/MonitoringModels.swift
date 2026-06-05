import Foundation

// MARK: - System stats

public struct SystemStats: Codable, Sendable {
    public var cpuPercent: Double
    public var memoryTotal: UInt64
    public var memoryUsed: UInt64
    public var memoryFree: UInt64
    public var memoryAvailable: UInt64
    public var swapTotal: UInt64
    public var swapUsed: UInt64
    public var diskTotal: String
    public var diskUsed: String
    public var diskAvailable: String
    public var diskUsePercent: Double
    public var uptime: String
    public var loadAverage: String?

    public var memoryUsagePercent: Double {
        memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) * 100 : 0
    }

    public static let zero = SystemStats(
        cpuPercent: 0, memoryTotal: 0, memoryUsed: 0, memoryFree: 0, memoryAvailable: 0,
        swapTotal: 0, swapUsed: 0, diskTotal: "—", diskUsed: "—", diskAvailable: "—",
        diskUsePercent: 0, uptime: "—", loadAverage: nil
    )
}

// MARK: - Network stats

public struct NetworkInterface: Codable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var rxBytes: UInt64
    public var txBytes: UInt64
    public var rxPackets: UInt64
    public var txPackets: UInt64
}

public struct NetworkStats: Codable, Sendable {
    public var interfaces: [NetworkInterface]
    public var rxHistory: [UInt64]
    public var txHistory: [UInt64]
    public var latencyMs: Double

    public static let zero = NetworkStats(interfaces: [], rxHistory: [], txHistory: [], latencyMs: 0)
}

// MARK: - Process info

/// Remote process snapshot polled from the server. Renamed from `ProcessInfo`
/// to avoid shadowing `Foundation.ProcessInfo` in app sources that import both.
public struct RemoteProcessInfo: Codable, Identifiable, Sendable {
    public var id: String { "\(pid)" }
    public var pid: UInt32
    public var name: String
    public var cpuPercent: Double
    public var memoryPercent: Double
    public var user: String?
    public var state: String?
    public var command: String?
}

// MARK: - Log entry

public struct LogEntry: Codable, Identifiable, Sendable {
    public var id: String { "\(source):\(lineNumber)" }
    public var source: String
    public var lineNumber: UInt64
    public var timestamp: String?
    public var level: String?
    public var message: String
    public var raw: String

    public init(source: String, lineNumber: UInt64, timestamp: String? = nil, level: String? = nil, message: String, raw: String) {
        self.source = source
        self.lineNumber = lineNumber
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.raw = raw
    }
}

// MARK: - Log source

public struct LogSource: Codable, Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var kind: LogSourceKind

    public init(name: String, path: String, kind: LogSourceKind = .file) {
        self.name = name
        self.path = path
        self.kind = kind
    }
}

public enum LogSourceKind: String, Codable, Sendable {
    case file
    case journal
    case docker
}

// MARK: - History point for charts

public struct DataPoint: Identifiable, Sendable {
    public var id: Int { index }
    public var index: Int
    public var value: Double
    public var label: String
}
