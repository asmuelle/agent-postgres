import XCTest
@testable import PgAgentMacOS

final class CloudServerProviderClientTests: XCTestCase {
    func testDigitalOceanListParsesDropletsAndBuildsRequest() async throws {
        let transport = MockCloudProviderTransport { request in
            XCTAssertEqual(request.url?.path, "/v2/droplets")
            XCTAssertTrue(request.url?.query?.contains("per_page=200") == true)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            return httpResponse(
                url: request.url!,
                body: """
                {
                  "droplets": [
                    {
                      "id": 42,
                      "name": "prod-api",
                      "status": "active",
                      "size_slug": "s-1vcpu-1gb",
                      "created_at": "2026-05-10T12:00:00Z",
                      "region": {"slug": "nyc3", "name": "New York 3"},
                      "image": {"slug": "ubuntu-24-04-x64", "name": "Ubuntu 24.04"},
                      "networks": {
                        "v4": [
                          {"ip_address": "203.0.113.10", "type": "public"},
                          {"ip_address": "10.10.0.5", "type": "private"}
                        ],
                        "v6": [{"ip_address": "2001:db8::10", "type": "public"}]
                      },
                      "tags": ["prod", "api"]
                    }
                  ]
                }
                """
            )
        }
        let client = DigitalOceanCloudProviderClient(transport: transport)
        let account = CloudServerAccountRecord(
            id: "do",
            provider: .digitalOcean,
            displayName: "DigitalOcean",
            keychainAccount: "cloud:do"
        )

        let servers = try await client.listServers(account: account, token: "token")

        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers.first?.providerServerId, "42")
        XCTAssertEqual(servers.first?.connectHost, "203.0.113.10")
        XCTAssertEqual(servers.first?.privateIPv4, "10.10.0.5")
        XCTAssertEqual(servers.first?.status, .running)
        XCTAssertEqual(servers.first?.tags, ["prod", "api"])
    }

    func testDigitalOceanCreateBuildsRequestBody() async throws {
        let transport = MockCloudProviderTransport { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v2/droplets")
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["name"] as? String, "build")
            XCTAssertEqual(json["region"] as? String, "nyc3")
            XCTAssertEqual(json["size"] as? String, "s-1vcpu-1gb")
            XCTAssertEqual(json["image"] as? String, "ubuntu-24-04-x64")
            XCTAssertEqual(json["ssh_keys"] as? [String], ["12345"])
            return httpResponse(
                url: request.url!,
                body: """
                {
                  "droplet": {
                    "id": 43,
                    "name": "build",
                    "status": "new",
                    "size_slug": "s-1vcpu-1gb",
                    "region": {"slug": "nyc3", "name": "New York 3"},
                    "image": {"slug": "ubuntu-24-04-x64", "name": "Ubuntu 24.04"},
                    "networks": {"v4": [], "v6": []},
                    "tags": ["ci"]
                  }
                }
                """,
                statusCode: 202
            )
        }
        let client = DigitalOceanCloudProviderClient(transport: transport)
        let account = CloudServerAccountRecord(
            id: "do",
            provider: .digitalOcean,
            displayName: "DigitalOcean",
            keychainAccount: "cloud:do"
        )

        let server = try await client.createServer(
            account: account,
            token: "token",
            request: CloudServerCreateRequest(
                name: "build",
                regionSlug: "nyc3",
                sizeSlug: "s-1vcpu-1gb",
                imageSlug: "ubuntu-24-04-x64",
                sshKeyIds: ["12345"],
                tags: ["ci"]
            )
        )

        XCTAssertEqual(server.providerServerId, "43")
        XCTAssertEqual(server.status, .provisioning)
    }

    func testHetznerListParsesServers() async throws {
        let transport = MockCloudProviderTransport { request in
            XCTAssertEqual(request.url?.path, "/v1/servers")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            return httpResponse(
                url: request.url!,
                body: """
                {
                  "servers": [
                    {
                      "id": 99,
                      "name": "edge",
                      "status": "running",
                      "created": "2026-05-10T12:00:00Z",
                      "public_net": {
                        "ipv4": {"ip": "198.51.100.20"},
                        "ipv6": {"ip": "2001:db8::20"}
                      },
                      "private_net": [{"ip": "10.0.0.20"}],
                      "server_type": {"name": "cx22"},
                      "image": {"name": "ubuntu-24.04"},
                      "datacenter": {"location": {"name": "fsn1", "description": "Falkenstein"}},
                      "labels": {"role": "edge"}
                    }
                  ]
                }
                """
            )
        }
        let client = HetznerCloudProviderClient(transport: transport)
        let account = CloudServerAccountRecord(
            id: "hetzner",
            provider: .hetzner,
            displayName: "Hetzner",
            keychainAccount: "cloud:hetzner"
        )

        let servers = try await client.listServers(account: account, token: "token")

        XCTAssertEqual(servers.first?.providerServerId, "99")
        XCTAssertEqual(servers.first?.connectHost, "198.51.100.20")
        XCTAssertEqual(servers.first?.locationLabel, "Falkenstein")
        XCTAssertEqual(servers.first?.tags, ["role:edge"])
        XCTAssertEqual(servers.first?.status, .running)
    }

    func testHetznerRebootBuildsActionRequest() async throws {
        let transport = MockCloudProviderTransport { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/servers/99/actions/reboot")
            return httpResponse(
                url: request.url!,
                body: #"{"action":{"id":123,"status":"running"}}"#
            )
        }
        let client = HetznerCloudProviderClient(transport: transport)
        let account = CloudServerAccountRecord(
            id: "hetzner",
            provider: .hetzner,
            displayName: "Hetzner",
            keychainAccount: "cloud:hetzner"
        )

        let result = try await client.rebootServer(account: account, token: "token", serverId: "99")

        XCTAssertEqual(result.providerActionId, "123")
        XCTAssertEqual(result.status, "running")
    }
}

final class CloudServerProfileGeneratorTests: XCTestCase {
    func testProfileGenerationUsesPublicAddressAndStableCloudId() throws {
        let account = CloudServerAccountRecord(
            id: "do",
            provider: .digitalOcean,
            displayName: "Production Cloud",
            keychainAccount: "cloud:do"
        )
        let server = CloudServerRecord(
            provider: .digitalOcean,
            accountId: "do",
            providerServerId: "42",
            name: "prod-api",
            status: .running,
            regionSlug: "nyc3",
            publicIPv4: "203.0.113.10",
            tags: ["api"]
        )

        let profile = try XCTUnwrap(CloudServerProfileGenerator.profile(from: server, account: account))

        XCTAssertEqual(profile.id, "cloud-digitalOcean-do-42")
        XCTAssertEqual(profile.name, "prod-api")
        XCTAssertEqual(profile.host, "203.0.113.10")
        XCTAssertEqual(profile.username, "root")
        XCTAssertEqual(profile.folderPath, "Cloud/Production Cloud")
        XCTAssertEqual(profile.tags, ["cloud", "DigitalOcean", "nyc3", "api"])
        XCTAssertEqual(profile.sshKeyReference, .agent(identityHint: nil))
    }

    func testProfileGenerationSkipsServerWithoutPublicAddress() {
        let account = CloudServerAccountRecord(
            id: "hetzner",
            provider: .hetzner,
            displayName: "Hetzner",
            keychainAccount: "cloud:hetzner"
        )
        let server = CloudServerRecord(
            provider: .hetzner,
            accountId: "hetzner",
            providerServerId: "99",
            name: "private",
            status: .running
        )

        XCTAssertNil(CloudServerProfileGenerator.profile(from: server, account: account))
    }
}

private final class MockCloudProviderTransport: CloudProviderTransport, @unchecked Sendable {
    private let handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await handler(request)
    }
}

private func httpResponse(
    url: URL,
    body: String,
    statusCode: Int = 200
) -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    return (Data(body.utf8), response)
}
