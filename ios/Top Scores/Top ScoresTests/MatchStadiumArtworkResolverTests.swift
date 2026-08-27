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

    @Test func remoteArtworkPrefersExactVenueThenHomeTeam() {
        let resolver = MatchStadiumArtworkResolver()
        let catalog = makeCatalog(
            teams: [
                "watford": StadiumArtworkTeam(
                    name: "Watford",
                    aliases: [],
                    sourceTeamIDs: ["57"],
                    venueIDs: []
                ),
                "shared-ground": StadiumArtworkTeam(
                    name: "Shared Ground Club",
                    aliases: [],
                    sourceTeamIDs: [],
                    venueIDs: ["42"]
                ),
            ],
            assets: [
                makeAsset(id: "watford-day", role: .team, light: .day, teamIDs: ["watford"]),
                makeAsset(id: "venue-day", role: .team, light: .day, teamIDs: ["shared-ground"]),
            ]
        )
        let match = makeMatch(homeTeamID: "57", lightContext: "day", venueID: "42")

        #expect(resolver.remoteAsset(for: match, catalog: catalog)?.id == "venue-day")
    }

    @Test func remoteMatchArtworkUsesHomeTeamOnlyThenGenericFallback() {
        let resolver = MatchStadiumArtworkResolver()
        let catalog = makeCatalog(
            teams: [
                "afc-bournemouth": StadiumArtworkTeam(
                    name: "AFC Bournemouth",
                    aliases: ["Bournemouth"],
                    sourceTeamIDs: ["1044"],
                    venueIDs: []
                )
            ],
            assets: [
                makeAsset(id: "bournemouth-night", role: .team, light: .night, teamIDs: ["afc-bournemouth"]),
                makeAsset(id: "generic-night", role: .genericMatch, light: .night),
            ]
        )
        let match = makeMatch(homeTeam: "Watford", awayTeam: "AFC Bournemouth", lightContext: "night")

        #expect(resolver.remoteAsset(for: match, catalog: catalog)?.id == "generic-night")
    }

    @Test func remoteTeamHeroPrefersNightArtwork() {
        let resolver = MatchStadiumArtworkResolver()
        let catalog = makeCatalog(
            teams: [
                "watford": StadiumArtworkTeam(
                    name: "Watford",
                    aliases: [],
                    sourceTeamIDs: ["57"],
                    venueIDs: []
                )
            ],
            assets: [
                makeAsset(id: "watford-day", role: .team, light: .day, teamIDs: ["watford"]),
                makeAsset(id: "watford-night", role: .team, light: .night, teamIDs: ["watford"]),
            ]
        )

        #expect(
            resolver.remoteTeamHeroAsset(
                teamID: "57",
                teamName: "Watford",
                catalog: catalog
            )?.id == "watford-night"
        )
    }

    private func makeMatch(
        homeTeamID: String? = nil,
        homeTeam: String = "Watford",
        awayTeam: String = "Arsenal",
        time: String = "15:00",
        lightContext: String? = nil,
        venueID: String? = nil
    ) -> Match {
        Match(
            date: "2026-08-16",
            time: time,
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            homeTeamId: homeTeamID,
            venueID: venueID,
            lightContext: lightContext,
            league: "Championship",
            tvChannels: []
        )
    }

    private func makeCatalog(
        teams: [String: StadiumArtworkTeam],
        assets: [StadiumArtworkAsset]
    ) -> StadiumArtworkCatalog {
        StadiumArtworkCatalog(
            schemaVersion: 1,
            catalogVersion: String(repeating: "a", count: 64),
            generatedAt: "2026-08-27T00:00:00Z",
            teams: teams,
            assets: assets
        )
    }

    private func makeAsset(
        id: String,
        role: StadiumArtworkRole,
        light: StadiumArtworkLightContext,
        teamIDs: [String] = []
    ) -> StadiumArtworkAsset {
        let hash = String(repeating: "b", count: 64)
        return StadiumArtworkAsset(
            id: id,
            role: role,
            lightContext: light,
            teamIDs: teamIDs,
            stadium: nil,
            sha256: hash,
            assetPath: "assets/\(hash).webp",
            assetURL: "/api/v1/stadium-artwork/assets/\(hash).webp",
            contentType: "image/webp",
            byteSize: 100,
            width: 640,
            height: 360,
            credit: StadiumArtworkCredit(
                author: "Top Scores",
                authorURL: nil,
                source: "Top Scores",
                sourcePage: nil,
                license: "Top Scores artwork",
                licenseURL: nil,
                attribution: "Top Scores artwork"
            )
        )
    }
}
