// Tests for `pgAgent://` URL parsing — every shape a producer emits (widget,
// Live Activity, iOS accessory widget, legacy SSH links) maps to a route;
// scheme matching is case-insensitive; unknown URLs only activate the app.

import XCTest

@testable import PgAgentApp

final class E_DeepLinkRoutingTests: XCTestCase {

    private func route(_ string: String) -> PgAgentDeepLink {
        PgAgentDeepLink(url: URL(string: string)!)
    }

    func testMonitoringOverview() {
        XCTAssertEqual(route("pgAgent://monitoring"), .monitoringOverview)
        XCTAssertEqual(route("pgAgent://monitoring/"), .monitoringOverview)
        XCTAssertEqual(route("pgAgent://fleet"), .monitoringOverview)
    }

    func testMonitoringInstance() {
        XCTAssertEqual(route("pgAgent://monitoring/prod-db"), .monitoring(profileId: "prod-db"))
    }

    func testSchemeAndHostAreCaseInsensitive() {
        XCTAssertEqual(route("pgagent://Monitoring/abc"), .monitoring(profileId: "abc"))
        XCTAssertEqual(route("PGAGENT://monitoring"), .monitoringOverview)
    }

    func testProfileIdIsPercentDecoded() {
        XCTAssertEqual(route("pgAgent://monitoring/my%20db"), .monitoring(profileId: "my db"))
    }

    func testLegacyProfileShapes() {
        for host in ["server", "profile", "terminal", "folder", "files"] {
            XCTAssertEqual(route("pgAgent://\(host)/p1"), .profile(profileId: "p1"), host)
        }
        XCTAssertEqual(route("pgAgent://folder/p1?path=/var/log"), .profile(profileId: "p1"))
        XCTAssertEqual(route("pgAgent://server"), .activate)
    }

    func testAutomationRoutesToProfileWhenPresent() {
        XCTAssertEqual(route("pgAgent://automation/op-1?profile=p9"), .profile(profileId: "p9"))
        XCTAssertEqual(route("pgAgent://automation/op-1"), .activate)
    }

    func testUnknownOrForeignURLsOnlyActivate() {
        XCTAssertEqual(route("pgAgent://notify?id=deploy&title=Deploy"), .activate)
        XCTAssertEqual(route("pgAgent://widget?id=api"), .activate)
        XCTAssertEqual(route("pgAgent://nonsense/x"), .activate)
        XCTAssertEqual(route("https://example.com/monitoring/x"), .activate)
    }

    func testMonitoringURLRoundTrips() throws {
        for id in ["prod-db", "8E0C1D1B-2F55-4A36-9F5B-2C2E7D0E4A10", "my db"] {
            let string = try XCTUnwrap(PgAgentDeepLink.monitoringURLString(profileId: id))
            XCTAssertEqual(route(string), .monitoring(profileId: id), id)
        }
    }
}
