// PgAgentMacOSBridgeTests — XCTest harness for the FFI bridge.
// Sprint 11: beta smoke tests — these run without a Rust library linked
// (the test host provides stub implementations).

import XCTest
@testable import PgAgentMacOS

final class PgAgentBetaSmokeTests: XCTestCase {

    // MARK: - Connection profile lifecycle

    func testCreateConnectionProfile() {
        let profile = ConnectionProfile(
            name: "Test Server",
            host: "test.example.com",
            port: 22,
            username: "admin",
            authMethod: .publicKey,
            privateKeyPath: "~/.ssh/id_ed25519"
        )
        XCTAssertEqual(profile.name, "Test Server")
        XCTAssertEqual(profile.keychainAccount, "admin@test.example.com:22")
        XCTAssertEqual(profile.sshKeyReference, .plainPath("~/.ssh/id_ed25519"))
        XCTAssertEqual(profile.privateKeyPath, "~/.ssh/id_ed25519")
        XCTAssertFalse(profile.favorite)
        XCTAssertTrue(profile.monitoredSystemdServices.isEmpty)
    }

    func testConnectionProfileStoreRoundTrip() {
        let store = ConnectionStoreData(
            connections: [
                ConnectionProfile(name: "A", host: "a.com", port: 22, username: "u"),
                ConnectionProfile(
                    name: "B",
                    host: "b.com",
                    port: 22,
                    username: "u",
                    monitoredSystemdServices: ["nginx.service", "postgresql.service"]
                ),
            ],
            folders: []
        )

        let encoded = try! JSONEncoder().encode(store)
        let decoded = try! JSONDecoder().decode(ConnectionStoreData.self, from: encoded)

        XCTAssertEqual(decoded.connections.count, 2)
        XCTAssertEqual(decoded.connections[0].host, "a.com")
        XCTAssertEqual(decoded.connections[1].host, "b.com")
        XCTAssertEqual(decoded.connections[1].monitoredSystemdServices, ["nginx.service", "postgresql.service"])
    }

    // MARK: - Layout persistence

    func testWorkspaceLayoutDefault() {
        let layout = WorkspaceLayout.default
        XCTAssertTrue(layout.sidebarVisible)
        XCTAssertFalse(layout.bottomVisible)
        XCTAssertTrue(layout.inspectorVisible)
        XCTAssertEqual(layout.sidebarWidth, 240)
    }

    func testWorkspaceLayoutRoundTrip() {
        let layout = WorkspaceLayout(
            sidebarVisible: false,
            bottomVisible: true,
            inspectorVisible: true,
            sidebarWidth: 180,
            bottomHeight: 250,
            inspectorWidth: 300
        )

        let encoded = try! JSONEncoder().encode(layout)
        let decoded = try! JSONDecoder().decode(WorkspaceLayout.self, from: encoded)

        XCTAssertFalse(decoded.sidebarVisible)
        XCTAssertTrue(decoded.bottomVisible)
        XCTAssertTrue(decoded.inspectorVisible)
        XCTAssertEqual(decoded.inspectorWidth, 300)
    }

    // MARK: - Tab group model

    func testTabActiveLookup() {
        let tab1 = WorkspaceTab(id: UUID(), title: "Tab 1", order: 0)
        let tab2 = WorkspaceTab(id: UUID(), title: "Tab 2", order: 1)
        let group = TabGroup(
            tabs: [tab1, tab2],
            activeTabId: tab1.id
        )
        XCTAssertEqual(group.activeTab?.title, "Tab 1")
    }

    // MARK: - File entry model

    func testFileEntrySorting() {
        let dir = FileEntry(name: "dir", path: "/dir", type: .directory)
        let file = FileEntry(name: "f.txt", path: "/f.txt", type: .file)
        let sorted = [file, dir].sorted { a, b in
            a.type == .directory && b.type != .directory
        }
        XCTAssertEqual(sorted[0].type, .directory)
        XCTAssertEqual(sorted[1].type, .file)
    }

    // MARK: - Transfer queue model

    func testTransferProgress() {
        let item = TransferItem(
            id: "1",
            direction: .upload,
            localPath: "/a", remotePath: "/b",
            size: 100,
            bytesTransferred: 25,
            status: .inProgress,
            connectionId: "c1"
        )
        XCTAssertEqual(item.progress, 0.25, accuracy: 0.001)
    }

    // MARK: - System stats model

    func testSystemStatsMemoryPercent() {
        let stats = SystemStats(
            cpuPercent: 50,
            memoryTotal: 8192 * 1024 * 1024,
            memoryUsed: 4096 * 1024 * 1024,
            memoryFree: 4096 * 1024 * 1024,
            memoryAvailable: 4096 * 1024 * 1024,
            swapTotal: 0, swapUsed: 0,
            diskTotal: "100G", diskUsed: "50G", diskAvailable: "50G",
            diskUsePercent: 50,
            uptime: "1d", loadAverage: nil
        )
        XCTAssertEqual(stats.memoryUsagePercent, 50, accuracy: 0.1)
    }

    // MARK: - Tauri import

    func testTauriImportParsesObject() {
        let json = """
        {"connections": [{"host": "s1.com"}], "folders": [{"name": "Work", "path": "Work"}]}
        """
        let data = try! JSONDecoder().decode(TauriConnectionImport.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(data.connections.count, 1)
        XCTAssertEqual(data.folders?.count, 1)
    }
}
