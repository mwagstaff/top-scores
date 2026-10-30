import Testing
@testable import Top_Scores

struct FixtureOptionsTests {
    @Test func tvTodayRemainsAvailableWithAnEmptyCalendar() {
        let days = FixtureBrowseSelectionResolver.tvListingDays(from: [], todayKey: "2026-10-30")
        #expect(days.map(\.date) == ["2026-10-30"])
        #expect(days.first?.matchCount == 0)
    }

    @Test func tvTodayDoesNotDuplicateOrReplaceExistingMatchCounts() {
        let today = FixtureCalendarDay(
            date: "2026-10-30", matchCount: 5, topMatchCount: 2,
            hasUnfinished: true, topMatchesHaveUnfinished: true, competitions: []
        )
        let days = FixtureBrowseSelectionResolver.tvListingDays(from: [today], todayKey: today.date)
        #expect(days == [today])
    }

    @Test func tvTodayIsInsertedInDateOrderWithoutChangingOtherDates() {
        let tomorrow = FixtureCalendarDay(
            date: "2026-10-31", matchCount: 8, topMatchCount: 4,
            hasUnfinished: true, topMatchesHaveUnfinished: true, competitions: []
        )
        let days = FixtureBrowseSelectionResolver.tvListingDays(from: [tomorrow], todayKey: "2026-10-30")
        #expect(days.map(\.date) == ["2026-10-30", "2026-10-31"])
        #expect(days.last == tomorrow)
    }
}
