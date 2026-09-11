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
        let prefersChampionsLeague = prefersChampionsLeagueTable(for: match)
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

            let championsLeagueCandidate = prefersChampionsLeague ? candidates.first {
                isChampionsLeague(id: $0.league.leagueID, name: $0.league.leagueName)
            } : nil
            guard let candidate = championsLeagueCandidate ?? candidates.sorted(by: isPreferred).first else {
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

    static func prefersChampionsLeagueTable(for match: Match) -> Bool {
        guard isChampionsLeague(id: match.leagueId, name: match.league) else { return false }

        let round = (match.leagueSubcategory ?? "")
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
        // Named qualifying/knockout stages take precedence over numeric rounds.
        let stageContext = "\(match.league.lowercased()) \(round)"
        if ["qualif", "preliminary", "playoff", "play-off", "play off", "knockout",
            "round of", "last ", "final", "1/"].contains(where: stageContext.contains) {
            return false
        }
        if round.contains("league phase") || round.contains("league stage") {
            return true
        }
        if round.isEmpty {
            // Legacy and synthetic matches may omit stage metadata entirely.
            return match.roundNumber.map { (1...8).contains($0) } ?? true
        }
        for matchday in 1...8 {
            if ["\(matchday)", "round \(matchday)", "matchday \(matchday)", "matchday\(matchday)"]
                .contains(round) {
                return true
            }
        }
        return false
    }

    private static func isChampionsLeague(id: String?, name: String) -> Bool {
        ["7", "uefa-champions-league", "champions-league"].contains(id?.lowercased() ?? "") ||
            ["uefachampionsleague", "championsleague"].contains(normalized(name))
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
