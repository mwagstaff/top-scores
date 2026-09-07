import Foundation

struct MatchStadiumArtworkResolver: Sendable {
    static let shared = MatchStadiumArtworkResolver()

    private let genericFamilyCount = 3

    func remoteAssets(for match: Match, catalog: StadiumArtworkCatalog) -> [StadiumArtworkAsset] {
        let teamAssets = remoteTeamHeroAssets(
            teamID: match.homeTeamId, teamName: match.homeTeam, catalog: catalog
        )
        return teamAssets.isEmpty
            ? catalog.assets.filter { $0.role == .genericMatch }.sorted { $0.id < $1.id }
            : teamAssets
    }

    func remoteTeamHeroAssets(
        teamID: String?, teamName: String, catalog: StadiumArtworkCatalog
    ) -> [StadiumArtworkAsset] {
        guard let resolvedID = resolvedTeamID(
            teamID: teamID, teamName: teamName, venueID: nil, catalog: catalog
        ) else { return [] }
        return catalog.assets.filter {
            $0.role == .team && $0.teamIDs.contains(resolvedID)
        }.sorted { $0.id < $1.id }
    }

    func remoteAsset(
        for match: Match, catalog: StadiumArtworkCatalog, selectionSeed: UInt32? = nil
    ) -> StadiumArtworkAsset? {
        selectedAsset(remoteAssets(for: match, catalog: catalog),
                      seed: selectionSeed ?? stableHash(match.homeTeam))
    }

    func remoteTeamHeroAsset(
        teamID: String?, teamName: String, catalog: StadiumArtworkCatalog
    ) -> StadiumArtworkAsset? {
        selectedAsset(remoteTeamHeroAssets(teamID: teamID, teamName: teamName, catalog: catalog),
                      seed: stableHash(teamName.lowercased()))
    }

    func assetName(for match: Match, selectionSeed: UInt32? = nil) -> String {
        bundledAssetName(teamID: match.homeTeamId, teamName: match.homeTeam,
                         seed: selectionSeed ?? stableHash(match.homeTeam.lowercased()))
    }

    func teamHeroAssetName(teamID: String?, teamName: String) -> String {
        bundledAssetName(teamID: teamID, teamName: teamName, seed: stableHash(teamName.lowercased()))
    }

    private func bundledAssetName(teamID: String?, teamName: String, seed: UInt32) -> String {
        // Existing bundled filenames are retained; lighting never filters the pool.
        let names: [String]
        if teamName.lowercased().contains("bournemouth") {
            names = (1...6).map { String(format: "BournemouthStadiumDay%02d", $0) }
                + (1...4).map { String(format: "BournemouthStadiumNight%02d", $0) }
        } else {
            let family = familyIndex(homeTeamID: teamID, homeTeamName: teamName)
            names = [String(format: "MatchStadium%02dDay", family),
                     String(format: "MatchStadium%02dNight", family)]
        }
        return names[Int(seed % UInt32(names.count))]
    }

    func familyIndex(homeTeamID: String?, homeTeamName: String) -> Int {
        // The canonical team name is stable across BSD payload refreshes,
        // whereas provider-specific numeric IDs are not.
        let identity = homeTeamName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nonEmpty
            ?? homeTeamID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "unknown-home-team"
        return Int(stableHash(identity) % UInt32(genericFamilyCount)) + 1
    }

    private func resolvedTeamID(
        teamID: String?,
        teamName: String,
        venueID: String?,
        catalog: StadiumArtworkCatalog
    ) -> String? {
        if let venueID = venueID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !venueID.isEmpty,
           let venueMatch = catalog.teams
            .sorted(by: { $0.key < $1.key })
            .first(where: { $0.value.venueIDs.contains(venueID) }) {
            return venueMatch.key
        }

        if let teamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !teamID.isEmpty {
            if catalog.teams[teamID] != nil {
                return teamID
            }
            if let sourceMatch = catalog.teams
                .sorted(by: { $0.key < $1.key })
                .first(where: { $0.value.sourceTeamIDs.contains(teamID) }) {
                return sourceMatch.key
            }
        }

        let targetName = TeamIdentityStore.normalizedKey(teamName)
        guard !targetName.isEmpty else { return nil }
        return catalog.teams
            .sorted(by: { $0.key < $1.key })
            .first { entry in
                ([entry.value.name] + entry.value.aliases)
                    .contains { TeamIdentityStore.normalizedKey($0) == targetName }
            }?
            .key
    }

    private func selectedAsset(
        _ assets: [StadiumArtworkAsset],
        seed: UInt32
    ) -> StadiumArtworkAsset? {
        let sorted = assets.sorted { $0.id < $1.id }
        guard !sorted.isEmpty else { return nil }
        return sorted[Int(seed % UInt32(sorted.count))]
    }

    private func stableHash(_ value: String) -> UInt32 {
        value.utf8.reduce(UInt32(2_166_136_261)) { hash, byte in
            (hash ^ UInt32(byte)) &* 16_777_619
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
