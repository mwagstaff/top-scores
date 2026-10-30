//
//  Top_ScoresUITests.swift
//  Top ScoresUITests
//
//  Created by Mike Wagstaff on 11/02/2026.
//

import XCTest

final class Top_ScoresUITests: XCTestCase {

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
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testSelectedFixtureDateStaysCenteredAfterRepeatedPageSwipes() throws {
        let app = XCUIApplication()
        app.launch()

        let calendarButton = app.buttons["calendar"]
        XCTAssertTrue(calendarButton.waitForExistence(timeout: 20))

        for _ in 0..<4 {
            let previousDate = calendarButton.value as? String
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.58))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.58))
            start.press(forDuration: 0.05, thenDragTo: end)

            let dateChanged = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value != %@", previousDate ?? ""),
                object: calendarButton
            )
            XCTAssertEqual(XCTWaiter.wait(for: [dateChanged], timeout: 3), .completed)
        }

        let selectedDateButton = app.buttons.allElementsBoundByIndex.first { element in
            guard let value = element.value as? String else { return false }
            return value.contains("matches") && value.contains("selected")
        }
        XCTAssertNotNil(selectedDateButton)
        XCTAssertTrue(selectedDateButton?.isHittable == true)
        XCTAssertEqual(
            selectedDateButton?.frame.midX ?? 0,
            app.frame.midX,
            // Allow a small layout tolerance while requiring the selected tile to stay
            // centred in the full carousel, regardless of the jump-button side.
            accuracy: 35
        )
    }

    @MainActor
    func testDateSwipeAcrossCompetitionHeaderStaysOnScores() throws {
        let app = XCUIApplication()
        app.launch()

        let calendarButton = app.buttons["calendar"]
        XCTAssertTrue(calendarButton.waitForExistence(timeout: 20))
        let previousDate = calendarButton.value as? String

        // Competition headers are buttons which normally navigate to Tables. A date
        // gesture beginning over one must remain exclusively a date gesture.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.32))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.32))
        start.press(forDuration: 0.05, thenDragTo: end)

        let dateChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", previousDate ?? ""),
            object: calendarButton
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dateChanged], timeout: 3), .completed)
        XCTAssertTrue(app.tabBars.buttons["Scores"].isSelected)
        XCTAssertFalse(app.tabBars.buttons["Tables"].isSelected)
    }

    @MainActor
    func testTodayButtonReturnsToClosestDate() throws {
        let app = XCUIApplication()
        app.launch()

        let dateButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "fixtureDate-")
        )
        XCTAssertTrue(dateButtons.firstMatch.waitForExistence(timeout: 20))
        let jumpButton = app.buttons["Return to today"]
        if jumpButton.exists {
            jumpButton.tap()
            XCTAssertFalse(jumpButton.exists)
        }

        let tiles = dateButtons.allElementsBoundByIndex
        let selectedIndex = try XCTUnwrap(tiles.firstIndex(where: { $0.isSelected }))
        XCTAssertGreaterThan(tiles.count, 1)
        let adjacentDateButton = tiles[selectedIndex == 0 ? 1 : selectedIndex - 1]
        let adjacentDateID = adjacentDateButton.identifier
        adjacentDateButton.tap()
        let adjacentDateSelected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"),
            object: app.buttons[adjacentDateID]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [adjacentDateSelected], timeout: 3), .completed)

        XCTAssertTrue(jumpButton.waitForExistence(timeout: 3))
        let targetPrefix = "fixtureCurrentDateJump-"
        XCTAssertTrue(jumpButton.identifier.hasPrefix(targetPrefix))
        let targetDateKey = String(jumpButton.identifier.dropFirst(targetPrefix.count))
        jumpButton.tap()

        let targetDateButton = app.buttons["fixtureDate-\(targetDateKey)"]
        let selectedDisplayedTarget = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"),
            object: targetDateButton
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selectedDisplayedTarget], timeout: 3), .completed)
        XCTAssertFalse(jumpButton.exists)
        XCTAssertTrue(app.tabBars.buttons["Scores"].isSelected)
    }

    @MainActor
    func testCombinedMatchMenuPresetsAndShortcuts() throws {
        let app = XCUIApplication()
        app.launch()
        let options = app.buttons["fixtureOptionsButton"]
        XCTAssertTrue(options.waitForExistence(timeout: 20))
        XCTAssertGreaterThan(options.frame.midX, app.frame.midX)
        XCTAssertLessThanOrEqual(options.frame.maxY, app.tabBars.firstMatch.frame.minY)

        options.tap()
        app.buttons["Top Teams"].tap()
        XCTAssertEqual(options.value as? String, "Top Teams")
        attachMenuScreenshot(app, name: "Scores - browsing")

        options.tap()
        XCTAssertTrue(app.buttons["Top Teams"].isSelected)
        XCTAssertEqual(options.frame.width, 50, accuracy: 1)
        XCTAssertTrue(app.buttons["fixtureTVShortcut"].isHittable)
        XCTAssertTrue(app.buttons["fixtureSearchShortcut"].isHittable)
        attachMenuScreenshot(app, name: "Scores - combined menu")
        app.buttons["Show All"].tap()
        XCTAssertEqual(options.value as? String, "All Competitions")
        XCTAssertFalse(app.buttons["Show All"].exists)

        options.tap()
        app.buttons["Custom…"].tap()
        XCTAssertTrue(app.buttons["customOptionsApply"].waitForExistence(timeout: 3))
        app.buttons["customOptionsBack"].tap()
        XCTAssertTrue(app.buttons["Show All"].isHittable)

        app.buttons["fixtureSearchShortcut"].tap()
        XCTAssertTrue(app.navigationBars["Find a Team"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        options.tap()
        let calendar = app.buttons["fixtureCalendarShortcut"]
        let calendarReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: calendar)
        XCTAssertEqual(XCTWaiter.wait(for: [calendarReady], timeout: 30), .completed)
        calendar.tap()
        XCTAssertTrue(app.buttons["fixtureCalendarViewMatches"].waitForExistence(timeout: 5))
        app.buttons["fixtureCalendarViewMatches"].tap()
        XCTAssertTrue(options.waitForExistence(timeout: 5))

        // TV Guide starts today and returns to the original fixture date on close.
        let dateButtons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "fixtureDate-"))
        let otherDate = try XCTUnwrap(dateButtons.allElementsBoundByIndex.first {
            !$0.isSelected && app.frame.insetBy(dx: 8, dy: 0).contains($0.frame)
        })
        let originalDateID = otherDate.identifier
        otherDate.tap()
        options.tap()
        app.buttons["fixtureTVShortcut"].tap()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())
        let todayButton = app.buttons["fixtureDate-\(today)"]
        XCTAssertTrue(todayButton.waitForExistence(timeout: 10))
        XCTAssertTrue(todayButton.isSelected)
        XCTAssertTrue(app.navigationBars["TV Guide"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        attachMenuScreenshot(app, name: "TV Guide - full screen")
        app.buttons["tvGuideClose"].tap()
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[originalDateID].isSelected)
        options.tap()
        app.buttons["Top Teams"].tap()
        XCTAssertEqual(options.value as? String, "Top Teams")
        options.tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.20)).tap()
        XCTAssertFalse(app.buttons["Show All"].exists)
    }

    @MainActor
    func testTVGuideWatchabilitySwipeDoesNotOpenDialog() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-tvListingsMinimumStars", "0"]
        app.launch()
        let options = app.buttons["fixtureOptionsButton"]
        XCTAssertTrue(options.waitForExistence(timeout: 30))
        options.tap()
        app.buttons["fixtureTVShortcut"].tap()
        XCTAssertTrue(app.buttons["tvGuideClose"].waitForExistence(timeout: 10))
        let ratings = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tvWatchability-"))
        let dates = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "fixtureDate-"))
        for _ in 0..<7 {
            if ratings.firstMatch.waitForExistence(timeout: 3) { break }
            app.swipeLeft()
        }
        let rating = try XCTUnwrap(ratings.allElementsBoundByIndex.first { $0.isHittable })
        let originalID = try XCTUnwrap(dates.allElementsBoundByIndex.first { $0.isSelected }).identifier
        // A short cancelled swipe must not be interpreted as a rating tap.
        let start = rating.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -30, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertFalse(app.navigationBars["Watchability Index"].exists)
        XCTAssertTrue(app.buttons[originalID].isSelected)
        // A full swipe that starts on the rating changes date without presenting a sheet.
        rating.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: rating.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)))
        expectation(for: NSPredicate { _, _ in !app.buttons[originalID].isSelected }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.navigationBars["Watchability Index"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.55))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.55)))
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: app.buttons[originalID])
        waitForExpectations(timeout: 10)
        rating.tap()
        XCTAssertTrue(app.navigationBars["Watchability Index"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
    }

    @MainActor
    func testTVGuideHorizontalDateSwipes() throws {
        let app = XCUIApplication()
        app.launch()
        let options = app.buttons["fixtureOptionsButton"]
        XCTAssertTrue(options.waitForExistence(timeout: 30))
        options.tap()
        app.buttons["fixtureTVShortcut"].tap()
        XCTAssertTrue(app.buttons["tvGuideClose"].waitForExistence(timeout: 10))
        let dates = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "fixtureDate-"))
        let original = try XCTUnwrap(dates.allElementsBoundByIndex.first { $0.isSelected })
        let originalID = original.identifier
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.55))
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.55))
        right.press(forDuration: 0.1, thenDragTo: left)
        let changed = NSPredicate { _, _ in !app.buttons[originalID].isSelected }
        expectation(for: changed, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        let next = try XCTUnwrap(dates.allElementsBoundByIndex.first { $0.isSelected })
        XCTAssertGreaterThan(next.identifier, originalID)
        XCTAssertTrue(app.navigationBars["TV Guide"].exists)
        left.press(forDuration: 0.1, thenDragTo: right)
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: app.buttons[originalID])
        waitForExpectations(timeout: 10)
        // Vertical scrolling must not change the chosen day.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        XCTAssertTrue(app.buttons[originalID].isSelected)
        XCTAssertTrue(app.buttons["tvGuideClose"].isHittable)
    }

    @MainActor
    func testIntegratedCustomOptionsDraftAndApply() throws {
        let app = XCUIApplication()
        app.launch()
        let options = app.buttons["fixtureOptionsButton"]
        XCTAssertTrue(options.waitForExistence(timeout: 30))
        options.tap()
        app.buttons["Top Teams"].tap()
        options.tap()
        XCTAssertTrue(app.buttons["Matches with Premier League teams"].exists)
        app.buttons["Custom…"].tap()
        let league = app.buttons["customOption-competition:premier-league"]
        XCTAssertTrue(league.waitForExistence(timeout: 5))
        league.tap()
        XCTAssertEqual(league.value as? String, "Selected")
        attachMenuScreenshot(app, name: "Custom - country flags and competition crests")
        app.buttons["customOptionsBack"].tap()
        app.buttons["Custom…"].tap()
        XCTAssertEqual(league.value as? String, "Selected")
        app.buttons["customOptionsClose"].tap()
        XCTAssertEqual(options.value as? String, "Top Teams", "Closing discards the draft")
        options.tap()
        app.buttons["Custom…"].tap()
        XCTAssertEqual(league.value as? String, "Not selected")
        league.tap()
        app.buttons["Rivalries"].tap()
        let rivalry = app.buttons["customOption-rivalry:der-klassiker"]
        XCTAssertTrue(rivalry.waitForExistence(timeout: 5))
        rivalry.tap()
        app.buttons["Competitions"].tap()
        XCTAssertEqual(league.value as? String, "Selected")
        app.buttons["customOptionsApply"].tap()
        XCTAssertFalse(app.buttons["customOptionsApply"].exists)
        XCTAssertEqual(options.value as? String, "Top Teams + Custom")
        options.tap()
        app.buttons["Top Teams"].tap()
    }

    @MainActor
    func testCustomTeamSearchStaysInsideOptions() throws {
        let app = XCUIApplication()
        app.launch()
        let options = app.buttons["fixtureOptionsButton"]
        XCTAssertTrue(options.waitForExistence(timeout: 30))
        options.tap()
        app.buttons["Custom…"].tap()
        app.buttons["Teams"].tap()
        let search = app.textFields["customOptionsSearch"]
        search.tap()
        search.typeText("Arsenal")
        let team = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "customOption-team:")).firstMatch
        XCTAssertTrue(team.waitForExistence(timeout: 30))
        XCTAssertTrue(team.isHittable)
        team.tap()
        XCTAssertEqual(team.value as? String, "Selected")
        attachMenuScreenshot(app, name: "Custom - team search within dialog")
        app.buttons["customOptionsClose"].tap()
        XCTAssertTrue(options.exists)
    }

    @MainActor
    func testCustomOptionsWithAccessibilityText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let options = app.buttons["fixtureOptionsButton"]
        XCTAssertTrue(options.waitForExistence(timeout: 30))
        options.tap()
        let custom = app.buttons["Custom…"]
        for _ in 0..<5 where !custom.isHittable { app.swipeUp() }
        custom.tap()
        XCTAssertTrue(app.buttons["customOptionsApply"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["customOptionsApply"].isHittable)
        XCTAssertTrue(app.buttons["customOptionsClose"].isHittable)
        let league = app.buttons["customOption-competition:premier-league"]
        let list = app.scrollViews["customOptionsList"]
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)), withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(league.isHittable)
        attachMenuScreenshot(app, name: "Custom - accessibility text")
        app.buttons["customOptionsClose"].tap()
    }

    @MainActor
    func testFullScreenCalendarDatesAndCollapsedSubscriptions() throws {
        let app = XCUIApplication()
        app.launch()
        let options = app.buttons["fixtureOptionsButton"]
        XCTAssertTrue(options.waitForExistence(timeout: 30))
        options.tap()
        let calendar = app.buttons["fixtureCalendarShortcut"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 5))
        calendar.tap()

        let close = app.buttons["fixtureCalendarClose"]
        let viewMatches = app.buttons["fixtureCalendarViewMatches"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(viewMatches.isHittable)
        let today = app.buttons["fixtureCalendarToday"]
        if today.exists { XCTAssertLessThan(today.frame.maxX, close.frame.minX) }
        let months = app.scrollViews["fixtureCalendarMonths"]
        XCTAssertTrue(months.exists)
        let dateButtons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "fixtureCalendarDay-"))
        attachMenuScreenshot(app, name: "Calendar - initial month")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Calendar accessibility hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let originalDate = dateButtons.matching(NSPredicate(format: "selected == true")).firstMatch
        XCTAssertTrue(originalDate.exists)
        XCTAssertTrue(originalDate.isHittable, "The calendar should open at the selected month")
        let originalKey = String(originalDate.identifier.dropFirst("fixtureCalendarDay-".count))
        let currentMonthDays = dateButtons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND enabled == true",
            "fixtureCalendarDay-\(originalKey.prefix(7))"
        ))
        let availableDay = try XCTUnwrap(currentMonthDays.allElementsBoundByIndex.first { $0.isHittable })
        let chosenDayID = availableDay.identifier
        XCTAssertFalse((availableDay.value as? String ?? "").isEmpty)
        availableDay.tap()
        let dateSelected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"), object: app.buttons[chosenDayID]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dateSelected], timeout: 3), .completed)
        attachMenuScreenshot(app, name: "Calendar - competition dots and collapsed subscriptions")
        let collapsedHeight = months.frame.height

        let subscribe = app.buttons["fixtureCalendarSubscribe-matches"]
        XCTAssertFalse(subscribe.exists)
        let disclosure = app.buttons["fixtureCalendarSubscriptions"]
        XCTAssertTrue(disclosure.exists)
        disclosure.tap()
        XCTAssertTrue(subscribe.waitForExistence(timeout: 3))
        for feed in ["matches", "85", "70", "55", "0"] {
            XCTAssertTrue(app.buttons["fixtureCalendarSubscribe-\(feed)"].isHittable)
        }
        XCTAssertLessThan(months.frame.height, collapsedHeight)
        attachMenuScreenshot(app, name: "Calendar - direct subscription actions")
        disclosure.tap()
        XCTAssertFalse(subscribe.exists)
        XCTAssertEqual(months.frame.height, collapsedHeight, accuracy: 2)

        months.swipeUp()
        XCTAssertEqual(today.value as? String, "Jump backward")
        attachMenuScreenshot(app, name: "Calendar - scrolling months")
        today.tap()
        XCTAssertFalse(today.exists)
        months.swipeDown()
        months.swipeDown()
        XCTAssertEqual(today.value as? String, "Jump forward")
        attachMenuScreenshot(app, name: "Calendar - Today jumps forward")
        today.tap()
        XCTAssertTrue(app.staticTexts["fixtureCalendarSelectedDate"].exists)
        close.tap()
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["fixtureDate-\(originalKey)"].isSelected, "Closing should not commit a preview date")
        options.tap()
        app.buttons["fixtureCalendarShortcut"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertFalse(subscribe.exists, "Subscriptions should start collapsed when reopened")
        app.buttons[chosenDayID].tap()
        viewMatches.tap()
        let chosenKey = String(chosenDayID.dropFirst("fixtureCalendarDay-".count))
        let chosenFixture = app.buttons["fixtureDate-\(chosenKey)"]
        XCTAssertTrue(chosenFixture.waitForExistence(timeout: 5))
        XCTAssertTrue(chosenFixture.isSelected)
    }

    @MainActor
    func testFullScreenCalendarWithAccessibilityText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let options = app.buttons["fixtureOptionsButton"]
        XCTAssertTrue(options.waitForExistence(timeout: 30))
        options.tap()
        app.buttons["fixtureCalendarShortcut"].tap()
        let close = app.buttons["fixtureCalendarClose"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let actions = app.scrollViews["fixtureCalendarActions"]
        XCTAssertTrue(actions.exists)
        let disclosure = app.buttons["fixtureCalendarSubscriptions"]
        for _ in 0..<6 where !disclosure.isHittable { actions.swipeUp() }
        XCTAssertTrue(disclosure.isHittable)
        disclosure.tap()
        let finalFeed = app.buttons["fixtureCalendarSubscribe-0"]
        for _ in 0..<8 where !finalFeed.isHittable { actions.swipeUp() }
        XCTAssertTrue(finalFeed.isHittable)
        XCTAssertTrue(close.isHittable)
        attachMenuScreenshot(app, name: "Calendar - accessibility text and subscriptions")
        close.tap()
    }

    @MainActor
    func testCombinedMatchMenuWithAccessibilityText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let options = app.buttons["fixtureOptionsButton"]
        XCTAssertTrue(options.waitForExistence(timeout: 20))
        options.tap()
        XCTAssertTrue(app.buttons["fixtureTVShortcut"].isHittable)
        let save = app.buttons["fixtureSaveView"]
        let menu = app.scrollViews["fixtureOptionsMenu"]
        for _ in 0..<6 where !save.isHittable {
            menu.swipeUp()
        }
        XCTAssertTrue(save.isHittable)
        attachMenuScreenshot(app, name: "Scores - accessibility menu")
    }

    @MainActor
    private func attachMenuScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
