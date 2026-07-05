import CloudKit
import Foundation
import os
#if os(macOS)
import Security
#endif

// =============================================================================
// FleetAlertRelay — hub-side publisher. Saves FleetAlert records into the
// custom "FleetAlerts" zone of the user's PRIVATE CloudKit database; the
// user's other devices receive them via a CKQuerySubscription push
// (FleetAlertSubscription.swift). No vendor cloud: alert data never leaves
// the user's Apple ID.
//
// Design points:
// - savePolicy .ifServerRecordUnchanged + deterministic record names →
//   `serverRecordChanged` is a benign "already relayed" dedupe, not an error.
// - Account problems surface as a status enum for the hub UI; they never
//   throw out of `publish` and never crash.
// - Transient network errors retry with capped exponential backoff.
// =============================================================================

enum FleetAlertRelayStatus: Equatable, Sendable {
    case unknown
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case missingEntitlement
    case error(String)

    var label: String {
        switch self {
        case .unknown: return "Not checked yet"
        case .available: return "iCloud available"
        case .noAccount: return "No iCloud account — sign in to relay alerts"
        case .restricted: return "iCloud access restricted"
        case .temporarilyUnavailable: return "iCloud temporarily unavailable"
        case .missingEntitlement: return "This build lacks CloudKit entitlements (unsigned dev build)"
        case .error(let message): return message
        }
    }

    var isAvailable: Bool { self == .available }
}

@MainActor
final class FleetAlertRelay: ObservableObject {
    @Published private(set) var status: FleetAlertRelayStatus = .unknown
    @Published private(set) var relayedCount = 0
    @Published private(set) var lastPublishAt: Date?

    private var lazyContainer: CKContainer?
    private var zoneReady = false
    private let log = Logger(subsystem: "com.pgagent", category: "FleetAlertRelay")

    private static let maxAttempts = 3
    private static let baseBackoffSeconds: Double = 2
    private static let maxBackoffSeconds: Double = 30

    /// CKContainer(identifier:) hard-crashes (Obj-C exception) in a process
    /// without the icloud-services entitlement — which is every unsigned
    /// CI/test/dev build. Never construct one unless the entitlement is
    /// really present.
    private var container: CKContainer? {
        if let lazyContainer { return lazyContainer }
        guard Self.processHasCloudKitEntitlement else { return nil }
        let made = CKContainer(identifier: FleetAlertCloudKit.containerIdentifier)
        lazyContainer = made
        return made
    }

    static var processHasCloudKitEntitlement: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.icloud-services" as CFString, nil
        )
        return value != nil
        #else
        // iOS builds always run signed (device or simulator) with the
        // entitlements from project.yml.
        return true
        #endif
    }

    /// Refresh `status` from CKContainer.accountStatus(). Never throws.
    @discardableResult
    func refreshAccountStatus() async -> FleetAlertRelayStatus {
        guard let container else {
            status = .missingEntitlement
            return status
        }
        do {
            let account = try await container.accountStatus()
            switch account {
            case .available: status = .available
            case .noAccount: status = .noAccount
            case .restricted: status = .restricted
            case .temporarilyUnavailable: status = .temporarilyUnavailable
            case .couldNotDetermine: status = .unknown
            @unknown default: status = .unknown
            }
        } catch {
            status = .error(shortMessage(for: error))
        }
        return status
    }

    /// Publish a batch of alerts. Returns the number actually accepted by the
    /// server (freshly saved; server-side dedupes don't count). Account or
    /// persistent network problems are reflected in `status`, not thrown.
    @discardableResult
    func publish(_ payloads: [FleetAlertPayload]) async -> Int {
        guard !payloads.isEmpty else { return 0 }
        guard await refreshAccountStatus().isAvailable,
              let database = container?.privateCloudDatabase
        else {
            log.info("Skipping relay of \(payloads.count) alert(s): \(self.status.label)")
            return 0
        }
        guard await ensureZone(in: database) else { return 0 }

        let records = payloads.map { $0.toRecord() }
        var attempt = 0
        while true {
            attempt += 1
            do {
                let saved = try await save(records: records, to: database)
                relayedCount += saved
                lastPublishAt = Date()
                status = .available
                return saved
            } catch {
                guard attempt < Self.maxAttempts, let delay = retryDelay(for: error, attempt: attempt) else {
                    status = .error(shortMessage(for: error))
                    log.error("Relay publish failed after \(attempt) attempt(s): \(String(describing: error))")
                    return 0
                }
                log.info("Relay publish attempt \(attempt) failed; retrying in \(delay, format: .fixed(precision: 1))s")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    // MARK: - Internals

    /// Save with .ifServerRecordUnchanged; count per-record successes and
    /// treat `serverRecordChanged` as an already-relayed no-op. Throws only
    /// for batch-level failures (network, auth) so the caller can retry.
    private func save(records: [CKRecord], to database: CKDatabase) async throws -> Int {
        let result = try await database.modifyRecords(
            saving: records,
            deleting: [],
            savePolicy: .ifServerRecordUnchanged,
            atomically: false
        )
        var saved = 0
        for (recordID, outcome) in result.saveResults {
            switch outcome {
            case .success:
                saved += 1
            case .failure(let error):
                if let ck = error as? CKError, ck.code == .serverRecordChanged {
                    log.debug("Alert \(recordID.recordName) already relayed — deduped server-side")
                } else {
                    log.error("Alert \(recordID.recordName) failed to relay: \(String(describing: error))")
                }
            }
        }
        return saved
    }

    /// Create the custom zone once per process; zone saves are idempotent.
    private func ensureZone(in database: CKDatabase) async -> Bool {
        if zoneReady { return true }
        do {
            _ = try await database.save(CKRecordZone(zoneID: FleetAlertCloudKit.zoneID))
            zoneReady = true
            return true
        } catch {
            status = .error("Couldn't create the FleetAlerts zone: \(shortMessage(for: error))")
            log.error("Zone creation failed: \(String(describing: error))")
            return false
        }
    }

    /// Backoff delay if the error is worth retrying, else nil.
    private func retryDelay(for error: Error, attempt: Int) -> Double? {
        guard let ck = error as? CKError else { return nil }
        switch ck.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            let suggested = ck.retryAfterSeconds ?? Self.baseBackoffSeconds * pow(2, Double(attempt - 1))
            return min(suggested, Self.maxBackoffSeconds)
        default:
            return nil
        }
    }

    private func shortMessage(for error: Error) -> String {
        (error as? CKError)?.localizedDescription ?? error.localizedDescription
    }
}
