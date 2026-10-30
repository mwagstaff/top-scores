import Testing
import SwiftUI
@testable import Top_Scores

struct FixtureCalendarSummaryTests {
    @Test func monthGridIncludesLeapDayAndRespectsFirstWeekday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        calendar.firstWeekday = 2
        let start = try #require(calendar.date(from: DateComponents(year: 2028, month: 2, day: 15)))
        let end = try #require(calendar.date(from: DateComponents(year: 2028, month: 3, day: 1)))
        let months = FixtureCalendarMonth.months(in: start...end, calendar: calendar)
        #expect(months.count == 2)
        #expect(months[0].days.count == 29)
        #expect(months[0].leadingEmptyDays == 1)
        #expect(months[1].leadingEmptyDays == 2)
        #expect(FixtureCalendarMonth.dateKey(for: months[0].days[28], calendar: calendar) == "2028-02-29")
    }

    @Test func monthGridCrossesYearAndDaylightSavingBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        calendar.firstWeekday = 1
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 30)))
        let end = try #require(calendar.date(from: DateComponents(year: 2027, month: 1, day: 1)))
        let months = FixtureCalendarMonth.months(in: start...end, calendar: calendar)
        #expect(months.map { $0.days.count } == [31, 30, 31, 31])
        #expect(months[0].leadingEmptyDays == 4)
        let keys = months.flatMap(\.days).map { FixtureCalendarMonth.dateKey(for: $0, calendar: calendar) }
        #expect(Set(keys).count == 123)
        #expect(keys.contains("2026-10-25"))
        #expect(keys.last == "2027-01-31")
    }

    @Test func dayDotsKeepCompetitionOrderAndDescribeOverflow() {
        let competitions = (1...5).map {
            FixtureCalendarCompetitionSummary(id: "league-\($0)", name: "League \($0)", matchCount: $0, weight: Double(6 - $0))
        }
        let indicators = FixtureCalendarIndicators(competitions: competitions)
        #expect(indicators.visible.map(\.id) == ["league-1", "league-2", "league-3"])
        #expect(indicators.overflowCount == 2)
        #expect(indicators.overflowMatchCount == 9)
        #expect(indicators.accessibilityDescription.contains("League 5, 5 matches"))
        let empty = FixtureCalendarIndicators(competitions: [])
        #expect(empty.visible.isEmpty)
        #expect(empty.overflowCount == 0)
        let three = FixtureCalendarIndicators(competitions: Array(competitions.prefix(3)))
        #expect(three.visible.count == 3)
        #expect(three.overflowCount == 0)
    }

    @Test func competitionSummaries_filterToSelectionAndSortByImportance() throws {
        let matches = try JSONDecoder().decode([Match].self, from: Data(#"""
        [
          {"date":"2026-10-31","time":"15:00","home_team":"Arsenal","away_team":"Chelsea","league":"Premier League"},
          {"date":"2026-10-31","time":"15:00","home_team":"Bayern Munich","away_team":"Mainz","league":"Bundesliga"},
          {"date":"2026-10-31","time":"15:00","home_team":"Augsburg","away_team":"Freiburg","league":"Bundesliga"},
          {"date":"2026-10-31","time":"15:00","home_team":"Sevilla","away_team":"Valencia","league":"La Liga"}
        ]
        """#.utf8))
        let catalog = [
            CompetitionCatalogEntry(
                id: "bundesliga",
                name: "Bundesliga",
                aliases: nil,
                weight: 80,
                region: "germany",
                logoURL: nil
            ),
            CompetitionCatalogEntry(
                id: "premier-league",
                name: "Premier League",
                aliases: nil,
                weight: 100,
                region: "england",
                logoURL: nil
            ),
            CompetitionCatalogEntry(
                id: "la-liga",
                name: "La Liga",
                aliases: nil,
                weight: 90,
                region: "spain",
                logoURL: nil
            ),
        ]

        func summaries(options: Set<String>, showAll: Bool = false) -> [FixtureCalendarCompetitionSummary] {
            let filtered = FixtureBrowseSelectionResolver.filterMatches(
                matches, topMatchesOnly: false, selectedCompetitionIDs: [], competitions: catalog,
                fixtureViewOptionIDs: options, showAllMatches: showAll, includePostponed: false
            )
            return FixtureBrowseSelectionResolver.competitionSummaries(for: filtered, catalog: catalog)
        }

        let top = summaries(options: [FixtureViewOptionID.topTeamsPreset])
        #expect(top.map(\.id) == ["premier-league", "bundesliga"])
        #expect(top.map(\.matchCount) == [1, 1])
        #expect(FixtureCalendarIndicators(competitions: top).visible.map(\.id) == ["premier-league", "bundesliga"])

        let all = summaries(options: [], showAll: true)
        #expect(all.map(\.id) == ["premier-league", "la-liga", "bundesliga"])
        #expect(all.map(\.matchCount) == [1, 1, 2])

        let mixed = summaries(options: [FixtureViewOptionID.topTeamsPreset, FixtureViewOptionID.competition("la-liga")])
        #expect(mixed.map(\.id) == ["premier-league", "la-liga", "bundesliga"])
        #expect(mixed.map(\.matchCount) == [1, 1, 1])

        let league = summaries(options: [FixtureViewOptionID.competition("bundesliga")])
        #expect(league.map(\.id) == ["bundesliga"])
        #expect(league.map(\.matchCount) == [2])
    }
}
