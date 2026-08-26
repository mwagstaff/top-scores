import Foundation

nonisolated enum MatchCompetitionTeamSide: String, Hashable, Sendable {
    case home
    case away
}

nonisolated struct MatchTeamCompetitionEntry: Identifiable, Equatable, Sendable {
    let side: MatchCompetitionTeamSide
    let teamName: String
    let displayName: String
    let leagueID: String
    let competitionID: String?
    let competitionName: String
    let position: Int

    var id: MatchCompetitionTeamSide { side }
}

nonisolated enum MatchTeamCompetitionResolver {
    static func resolve(
        match: Match,
        leagues: [LeagueTable],
        competitions: [CompetitionCatalogEntry]
    ) -> [MatchTeamCompetitionEntry] {
        let teams: [(MatchCompetitionTeamSide, String, String)] = [
            (.home, match.homeTeam, match.displayHomeTeam),
            (.away, match.awayTeam, match.displayAwayTeam),
        ]

        return teams.compactMap { side, teamName, displayName in
            let canonicalTeamName = TeamIdentityStore.shared.canonicalName(for: teamName)
            let candidates = leagues.compactMap { league -> Candidate? in
                let rows = league.rows + league.groups.flatMap(\.rows)
                guard let row = rows.first(where: {
                    TeamIdentityStore.shared.canonicalName(for: $0.team)
                        .caseInsensitiveCompare(canonicalTeamName) == .orderedSame
                }) else {
                    return nil
                }

                return Candidate(
                    league: league,
                    row: row,
                    competition: competitionMetadata(for: league, in: competitions),
                    isMatchCompetition: namesMatch(league.leagueName, match.league)
                )
            }

            guard let candidate = candidates.sorted(by: isPreferred).first else {
                return nil
            }

            return MatchTeamCompetitionEntry(
                side: side,
                teamName: teamName,
                displayName: displayName,
                leagueID: candidate.league.leagueID,
                competitionID: candidate.competition?.stableID,
                competitionName: candidate.competition?.name ?? candidate.league.leagueName,
                position: candidate.row.position
            )
        }
    }

    private struct Candidate {
        let league: LeagueTable
        let row: LeagueTableRow
        let competition: CompetitionCatalogEntry?
        let isMatchCompetition: Bool

        var isDomesticCompetition: Bool {
            if let region = competition?.region?.lowercased() {
                return region != "europe" && region != "world"
            }

            let normalizedName = MatchTeamCompetitionResolver.normalized(league.leagueName)
            return !["uefa", "fifa", "worldcup", "championsleague", "europaleague", "conferenceleague", "nationsleague"]
                .contains(where: normalizedName.contains)
        }

        var weight: Double {
            competition?.weight ?? 0
        }
    }

    private static func isPreferred(_ left: Candidate, _ right: Candidate) -> Bool {
        if left.isDomesticCompetition != right.isDomesticCompetition {
            return left.isDomesticCompetition
        }
        if left.isMatchCompetition != right.isMatchCompetition {
            return left.isMatchCompetition
        }
        if left.weight != right.weight {
            return left.weight > right.weight
        }
        return left.league.leagueName.localizedCaseInsensitiveCompare(right.league.leagueName) == .orderedAscending
    }

    private static func competitionMetadata(
        for league: LeagueTable,
        in competitions: [CompetitionCatalogEntry]
    ) -> CompetitionCatalogEntry? {
        competitions.first { competition in
            competition.allNames.contains { namesMatch($0, league.leagueName) }
        }
    }

    private static func namesMatch(_ left: String, _ right: String) -> Bool {
        normalized(left) == normalized(right)
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .filter(\.isLetter)
    }
}

actor MatchTeamCompetitionLoader {
    static let shared = MatchTeamCompetitionLoader()

    private var competitionCatalogsByBaseURL: [String: [CompetitionCatalogEntry]] = [:]
    private var catalogTasksByBaseURL: [String: Task<[CompetitionCatalogEntry], Never>] = [:]

    func load(match: Match, apiBaseURL: String) async -> [MatchTeamCompetitionEntry] {
        async let tablesResult = try? LeagueTablesCatalog.shared.refresh(apiBaseURL: apiBaseURL)
        async let competitions = competitionCatalog(apiBaseURL: apiBaseURL)

        let (tables, catalog) = await (tablesResult, competitions)
        guard let tables else { return [] }

        CompetitionBadgeCache.shared.warmIfNeeded(entries: catalog)
        return MatchTeamCompetitionResolver.resolve(
            match: match,
            leagues: tables.leagues,
            competitions: catalog
        )
    }

    private func competitionCatalog(apiBaseURL: String) async -> [CompetitionCatalogEntry] {
        if let cached = competitionCatalogsByBaseURL[apiBaseURL] {
            return cached
        }
        if let existingTask = catalogTasksByBaseURL[apiBaseURL] {
            return await existingTask.value
        }
        guard let baseURL = URL(string: apiBaseURL) else { return [] }

        let task = Task {
            (try? await APIClient(baseURL: baseURL).fetchCompetitionCatalog().competitions) ?? []
        }
        catalogTasksByBaseURL[apiBaseURL] = task
        let catalog = await task.value
        catalogTasksByBaseURL[apiBaseURL] = nil
        if !catalog.isEmpty {
            competitionCatalogsByBaseURL[apiBaseURL] = catalog
        }
        return catalog
    }
}
