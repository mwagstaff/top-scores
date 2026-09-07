import Foundation
import Testing
@testable import Top_Scores

struct MatchStadiumArtworkResolverTests {
    @Test func sameHomeTeamKeepsArtworkAcrossOpponentsAndLighting() {
        let resolver = MatchStadiumArtworkResolver()
        let first = makeMatch(homeTeamID: "57", awayTeam: "Arsenal", lightContext: "day")
        let second = makeMatch(homeTeamID: "different-provider-id", awayTeam: "Leeds United", lightContext: "night")
        #expect(resolver.assetName(for: first) == resolver.assetName(for: second))
    }

    @Test func bournemouthUsesAllBundledImagesRegardlessOfLighting() {
        let resolver = MatchStadiumArtworkResolver()
        let match = makeMatch(homeTeam: "AFC Bournemouth", lightContext: "day")
        let assets = Set((0..<10).map { resolver.assetName(for: match, selectionSeed: UInt32($0)) })
        #expect(assets.count == 10)
        #expect(assets.contains("BournemouthStadiumNight04"))
        #expect(assets.contains("BournemouthStadiumDay06"))
    }

    @Test func awayClubNeverOverridesHomeClubArtwork() {
        let resolver = MatchStadiumArtworkResolver()
        let match = makeMatch(awayTeam: "Bournemouth")
        #expect(!resolver.assetName(for: match).contains("Bournemouth"))
    }

    @Test func teamHeroArtworkIsStableAcrossProviderIDs() {
        let resolver = MatchStadiumArtworkResolver()
        #expect(resolver.teamHeroAssetName(teamID: "57", teamName: "Watford")
            == resolver.teamHeroAssetName(teamID: "other", teamName: "Watford"))
    }

    @Test func remoteMatchArtworkPrefersHomeTeamOverVenue() {
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

        #expect(resolver.remoteAsset(for: match, catalog: catalog)?.id == "watford-day")
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

    @Test func remoteTeamGalleryIncludesEveryLightingContext() {
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
                makeAsset(id: "watford-any", role: .team, light: .any, teamIDs: ["watford"]),
            ]
        )

        #expect(
            resolver.remoteTeamHeroAssets(
                teamID: "57",
                teamName: "Watford",
                catalog: catalog
            ).map(\.id) == ["watford-any", "watford-day", "watford-night"]
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
