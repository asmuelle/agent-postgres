import XCTest

// `MobileAppModel.swift` is compiled directly into this logic-test target
// (see project.yml): which tab is showing and which database Query and
// Browse are scoped to.

@MainActor
final class MobileAppModelTests: XCTestCase {

    func testStartsOnPulseWithNoDatabase() {
        let model = MobileAppModel()
        XCTAssertEqual(model.selectedTab, .pulse)
        XCTAssertNil(model.currentProfileId)
    }

    func testOpenSelectsDatabaseAndTab() {
        let model = MobileAppModel()
        model.open(profileId: "a", in: .browse)
        XCTAssertEqual(model.currentProfileId, "a")
        XCTAssertEqual(model.selectedTab, .browse)
    }

    func testOpenDefaultsToQuery() {
        let model = MobileAppModel()
        model.open(profileId: "a")
        XCTAssertEqual(model.selectedTab, .query)
    }

    func testDeletedCurrentDatabaseIsCleared() {
        let model = MobileAppModel()
        model.open(profileId: "a")
        model.reconcile(availableProfileIds: ["b", "c"])
        XCTAssertNil(model.currentProfileId)
    }

    func testSoleDatabaseIsChosenAutomatically() {
        let model = MobileAppModel()
        model.reconcile(availableProfileIds: ["only"])
        XCTAssertEqual(model.currentProfileId, "only")
    }

    func testNoAutomaticChoiceAmongSeveral() {
        let model = MobileAppModel()
        model.reconcile(availableProfileIds: ["a", "b"])
        XCTAssertNil(model.currentProfileId)
    }

    func testExistingChoiceSurvivesReconcile() {
        let model = MobileAppModel()
        model.open(profileId: "b")
        model.reconcile(availableProfileIds: ["a", "b"])
        XCTAssertEqual(model.currentProfileId, "b")
    }

    func testPresentRequestsASheet() {
        let model = MobileAppModel()
        model.present(.editConnection(profileId: "a"))
        XCTAssertEqual(model.presentedSheet, .editConnection(profileId: "a"))
    }

    // MARK: - Connection only once a database tab is used

    func testNoConnectionWhileOnlyPulseHasBeenShown() {
        let model = MobileAppModel()
        model.reconcile(availableProfileIds: ["only"])
        XCTAssertEqual(model.currentProfileId, "only")
        XCTAssertNil(model.connectedProfileId)
    }

    func testVisitingQueryOrBrowseConnectsTheCurrentDatabase() {
        let model = MobileAppModel()
        model.currentProfileId = "a"
        model.selectedTab = .browse
        XCTAssertEqual(model.connectedProfileId, "a")
        // Going back to Pulse keeps it: the user is working with it.
        model.selectedTab = .pulse
        XCTAssertEqual(model.connectedProfileId, "a")
    }

    func testOpenConnects() {
        let model = MobileAppModel()
        model.open(profileId: "a", in: .query)
        XCTAssertEqual(model.connectedProfileId, "a")
    }

    // MARK: - Sheets never replace each other

    func testPresentDoesNotReplaceAnOpenSheet() {
        let model = MobileAppModel()
        model.present(.editConnection(profileId: "a"))
        model.present(.newConnection)
        XCTAssertEqual(model.presentedSheet, .editConnection(profileId: "a"))
    }

    /// A tapped alert is shown in one window: Pulse, with the alert waiting
    /// for Pulse to push its detail.
    func testShowAlertSwitchesToPulseAndHoldsTheRoute() {
        let model = MobileAppModel()
        model.open(profileId: "a", in: .query)
        model.present(.sshKeys)
        let route = MobileAlertRoute(instanceId: "a", kind: .longRunning, blockerPid: nil)

        model.showAlert(route)

        XCTAssertEqual(model.selectedTab, .pulse)
        XCTAssertNil(model.presentedSheet)
        XCTAssertEqual(model.alertRoute, route)
    }

    /// Each "Open in New Window" is a new window, even for the same database.
    func testWindowTargetsForTheSameDatabaseAreDistinct() {
        XCTAssertNotEqual(MobileWindowTarget(profileId: "a"), MobileWindowTarget(profileId: "a"))
    }

    /// Siri, Spotlight or a control can move the window, but never throw
    /// away a half-typed connection form.
    func testSystemNavigationKeepsAFormButClosesOtherSheets() {
        let model = MobileAppModel()
        model.present(.newConnection)
        model.dismissSheetUnlessItHoldsInput()
        XCTAssertEqual(model.presentedSheet, .newConnection)

        model.dismissSheet()
        model.present(.pro)
        model.dismissSheetUnlessItHoldsInput()
        XCTAssertNil(model.presentedSheet)
    }
}
