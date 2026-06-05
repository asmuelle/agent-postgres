import Foundation

#if canImport(Darwin)
import Darwin
#endif

public enum TailscaleResolutionMode: String, Codable, CaseIterable, Hashable, Sendable {
    case system
    case preferTailnet
    case requireTailnet

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .preferTailnet: return "Prefer Tailnet"
        case .requireTailnet: return "Require Tailnet"
        }
    }
}

public enum MultipathTCPMode: String, Codable, CaseIterable, Hashable, Sendable {
    case system
    case disabled
    case handover
    case interactive
    case aggregate

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .disabled: return "Disabled"
        case .handover: return "Handover"
        case .interactive: return "Interactive"
        case .aggregate: return "Aggregate"
        }
    }
}

public struct NetworkConnectionOptions: Codable, Hashable, Sendable {
    public static let `default` = NetworkConnectionOptions()

    public var tailscaleResolutionMode: TailscaleResolutionMode
    public var tailscaleHostOverride: String?
    public var multipathTCPMode: MultipathTCPMode

    public init(
        tailscaleResolutionMode: TailscaleResolutionMode = .system,
        tailscaleHostOverride: String? = nil,
        multipathTCPMode: MultipathTCPMode = .system
    ) {
        self.tailscaleResolutionMode = tailscaleResolutionMode
        self.tailscaleHostOverride = tailscaleResolutionMode == .system
            ? nil
            : tailscaleHostOverride?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .networkNilIfEmpty
        self.multipathTCPMode = multipathTCPMode
    }

    public var isDefault: Bool {
        self == Self.default
    }
}

public struct TailscaleHostResolution: Equatable, Hashable, Sendable {
    public var sourceHost: String
    public var connectHost: String
    public var port: UInt16
    public var mode: TailscaleResolutionMode
    public var resolvedAddresses: [String]
    public var tailnetAddress: String?
    public var usedHostOverride: Bool

    public init(
        sourceHost: String,
        connectHost: String,
        port: UInt16,
        mode: TailscaleResolutionMode,
        resolvedAddresses: [String] = [],
        tailnetAddress: String? = nil,
        usedHostOverride: Bool = false
    ) {
        self.sourceHost = sourceHost
        self.connectHost = connectHost
        self.port = port
        self.mode = mode
        self.resolvedAddresses = resolvedAddresses
        self.tailnetAddress = tailnetAddress
        self.usedHostOverride = usedHostOverride
    }

    public var isTailnetRoute: Bool {
        tailnetAddress != nil || TailscaleAddressClassifier.isTailscaleAddress(connectHost)
    }
}

public enum TailscaleResolutionError: LocalizedError, Equatable, Sendable {
    case requiredTailnetUnavailable(host: String, port: UInt16, resolvedAddresses: [String])

    public var errorDescription: String? {
        switch self {
        case .requiredTailnetUnavailable(let host, let port, let addresses):
            let suffix = addresses.isEmpty ? "No addresses were returned." : "Resolved addresses: \(addresses.joined(separator: ", "))."
            return "Required Tailnet route unavailable for \(host):\(port). \(suffix)"
        }
    }
}

public enum TailscaleAddressClassifier {
    public static func isTailscaleAddress(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return isTailscaleIPv4(trimmed) || isTailscaleIPv6(trimmed)
    }

    public static func isTailscaleIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { part -> Int? in
            guard let value = Int(part), (0...255).contains(value) else { return nil }
            return value
        }
        guard octets.count == 4 else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    public static func isTailscaleIPv6(_ value: String) -> Bool {
        #if canImport(Darwin)
        var address = in6_addr()
        let parsed = value.withCString { pointer in
            inet_pton(AF_INET6, pointer, &address)
        }
        guard parsed == 1 else { return false }
        return withUnsafeBytes(of: address) { raw in
            let bytes = Array(raw)
            return bytes.count >= 6
                && bytes[0] == 0xfd
                && bytes[1] == 0x7a
                && bytes[2] == 0x11
                && bytes[3] == 0x5c
                && bytes[4] == 0xa1
                && bytes[5] == 0xe0
        }
        #else
        return value.lowercased().hasPrefix("fd7a:115c:a1e0:")
        #endif
    }
}

public enum NetworkPolishHostLookup {
    public static func systemAddresses(for host: String, port: UInt16) -> [String] {
        #if canImport(Darwin)
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let result else { return [] }
        defer { freeaddrinfo(result) }

        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let info = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let nameStatus = getnameinfo(
                info.pointee.ai_addr,
                info.pointee.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if nameStatus == 0 {
                let address = String(cString: buffer)
                if !addresses.contains(address) {
                    addresses.append(address)
                }
            }
            cursor = info.pointee.ai_next
        }
        return addresses
        #else
        return []
        #endif
    }
}

public enum NetworkPolishResolver {
    public typealias AddressLookup = @Sendable (_ host: String, _ port: UInt16) -> [String]
    public static let systemAddressLookup: AddressLookup = { host, port in
        NetworkPolishHostLookup.systemAddresses(for: host, port: port)
    }

    public static func resolve(
        host: String,
        port: UInt16,
        options: NetworkConnectionOptions = .default,
        lookup: AddressLookup = NetworkPolishResolver.systemAddressLookup
    ) throws -> TailscaleHostResolution {
        let sourceHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let overrideHost = options.tailscaleHostOverride
        let shouldUseTailnetHost = options.tailscaleResolutionMode != .system
        let connectHost = shouldUseTailnetHost ? (overrideHost ?? sourceHost) : sourceHost

        guard options.tailscaleResolutionMode != .system else {
            return TailscaleHostResolution(
                sourceHost: sourceHost,
                connectHost: connectHost,
                port: port,
                mode: options.tailscaleResolutionMode,
                usedHostOverride: connectHost != sourceHost
            )
        }

        let resolvedAddresses: [String]
        if TailscaleAddressClassifier.isTailscaleAddress(connectHost) {
            resolvedAddresses = [connectHost]
        } else {
            resolvedAddresses = lookup(connectHost, port)
        }
        let tailnetAddress = resolvedAddresses.first(where: TailscaleAddressClassifier.isTailscaleAddress)

        if options.tailscaleResolutionMode == .requireTailnet, tailnetAddress == nil {
            throw TailscaleResolutionError.requiredTailnetUnavailable(
                host: connectHost,
                port: port,
                resolvedAddresses: resolvedAddresses
            )
        }

        return TailscaleHostResolution(
            sourceHost: sourceHost,
            connectHost: connectHost,
            port: port,
            mode: options.tailscaleResolutionMode,
            resolvedAddresses: resolvedAddresses,
            tailnetAddress: tailnetAddress,
            usedHostOverride: connectHost != sourceHost
        )
    }

    public static func resolveWithSystemLookup(
        host: String,
        port: UInt16,
        options: NetworkConnectionOptions = .default
    ) async throws -> TailscaleHostResolution {
        try await Task.detached(priority: .utility) {
            try resolve(host: host, port: port, options: options)
        }.value
    }
}

public enum NetworkCapabilityState: String, Codable, Hashable, Sendable {
    case supported
    case unavailable
    case blocked
}

public struct NetworkCapabilityAudit: Codable, Hashable, Sendable {
    public var state: NetworkCapabilityState
    public var detail: String

    public init(state: NetworkCapabilityState, detail: String) {
        self.state = state
        self.detail = detail
    }

    public var isSupported: Bool {
        state == .supported
    }
}

public struct SSHKeyExchangeAudit: Codable, Hashable, Sendable {
    public var supportedAlgorithms: [String]
    public var missingPostQuantumAlgorithms: [String]

    public init(
        supportedAlgorithms: [String] = [
            "curve25519-sha256",
            "curve25519-sha256@libssh.org",
            "diffie-hellman-group16-sha512",
            "diffie-hellman-group14-sha256",
            "diffie-hellman-group14-sha1",
            "diffie-hellman-group1-sha1",
            "ext-info-c",
            "kex-strict-c-v00@openssh.com",
        ],
        missingPostQuantumAlgorithms: [String] = [
            "sntrup761x25519-sha512@openssh.com",
            "mlkem768x25519-sha256",
        ]
    ) {
        self.supportedAlgorithms = supportedAlgorithms
        self.missingPostQuantumAlgorithms = missingPostQuantumAlgorithms
    }

    public var exposesPostQuantumKex: Bool {
        missingPostQuantumAlgorithms.isEmpty
    }
}

public struct NetworkPolishAuditReport: Codable, Hashable, Sendable {
    public static let current = NetworkPolishAuditReport()

    public var sshMultipathTCP: NetworkCapabilityAudit
    public var urlSessionMultipathTCP: NetworkCapabilityAudit
    public var postQuantumKex: SSHKeyExchangeAudit

    public init(
        sshMultipathTCP: NetworkCapabilityAudit = NetworkCapabilityAudit(
            state: .unavailable,
            detail: "SSH uses russh over tokio::net::TcpStream; the current core has no pre-connect MPTCP socket hook."
        ),
        urlSessionMultipathTCP: NetworkCapabilityAudit = NetworkCapabilityAudit(
            state: .supported,
            detail: "iOS URLSession-backed HTTP transports can request an Apple Multipath TCP service type when the app is entitled."
        ),
        postQuantumKex: SSHKeyExchangeAudit = SSHKeyExchangeAudit()
    ) {
        self.sshMultipathTCP = sshMultipathTCP
        self.urlSessionMultipathTCP = urlSessionMultipathTCP
        self.postQuantumKex = postQuantumKex
    }
}

#if os(iOS)
public extension MultipathTCPMode {
    var urlSessionMultipathServiceType: URLSessionConfiguration.MultipathServiceType {
        switch self {
        case .system, .disabled:
            return .none
        case .handover:
            return .handover
        case .interactive:
            return .interactive
        case .aggregate:
            return .aggregate
        }
    }
}
#endif

private extension String {
    var networkNilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
