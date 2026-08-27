import Foundation
import Combine

struct TopTeamsPresetTeam: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let aliases: [String]
    let sourceTeamIDs: [String]
    let elo: Double?
    let countryCode: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case aliases
        case sourceTeamIDs = "source_team_ids"
        case elo
        case countryCode = "country_code"
    }
}

struct TopTeamsPresetDefinition: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let id: String
    let revision: String
    let title: String
    let clubEloThreshold: Double
    let premierLeagueCompetitionID: String?
    let championsLeagueCompetitionID: String
    let otherUEFACompetitionIDs: [String]
    let qualifyingRoundPatterns: [String]
    let displaySections: [String]
    let unconditionalTeams: [TopTeamsPresetTeam]
    let conditionalUEFATeams: [TopTeamsPresetTeam]
    let majorTeams: [TopTeamsPresetTeam]
    let updatedAt: String?
    let sources: TopTeamsPresetSources?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case revision
        case title
        case clubEloThreshold = "club_elo_threshold"
        case premierLeagueCompetitionID = "premier_league_competition_id"
        case championsLeagueCompetitionID = "champions_league_competition_id"
        case otherUEFACompetitionIDs = "other_uefa_competition_ids"
        case qualifyingRoundPatterns = "qualifying_round_patterns"
        case displaySections = "display_sections"
        case unconditionalTeams = "unconditional_teams"
        case conditionalUEFATeams = "conditional_uefa_teams"
        case majorTeams = "major_teams"
        case updatedAt = "updated_at"
        case sources
    }

    static let fallback = TopTeamsPresetDefinition(
        schemaVersion: 1,
        id: FixtureViewOptionID.topTeamsPreset,
        revision: "bundled-1",
        title: "Top teams",
        clubEloThreshold: 1750,
        premierLeagueCompetitionID: "premier-league",
        championsLeagueCompetitionID: "uefa-champions-league",
        otherUEFACompetitionIDs: [
            "uefa-europa-league",
            "uefa-conference-league",
            "uefa-super-cup",
        ],
        qualifyingRoundPatterns: ["qualifying", "qualification", "playoff", "play-off", "play off"],
        displaySections: [
            "Any match involving a current Premier League team",
            "Any international involving England, Wales, Scotland, Northern Ireland or Republic of Ireland",
            "Any match involving Real Madrid, Barcelona or Bayern Munich",
            "Every Champions League league-phase or knockout match",
            "Champions League qualifying and other UEFA club matches involving UK or Irish clubs",
            "Champions League qualifying and other UEFA club matches involving major Club Elo teams",
        ],
        unconditionalTeams: Self.fallbackTeams([
            ("England", []),
            ("Wales", []),
            ("Scotland", []),
            ("Northern Ireland", []),
            ("Republic of Ireland", ["Ireland"]),
            ("Real Madrid", []),
            ("Barcelona", ["FC Barcelona"]),
            ("Bayern Munich", ["Bayern", "Bayern München", "FC Bayern München"]),
        ]),
        conditionalUEFATeams: Self.fallbackTeams([
            ("Celtic", ["Celtic FC"]),
            ("Rangers", ["Rangers FC"]),
            ("Inter Milan", ["Inter", "Internazionale"]),
            ("AC Milan", ["Milan"]),
            ("Juventus", ["Juventus FC"]),
            ("Atletico Madrid", ["Atlético Madrid"]),
            ("Borussia Dortmund", ["Dortmund"]),
            ("Bayer Leverkusen", ["Leverkusen"]),
            ("Paris Saint-Germain", ["Paris SG", "PSG"]),
            ("Benfica", []),
            ("Porto", []),
            ("Sporting CP", ["Sporting"]),
        ]),
        majorTeams: Self.fallbackTeams([
            ("Inter Milan", ["Inter", "Internazionale"]),
            ("AC Milan", ["Milan"]),
            ("Juventus", ["Juventus FC"]),
            ("Atletico Madrid", ["Atlético Madrid"]),
            ("Borussia Dortmund", ["Dortmund"]),
            ("Bayer Leverkusen", ["Leverkusen"]),
            ("Paris Saint-Germain", ["Paris SG", "PSG"]),
            ("Benfica", []),
            ("Porto", []),
            ("Sporting CP", ["Sporting"]),
        ]),
        updatedAt: nil,
        sources: nil
    )

    private static func fallbackTeams(
        _ values: [(String, [String])]
    ) -> [TopTeamsPresetTeam] {
        values.map { name, aliases in
            TopTeamsPresetTeam(
                id: normalizedID(name),
                name: name,
                aliases: aliases,
                sourceTeamIDs: [],
                elo: nil,
                countryCode: nil
            )
        }
    }

    private static func normalizedID(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "-")
    }

    nonisolated func sanitized() -> TopTeamsPresetDefinition {
        let excludedConditionalTeamKeys: Set<String> = [
            Self.normalizedTeamKey("FK Arsenal Tivat"),
            Self.normalizedTeamKey("Comoros"),
        ]
        return TopTeamsPresetDefinition(
            schemaVersion: schemaVersion,
            id: id,
            revision: revision,
            title: title,
            clubEloThreshold: clubEloThreshold,
            premierLeagueCompetitionID: premierLeagueCompetitionID,
            championsLeagueCompetitionID: championsLeagueCompetitionID,
            otherUEFACompetitionIDs: otherUEFACompetitionIDs,
            qualifyingRoundPatterns: qualifyingRoundPatterns,
            displaySections: displaySections,
            unconditionalTeams: Self.deduplicated(unconditionalTeams),
            conditionalUEFATeams: Self.deduplicated(
                conditionalUEFATeams.filter {
                    !excludedConditionalTeamKeys.contains(Self.normalizedTeamKey($0.name))
                }
            ),
            majorTeams: Self.deduplicated(
                majorTeams.filter {
                    !excludedConditionalTeamKeys.contains(Self.normalizedTeamKey($0.name))
                }
            ),
            updatedAt: updatedAt,
            sources: sources
        )
    }

    private nonisolated static func deduplicated(
        _ teams: [TopTeamsPresetTeam]
    ) -> [TopTeamsPresetTeam] {
        var result: [TopTeamsPresetTeam] = []
        var keysByIndex: [Set<String>] = []

        for team in teams {
            let teamKeys = Set(([team.name] + team.aliases).map(normalizedTeamKey).filter { !$0.isEmpty })
            guard !teamKeys.isEmpty else { continue }

            if let index = keysByIndex.firstIndex(where: { !$0.isDisjoint(with: teamKeys) }) {
                let existing = result[index]
                var aliases = Set(existing.aliases + team.aliases)
                if normalizedTeamKey(team.name) != normalizedTeamKey(existing.name) {
                    aliases.insert(team.name)
                }
                aliases.remove(existing.name)
                result[index] = TopTeamsPresetTeam(
                    id: existing.id,
                    name: existing.name,
                    aliases: aliases.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
                    sourceTeamIDs: Array(Set(existing.sourceTeamIDs + team.sourceTeamIDs)).sorted(),
                    elo: [existing.elo, team.elo].compactMap { $0 }.max(),
                    countryCode: existing.countryCode ?? team.countryCode
                )
                keysByIndex[index].formUnion(teamKeys)
            } else {
                result.append(team)
                keysByIndex.append(teamKeys)
            }
        }

        return result
    }

    private nonisolated static func normalizedTeamKey(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined()
    }
}

struct TopTeamsPresetSources: Codable, Equatable, Sendable {
    let configUpdatedAt: String?
    let clubEloUpdatedAt: String?
    let premierLeagueUpdatedAt: String?
    let teamCatalogUpdatedAt: String?

    enum CodingKeys: String, CodingKey {
        case configUpdatedAt = "config_updated_at"
        case clubEloUpdatedAt = "club_elo_updated_at"
        case premierLeagueUpdatedAt = "premier_league_updated_at"
        case teamCatalogUpdatedAt = "team_catalog_updated_at"
    }
}

nonisolated struct TopTeamsPresetMatcher: Sendable {
    private let definition: TopTeamsPresetDefinition
    private let unconditionalTeamIDs: Set<String>
    private let unconditionalTeamKeys: Set<String>
    private let conditionalTeamIDs: Set<String>
    private let conditionalTeamKeys: Set<String>

    init(definition: TopTeamsPresetDefinition) {
        self.definition = definition
        unconditionalTeamIDs = Set(definition.unconditionalTeams.flatMap(\.sourceTeamIDs))
        unconditionalTeamKeys = Self.teamKeys(definition.unconditionalTeams)
        conditionalTeamIDs = Set(definition.conditionalUEFATeams.flatMap(\.sourceTeamIDs))
        conditionalTeamKeys = Self.teamKeys(definition.conditionalUEFATeams)
    }

    func matches(_ match: Match, competitionID: String?) -> Bool {
        if competitionID == (definition.premierLeagueCompetitionID ?? "premier-league") ||
            MatchesStore.matchIncludesPremierLeagueTeam(match) ||
            teamMatches(match.homeTeam, sourceID: match.homeTeamId, ids: unconditionalTeamIDs, keys: unconditionalTeamKeys) ||
            teamMatches(match.awayTeam, sourceID: match.awayTeamId, ids: unconditionalTeamIDs, keys: unconditionalTeamKeys) {
            return true
        }

        if competitionID == definition.championsLeagueCompetitionID,
           !isQualifyingRound(match) {
            return true
        }

        let conditionalCompetitionIDs = Set(
            [definition.championsLeagueCompetitionID] + definition.otherUEFACompetitionIDs
        )
        guard let competitionID,
              conditionalCompetitionIDs.contains(competitionID) else {
            return false
        }

        return teamMatches(
            match.homeTeam,
            sourceID: match.homeTeamId,
            ids: conditionalTeamIDs,
            keys: conditionalTeamKeys
        ) || teamMatches(
            match.awayTeam,
            sourceID: match.awayTeamId,
            ids: conditionalTeamIDs,
            keys: conditionalTeamKeys
        )
    }

    private func isQualifyingRound(_ match: Match) -> Bool {
        let round = [match.league, match.leagueSubcategory]
            .compactMap { $0 }
            .joined(separator: " ")
        let normalizedRound = Self.normalizedKey(round)
        return definition.qualifyingRoundPatterns.contains { pattern in
            normalizedRound.contains(Self.normalizedKey(pattern))
        }
    }

    private func teamMatches(
        _ name: String,
        sourceID: String?,
        ids: Set<String>,
        keys: Set<String>
    ) -> Bool {
        if let sourceID, ids.contains(sourceID) { return true }
        return !TeamIdentityStore.shared.normalizedKeys(for: name).isDisjoint(with: keys)
    }

    private static func teamKeys(_ teams: [TopTeamsPresetTeam]) -> Set<String> {
        Set(teams.flatMap { team in
            [team.name] + team.aliases
        }.flatMap { name in
            Array(TeamIdentityStore.shared.normalizedKeys(for: name)) + [normalizedKey(name)]
        })
    }

    private static func normalizedKey(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }
}

@MainActor
final class TopTeamsPresetStore: ObservableObject {
    static let shared = TopTeamsPresetStore()

    @Published private(set) var preset: TopTeamsPresetDefinition
    @Published private(set) var isRefreshing = false

    private static let cacheTTL: TimeInterval = 6 * 60 * 60
    private static let supportedSchemaVersion = 1
    private var fetchedAt: Date?
    private var refreshTask: Task<TopTeamsPresetDefinition, Error>?

    private init() {
        if let cached = Self.loadCache(),
           cached.preset.schemaVersion == Self.supportedSchemaVersion {
            preset = cached.preset.sanitized()
            fetchedAt = cached.fetchedAt
        } else {
            preset = .fallback
        }
    }

    func ensureFresh(apiBaseURL: String, force: Bool = false) async {
        if !force,
           let fetchedAt,
           Date().timeIntervalSince(fetchedAt) < Self.cacheTTL {
            return
        }
        if let refreshTask {
            _ = try? await refreshTask.value
            return
        }
        guard let baseURL = URL(string: apiBaseURL) else { return }

        isRefreshing = true
        let task = Task<TopTeamsPresetDefinition, Error> {
            try await APIClient(baseURL: baseURL).fetchTopTeamsPreset()
        }
        refreshTask = task
        defer {
            refreshTask = nil
            isRefreshing = false
        }

        do {
            let fetched = try await task.value.sanitized()
            guard fetched.schemaVersion == Self.supportedSchemaVersion,
                  fetched.id == FixtureViewOptionID.topTeamsPreset,
                  !fetched.unconditionalTeams.isEmpty else {
                diagnosticLog("[TopTeamsPreset] Ignoring invalid or unsupported preset payload")
                return
            }
            preset = fetched
            fetchedAt = Date()
            Self.persist(TopTeamsPresetCache(fetchedAt: fetchedAt ?? Date(), preset: fetched))
        } catch {
            diagnosticLog("[TopTeamsPreset] Refresh failed: %@", String(describing: error))
        }
    }

    private struct TopTeamsPresetCache: Codable {
        let fetchedAt: Date
        let preset: TopTeamsPresetDefinition
    }

    private static func loadCache() -> TopTeamsPresetCache? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TopTeamsPresetCache.self, from: data)
    }

    private static func persist(_ payload: TopTeamsPresetCache) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static var cacheURL: URL {
        let fileManager = FileManager.default
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("TopScores", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("top-teams-preset-cache.json")
    }
}
