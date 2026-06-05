import Foundation

public protocol CloudProviderTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionCloudProviderTransport: CloudProviderTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public init(multipathMode: MultipathTCPMode) {
        let configuration = URLSessionConfiguration.default
        #if os(iOS)
        configuration.multipathServiceType = multipathMode.urlSessionMultipathServiceType
        #endif
        self.session = URLSession(configuration: configuration)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudServerAPIError.invalidResponse
        }
        return (data, httpResponse)
    }
}

public protocol CloudServerProviderClient: Sendable {
    var provider: CloudServerProvider { get }

    func listServers(account: CloudServerAccountRecord, token: String) async throws -> [CloudServerRecord]
    func createServer(account: CloudServerAccountRecord, token: String, request: CloudServerCreateRequest) async throws -> CloudServerRecord
    func deleteServer(account: CloudServerAccountRecord, token: String, serverId: String) async throws -> CloudServerActionResult
    func rebootServer(account: CloudServerAccountRecord, token: String, serverId: String) async throws -> CloudServerActionResult
}

public enum CloudServerProviderClientFactory {
    public static func client(
        for provider: CloudServerProvider,
        transport: CloudProviderTransport = URLSessionCloudProviderTransport()
    ) -> CloudServerProviderClient {
        switch provider {
        case .digitalOcean:
            return DigitalOceanCloudProviderClient(transport: transport)
        case .hetzner:
            return HetznerCloudProviderClient(transport: transport)
        }
    }
}

public struct DigitalOceanCloudProviderClient: CloudServerProviderClient {
    public let provider: CloudServerProvider = .digitalOcean

    private let transport: CloudProviderTransport
    private let baseURL: URL

    public init(
        transport: CloudProviderTransport = URLSessionCloudProviderTransport(),
        baseURL: URL = URL(string: "https://api.digitalocean.com/v2")!
    ) {
        self.transport = transport
        self.baseURL = baseURL
    }

    public func listServers(account: CloudServerAccountRecord, token: String) async throws -> [CloudServerRecord] {
        var request = try authenticatedRequest(path: "/droplets", token: token)
        request.url = request.url?.appending(queryItems: [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "per_page", value: "200"),
        ])
        let data = try await perform(request, expectedStatusCodes: 200..<300)
        do {
            let response = try Self.decoder.decode(DigitalOceanDropletsResponse.self, from: data)
            return response.droplets.map { $0.serverRecord(accountId: account.id) }
        } catch {
            throw CloudServerAPIError.decoding(error.localizedDescription)
        }
    }

    public func createServer(
        account: CloudServerAccountRecord,
        token: String,
        request createRequest: CloudServerCreateRequest
    ) async throws -> CloudServerRecord {
        if let validationError = createRequest.validationError {
            throw CloudServerAPIError.invalidCreateRequest(validationError)
        }

        var request = try authenticatedRequest(path: "/droplets", token: token)
        request.httpMethod = "POST"
        request.httpBody = try Self.encoder.encode(DigitalOceanCreateDropletRequest(createRequest))
        let data = try await perform(request, expectedStatusCodes: 200..<300)
        do {
            let response = try Self.decoder.decode(DigitalOceanDropletResponse.self, from: data)
            return response.droplet.serverRecord(accountId: account.id)
        } catch {
            throw CloudServerAPIError.decoding(error.localizedDescription)
        }
    }

    public func deleteServer(account: CloudServerAccountRecord, token: String, serverId: String) async throws -> CloudServerActionResult {
        var request = try authenticatedRequest(path: "/droplets/\(serverId.urlPathEscaped)", token: token)
        request.httpMethod = "DELETE"
        _ = try await perform(request, expectedStatusCodes: 200..<300)
        return CloudServerActionResult(
            provider: provider,
            action: .delete,
            serverId: serverId,
            status: "accepted"
        )
    }

    public func rebootServer(account: CloudServerAccountRecord, token: String, serverId: String) async throws -> CloudServerActionResult {
        var request = try authenticatedRequest(path: "/droplets/\(serverId.urlPathEscaped)/actions", token: token)
        request.httpMethod = "POST"
        request.httpBody = try Self.encoder.encode(["type": "reboot"])
        let data = try await perform(request, expectedStatusCodes: 200..<300)
        do {
            let response = try Self.decoder.decode(DigitalOceanActionResponse.self, from: data)
            return CloudServerActionResult(
                provider: provider,
                action: .reboot,
                serverId: serverId,
                providerActionId: response.action.id.map(String.init),
                status: response.action.status ?? "accepted"
            )
        } catch {
            return CloudServerActionResult(
                provider: provider,
                action: .reboot,
                serverId: serverId,
                status: "accepted"
            )
        }
    }

    private func authenticatedRequest(path: String, token: String) throws -> URLRequest {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw CloudServerAPIError.invalidAccount("DigitalOcean API token is missing.")
        }
        var request = URLRequest(url: baseURL.appendingAPIPath(path))
        request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func perform(_ request: URLRequest, expectedStatusCodes: Range<Int>) async throws -> Data {
        let (data, response) = try await transport.data(for: request)
        guard expectedStatusCodes.contains(response.statusCode) else {
            throw CloudServerAPIError.httpStatus(response.statusCode, Self.errorBody(from: data))
        }
        return data
    }

    private static func errorBody(from data: Data) -> String {
        String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).cloudProviderNilIfEmpty ?? "No response body"
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

public struct HetznerCloudProviderClient: CloudServerProviderClient {
    public let provider: CloudServerProvider = .hetzner

    private let transport: CloudProviderTransport
    private let baseURL: URL

    public init(
        transport: CloudProviderTransport = URLSessionCloudProviderTransport(),
        baseURL: URL = URL(string: "https://api.hetzner.cloud/v1")!
    ) {
        self.transport = transport
        self.baseURL = baseURL
    }

    public func listServers(account: CloudServerAccountRecord, token: String) async throws -> [CloudServerRecord] {
        var request = try authenticatedRequest(path: "/servers", token: token)
        request.url = request.url?.appending(queryItems: [
            URLQueryItem(name: "per_page", value: "50"),
        ])
        let data = try await perform(request, expectedStatusCodes: 200..<300)
        do {
            let response = try Self.decoder.decode(HetznerServersResponse.self, from: data)
            return response.servers.map { $0.serverRecord(accountId: account.id) }
        } catch {
            throw CloudServerAPIError.decoding(error.localizedDescription)
        }
    }

    public func createServer(
        account: CloudServerAccountRecord,
        token: String,
        request createRequest: CloudServerCreateRequest
    ) async throws -> CloudServerRecord {
        if let validationError = createRequest.validationError {
            throw CloudServerAPIError.invalidCreateRequest(validationError)
        }

        var request = try authenticatedRequest(path: "/servers", token: token)
        request.httpMethod = "POST"
        request.httpBody = try Self.encoder.encode(HetznerCreateServerRequest(createRequest))
        let data = try await perform(request, expectedStatusCodes: 200..<300)
        do {
            let response = try Self.decoder.decode(HetznerServerResponse.self, from: data)
            return response.server.serverRecord(accountId: account.id)
        } catch {
            throw CloudServerAPIError.decoding(error.localizedDescription)
        }
    }

    public func deleteServer(account: CloudServerAccountRecord, token: String, serverId: String) async throws -> CloudServerActionResult {
        var request = try authenticatedRequest(path: "/servers/\(serverId.urlPathEscaped)", token: token)
        request.httpMethod = "DELETE"
        let data = try await perform(request, expectedStatusCodes: 200..<300)
        return Self.actionResult(
            data: data,
            provider: provider,
            action: .delete,
            serverId: serverId
        )
    }

    public func rebootServer(account: CloudServerAccountRecord, token: String, serverId: String) async throws -> CloudServerActionResult {
        var request = try authenticatedRequest(path: "/servers/\(serverId.urlPathEscaped)/actions/reboot", token: token)
        request.httpMethod = "POST"
        let data = try await perform(request, expectedStatusCodes: 200..<300)
        return Self.actionResult(
            data: data,
            provider: provider,
            action: .reboot,
            serverId: serverId
        )
    }

    private func authenticatedRequest(path: String, token: String) throws -> URLRequest {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw CloudServerAPIError.invalidAccount("Hetzner API token is missing.")
        }
        var request = URLRequest(url: baseURL.appendingAPIPath(path))
        request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func perform(_ request: URLRequest, expectedStatusCodes: Range<Int>) async throws -> Data {
        let (data, response) = try await transport.data(for: request)
        guard expectedStatusCodes.contains(response.statusCode) else {
            throw CloudServerAPIError.httpStatus(response.statusCode, Self.errorBody(from: data))
        }
        return data
    }

    private static func actionResult(
        data: Data,
        provider: CloudServerProvider,
        action: CloudServerLifecycleAction,
        serverId: String
    ) -> CloudServerActionResult {
        guard let response = try? decoder.decode(HetznerActionResponse.self, from: data) else {
            return CloudServerActionResult(
                provider: provider,
                action: action,
                serverId: serverId,
                status: "accepted"
            )
        }

        return CloudServerActionResult(
            provider: provider,
            action: action,
            serverId: serverId,
            providerActionId: response.action.id.map(String.init),
            status: response.action.status ?? "accepted"
        )
    }

    private static func errorBody(from data: Data) -> String {
        String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).cloudProviderNilIfEmpty ?? "No response body"
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

// MARK: - DigitalOcean DTOs

private struct DigitalOceanDropletsResponse: Decodable {
    let droplets: [DigitalOceanDroplet]
}

private struct DigitalOceanDropletResponse: Decodable {
    let droplet: DigitalOceanDroplet
}

private struct DigitalOceanDroplet: Decodable {
    struct Region: Decodable {
        let slug: String?
        let name: String?
    }

    struct Image: Decodable {
        let slug: String?
        let name: String?
    }

    struct Networks: Decodable {
        let v4: [NetworkV4]?
        let v6: [NetworkV6]?
    }

    struct NetworkV4: Decodable {
        let ipAddress: String?
        let type: String?

        private enum CodingKeys: String, CodingKey {
            case ipAddress = "ip_address"
            case type
        }
    }

    struct NetworkV6: Decodable {
        let ipAddress: String?
        let type: String?

        private enum CodingKeys: String, CodingKey {
            case ipAddress = "ip_address"
            case type
        }
    }

    let id: Int64
    let name: String
    let status: String?
    let region: Region?
    let image: Image?
    let sizeSlug: String?
    let networks: Networks?
    let tags: [String]?
    let createdAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
        case region
        case image
        case sizeSlug = "size_slug"
        case networks
        case tags
        case createdAt = "created_at"
    }

    func serverRecord(accountId: String) -> CloudServerRecord {
        CloudServerRecord(
            provider: .digitalOcean,
            accountId: accountId,
            providerServerId: String(id),
            name: name,
            status: CloudServerPowerState(digitalOceanStatus: status),
            regionSlug: region?.slug,
            regionName: region?.name,
            sizeSlug: sizeSlug,
            imageSlug: image?.slug,
            imageName: image?.name,
            publicIPv4: networks?.v4?.first(where: { $0.type == "public" })?.ipAddress,
            publicIPv6: networks?.v6?.first(where: { $0.type == "public" })?.ipAddress,
            privateIPv4: networks?.v4?.first(where: { $0.type == "private" })?.ipAddress,
            tags: tags ?? [],
            createdAt: createdAt
        )
    }
}

private struct DigitalOceanCreateDropletRequest: Encodable {
    let name: String
    let region: String
    let size: String
    let image: String
    let sshKeys: [String]
    let backups: Bool
    let ipv6: Bool
    let tags: [String]
    let userData: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case region
        case size
        case image
        case sshKeys = "ssh_keys"
        case backups
        case ipv6
        case tags
        case userData = "user_data"
    }

    init(_ request: CloudServerCreateRequest) {
        name = request.name
        region = request.regionSlug
        size = request.sizeSlug
        image = request.imageSlug
        sshKeys = request.sshKeyIds
        backups = request.enableBackups
        ipv6 = request.enableIPv6
        tags = request.tags
        userData = request.userData
    }
}

private struct DigitalOceanActionResponse: Decodable {
    let action: Action

    struct Action: Decodable {
        let id: Int64?
        let status: String?
    }
}

// MARK: - Hetzner DTOs

private struct HetznerServersResponse: Decodable {
    let servers: [HetznerServer]
}

private struct HetznerServerResponse: Decodable {
    let server: HetznerServer
}

private struct HetznerServer: Decodable {
    struct PublicNet: Decodable {
        let ipv4: IPAddress?
        let ipv6: IPAddress?
    }

    struct PrivateNet: Decodable {
        let ip: String?
    }

    struct IPAddress: Decodable {
        let ip: String?
    }

    struct ServerType: Decodable {
        let name: String?
    }

    struct Image: Decodable {
        let name: String?
    }

    struct Datacenter: Decodable {
        let location: Location?
    }

    struct Location: Decodable {
        let name: String?
        let description: String?
    }

    let id: Int64
    let name: String
    let status: String?
    let publicNet: PublicNet?
    let privateNet: [PrivateNet]?
    let serverType: ServerType?
    let image: Image?
    let datacenter: Datacenter?
    let labels: [String: String]?
    let created: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
        case publicNet = "public_net"
        case privateNet = "private_net"
        case serverType = "server_type"
        case image
        case datacenter
        case labels
        case created
    }

    func serverRecord(accountId: String) -> CloudServerRecord {
        CloudServerRecord(
            provider: .hetzner,
            accountId: accountId,
            providerServerId: String(id),
            name: name,
            status: CloudServerPowerState(hetznerStatus: status),
            regionSlug: datacenter?.location?.name,
            regionName: datacenter?.location?.description,
            sizeSlug: serverType?.name,
            imageName: image?.name,
            publicIPv4: publicNet?.ipv4?.ip,
            publicIPv6: publicNet?.ipv6?.ip,
            privateIPv4: privateNet?.first?.ip,
            tags: labels?.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" } ?? [],
            metadata: labels ?? [:],
            createdAt: created
        )
    }
}

private struct HetznerCreateServerRequest: Encodable {
    let name: String
    let serverType: String
    let image: String
    let location: String
    let sshKeys: [String]
    let labels: [String: String]
    let userData: String?
    let publicNet: PublicNet

    struct PublicNet: Encodable {
        let enableIPv4: Bool
        let enableIPv6: Bool

        private enum CodingKeys: String, CodingKey {
            case enableIPv4 = "enable_ipv4"
            case enableIPv6 = "enable_ipv6"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case serverType = "server_type"
        case image
        case location
        case sshKeys = "ssh_keys"
        case labels
        case userData = "user_data"
        case publicNet = "public_net"
    }

    init(_ request: CloudServerCreateRequest) {
        name = request.name
        serverType = request.sizeSlug
        image = request.imageSlug
        location = request.regionSlug
        sshKeys = request.sshKeyIds
        labels = Dictionary(uniqueKeysWithValues: request.tags.map { ($0, "true") })
        userData = request.userData
        publicNet = PublicNet(enableIPv4: true, enableIPv6: request.enableIPv6)
    }
}

private struct HetznerActionResponse: Decodable {
    let action: Action

    struct Action: Decodable {
        let id: Int64?
        let status: String?
    }
}

private extension CloudServerPowerState {
    init(digitalOceanStatus: String?) {
        switch digitalOceanStatus?.lowercased() {
        case "new":
            self = .provisioning
        case "active":
            self = .running
        case "off":
            self = .stopped
        case "archive":
            self = .stopped
        default:
            self = .unknown
        }
    }

    init(hetznerStatus: String?) {
        switch hetznerStatus?.lowercased() {
        case "initializing", "starting":
            self = .provisioning
        case "running":
            self = .running
        case "off":
            self = .stopped
        case "rebooting":
            self = .rebooting
        case "deleting":
            self = .deleting
        case "migrating", "rebuilding":
            self = .provisioning
        default:
            self = .unknown
        }
    }
}

private extension URL {
    func appendingAPIPath(_ path: String) -> URL {
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return appendingPathComponent(trimmedPath)
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, trimmedPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        return components.url ?? appendingPathComponent(trimmedPath)
    }

    func appending(queryItems: [URLQueryItem]) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        components.queryItems = (components.queryItems ?? []) + queryItems
        return components.url ?? self
    }
}

private extension String {
    var urlPathEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }

    var cloudProviderNilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
