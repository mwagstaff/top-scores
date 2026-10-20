//
//  Top_Scores_Watch_Watch_AppUITests.swift
//  Top Scores Watch Watch AppUITests
//
//  Created by Mike Wagstaff on 12/02/2026.
//

import XCTest

final class Top_Scores_Watch_Watch_AppUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testLiveActivityLaunchOpensCompetition() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-live-activity-url",
            "topscores://match?id=8324&date=2026-10-17&time=15:00&league=Premier%20League&home=Brentford&away=Liverpool&homeScore=1&awayScore=0&status=HT"
        ]
        app.launchEnvironment["LIVE_ACTIVITY_MATCHES_JSON"] = """
        [
          {"date":"2026-10-17","time":"15:00","league":"Premier League","home_team":"Brentford","away_team":"Liverpool","match_details_id":"8324","home_score":1,"away_score":1,"score_status":"62"},
          {"date":"2026-10-17","time":"15:00","league":"Premier League","home_team":"Fulham","away_team":"Hull","match_details_id":"8325","home_score":0,"away_score":0,"score_status":"62"}
        ]
        """
        app.launch()
        XCTAssertTrue(app.staticTexts["Brentford"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Liverpool"].exists)
        XCTAssertTrue(app.navigationBars["Premier League"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Fulham"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Top Scores"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Premier League"].exists)
        // Returning home must not replay the cold-launch route.
        XCTAssertTrue(app.staticTexts["Waiting for phone data"].exists || app.staticTexts["Fixtures"].exists)
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
