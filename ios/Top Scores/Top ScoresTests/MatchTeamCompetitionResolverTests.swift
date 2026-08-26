import Testing
@testable import Top_Scores

struct MatchTeamCompetitionResolverTests {
    @Test func cupTieResolvesEachTeamsOwnDivisionAndPosition() {
        let entries = MatchTeamCompetitionResolver.resolve(
            match: makeMatch(
                homeTeam: "Watford",
                awayTeam: "Peterborough United",
                league: "EFL Cup"
            ),
            leagues: [
                makeTable(id: "40", name: "EFL Cup", rows: []),
                makeTable(id: "12", name: "Championship", rows: [makeRow(team: "Watford", position: 7)]),
                makeTable(id: "86", name: "League One", rows: [makeRow(team: "Peterborough United", position: 13)]),
            ],
            competitions: [
                makeCompetition(id: "english-league-cup", name: "EFL Cup", weight: 60, region: "england"),
                makeCompetition(id: "championship", name: "Championship", weight: 40, region: "england"),
                makeCompetition(id: "league-one", name: "EFL League One", aliases: ["League One"], weight: 14, region: "england"),
            ]
        )

        #expect(entries.count == 2)
        #expect(entries[0].side == .home)
        #expect(entries[0].leagueID == "12")
        #expect(entries[0].competitionID == "championship")
        #expect(entries[0].competitionName == "Championship")
        #expect(entries[0].position == 7)
        #expect(entries[1].side == .away)
        #expect(entries[1].leagueID == "86")
        #expect(entries[1].competitionID == "league-one")
        #expect(entries[1].competitionName == "EFL League One")
        #expect(entries[1].position == 13)
    }

    @Test func continentalTiePrefersEachClubsDomesticTable() {
        let entries = MatchTeamCompetitionResolver.resolve(
            match: makeMatch(homeTeam: "Liverpool", awayTeam: "Real Madrid", league: "UEFA Champions League"),
            leagues: [
                makeTable(
                    id: "7",
                    name: "UEFA Champions League",
                    rows: [makeRow(team: "Liverpool", position: 4), makeRow(team: "Real Madrid", position: 5)]
                ),
                makeTable(id: "1", name: "Premier League", rows: [makeRow(team: "Liverpool", position: 2)]),
                makeTable(id: "2", name: "La Liga", rows: [makeRow(team: "Real Madrid", position: 1)]),
            ],
            competitions: [
                makeCompetition(id: "uefa-champions-league", name: "UEFA Champions League", weight: 90, region: "europe"),
                makeCompetition(id: "premier-league", name: "Premier League", weight: 100, region: "england"),
                makeCompetition(id: "la-liga", name: "La Liga", weight: 50, region: "spain"),
            ]
        )

        #expect(entries.map(\.competitionID) == ["premier-league", "la-liga"])
        #expect(entries.map(\.leagueID) == ["1", "2"])
    }

    private func makeMatch(homeTeam: String, awayTeam: String, league: String) -> Match {
        Match(
            date: "2026-08-25",
            time: "19:45",
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            league: league,
            tvChannels: []
        )
    }

    private func makeCompetition(
        id: String,
        name: String,
        aliases: [String] = [],
        weight: Double,
        region: String
    ) -> CompetitionCatalogEntry {
        CompetitionCatalogEntry(
            id: id,
            name: name,
            aliases: aliases,
            weight: weight,
            region: region,
            logoURL: nil
        )
    }

    private func makeTable(id: String, name: String, rows: [LeagueTableRow]) -> LeagueTable {
        LeagueTable(
            leagueID: id,
            leagueName: name,
            stageName: nil,
            sourceURL: nil,
            updatedAt: nil,
            rows: rows
        )
    }

    private func makeRow(team: String, position: Int) -> LeagueTableRow {
        LeagueTableRow(
            position: position,
            team: team,
            played: 2,
            won: 1,
            drawn: 0,
            lost: 1,
            goalsFor: 2,
            goalsAgainst: 2,
            goalDifference: 0,
            points: 3,
            form: [],
            rankStatus: nil
        )
    }
}
