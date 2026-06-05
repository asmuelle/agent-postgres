import Foundation
import OSLog
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

/// Singleton that manages the Rust bridge lifecycle and exposes a
/// thin Swift API over the uniffi-generated FFI surface.
///
/// Responsibilities:
/// - `initialize()`: calls `rshellInit()` and registers the event callback.
/// - `connect(...)`: maps a `ConnectionProfile` to `FfiConnectConfig` and
///   calls `rshellConnect`.
/// - `openTerminal(...)`: starts a PTY and parses the generation counter.
/// - `sendInput`, `resize`, `closeTerminal`: thin pass-throughs.
///
/// FFI calls run off the main thread. Terminal lifecycle and input use a
/// serial control queue for ordering; remote commands, monitor reads, and
/// short SFTP probes use a separate utility queue so slow host commands do
/// not delay interactive typing.
final class BridgeManager {
    static let shared = BridgeManager()
    private let logger = Logger(subsystem: "com.mc-ssh", category: "bridge")

    /// Serial control queue for terminal lifecycle and input ordering.
    let dispatchQueue: DispatchQueue
    /// Utility FFI queue for remote commands, monitoring, and SFTP probes.
    /// Kept separate from `dispatchQueue` so a slow command cannot delay
    /// terminal input writes.
    private let utilityQueue: DispatchQueue

    private(set) var isInitialized = false

    /// Strong reference — Rust holds a callback handle but we keep a
    /// Swift reference too, so the object isn't deallocated while Rust
    /// is still calling into it.
    private var eventCallback: PgAgentEventCallback?

    private init() {
        self.dispatchQueue = DispatchQueue(
            label: "com.mc-ssh.bridge",
            qos: .userInitiated,
            attributes: [],
            autoreleaseFrequency: .workItem
        )
        self.utilityQueue = DispatchQueue(
            label: "com.mc-ssh.bridge.utility",
            qos: .utility,
            attributes: .concurrent,
            autoreleaseFrequency: .workItem
        )
    }

    private func runOnControlQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await run(on: dispatchQueue, work)
    }

    private func runOnUtilityQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await run(on: utilityQueue, work)
    }

    private func run<T>(
        on queue: DispatchQueue,
        _ work: @escaping () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Lifecycle

    /// Initialize the Rust bridge. Call once from `AppDelegate`. Idempotent
    /// on the Rust side, but we guard against double-init in Swift.
    func initialize() {
        dispatchQueue.async { [weak self] in
            guard let self else { return }

            if self.isInitialized {
                self.logger.warning("BridgeManager.initialize() called twice; ignoring")
                return
            }

            self.logger.info("Initializing Rust bridge")

            guard rshellInit() else {
                self.logger.fault("rshellInit() returned false")
                return
            }

            // Register a single event callback for the lifetime of the app.
            // PTY output, connection status changes, and transfer progress
            // all flow through this callback.
            let callback = PgAgentEventCallback()
            rshellSetEventCallback(callback: callback)
            self.eventCallback = callback

            self.isInitialized = true
            self.logger.log("Rust bridge initialized")
        }
    }

    func shutdown() {
        logger.info("Shutting down Rust bridge")
        isInitialized = false
        // The Rust runtime is dropped on process exit; nothing else to do.
    }

    // MARK: - Connection

    /// Map a stored `ConnectionProfile` to an FFI config and connect.
    ///
    /// `sessionId` lets the caller open multiple PTY sessions to the same
    /// `(user, host, port)` triple — each tab passes its own UUID-derived
    /// suffix and ssh-commander-core keys the connections separately. Without
    /// it, opening the same profile twice would replace the first PTY
    /// (the connection-manager `HashMap` key would collide).
    ///
    /// Returns the canonical connection id Rust assigned (`"user@host:port"`
    /// or `"user@host:port#sessionId"`), which subsequent `openTerminal`,
    /// `sendInput`, `closeTerminal` calls must reuse verbatim.
    func connect(
        profile: ConnectionProfile,
        password: String?,
        keyPath: String? = nil,
        passphrase: String? = nil,
        useAgent: Bool = false,
        agentIdentityHint: String? = nil,
        sessionId: String? = nil
    ) async throws -> String {
        let networkResolution: TailscaleHostResolution
        do {
            networkResolution = try await NetworkPolishResolver.resolveWithSystemLookup(
                host: profile.host,
                port: profile.port,
                options: profile.networkOptions
            )
        } catch let error as TailscaleResolutionError {
            throw BridgeError.network(error.localizedDescription)
        }

        if networkResolution.usedHostOverride {
            logger.info(
                "Using Tailnet host override \(networkResolution.connectHost, privacy: .public) for \(profile.host, privacy: .public)"
            )
        } else if networkResolution.isTailnetRoute {
            logger.info(
                "Tailscale route resolved for \(profile.host, privacy: .public): \(networkResolution.tailnetAddress ?? profile.host, privacy: .public)"
            )
        }

        if profile.networkOptions.multipathTCPMode != .system {
            logger.info(
                "Multipath TCP mode \(profile.networkOptions.multipathTCPMode.rawValue, privacy: .public) requested for SSH, but current russh transport is standard TCP"
            )
        }

        let config = FfiConnectConfig(
            host: networkResolution.connectHost,
            port: profile.port,
            username: profile.username,
            password: password,
            keyPath: keyPath ?? profile.privateKeyPath,
            passphrase: passphrase,
            useAgent: useAgent,
            agentIdentityHint: agentIdentityHint,
            sessionId: sessionId
        )

        do {
            let connectionId: String = try await runOnControlQueue {
                try rshellConnect(config: config)
            }
            logger.log("Connected: \(connectionId, privacy: .public)")
            return connectionId
        } catch let err as ConnectError {
            logger.error("Connect failed: \(String(describing: err), privacy: .public)")
            switch err {
            case .HostKeyMismatch(let detail):
                throw BridgeError.hostKeyMismatch(
                    host: networkResolution.connectHost,
                    port: profile.port,
                    detail: detail
                )
            default:
                throw BridgeError.from(err)
            }
        } catch {
            logger.error("Connect failed (unexpected): \(error.localizedDescription, privacy: .public)")
            throw BridgeError.other(error.localizedDescription)
        }
    }

    func disconnect(connectionId: String) {
        dispatchQueue.async {
            _ = rshellDisconnect(connectionId: connectionId)
        }
    }

    /// Probe whether SFTP is available on an already-connected
    /// session by issuing a one-shot `list_dir(".")`. Used to decide
    /// whether to fall back to SFTP-mode after a denied PTY: if the
    /// shell is blocked but SFTP works (scponly, ForceCommand
    /// internal-sftp, hosting-account restrictions), the connection
    /// is still useful for file transfer.
    ///
    /// Returns `true` if the listing succeeded, `false` for any
    /// error (subsystem refused, permission denied, network drop).
    /// We don't try to interpret the error — at this point we've
    /// already established the SSH transport works, so anything
    /// that breaks here is genuinely a "this session is unusable"
    /// signal.
    func canUseSftp(connectionId: String) async -> Bool {
        do {
            _ = try await sftpListDir(connectionId: connectionId, path: ".")
            return true
        } catch {
            logger.info("SFTP probe failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - PTY

    /// Start a PTY session. Returns the `generation` counter so the caller
    /// can use it for `closeTerminal` and stale-close protection.
    func openTerminal(connectionId: String, cols: Int = 80, rows: Int = 24) async throws -> UInt64 {
        let result: FfiResult = try await runOnControlQueue {
            rshellPtyStart(
                connectionId: connectionId,
                cols: UInt32(cols),
                rows: UInt32(rows)
            )
        }
        let payload = try result.requireValue(operation: "PTY start")
        guard
            let data = payload.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(PtyStartPayload.self, from: data)
        else {
            throw BridgeError.malformedResponse(
                operation: "PTY start",
                detail: "Rust returned an invalid PTY generation payload."
            )
        }

        logger.log("PTY \(connectionId, privacy: .public) generation=\(decoded.generation)")
        return decoded.generation
    }

    func executeCommand(connectionId: String, command: String) async throws -> String {
        let result: FfiResult = try await runOnUtilityQueue {
            rshellExecuteCommand(connectionId: connectionId, command: command)
        }
        return try result.requireValue(operation: "execute command")
    }

    func getSystemStats(connectionId: String) async throws -> FfiSystemStats {
        try await runOnUtilityQueue {
            try rshellGetSystemStats(connectionId: connectionId)
        }
    }

    func getProcesses(connectionId: String) async throws -> [FfiProcess] {
        try await runOnUtilityQueue {
            try rshellGetProcesses(connectionId: connectionId)
        }
    }

    func signalProcess(connectionId: String, pid: UInt32, signal: FfiSignal) async throws {
        try await runOnUtilityQueue {
            try rshellSignalProcess(connectionId: connectionId, pid: pid, signal: signal)
        }
    }

    func sftpListDir(connectionId: String, path: String) async throws -> [FfiFileEntry] {
        try await runOnUtilityQueue {
            try rshellSftpListDir(connectionId: connectionId, path: path)
        }
    }

    func sftpCreateDir(connectionId: String, path: String) async throws {
        try await runOnUtilityQueue {
            try rshellSftpCreateDir(connectionId: connectionId, path: path)
        }
    }

    func sftpRename(connectionId: String, oldPath: String, newPath: String) async throws {
        try await runOnUtilityQueue {
            try rshellSftpRename(connectionId: connectionId, oldPath: oldPath, newPath: newPath)
        }
    }

    func sftpDeleteFile(connectionId: String, path: String) async throws {
        try await runOnUtilityQueue {
            try rshellSftpDeleteFile(connectionId: connectionId, path: path)
        }
    }

    func sftpDeleteDir(connectionId: String, path: String) async throws {
        try await runOnUtilityQueue {
            try rshellSftpDeleteDir(connectionId: connectionId, path: path)
        }
    }

    func sftpDownload(
        transferId: UUID,
        connectionId: String,
        remotePath: String,
        localPath: String,
        expectedSize: UInt64
    ) async throws -> UInt64 {
        try await runOnUtilityQueue {
            try rshellSftpDownload(
                transferId: transferId.uuidString,
                connectionId: connectionId,
                remotePath: remotePath,
                localPath: localPath,
                expectedSize: expectedSize
            )
        }
    }

    func sftpUpload(
        transferId: UUID,
        connectionId: String,
        localPath: String,
        remotePath: String
    ) async throws -> UInt64 {
        try await runOnUtilityQueue {
            try rshellSftpUpload(
                transferId: transferId.uuidString,
                connectionId: connectionId,
                localPath: localPath,
                remotePath: remotePath
            )
        }
    }

    @discardableResult
    func sftpCancel(transferId: UUID) -> Bool {
        rshellSftpCancel(transferId: transferId.uuidString)
    }

    func sftpChmod(connectionId: String, path: String, mode: String) async throws {
        try await runOnUtilityQueue {
            try rshellSftpChmod(connectionId: connectionId, path: path, mode: mode)
        }
    }

    func sftpChown(connectionId: String, path: String, uid: String) async throws {
        try await runOnUtilityQueue {
            try rshellSftpChown(connectionId: connectionId, path: path, uid: uid)
        }
    }

    func sftpChgrp(connectionId: String, path: String, gid: String) async throws {
        try await runOnUtilityQueue {
            try rshellSftpChgrp(connectionId: connectionId, path: path, gid: gid)
        }
    }

    func sftpResolveUid(connectionId: String, uid: String) async throws -> String {
        try await runOnUtilityQueue {
            try rshellSftpResolveUid(connectionId: connectionId, uid: uid)
        }
    }

    func sftpResolveGid(connectionId: String, gid: String) async throws -> String {
        try await runOnUtilityQueue {
            try rshellSftpResolveGid(connectionId: connectionId, gid: gid)
        }
    }

    func forgetHostKey(host: String, port: UInt16) async throws {
        try await runOnUtilityQueue {
            let result = rshellForgetHostKey(host: host, port: port)
            try result.requireSuccess(operation: "forget host key")
        }
    }


    /// Send keyboard input to a running PTY.
    ///
    /// Coalesced through a per-connection batcher so a paste of N bytes
    /// produces one FFI call (or a handful) instead of one per byte.
    /// Single keystrokes still flush within ~16 ms so latency is
    /// imperceptible.
    func sendInput(connectionId: String, data: Data) {
        dispatchQueue.async { [weak self] in
            guard let self else { return }
            self.writeBatcher(for: connectionId).append(data)
        }
    }

    /// Flush any pending writes for a connection (used on close so we
    /// don't lose the trailing bytes of a final command).
    func flushPendingInput(connectionId: String) {
        dispatchQueue.async { [weak self] in
            self?.writeBatchers.removeValue(forKey: connectionId)?.flushNow()
        }
    }

    // MARK: - Write batching

    private var writeBatchers: [String: WriteBatcher] = [:]

    private func writeBatcher(for connectionId: String) -> WriteBatcher {
        if let existing = writeBatchers[connectionId] { return existing }
        let new = WriteBatcher(connectionId: connectionId, queue: dispatchQueue)
        writeBatchers[connectionId] = new
        return new
    }

    /// Resize a running PTY. Currently called only from explicit resize
    /// triggers; per-frame resize is deferred to Sprint 8 with debouncing.
    func resize(connectionId: String, cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        dispatchQueue.async {
            _ = rshellPtyResize(
                connectionId: connectionId,
                cols: UInt32(cols),
                rows: UInt32(rows)
            )
        }
    }

    func closeTerminal(connectionId: String, generation: UInt64) {
        dispatchQueue.async { [weak self] in
            // Flush any pending input before tearing down — bytes typed
            // within the 16 ms batching window before Cmd+W would
            // otherwise be lost.
            self?.writeBatchers.removeValue(forKey: connectionId)?.flushNow()
            _ = rshellPtyClose(connectionId: connectionId, expectedGeneration: generation)
        }
    }
}

private struct PtyStartPayload: Decodable {
    let generation: UInt64
}

private extension FfiResult {
    func requireSuccess(operation: String) throws {
        guard success else {
            throw BridgeError.operationFailed(
                operation: operation,
                detail: error ?? "\(operation) failed without an error message."
            )
        }
    }

    func requireValue(operation: String) throws -> String {
        try requireSuccess(operation: operation)
        guard let value else {
            throw BridgeError.malformedResponse(
                operation: operation,
                detail: "\(operation) succeeded without a return value."
            )
        }
        return value
    }
}

// MARK: - Errors

/// Swift-side mirror of `ConnectError` plus the non-connect error cases.
/// Keeping this Swift-typed (rather than passing `ConnectError` through
/// directly) means the rest of the app doesn't have to depend on the
/// uniffi-generated module.
enum BridgeError: Error, LocalizedError {
    case configInvalid(String)
    case passphraseRequired(String)
    case authFailed(String)
    case hostKeyMismatch(host: String, port: UInt16, detail: String)
    case network(String)
    case ptyStart(String)
    case notInitialized
    case operationFailed(operation: String, detail: String)
    case malformedResponse(operation: String, detail: String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .configInvalid(let msg):     return "Invalid configuration: \(msg)"
        case .passphraseRequired(let msg): return "Key passphrase required: \(msg)"
        case .authFailed(let msg):        return "Authentication failed: \(msg)"
        case .hostKeyMismatch(_, _, let msg): return "Host key mismatch: \(msg)"
        case .network(let msg):           return "Network error: \(msg)"
        case .ptyStart(let msg):          return "Failed to start terminal: \(msg)"
        case .notInitialized:             return "Rust bridge not initialized"
        case .operationFailed(let operation, let detail):
            return "\(operation) failed: \(detail)"
        case .malformedResponse(let operation, let detail):
            return "\(operation) returned an unexpected response: \(detail)"
        case .other(let msg):             return msg
        }
    }

    static func from(_ err: ConnectError) -> BridgeError {
        // uniffi 0.28 generates PascalCase Swift enum cases from the Rust
        // variant names — keep these in lock-step if a variant is added.
        switch err {
        case .ConfigInvalid(let detail):     return .configInvalid(detail)
        case .PassphraseRequired(let detail): return .passphraseRequired(detail)
        case .AuthFailed(let detail):        return .authFailed(detail)
        case .HostKeyMismatch(let detail):   return .hostKeyMismatch(host: "", port: 0, detail: detail)
        case .Network(let detail):           return .network(detail)
        case .Other(let detail):             return .other(detail)
        }
    }
}
