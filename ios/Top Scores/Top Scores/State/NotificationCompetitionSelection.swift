import Foundation

nonisolated enum NotificationCompetitionSelection {
    static func optionID(
        for leagueName: String,
        catalog: [CompetitionCatalogEntry]
    ) -> String {
        let competition = catalog.first { entry in
            entry.allNames.contains {
                $0.localizedCaseInsensitiveCompare(leagueName) == .orderedSame
            }
        }
        return competition
            .map { FixtureViewOptionID.competition($0.stableID) }
            ?? FixtureViewOptionID.legacyCompetition(leagueName)
    }

    static func isSelected(
        leagueName: String,
        optionIDs: [String],
        catalog: [CompetitionCatalogEntry]
    ) -> Bool {
        optionIDs.contains(optionID(for: leagueName, catalog: catalog))
    }

    static func toggling(
        leagueName: String,
        optionIDs: [String],
        catalog: [CompetitionCatalogEntry]
    ) -> [String] {
        let targetID = optionID(for: leagueName, catalog: catalog)
        var updated = Set(optionIDs)
        if updated.contains(targetID) {
            updated.remove(targetID)
        } else {
            updated.insert(targetID)
        }
        return updated.sorted()
    }

    static func canonicalLeagueNames(
        optionIDs: [String],
        existingLeagueNames: [String],
        catalog: [CompetitionCatalogEntry]
    ) -> [String] {
        let selectedStableIDs = Set(optionIDs.compactMap(FixtureViewOptionID.competitionStableID))
        var resolvedStableIDs = Set<String>()
        var names: [String] = []

        for competition in catalog where selectedStableIDs.contains(competition.stableID) {
            resolvedStableIDs.insert(competition.stableID)
            names.append(competition.name)
        }

        for existingName in existingLeagueNames {
            let stableID = FixtureViewOptionID.competitionStableID(
                from: optionID(for: existingName, catalog: catalog)
            )
            guard
                let stableID,
                selectedStableIDs.contains(stableID),
                !resolvedStableIDs.contains(stableID)
            else {
                continue
            }
            resolvedStableIDs.insert(stableID)
            names.append(existingName)
        }

        return names.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    static func canonicalOptionIDs(
        optionIDs: [String],
        existingLeagueNames: [String],
        catalog: [CompetitionCatalogEntry]
    ) -> [String] {
        let selectedCompetitionIDs = Set(optionIDs.compactMap(FixtureViewOptionID.competitionStableID))
        var unresolvedCompetitionIDs = selectedCompetitionIDs
        var canonicalIDs = Set(optionIDs.filter { FixtureViewOptionID.competitionStableID(from: $0) == nil })

        for competition in catalog where selectedCompetitionIDs.contains(competition.stableID) {
            canonicalIDs.insert(FixtureViewOptionID.competition(competition.stableID))
            unresolvedCompetitionIDs.remove(competition.stableID)
        }

        for existingName in existingLeagueNames {
            guard let competition = catalog.first(where: { entry in
                entry.allNames.contains {
                    $0.localizedCaseInsensitiveCompare(existingName) == .orderedSame
                }
            }) else {
                continue
            }
            let legacyStableID = FixtureViewOptionID.competitionStableID(
                from: FixtureViewOptionID.legacyCompetition(existingName)
            )
            guard
                selectedCompetitionIDs.contains(competition.stableID) ||
                legacyStableID.map(selectedCompetitionIDs.contains) == true
            else {
                continue
            }
            canonicalIDs.insert(FixtureViewOptionID.competition(competition.stableID))
            unresolvedCompetitionIDs.remove(competition.stableID)
            if let legacyStableID {
                unresolvedCompetitionIDs.remove(legacyStableID)
            }
        }

        // A loaded catalog is authoritative. Dropping unresolved competition IDs
        // prevents a stale/renamed ID from remaining active while invisible in the UI.
        if catalog.isEmpty {
            canonicalIDs.formUnion(unresolvedCompetitionIDs.map(FixtureViewOptionID.competition))
        }
        return canonicalIDs.sorted()
    }
}
