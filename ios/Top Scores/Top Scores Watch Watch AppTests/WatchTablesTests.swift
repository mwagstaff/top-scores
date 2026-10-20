import Foundation
import SwiftUI
import Testing
@testable import Top_Scores_Watch_Watch_App

struct WatchTablesTests {
    @Test func decodesLiveRowsAndGroupTablesWithoutDuplicatingFlattenedRows() throws {
        let data = Data(#"""
        {"leagues":[
          {"league_id":"1","league_name":"Premier League","rows":[
            {"position":1,"team":"Arsenal","points":24,"live":true},
            {"position":2,"team":"Chelsea","points":20}]},
          {"league_id":"27","league_name":"World Cup",
           "groups":[{"name":"Group A","rows":[{"position":1,"team":"Mexico","points":6}]}],
           "rows":[{"position":1,"team":"Mexico","points":6}]}
        ]}
        """#.utf8)
        let payload = try JSONDecoder().decode(WatchTablesPayload.self, from: data)
        #expect(payload.leagues[0].sections[0].rows[0].live == true)
        #expect(payload.leagues[0].sections[0].rows[1].live != true)
        #expect(payload.leagues[1].sections.count == 1)
        #expect(payload.leagues[1].sections[0].name == "Group A")
        #expect(payload.leagues[1].sections[0].rows.count == 1)
    }

    @Test func ordersByFixturePriorityThenNameAndOmitsEmptyTables() {
        let row = WatchLeagueTable.Row(position: 1, team: "Team", points: 3, live: false)
        func league(_ id: String, _ name: String, empty: Bool = false) -> WatchLeagueTable {
            WatchLeagueTable(leagueID: id, leagueName: name, groups: nil, rows: empty ? [] : [row])
        }
        let catalog = WatchTableCompetitionCatalog(competitions: [
            .init(id: "1", name: "Premier League", aliases: nil, weight: 100),
            .init(id: "2", name: "Championship", aliases: ["English Championship"], weight: 90)
        ])
        let sorted = catalog.sorted([
            league("x", "Zulu"), league("y", "Alpha"),
            league("alias", "English Championship"), league("1", "English Premier League"),
            league("empty", "Empty", empty: true)
        ])
        #expect(sorted.map(\.id) == ["1", "alias", "y", "x"])
    }

    @Test func fplColoursMatchPhoneThresholdsIncludingNegativeAndCaptainScores() {
        let red = Color(red: 0.92, green: 0.23, blue: 0.20)
        let amber = Color(red: 0.95, green: 0.62, blue: 0.16)
        let green = Color(red: 0.24, green: 0.76, blue: 0.30)
        for points in [-2, 0, 2] { #expect(WatchFantasyScoreStyle.color(points: points) == red) }
        for points in [3, 5] { #expect(WatchFantasyScoreStyle.color(points: points) == amber) }
        for points in [6, 39] { #expect(WatchFantasyScoreStyle.color(points: points) == green) }
    }
    @Test func teamMatchSelectionPrefersLiveThenLatestCompletedMatch() throws {
        let data = Data(#"""
        [
          {"date":"2026-10-17","time":"20:00","home_team":"Arsenal","away_team":"Chelsea","league":"Premier League","score_status":null},
          {"date":"2026-10-17","time":"18:00","home_team":"Arsenal","away_team":"Chelsea","league":"Premier League","score_status":"Postponed"},
          {"date":"2026-10-16","time":"15:00","home_team":"Chelsea","away_team":"Arsenal","league":"FA Cup","score_status":"FT"},
          {"date":"2026-10-17","time":"12:00","home_team":"Arsenal","away_team":"Liverpool","league":"Premier League","score_status":"HT"},
          {"date":"2026-10-15","time":"15:00","home_team":"Arsenal","away_team":"Everton","league":"Premier League","score_status":"FT"}
        ]
        """#.utf8)
        let matches = try JSONDecoder().decode([WatchMatch].self, from: data)
        #expect(WatchTableMatchSelection.currentOrLatest(in: matches)?.awayTeam == "Liverpool")
        let completed = WatchTableMatchSelection.currentOrLatest(in: matches.filter { !$0.isInProgress })
        #expect(completed?.league == "FA Cup")
        #expect(completed?.awayTeam == "Arsenal")
        #expect(WatchTableMatchSelection.currentOrLatest(in: Array(matches.prefix(2))) == nil)
        #expect(WatchTableMatchSelection.currentOrLatest(in: []) == nil)
    }

}
