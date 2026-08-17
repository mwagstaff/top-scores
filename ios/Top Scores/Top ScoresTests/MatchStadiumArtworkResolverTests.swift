import Foundation
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

    @Test func bournemouthDayMatchSelectsFromAllSixDayAssets() {
        let resolver = MatchStadiumArtworkResolver()
        let match = makeMatch(homeTeam: "AFC Bournemouth", lightContext: "day")

        let assets = Set((0 ..< 6).map { seed in
            resolver.assetName(for: match, selectionSeed: UInt32(seed))
        })

        #expect(assets == Set((1 ... 6).map { String(format: "BournemouthStadiumDay%02d", $0) }))
    }

    @Test func bournemouthAwayMatchSelectsFromNightAssets() {
        let resolver = MatchStadiumArtworkResolver()
        let match = makeMatch(awayTeam: "Bournemouth", lightContext: "night")

        #expect(resolver.assetName(for: match, selectionSeed: 3) == "BournemouthStadiumNight04")
        #expect(resolver.assetName(for: match, selectionSeed: 4) == "BournemouthStadiumNight01")
    }

    @Test func teamHeroArtworkIsStableAndAlwaysUsesEveningArtwork() {
        let resolver = MatchStadiumArtworkResolver()

        let first = resolver.teamHeroAssetName(teamID: "57", teamName: "Watford")
        let second = resolver.teamHeroAssetName(teamID: "different-provider-id", teamName: "Watford")

        #expect(first == second)
        #expect(first.hasSuffix("Night"))
    }

    @Test func bournemouthTeamHeroUsesDedicatedNightArtwork() {
        let asset = MatchStadiumArtworkResolver().teamHeroAssetName(
            teamID: "1044",
            teamName: "AFC Bournemouth"
        )

        #expect(asset.hasPrefix("BournemouthStadiumNight"))
    }

    private func makeMatch(
        homeTeamID: String? = nil,
        homeTeam: String = "Watford",
        awayTeam: String = "Arsenal",
        time: String = "15:00",
        lightContext: String? = nil
    ) -> Match {
        Match(
            date: "2026-08-16",
            time: time,
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            homeTeamId: homeTeamID,
            lightContext: lightContext,
            league: "Championship",
            tvChannels: []
        )
    }
}
