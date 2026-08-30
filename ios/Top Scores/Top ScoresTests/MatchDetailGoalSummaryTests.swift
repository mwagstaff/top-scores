import Testing
@testable import Top_Scores

struct MatchDetailGoalSummaryTests {
    @Test func matchEventsDefaultToNewestFirstAndCanToggleOrder() {
        var order = MatchEventSortOrder.defaultOrder

        #expect(order == .newestFirst)
        #expect(order.sorts(90, before: 12))

        order.toggle()

        #expect(order == .oldestFirst)
        #expect(order.sorts(12, before: 90))
    }

    @Test func ownGoalIsCreditedToOpposingTeam() {
        let match = Match(
            date: "2026-08-30",
            time: "14:00",
            homeTeam: "Chelsea",
            awayTeam: "Brighton & Hove Albion",
            league: "Premier League",
            tvChannels: [],
            homeScore: 4,
            awayScore: 3,
            scoreStatus: "FT",
            homeGoalScorers: [
                MatchGoalScorer(
                    player: "Joao Pedro",
                    goalTimes: ["32'"],
                    ownGoalTimes: ["63'"]
                )
            ],
            awayGoalScorers: [
                MatchGoalScorer(player: "Yalcouye", goalTimes: ["35'"])
            ]
        )

        let homeCredits = match.goalCredits(for: .home)
        let awayCredits = match.goalCredits(for: .away)

        #expect(homeCredits.scorers.map(\.player) == ["Joao Pedro"])
        #expect(homeCredits.ownGoalScorers.flatMap(\.ownGoalTimes).isEmpty)
        #expect(awayCredits.scorers.map(\.player) == ["Yalcouye"])
        #expect(awayCredits.ownGoalScorers.map(\.player) == ["Joao Pedro"])
        #expect(awayCredits.ownGoalScorers.flatMap(\.ownGoalTimes) == ["63'"])
    }
}
