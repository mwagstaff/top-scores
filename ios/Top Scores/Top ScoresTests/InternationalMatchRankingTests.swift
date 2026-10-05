import Foundation
import Testing
@testable import Top_Scores

struct InternationalMatchRankingTests {
    @MainActor @Test func arrivingRatingsReplacePinnedFallbackOrderForLiveFixtures() async throws {
        let store = MatchesStore()
        let preferences = PreferencesSnapshot(
            selectedLeagues: [], selectedChannels: [], englishPremierLeagueTeamsOnly: false,
            apiBaseURL: "https://international-rankings.test/api/v1", refreshIntervalMinutes: 1,
            matchGroupSortOrder: .kickoffThenTeamScore, premierLeagueMatchesFirst: false
        )
        let date = "2026-10-03"
        let matches = [
            Match(date: date, time: "17:00", homeTeam: "Belarus", awayTeam: "San Marino",
                  league: "UEFA Nations League", tvChannels: [], scoreStatus: "1H"),
            Match(date: date, time: "17:00", homeTeam: "Croatia", awayTeam: "England",
                  league: "UEFA Nations League", tvChannels: [], scoreStatus: "1H")
        ]
        for match in matches { #expect(match.isInProgress) }
        let pages = [date: matches]
        let initial = try #require(await store.groupFixtureBrowsePages(
            filteredMatchesByDate: pages, unfilteredMatchesByDate: pages, preferences: preferences
        ))
        #expect(initial.filtered[date]?.first?.leagues.first?.matches.map(\.homeTeam) == ["Belarus", "Croatia"])

        let entries = [
            TeamRankingEntry(name: "England", points: 2114, aliases: []),
            TeamRankingEntry(name: "Croatia", points: 1891, aliases: []),
            TeamRankingEntry(name: "Belarus", points: 1514, aliases: []),
            TeamRankingEntry(name: "San Marino", points: 821, aliases: [])
        ]
        let revision = store.fixturesViewState.teamRatingsRevision
        await store.applyTeamRatingSnapshot(entries: entries, defaultElo: 1000)
        #expect(store.fixturesViewState.teamRatingsRevision == revision + 1)
        let refreshed = try #require(await store.groupFixtureBrowsePages(
            filteredMatchesByDate: pages, unfilteredMatchesByDate: pages, preferences: preferences
        ))
        #expect(refreshed.filtered[date]?.first?.leagues.first?.matches.map(\.homeTeam) == ["Croatia", "Belarus"])
        #expect(refreshed.unfiltered == refreshed.filtered)

        await store.applyTeamRatingSnapshot(entries: entries, defaultElo: 1000)
        #expect(store.fixturesViewState.teamRatingsRevision == revision + 1)
        let stable = try #require(await store.groupFixtureBrowsePages(
            filteredMatchesByDate: [date: Array(matches.reversed())],
            unfilteredMatchesByDate: [date: Array(matches.reversed())], preferences: preferences
        ))
        #expect(stable.filtered == refreshed.filtered)
    }

    @MainActor @Test func rankingsIncludeNationalTeamsAndSortSameKickoffByStrength() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InternationalRankingsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = APIClient(
            baseURL: URL(string: "https://international-rankings.test/api/v1")!,
            session: session
        )
        let entries = try await client.fetchTeamRankings()
        #expect(entries.count == 5)
        let lookup = TeamRatingLookup(entries: entries, defaultPoints: 1000)
        #expect(lookup.resolvedRating(for: "England") == 2114)
        #expect(lookup.resolvedRating(for: "San Marino") == 821)

        let matches = [
            Match(date: "2026-10-03", time: "17:00", homeTeam: "Belarus",
                  awayTeam: "San Marino", league: "UEFA Nations League", tvChannels: []),
            Match(date: "2026-10-03", time: "17:00", homeTeam: "Croatia",
                  awayTeam: "England", league: "UEFA Nations League", tvChannels: []),
            Match(date: "2026-10-03", time: "14:00", homeTeam: "Finland",
                  awayTeam: "Albania", league: "UEFA Nations League", tvChannels: [])
        ]
        let kickoffOrder = MatchGroupingEngine.groupMatches(
            matches, sortOrder: .kickoffThenTeamScore, ratingLookup: lookup
        )
        #expect(kickoffOrder.first?.leagues.first?.matches.map(\.homeTeam) ==
                ["Finland", "Croatia", "Belarus"])
        let scoreOrder = MatchGroupingEngine.groupMatches(
            Array(matches.prefix(2)), sortOrder: .teamScore, ratingLookup: lookup
        )
        #expect(scoreOrder.first?.leagues.first?.matches.map(\.homeTeam) == ["Croatia", "Belarus"])

        // Explicit club-only callers can still filter their requests.
        let clubEntries = try await client.fetchTeamRankings(type: "club")
        #expect(clubEntries.map(\.name) == ["Arsenal"])
    }
}

private final class InternationalRankingsURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let type = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "type" })?.value
        let club = #"{"Name":"Arsenal","Points":2056,"Type":"club"}"#
        let national = #"""
        {"Name":"England","Points":2114,"Type":"national"},
        {"Name":"Croatia","Points":1891,"Type":"national"},
        {"Name":"Belarus","Points":1514,"Type":"national"},
        {"Name":"San Marino","Points":821,"Type":"national"}
        """#
        let body = type == "club" ? "[\(club)]" : "[\(club),\(national)]"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
