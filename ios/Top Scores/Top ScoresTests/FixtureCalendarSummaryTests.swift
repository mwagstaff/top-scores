import Testing
import SwiftUI
@testable import Top_Scores

struct FixtureCalendarSummaryTests {
    @MainActor
    @Test func datePickerOnlyAllowsDatesWithFixtures() {
        let coordinator = FixtureAvailableDatePicker.Coordinator(
            selection: .constant(Date()),
            availableDateKeys: ["2026-08-26"]
        )
        let selection = UICalendarSelectionSingleDate(delegate: coordinator)

        #expect(coordinator.dateSelection(
            selection,
            canSelectDate: DateComponents(year: 2026, month: 8, day: 26)
        ))
        #expect(!coordinator.dateSelection(
            selection,
            canSelectDate: DateComponents(year: 2026, month: 8, day: 27)
        ))
    }

    @Test func competitionSummaries_filterToSelectionAndSortByImportance() {
        let day = FixtureCalendarDay(
            date: "2026-08-26",
            matchCount: 12,
            topMatchCount: 12,
            hasUnfinished: true,
            topMatchesHaveUnfinished: true,
            competitions: [
                FixtureCalendarCompetition(
                    id: "bundesliga",
                    matchCount: 4,
                    hasUnfinished: true
                ),
                FixtureCalendarCompetition(
                    id: "premier-league",
                    matchCount: 5,
                    hasUnfinished: true
                ),
                FixtureCalendarCompetition(
                    id: "la-liga",
                    matchCount: 3,
                    hasUnfinished: true
                ),
            ]
        )
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

        let summaries = FixtureBrowseSelectionResolver.competitionSummaries(
            for: day,
            catalog: catalog,
            selectedCompetitionIDs: ["premier-league", "bundesliga"]
        )

        #expect(summaries.map(\.id) == ["premier-league", "bundesliga"])
        #expect(summaries.map(\.matchCount) == [5, 4])
    }
}
