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
            // The jump button reserves asymmetric edge space, so the selected tile is
            // centered in the unobscured carousel rather than the full screen.
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
    func testJumpButtonReturnsToItsDisplayedDate() throws {
        let app = XCUIApplication()
        app.launch()

        let calendarButton = app.buttons["calendar"]
        XCTAssertTrue(calendarButton.waitForExistence(timeout: 20))

        for _ in 0..<2 {
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

        let jumpButton = app.buttons["Jump to next scheduled match"]
        XCTAssertTrue(jumpButton.waitForExistence(timeout: 3))
        let targetPrefix = "fixtureDateJump-"
        XCTAssertTrue(jumpButton.identifier.hasPrefix(targetPrefix))
        let targetDateKey = String(jumpButton.identifier.dropFirst(targetPrefix.count))
        jumpButton.tap()

        let targetDateButton = app.buttons["fixtureDate-\(targetDateKey)"]
        let selectedDisplayedTarget = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"),
            object: targetDateButton
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selectedDisplayedTarget], timeout: 3), .completed)
        XCTAssertTrue(app.tabBars.buttons["Scores"].isSelected)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
