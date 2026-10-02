import XCTest

// `MobileSystemNavigator.swift` is compiled directly into this logic-test
// target (see project.yml): where Siri, Spotlight, Control Center and
// widget links send the app.

@MainActor
final class MobileSystemNavigationTests: XCTestCase {

    // MARK: - pgAgent:// links

    func testFleetAndPulseLinksOpenPulse() {
        XCTAssertEqual(MobileSystemDestination(url: URL(string: "pgAgent://fleet")!), .pulse)
        XCTAssertEqual(MobileSystemDestination(url: URL(string: "pgAgent://pulse")!), .pulse)
    }

    func testQueryAndBrowseLinksCarryTheDatabase() {
        XCTAssertEqual(MobileSystemDestination(url: URL(string: "pgAgent://query?db=abc")!), .query(profileId: "abc"))
        XCTAssertEqual(MobileSystemDestination(url: URL(string: "pgAgent://browse?db=abc")!), .browse(profileId: "abc"))
    }

    func testQueryLinkWithoutADatabaseKeepsTheCurrentOne() {
        XCTAssertEqual(MobileSystemDestination(url: URL(string: "pgAgent://query")!), .query(profileId: nil))
        XCTAssertEqual(MobileSystemDestination(url: URL(string: "pgAgent://query?db=")!), .query(profileId: nil))
    }

    func testSchemeIsCaseInsensitive() {
        XCTAssertEqual(MobileSystemDestination(url: URL(string: "pgagent://pulse")!), .pulse)
    }

    func testIgnoresOtherLinks() {
        XCTAssertNil(MobileSystemDestination(url: URL(string: "https://example.com/pulse")!))
        XCTAssertNil(MobileSystemDestination(url: URL(string: "pgAgent://somewhere")!))
    }

    // MARK: - Navigator

    /// One window takes a request; the others must not act on it again.
    func testARequestIsTakenOnce() {
        let navigator = MobileSystemNavigator()
        navigator.request(.pulse)

        XCTAssertEqual(navigator.take(), .pulse)
        XCTAssertNil(navigator.take())
    }

    func testANewerRequestReplacesAnUntakenOne() {
        let navigator = MobileSystemNavigator()
        navigator.request(.pulse)
        navigator.request(.query(profileId: "a"))

        XCTAssertEqual(navigator.take(), .query(profileId: "a"))
    }

    /// A request nobody took in time (say, the unlock was cancelled) must
    /// not fire later, when the user opens the app for something else.
    func testAnOldRequestExpires() {
        let navigator = MobileSystemNavigator()
        let start = Date(timeIntervalSince1970: 1_000_000)
        navigator.request(.pulse, at: start)

        XCTAssertNil(navigator.take(at: start.addingTimeInterval(MobileSystemNavigator.requestLifetime + 1)))
    }

    func testARecentRequestIsTaken() {
        let navigator = MobileSystemNavigator()
        let start = Date(timeIntervalSince1970: 1_000_000)
        navigator.request(.pulse, at: start)

        XCTAssertEqual(navigator.take(at: start.addingTimeInterval(1)), .pulse)
    }
}
