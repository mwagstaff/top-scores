import Foundation
import Testing
@testable import Top_Scores_Watch_Watch_App

@MainActor
struct WatchLiveActivityLinkTests {
    @Test func opensMatchWithSummaryWithoutPhoneData() throws {
        let url = try #require(URL(string: "topscores://match?id=8324&date=2026-10-17&time=15%3A00&league=Premier%20League&home=Brighton%20%26%20Hove&away=Man%20City&homeScore=2&awayScore=1&status=67"))
        let match = try #require(WatchLiveActivityLink.match(from: url))
        #expect(match.matchDetailsIDValue == "8324")
        #expect(match.homeTeam == "Brighton & Hove")
        #expect(match.awayTeam == "Man City")
        #expect(match.homeScore == 2)
        #expect(match.awayScore == 1)
        #expect(match.scoreStatus == "67")
        #expect(match.date == "2026-10-17")
        #expect(match.time == "15:00")
    }

    @Test func upcomingMatchDoesNotInventScores() throws {
        let url = try #require(URL(string: "topscores://match?id=8324&date=2026-10-17&time=15%3A00&league=Premier&home=Home&away=Away"))
        let match = try #require(WatchLiveActivityLink.match(from: url))
        #expect(match.homeScore == nil)
        #expect(match.awayScore == nil)
        #expect(match.scoreStatus == nil)
    }

    @Test func competitionIncludesSelectedMatchBeforePhoneSync() throws {
        let selected = try match(id: "8324", league: "Premier League", date: "2026-10-17")
        let competition = WatchLiveActivityLink.competition(for: selected, matches: [])
        #expect(competition.name == "Premier League")
        #expect(competition.matches.map(\.matchDetailsIDValue) == ["8324"])
    }

    @Test func competitionKeepsSameDayPeersAndUsesSyncedSelectedMatch() throws {
        let selected = try match(id: "8324", league: "Premier League", date: "2026-10-17")
        let peer = try match(id: "8325", league: "Premier League", date: "2026-10-17")
        let otherLeague = try match(id: "8326", league: "La Liga", date: "2026-10-17")
        let tomorrow = try match(id: "8327", league: "Premier League", date: "2026-10-18")
        let competition = WatchLiveActivityLink.competition(
            for: selected, matches: [selected, peer, otherLeague, tomorrow]
        )
        #expect(Set(competition.matches.compactMap(\.matchDetailsIDValue)) == ["8324", "8325"])
        #expect(competition.matches.count == 2)
    }

    private func match(id: String, league: String, date: String) throws -> WatchMatch {
        var url = URLComponents()
        url.scheme = "topscores"
        url.host = "match"
        url.queryItems = [
            URLQueryItem(name: "id", value: id), URLQueryItem(name: "date", value: date),
            URLQueryItem(name: "time", value: "15:00"), URLQueryItem(name: "league", value: league),
            URLQueryItem(name: "home", value: "Home " + id), URLQueryItem(name: "away", value: "Away")
        ]
        let link = try #require(url.url)
        return try #require(WatchLiveActivityLink.match(from: link))
    }

    @Test(arguments: [
        "https://match?id=8324", "topscores://other?id=8324",
        "topscores://match", "topscores://match?id=&date=2026-10-17&time=15:00&league=Premier&home=Home&away=Away"
    ]) func ignoresUnrelatedOrIncompleteLinks(_ link: String) throws {
        #expect(WatchLiveActivityLink.match(from: try #require(URL(string: link))) == nil)
    }
}
