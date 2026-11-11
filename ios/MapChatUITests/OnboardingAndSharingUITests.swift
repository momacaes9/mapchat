import XCTest

/// UI tests run against the in-memory mock backend (`-mockBackend`), so
/// they need no network, accounts or location permission.
final class OnboardingAndSharingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mockBackend", "-resetPrefs"] + args
        app.launch()
        return app
    }

    func testOnboardingRequiresConsentBeforeStarting() {
        let app = launch(["-resetOnboarding"])

        XCTAssertTrue(app.staticTexts["Find your roommate, stair-free"].waitForExistence(timeout: 10))
        for _ in 0..<3 { app.buttons["onboarding.next"].tap() }

        XCTAssertTrue(app.staticTexts["Permissions"].waitForExistence(timeout: 5))
        let finish = app.buttons["onboarding.finish"]
        XCTAssertTrue(finish.exists)
        XCTAssertFalse(finish.isEnabled, "Cannot start without acknowledging how sharing works")

        let consent = app.switches["onboarding.consent"]
        // Tap the switch control itself (right edge) rather than the long label.
        consent.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(finish.isEnabled)
        finish.tap()

        // Mock backend is signed in: the map with the sharing indicator appears.
        XCTAssertTrue(app.staticTexts["Sharing ON with Ana"].waitForExistence(timeout: 10))
    }

    func testPauseAllSharingUpdatesIndicatorEverywhere() {
        let app = launch(["-skipOnboarding"])

        XCTAssertTrue(app.staticTexts["Sharing ON with Ana"].waitForExistence(timeout: 10))

        app.tabBars.buttons["Sharing"].tap()
        let pause = app.switches["sharing.pauseAll"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()

        XCTAssertTrue(app.staticTexts["Sharing paused"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Map"].tap()
        XCTAssertTrue(app.staticTexts["Sharing paused"].waitForExistence(timeout: 5),
                      "The map's indicator must show that sharing is paused")
    }

    func testPausingOnePersonChangesTheirStatus() {
        let app = launch(["-skipOnboarding"])
        app.tabBars.buttons["Sharing"].tap()

        let pauseAna = app.buttons["sharing.pause.Ana"]
        XCTAssertTrue(pauseAna.waitForExistence(timeout: 10))
        pauseAna.tap()
        XCTAssertTrue(app.staticTexts["Paused"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Resume"].exists)
    }

    func testErrorStateOffersRetry() {
        let app = launch(["-skipOnboarding", "-mockFriendsError"])
        XCTAssertTrue(app.descendants(matching: .any)["map.retry"].waitForExistence(timeout: 10))
    }

    func testElevatorOnlySettingHidesStairsOptions() {
        let app = launch(["-skipOnboarding"])
        app.tabBars.buttons["Settings"].tap()
        let toggle = app.switches["settings.elevatorOnly"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        // -resetPrefs guarantees the toggle starts off.
        XCTAssertEqual(toggle.value as? String, "0")
        // A tap right after the tab switch can be dropped; retry briefly.
        for _ in 0..<3 where (toggle.value as? String) != "1" {
            toggle.switches.firstMatch.tap()
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: toggle)], timeout: 2)
        }
        XCTAssertEqual(toggle.value as? String, "1", "Elevator-only toggle should be on")
        app.tabBars.buttons["Map"].tap()
        // MapKit re-renders after a tab switch; let it settle before querying.
        sleep(2)
        XCTAssertTrue(app.staticTexts["Elevator-only routes are on"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Fastest"].exists)

        app.descendants(matching: .any)["map.route.Ana"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["• Take elevator A to floor 3"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No stairs"].exists)

    }
}
