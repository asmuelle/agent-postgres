import Foundation
import OSLog
import PgAgentMacOS

// =============================================================================
// Network/dev tools bridge — Swift wrappers over `rshell_git_status`,
// `rshell_dns_resolve`, `rshell_listening_ports`, and the tcpdump capture
// pair. Tools share an internal dispatch queue so a long-running git fetch
// can't queue behind a Postgres introspection (or vice versa).
// =============================================================================

enum ToolsBridgeError: Error, LocalizedError {
    case connectionNotFound(String)
    case notSshConnection(String)
    case remoteCommand(String)
    case sshExec(String)
    case parse(String)
    case captureNotFound(UInt64)
    case io(String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .connectionNotFound(let id): return "Connection not found: \(id)"
        case .notSshConnection(let id):   return "Not an SSH connection: \(id)"
        case .remoteCommand(let m):       return m
        case .sshExec(let m):             return "SSH exec failed: \(m)"
        case .parse(let m):               return "Parse error: \(m)"
        case .captureNotFound(let id):    return "Capture not found: \(id)"
        case .io(let m):                  return "IO error: \(m)"
        case .other(let m):               return m
        }
    }

    static func from(_ err: FfiToolsError) -> ToolsBridgeError {
        switch err {
        case .ConnectionNotFound(let id):  return .connectionNotFound(id)
        case .NotSshConnection(let id):    return .notSshConnection(id)
        case .RemoteCommand(let m):        return .remoteCommand(m)
        case .SshExec(let m):              return .sshExec(m)
        case .Parse(let m):                return .parse(m)
        case .CaptureNotFound(let id):     return .captureNotFound(id)
        case .Io(let m):                   return .io(m)
        }
    }
}

extension BridgeManager {
    func toolsGitStatus(connectionId: String, repoPath: String) async throws -> FfiGitStatus {
        try await toolsWrapping {
            try rshellGitStatus(connectionId: connectionId, repoPath: repoPath)
        }
    }

    /// Resolve `name` of `recordType` from each perspective in `perspectives`.
    /// A perspective is either an SSH connection id or `"local"` (the Mac).
    func toolsDnsResolve(
        name: String,
        recordType: FfiDnsRecordType,
        perspectives: [String]
    ) async -> [FfiDnsAnswer] {
        // Capture the raw rawValue to dodge Sendable warnings for the
        // uniffi-generated enum, which isn't marked Sendable in the
        // generated bindings.
        let rawType = recordType
        return await withCheckedContinuation { continuation in
            toolsQueue.async {
                let result = rshellDnsResolve(
                    name: name,
                    recordType: rawType,
                    perspectives: perspectives
                )
                continuation.resume(returning: result)
            }
        }
    }

    func toolsListeningPorts(connectionId: String) async throws -> [FfiListeningPort] {
        try await toolsWrapping {
            try rshellListeningPorts(connectionId: connectionId)
        }
    }

    func toolsTcpdumpStart(
        connectionId: String,
        interface: String,
        filter: String,
        snaplen: UInt32?
    ) async throws -> UInt64 {
        try await toolsWrapping {
            try rshellTcpdumpStart(
                connectionId: connectionId,
                interface: interface,
                filter: filter,
                snaplen: snaplen
            )
        }
    }

    func toolsTcpdumpStop(captureId: UInt64) async throws {
        try await toolsWrapping {
            try rshellTcpdumpStop(captureId: captureId)
        }
    }

    private func toolsWrapping<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            toolsQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch let err as FfiToolsError {
                    continuation.resume(throwing: ToolsBridgeError.from(err))
                } catch {
                    continuation.resume(
                        throwing: ToolsBridgeError.other(error.localizedDescription)
                    )
                }
            }
        }
    }
}

private nonisolated(unsafe) let toolsQueue: DispatchQueue = {
    DispatchQueue(
        label: "com.mc-ssh.bridge.tools",
        qos: .utility,
        attributes: .concurrent,
        autoreleaseFrequency: .workItem
    )
}()
