import Testing
@testable import Top_Scores

struct MatchStadiumArtworkResolverTests {
    @Test func sameHomeTeamKeepsFamilyAcrossOpponents() {
        let resolver = MatchStadiumArtworkResolver()
        let first = makeMatch(homeTeamID: "57", awayTeam: "Arsenal", lightContext: "day")
        let second = makeMatch(homeTeamID: "different-provider-id", awayTeam: "Leeds United", lightContext: "night")

        #expect(resolver.familyIndex(homeTeamID: first.homeTeamId, homeTeamName: first.homeTeam)
            == resolver.familyIndex(homeTeamID: second.homeTeamId, homeTeamName: second.homeTeam))
        #expect(resolver.assetName(for: first).hasSuffix("Day"))
        #expect(resolver.assetName(for: second).hasSuffix("Night"))
    }

    @Test func apiLightContextTakesPrecedenceOverKickoffHour() {
        let resolver = MatchStadiumArtworkResolver()
        let lateDaylightMatch = makeMatch(homeTeamID: "57", time: "22:00", lightContext: "day")

        #expect(resolver.lightContext(for: lateDaylightMatch) == .day)
    }

    @Test func kickoffHourProvidesSafeFallbackWithoutVenueData() {
        let resolver = MatchStadiumArtworkResolver()

        #expect(resolver.lightContext(for: makeMatch(time: "15:00")) == .day)
        #expect(resolver.lightContext(for: makeMatch(time: "20:00")) == .night)
    }

    private func makeMatch(
        homeTeamID: String? = nil,
        awayTeam: String = "Arsenal",
        time: String = "15:00",
        lightContext: String? = nil
    ) -> Match {
        Match(
            date: "2026-08-16",
            time: time,
            homeTeam: "Watford",
            awayTeam: awayTeam,
            homeTeamId: homeTeamID,
            lightContext: lightContext,
            league: "Championship",
            tvChannels: []
        )
    }
}
