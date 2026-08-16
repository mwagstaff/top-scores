import Foundation
import Combine

@MainActor
final class TeamCatalogStore: ObservableObject {
    @Published private(set) var competitions: [CompetitionCatalogEntry] = []
    @Published private(set) var searchResults: [TeamCatalogEntry] = []
    @Published private(set) var selectedTeamsByID: [String: TeamCatalogEntry] = [:]
    @Published private(set) var teamsByCompetitionID: [String: [TeamCatalogEntry]] = [:]
    @Published private(set) var isLoadingCatalog = false
    @Published private(set) var isSearching = false
    @Published private(set) var loadingCompetitionIDs: Set<String> = []
    @Published private(set) var errorMessage: String?

    private var baseURL: URL?
    private var cachedTeamsByID: [String: TeamCatalogEntry] = [:]

    init() {
        loadCache()
    }

    func configure(apiBaseURL: String, selectedTeamIDs: Set<String>) async {
        guard let url = URL(string: apiBaseURL) else {
            errorMessage = "Invalid API URL."
            return
        }
        baseURL = url
        isLoadingCatalog = competitions.isEmpty
        errorMessage = nil

        do {
            async let competitionResponse = APIClient(baseURL: url).fetchCompetitionCatalog()
            let loadedSelectedTeams: TeamCatalogResponse
            if selectedTeamIDs.isEmpty {
                loadedSelectedTeams = TeamCatalogResponse(
                    teams: [], count: 0, totalCount: 0, offset: 0, limit: 200,
                    hasMore: false, updatedAt: nil, source: nil
                )
            } else {
                loadedSelectedTeams = try await APIClient(baseURL: url).fetchTeamCatalog(
                    ids: Array(selectedTeamIDs).sorted(),
                    limit: 200
                )
            }
            let loadedCompetitions = try await competitionResponse
            competitions = loadedCompetitions.competitions.sorted(by: Self.competitionSort)
            remember(loadedSelectedTeams.teams)
            selectedTeamsByID = resolveSelectedTeams(selectedTeamIDs)
        } catch {
            selectedTeamsByID = resolveSelectedTeams(selectedTeamIDs)
            errorMessage = "Unable to load teams. Previously viewed teams remain available."
        }
        isLoadingCatalog = false
    }

    func updateSelectedTeamIDs(_ ids: Set<String>) async {
        selectedTeamsByID = resolveSelectedTeams(ids)
        let missing = ids.filter { selectedTeamsByID[$0] == nil }
        guard !missing.isEmpty, let baseURL else { return }
        do {
            let response = try await APIClient(baseURL: baseURL).fetchTeamCatalog(
                ids: Array(missing).sorted(),
                limit: 200
            )
            remember(response.teams)
            selectedTeamsByID = resolveSelectedTeams(ids)
        } catch {
            // The stable option ID still provides a usable offline fallback label.
        }
    }

    func search(_ rawQuery: String) async {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            searchResults = []
            isSearching = false
            return
        }
        guard let baseURL else { return }
        searchResults = []
        isSearching = true
        errorMessage = nil

        do {
            try await Task.sleep(nanoseconds: 275_000_000)
            try Task.checkCancellation()
            let response = try await APIClient(baseURL: baseURL).fetchTeamCatalog(
                query: query,
                limit: 50
            )
            try Task.checkCancellation()
            remember(response.teams)
            searchResults = response.teams
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled {
                searchResults = []
                errorMessage = "Unable to search teams."
            }
        }
        if !Task.isCancelled {
            isSearching = false
        }
    }

    func loadTeams(for competitionID: String) async {
        guard teamsByCompetitionID[competitionID] == nil,
              !loadingCompetitionIDs.contains(competitionID),
              let baseURL else { return }
        loadingCompetitionIDs.insert(competitionID)
        defer { loadingCompetitionIDs.remove(competitionID) }
        do {
            let response = try await APIClient(baseURL: baseURL).fetchTeamCatalog(
                competitionID: competitionID,
                limit: 200
            )
            remember(response.teams)
            teamsByCompetitionID[competitionID] = response.teams
            errorMessage = nil
        } catch {
            teamsByCompetitionID[competitionID] = []
            errorMessage = "Unable to load teams for this competition."
        }
    }

    func team(for id: String) -> TeamCatalogEntry? {
        selectedTeamsByID[id] ?? cachedTeamsByID[id]
    }

    private func remember(_ teams: [TeamCatalogEntry]) {
        guard !teams.isEmpty else { return }
        teams.forEach { team in
            cachedTeamsByID[team.id] = team
            team.aliases.forEach { alias in
                let aliasID = Self.stableID(for: alias)
                if !aliasID.isEmpty, cachedTeamsByID[aliasID] == nil {
                    cachedTeamsByID[aliasID] = team
                }
            }
        }
        saveCache()
    }

    private func resolveSelectedTeams(_ ids: Set<String>) -> [String: TeamCatalogEntry] {
        Dictionary(uniqueKeysWithValues: ids.compactMap { id in
            cachedTeamsByID[id].map { (id, $0) }
        })
    }

    private static func competitionSort(
        _ left: CompetitionCatalogEntry,
        _ right: CompetitionCatalogEntry
    ) -> Bool {
        if left.region != right.region {
            return (left.region ?? "").localizedCaseInsensitiveCompare(right.region ?? "") == .orderedAscending
        }
        if left.weight != right.weight { return left.weight > right.weight }
        return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
    }

    private static func stableID(for value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "-")
    }

    private struct CachePayload: Codable {
        let teams: [TeamCatalogEntry]
    }

    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("team-catalog-cache.json")
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let payload = try? JSONDecoder().decode(CachePayload.self, from: data) else {
            return
        }
        rememberWithoutSaving(payload.teams)
    }

    private func rememberWithoutSaving(_ teams: [TeamCatalogEntry]) {
        teams.forEach { team in
            cachedTeamsByID[team.id] = team
            team.aliases.forEach { alias in
                let aliasID = Self.stableID(for: alias)
                if !aliasID.isEmpty, cachedTeamsByID[aliasID] == nil {
                    cachedTeamsByID[aliasID] = team
                }
            }
        }
    }

    private func saveCache() {
        let unique = Dictionary(grouping: cachedTeamsByID.values, by: \TeamCatalogEntry.id)
            .compactMap { $0.value.first }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard let data = try? JSONEncoder().encode(CachePayload(teams: unique)) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
