import XCTest

final class PredictionGameUITests: XCTestCase {
    @MainActor
    func testPredictionHomeKeepsVisibilityChoiceAndHasNoLoginButton() throws {
        continueAfterFailure = false
        let app = application()
        app.launch()
        let menuButton = app.buttons["prediction-game-menu"]
        XCTAssertTrue(menuButton.waitForExistence(timeout: 20))
        XCTAssertEqual(menuButton.value as? String, "Off")
        menuButton.tap()

        let toggle = app.switches["beat-ai-show-predictions"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["beat-ai-competition"].exists)
        XCTAssertTrue(app.buttons["beat-ai-start"].exists)
        XCTAssertFalse(app.buttons["Connect Game Center"].exists)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1"), object: toggle
        )], timeout: 5), .completed)
        app.buttons["beat-ai-close"].tap()
        XCTAssertTrue(menuButton.waitForExistence(timeout: 5))
        XCTAssertEqual(menuButton.value as? String, "On")
        menuButton.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        attach(app, name: "Beat the AI home")
        app.buttons["beat-ai-close"].tap()
    }

    @MainActor
    func testProgressIsReachableFromTheGameHome() throws {
        continueAfterFailure = false
        let app = application()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Scores"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["beat-ai-start"].exists)
        app.tabBars.buttons["Profile"].tap()
        let entry = app.buttons["prediction-game-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        let progress = app.buttons["beat-ai-progress"]
        if !progress.isHittable { app.swipeUp() }
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        progress.tap()
        let achievements = app.buttons["Achievements"]
        XCTAssertTrue(achievements.waitForExistence(timeout: 5))
        achievements.tap()
        XCTAssertTrue(app.staticTexts["First Whistle"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Connect Game Center"].exists)
        attach(app, name: "Beat the AI achievements")
    }

    @MainActor
    func testPrivateLeaguesAreInsideTheGameAndJoiningRequiresAConfirmButton() throws {
        continueAfterFailure = false
        let app = application()
        app.launch()
        let menu = app.buttons["prediction-game-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        let leagues = app.buttons["beat-ai-my-leagues"]
        for _ in 0..<4 where !leagues.isHittable { app.swipeUp() }
        XCTAssertTrue(leagues.waitForExistence(timeout: 5))
        leagues.tap()
        let join = app.buttons["mini-league-join"]
        XCTAssertTrue(join.waitForExistence(timeout: 10))
        join.tap()
        XCTAssertTrue(app.textFields["mini-league-invite-code"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["mini-league-join-confirm"].exists)
        XCTAssertFalse(app.buttons["Connect Game Center"].exists)
        app.buttons["Cancel"].tap()
        app.buttons["mini-league-create"].tap()
        XCTAssertTrue(app.textFields["mini-league-name"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["mini-league-create-confirm"].isEnabled)
        attach(app, name: "Private league creation")
    }

    @MainActor
    private func application() -> XCUIApplication {
        let app = XCUIApplication()
        // No guest accounts, scores or Game Center connections are created by UI tests.
        app.launchArguments = [
            "-predictionGame.enabled", "NO",
            "-preferences.showPredictedScores", "NO",
            "-preferences.apiBaseURL", "http://127.0.0.1:1/api/v1",
        ]
        return app
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
