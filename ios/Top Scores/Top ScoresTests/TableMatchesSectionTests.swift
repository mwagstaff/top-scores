import Testing
@testable import Top_Scores

struct TableMatchesSectionTests {
    @Test func liveMatchesTakePriorityOverResultsAndFixtures() {
        let section = TableMatchesSection.resolve(from: [
            match(date: "2020-08-20", home: "A", away: "B", round: 1, status: "FT"),
            match(date: "2026-08-29", home: "C", away: "D", round: 2, status: "45"),
            match(date: "2099-08-30", home: "E", away: "F", round: 3),
        ])

        #expect(section?.kind == .inProgress)
        #expect(section?.matches.map(\.homeTeam) == ["C"])
    }

    @Test func latestResultsContainOnlyTheLatestCompletedRound() {
        let section = TableMatchesSection.resolve(from: [
            match(date: "2020-08-20", home: "A", away: "B", round: 1, status: "FT"),
            match(date: "2020-08-27", home: "A", away: "C", round: 2, status: "FT"),
            match(date: "2020-08-28", home: "B", away: "D", round: 2, status: "FT"),
            match(date: "2099-09-03", home: "A", away: "D", round: 3),
        ])

        #expect(section?.kind == .latestResults)
        #expect(section?.matches.map(\.roundNumber) == [2, 2])
    }

    @Test func futureFixturesUseTheNextRoundWhenNoResultsExist() {
        let section = TableMatchesSection.resolve(from: [
            match(date: "2099-08-30", home: "A", away: "B", round: 1),
            match(date: "2099-08-31", home: "C", away: "D", round: 1),
            match(date: "2099-09-06", home: "A", away: "C", round: 2),
        ])

        #expect(section?.kind == .futureFixtures)
        #expect(section?.matches.map(\.roundNumber) == [1, 1])
    }

    @Test func repeatedTeamsInferRoundBoundariesForOlderPayloads() {
        let section = TableMatchesSection.resolve(from: [
            match(date: "2020-08-20", home: "A", away: "B", round: nil, status: "FT"),
            match(date: "2020-08-20", home: "C", away: "D", round: nil, status: "FT"),
            match(date: "2020-08-27", home: "A", away: "C", round: nil, status: "FT"),
            match(date: "2020-08-27", home: "B", away: "D", round: nil, status: "FT"),
        ])

        #expect(section?.kind == .latestResults)
        #expect(section?.matches.map(\.homeTeam) == ["A", "B"])
    }

    private func match(
        date: String,
        home: String,
        away: String,
        round: Int?,
        status: String? = nil
    ) -> Match {
        Match(
            date: date,
            time: "15:00",
            homeTeam: home,
            awayTeam: away,
            league: "Test League",
            leagueId: "test-league",
            seasonID: 1,
            roundNumber: round,
            tvChannels: [],
            homeScore: status == "FT" ? 1 : nil,
            awayScore: status == "FT" ? 0 : nil,
            scoreStatus: status
        )
    }
}
