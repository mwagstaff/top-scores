import Foundation
import Testing
@testable import Top_Scores

struct TeamDetailsTests {
    @Test func teamResultsQueryTargetsOneTeamAndBypassesPreferenceFilters() {
        let queryItems = APIClient.teamResultsQueryItems(
            teamName: "Sevilla",
            limit: 20,
            now: Date(timeIntervalSince1970: 1_786_752_000)
        )
        let values = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(values["team"] == "Sevilla")
        #expect(values["mode"] == "results")
        #expect(values["sort"] == "desc")
        #expect(values["filter_mode"] == "intersection")
        #expect(values["page"] == "1")
        #expect(values["page_size"] == "20")
        #expect(values["league"] == nil)
        #expect(values["channel"] == nil)
        #expect(values["view_option"] == nil)
    }

    @Test func standingResolverFallsBackToLeagueNameAcrossIDNamespaces() throws {
        let context = TeamDetailsContext(
            teamID: "282",
            teamName: "Sevilla",
            displayName: "Sevilla",
            alternateNames: [],
            originatingLeagueID: "4335",
            originatingLeagueName: "La Liga",
            originatingMatch: nil
        )
        let cupRow = makeRow(position: 2, team: "Sevilla", played: 6)
        let leagueRow = makeRow(position: 8, team: "Sevilla", played: 20)
        let response = LeagueTablesResponse(
            leagues: [
                makeTable(id: "999", name: "European Cup", rows: [cupRow]),
                makeTable(id: "3", name: "La Liga", rows: [leagueRow]),
            ],
            lastUpdated: nil
        )

        let standing = try #require(
            TeamDetailsStandingResolver.resolve(context: context, response: response)
        )

        #expect(standing.leagueID == "3")
        #expect(standing.leagueName == "La Liga")
        #expect(standing.row.played == 20)
        #expect(standing.row.position == 8)
    }

    @Test @MainActor func matchDecodesLeagueIdentityForTeamNavigation() throws {
        let data = Data("""
        {
          "date": "2026-08-15",
          "time": "20:30",
          "home_team": "Sevilla",
          "away_team": "Rayo Vallecano",
          "home_team_id": "282",
          "away_team_id": "726",
          "league": "La Liga",
          "league_id": "564",
          "tv_channels": []
        }
        """.utf8)

        let match = try JSONDecoder().decode(Match.self, from: data)

        #expect(match.leagueId == "564")
        #expect(match.homeTeamId == "282")
        #expect(match.awayTeamId == "726")
    }

    @Test func finishedOriginatingMatchOverridesStaleResultsAndAppearsFirst() {
        let current = makeMatch(id: "currentmatch", date: "2026-08-15", homeScore: 3, awayScore: 0)
        let context = TeamDetailsContext(
            teamID: "282",
            teamName: "Sevilla",
            displayName: "Sevilla",
            alternateNames: [],
            originatingLeagueID: "564",
            originatingLeagueName: "La Liga",
            originatingMatch: current
        )
        let staleCurrent = makeMatch(id: "currentmatch", date: "2026-08-15", homeScore: 1, awayScore: 0)
        let previous = makeMatch(id: "previousmatch", date: "2026-08-08")

        let matches = TeamDetailsMatchResolver.previousMatches(
            context: context,
            from: [staleCurrent, previous],
            now: makeDate(year: 2026, month: 8, day: 16)
        )

        #expect(matches.map(\.matchDetailsID) == ["currentmatch", "previousmatch"])
        #expect(matches.first?.homeScore == 3)
        #expect(matches.first?.awayScore == 0)
    }

    @Test func formUsesLatestFinishedMatchInsteadOfStaleStandingForm() throws {
        let current = makeMatch(id: "currentmatch", date: "2026-08-15", homeScore: 3, awayScore: 0)
        let context = TeamDetailsContext(
            teamID: "282",
            teamName: "Sevilla",
            displayName: "Sevilla",
            alternateNames: [],
            originatingLeagueID: "564",
            originatingLeagueName: "La Liga",
            originatingMatch: current
        )
        let standing = TeamSeasonStanding(
            leagueID: "3",
            leagueName: "La Liga",
            groupName: nil,
            realtime: false,
            row: makeRow(position: 1, team: "Sevilla", played: 1)
        )
        let now = makeDate(year: 2026, month: 8, day: 16)
        let matches = TeamDetailsMatchResolver.previousMatches(context: context, from: [], now: now)

        let form = TeamDetailsFormResolver.recentForm(
            context: context,
            standing: standing,
            matches: matches,
            now: now
        )

        #expect(form == ["W"])
    }

    @Test func unfinishedOriginatingMatchDoesNotAppearInPreviousMatches() {
        let current = makeMatch(
            id: "currentmatch",
            date: "2099-08-16",
            homeScore: nil,
            awayScore: nil,
            scoreStatus: nil
        )
        let context = TeamDetailsContext(
            teamID: "282",
            teamName: "Sevilla",
            displayName: "Sevilla",
            alternateNames: [],
            originatingLeagueID: "564",
            originatingLeagueName: "La Liga",
            originatingMatch: current
        )
        let staleFinishedVersion = makeMatch(id: "currentmatch", date: "2099-08-16")
        let previous = makeMatch(id: "previousmatch", date: "2099-08-08")

        let matches = TeamDetailsMatchResolver.previousMatches(
            context: context,
            from: [staleFinishedVersion, previous],
            now: makeDate(year: 2099, month: 8, day: 15)
        )

        #expect(matches.map(\.matchDetailsID) == ["previousmatch"])
    }

    @Test func postponedMatchesAreExcludedFromPreviousMatches() {
        let context = TeamDetailsContext(
            teamID: nil,
            teamName: "Watford",
            displayName: "Watford",
            alternateNames: [],
            originatingLeagueID: "4329",
            originatingLeagueName: "Championship",
            originatingMatch: nil
        )
        let postponed = makeMatch(
            id: "postponed",
            date: "2026-03-07",
            homeTeam: "Watford",
            awayTeam: "Wrexham",
            league: "Championship",
            leagueID: "4329",
            homeScore: nil,
            awayScore: nil,
            scoreStatus: "POSTPONED"
        )
        let completed = makeMatch(
            id: "completed",
            date: "2026-08-07",
            homeTeam: "Bristol City",
            awayTeam: "Watford",
            league: "FA Cup",
            leagueID: nil,
            homeScore: 5,
            awayScore: 1
        )

        let matches = TeamDetailsMatchResolver.previousMatches(
            context: context,
            from: [postponed, completed],
            now: makeDate(year: 2026, month: 8, day: 16)
        )

        #expect(matches.map(\.matchDetailsID) == ["completed"])
    }

    @Test func formAndPreviousMatchesUseOnlyTheCurrentSeason() {
        let context = TeamDetailsContext(
            teamID: nil,
            teamName: "Watford",
            displayName: "Watford",
            alternateNames: [],
            originatingLeagueID: "4329",
            originatingLeagueName: "Championship",
            originatingMatch: nil
        )
        let standing = TeamSeasonStanding(
            leagueID: "12",
            leagueName: "Championship",
            groupName: nil,
            realtime: false,
            row: makeRow(
                position: 14,
                team: "Watford",
                played: 0,
                form: ["L", "L", "L", "L", "L"]
            )
        )
        let cupWin = makeMatch(
            id: "cupwin",
            date: "2026-08-08",
            homeTeam: "Watford",
            awayTeam: "Crawley Town",
            league: "EFL Cup",
            leagueID: nil,
            homeScore: 1,
            awayScore: 0
        )
        let cupLoss = makeMatch(
            id: "cuploss",
            date: "2026-01-10",
            homeTeam: "Bristol City",
            awayTeam: "Watford",
            league: "FA Cup",
            leagueID: nil,
            homeScore: 5,
            awayScore: 1
        )
        let postponed = makeMatch(
            id: "postponed",
            date: "2026-03-07",
            homeTeam: "Watford",
            awayTeam: "Wrexham",
            league: "Championship",
            leagueID: "4329",
            homeScore: nil,
            awayScore: nil,
            scoreStatus: "POSTPONED"
        )
        let matches = TeamDetailsMatchResolver.previousMatches(
            context: context,
            from: [cupWin, postponed, cupLoss],
            now: makeDate(year: 2026, month: 8, day: 16)
        )

        #expect(matches.map(\.matchDetailsID) == ["cupwin"])

        let form = TeamDetailsFormResolver.recentForm(
            context: context,
            standing: standing,
            matches: matches,
            now: makeDate(year: 2026, month: 8, day: 16)
        )

        #expect(form == ["W"])
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

    private func makeRow(
        position: Int,
        team: String,
        played: Int,
        form: [String] = ["W", "D", "W", "L", "W"]
    ) -> LeagueTableRow {
        LeagueTableRow(
            position: position,
            team: team,
            played: played,
            won: 10,
            drawn: 5,
            lost: 5,
            goalsFor: 32,
            goalsAgainst: 20,
            goalDifference: 12,
            points: 35,
            form: form,
            rankStatus: nil
        )
    }

    private func makeMatch(
        id: String,
        date: String,
        homeTeam: String = "Sevilla",
        awayTeam: String = "Opponent",
        league: String = "La Liga",
        leagueID: String? = "564",
        homeScore: Int? = 1,
        awayScore: Int? = 0,
        scoreStatus: String? = "FT"
    ) -> Match {
        Match(
            date: date,
            time: "20:00",
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            league: league,
            leagueId: leagueID,
            matchDetailsID: id,
            tvChannels: [],
            homeScore: homeScore,
            awayScore: awayScore,
            scoreStatus: scoreStatus
        )
    }

    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
