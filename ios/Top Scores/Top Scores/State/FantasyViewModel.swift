import Foundation
import Combine

@MainActor
final class FantasyViewModel: ObservableObject {
    private static let gameUpdatingUserMessage = "Fantasy Football data is temporarily unavailable while the official game is being updated. Please try again in a few minutes."

    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var data: FantasySquadDisplayData?
    @Published private(set) var rivalSquads: [FantasyRivalSquad] = []
    @Published private(set) var trackedLeagueStandings: [FantasyTrackedLeagueStanding] = []
    @Published private(set) var myProfile: FantasyEntryProfile?
    @Published private(set) var lastUpdated: Date?
    @Published var errorMessage: String?

    private let fantasyPublicClient = FantasyPublicAPIClient()
    private var cachedBootstrapLookup: FantasyBootstrapLookup?
    private var cachedBootstrapFetchedAt: Date?
    private var cachedBootstrapBaseURL: String?
    private let bootstrapCacheTTL: TimeInterval = 12 * 60 * 60
    private var cachedTransferRecommendations: [String: (payload: FantasyTransferRecommendationsResponse, fetchedAt: Date)] = [:]
    private let transferRecommendationsCacheTTL: TimeInterval = 10 * 60
    private var cachedPlayerDetailsBootstrap: FantasyBootstrapLookup?
    private var cachedPlayerDetailsBootstrapFetchedAt: Date?
    private let playerDetailsBootstrapCacheTTL: TimeInterval = 6 * 60 * 60
    private var cachedSeasonFixtures: [FantasyFixture] = []
    private var cachedSeasonFixturesFetchedAt: Date?
    private let seasonFixturesCacheTTL: TimeInterval = 30 * 60
    private var rivalRefreshToken = UUID()
    private var leagueRefreshToken = UUID()

    func reset() {
        isLoading = false
        isRefreshing = false
        data = nil
        rivalSquads = []
        trackedLeagueStandings = []
        myProfile = nil
        lastUpdated = nil
        errorMessage = nil
        cachedBootstrapLookup = nil
        cachedBootstrapFetchedAt = nil
        cachedBootstrapBaseURL = nil
        cachedTransferRecommendations = [:]
        cachedPlayerDetailsBootstrap = nil
        cachedPlayerDetailsBootstrapFetchedAt = nil
        cachedSeasonFixtures = []
        cachedSeasonFixturesFetchedAt = nil
    }

    func refresh(
        managerEntryID: String,
        apiBaseURL: String,
        rivalManagers: [FantasyRivalManager],
        trackedLeagues: [FantasyTrackedLeague]
    ) async {
        let refreshStartedAt = Date()
        let trimmedManagerID = managerEntryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let entryID = Int(trimmedManagerID), entryID > 0 else {
            errorMessage = "Stored manager ID is invalid. Please relink your Fantasy account."
            return
        }

        guard let baseURL = URL(string: apiBaseURL) else {
            errorMessage = "Invalid API base URL in preferences."
            return
        }

        let hadExistingData = data != nil
        if hadExistingData {
            isRefreshing = true
        } else {
            isLoading = true
        }

        defer {
            isLoading = false
            isRefreshing = false
        }

        do {
            let serverClient = APIClient(baseURL: baseURL)
            logPerf("refresh_start entry_id=\(entryID) rivals=\(rivalManagers.count) leagues=\(trackedLeagues.count)")

            let currentGameweek = try await timed("current_gameweek") {
                try await serverClient.fetchFantasyCurrentGameweek()
            }

            let bootstrapBaseURLKey = baseURL.absoluteString
            async let bootstrapLookupTask = fetchBootstrapLookup(
                serverClient: serverClient,
                baseURLKey: bootstrapBaseURLKey
            )
            async let myProfileTask = fetchMyProfile(entryID: entryID)
            async let picksTask = timed("my_picks") {
                try await fantasyPublicClient.fetchPicks(
                    entryID: entryID,
                    eventID: currentGameweek.id
                )
            }
            async let liveTask = timed("event_live") {
                try await fantasyPublicClient.fetchEventLive(eventID: currentGameweek.id)
            }
            async let fixturesTask = timed("event_fixtures") {
                try await fantasyPublicClient.fetchEventFixtures(eventID: currentGameweek.id)
            }
            async let seasonFixturesTask = fetchSeasonFixtures()

            let (bootstrapLookup, myProfile, picksResponse, liveResponse, fixtures, seasonFixtures) = try await (
                bootstrapLookupTask,
                myProfileTask,
                picksTask,
                liveTask,
                fixturesTask,
                seasonFixturesTask
            )
            self.myProfile = myProfile

            data = FantasySquadBuilder.build(
                gameweek: currentGameweek,
                picksResponse: picksResponse,
                liveResponse: liveResponse,
                fixtures: fixtures,
                seasonFixtures: seasonFixtures,
                bootstrap: bootstrapLookup
            )

            let normalizedRivals = deduplicatedRivals(
                rivalManagers: rivalManagers,
                excludingEntryID: entryID
            )
            if normalizedRivals.isEmpty {
                rivalSquads = []
            } else {
                let refreshToken = UUID()
                rivalRefreshToken = refreshToken
                Task {
                    let refreshedRivals = await self.fetchRivalSquads(
                        rivals: normalizedRivals,
                        gameweek: currentGameweek,
                        liveResponse: liveResponse,
                        fixtures: fixtures,
                        seasonFixtures: seasonFixtures,
                        bootstrapLookup: bootstrapLookup
                    )
                    guard self.rivalRefreshToken == refreshToken else { return }
                    self.rivalSquads = refreshedRivals
                    self.logPerf("rivals_complete count=\(refreshedRivals.count)")
                }
            }

            let normalizedTrackedLeagues = deduplicatedTrackedLeagues(trackedLeagues: trackedLeagues)
            if normalizedTrackedLeagues.isEmpty {
                trackedLeagueStandings = []
            } else {
                let refreshToken = UUID()
                leagueRefreshToken = refreshToken
                Task {
                    let refreshedLeagues = await self.fetchTrackedLeagueStandings(
                        trackedLeagues: normalizedTrackedLeagues,
                        managerEntryID: entryID
                    )
                    guard self.leagueRefreshToken == refreshToken else { return }
                    self.trackedLeagueStandings = refreshedLeagues
                    self.logPerf("leagues_complete count=\(refreshedLeagues.count)")
                }
            }
            lastUpdated = Date()
            errorMessage = nil
            let totalDurationMs = Date().timeIntervalSince(refreshStartedAt) * 1000
            logPerf("refresh_complete entry_id=\(entryID) rivals_loaded=\(rivalSquads.count) duration_ms=\(Int(totalDurationMs))")
        } catch {
            let totalDurationMs = Date().timeIntervalSince(refreshStartedAt) * 1000
            logPerf("refresh_failed entry_id=\(entryID) duration_ms=\(Int(totalDurationMs)) error=\"\(error.localizedDescription)\"")
            errorMessage = userFriendlyErrorMessage(for: error)
        }
    }

    func validateRivalEntryID(_ rawEntryID: String) async throws -> FantasyEntryProfile {
        let trimmed = rawEntryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RivalValidationError.empty
        }
        guard trimmed.allSatisfy(\.isNumber) else {
            throw RivalValidationError.nonNumeric
        }
        guard let entryID = Int(trimmed), entryID > 0 else {
            throw RivalValidationError.invalidNumber
        }
        return try await fantasyPublicClient.fetchEntryProfile(entryID: entryID)
    }

    func validateLeagueID(_ rawLeagueID: String, managerEntryID: String) async throws -> FantasyTrackedLeagueStanding {
        let trimmedLeagueID = rawLeagueID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLeagueID.isEmpty else {
            throw LeagueValidationError.empty
        }
        guard trimmedLeagueID.allSatisfy(\.isNumber) else {
            throw LeagueValidationError.nonNumeric
        }
        guard let leagueID = Int(trimmedLeagueID), leagueID > 0 else {
            throw LeagueValidationError.invalidNumber
        }

        let trimmedManagerID = managerEntryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let myEntryID = Int(trimmedManagerID), myEntryID > 0 else {
            throw LeagueValidationError.missingManager
        }

        return try await fetchLeagueStandingSnapshot(leagueID: leagueID, managerEntryID: myEntryID)
    }

    func loadPlayerDetails(
        elementID: Int,
        gameweekID: Int,
        apiBaseURL: String
    ) async throws -> FantasyPlayerDetailsData {
        async let bootstrapLookupTask = fetchPlayerDetailsBootstrapLookup(apiBaseURL: apiBaseURL)
        async let elementSummaryTask = timed("element_summary element_id=\(elementID)") {
            try await fantasyPublicClient.fetchElementSummary(elementID: elementID)
        }

        let (bootstrapLookup, elementSummary) = try await (bootstrapLookupTask, elementSummaryTask)
        return try FantasyPlayerDetailsBuilder.build(
            elementID: elementID,
            gameweekID: gameweekID,
            bootstrap: bootstrapLookup,
            summary: elementSummary
        )
    }

    func fetchTransferRecommendations(
        elementID: Int,
        apiBaseURL: String
    ) async throws -> FantasyTransferRecommendationsResponse {
        guard let baseURL = URL(string: apiBaseURL) else {
            throw FantasyPublicAPIError.invalidURL
        }

        let cacheKey = "\(baseURL.absoluteString)|\(elementID)"
        let now = Date()
        if let cached = cachedTransferRecommendations[cacheKey],
           now.timeIntervalSince(cached.fetchedAt) < transferRecommendationsCacheTTL {
            let age = Int(now.timeIntervalSince(cached.fetchedAt))
            logPerf("transfer_recommendations_cache_hit element_id=\(elementID) age_s=\(age)")
            return cached.payload
        }

        let serverClient = APIClient(baseURL: baseURL)
        let response = try await timed("transfer_recommendations element_id=\(elementID)") {
            try await serverClient.fetchFantasyTransferRecommendations(elementID: elementID)
        }
        cachedTransferRecommendations[cacheKey] = (payload: response, fetchedAt: now)
        return response
    }

    private func fetchPlayerDetailsBootstrapLookup(apiBaseURL: String) async throws -> FantasyBootstrapLookup {
        let now = Date()
        if let cachedPlayerDetailsBootstrap,
           let cachedPlayerDetailsBootstrapFetchedAt,
           now.timeIntervalSince(cachedPlayerDetailsBootstrapFetchedAt) < playerDetailsBootstrapCacheTTL {
            let age = Int(now.timeIntervalSince(cachedPlayerDetailsBootstrapFetchedAt))
            logPerf("bootstrap_static_details_cache_hit age_s=\(age)")
            return cachedPlayerDetailsBootstrap
        }

        do {
            let fullBootstrap = try await timed("bootstrap_static_details_fetch") {
                try await fantasyPublicClient.fetchBootstrapStatic()
            }
            cachedPlayerDetailsBootstrap = fullBootstrap
            cachedPlayerDetailsBootstrapFetchedAt = now
            return fullBootstrap
        } catch {
            logPerf("bootstrap_static_details_fetch_failed fallback=server_lookup error=\"\(error.localizedDescription)\"")
            guard let baseURL = URL(string: apiBaseURL) else {
                throw FantasyPublicAPIError.invalidURL
            }
            let serverClient = APIClient(baseURL: baseURL)
            let bootstrapBaseURLKey = baseURL.absoluteString
            return try await fetchBootstrapLookup(
                serverClient: serverClient,
                baseURLKey: bootstrapBaseURLKey
            )
        }
    }

    private func deduplicatedRivals(
        rivalManagers: [FantasyRivalManager],
        excludingEntryID: Int
    ) -> [FantasyRivalManager] {
        var seen = Set<Int>()
        var result: [FantasyRivalManager] = []

        for rival in rivalManagers {
            guard rival.entryID > 0 else { continue }
            guard rival.entryID != excludingEntryID else { continue }
            guard !seen.contains(rival.entryID) else { continue }
            seen.insert(rival.entryID)
            result.append(rival)
        }

        return result
    }

    private func deduplicatedTrackedLeagues(trackedLeagues: [FantasyTrackedLeague]) -> [FantasyTrackedLeague] {
        var seen = Set<Int>()
        var result: [FantasyTrackedLeague] = []

        for trackedLeague in trackedLeagues {
            guard trackedLeague.leagueID > 0 else { continue }
            guard !seen.contains(trackedLeague.leagueID) else { continue }
            seen.insert(trackedLeague.leagueID)
            result.append(trackedLeague)
        }

        return result
    }

    private func fetchRivalSquads(
        rivals: [FantasyRivalManager],
        gameweek: FantasyGameweek,
        liveResponse: FantasyEventLiveResponse,
        fixtures: [FantasyFixture],
        seasonFixtures: [FantasyFixture],
        bootstrapLookup: FantasyBootstrapLookup
    ) async -> [FantasyRivalSquad] {
        var refreshedRivals: [FantasyRivalSquad] = []

        for rival in rivals {
            do {
                async let rivalProfileTask = fetchMyProfile(entryID: rival.entryID)
                let rivalPicks = try await timed("rival_picks entry_id=\(rival.entryID)") {
                    try await fantasyPublicClient.fetchPicks(
                        entryID: rival.entryID,
                        eventID: gameweek.id
                    )
                }
                let rivalProfile = await rivalProfileTask
                let rivalSquad = FantasySquadBuilder.build(
                    gameweek: gameweek,
                    picksResponse: rivalPicks,
                    liveResponse: liveResponse,
                    fixtures: fixtures,
                    seasonFixtures: seasonFixtures,
                    bootstrap: bootstrapLookup
                )
                refreshedRivals.append(
                    FantasyRivalSquad(
                        entryID: rival.entryID,
                        teamName: rival.teamName,
                        managerName: rival.managerDisplayName,
                        squad: rivalSquad,
                        allGameweeksPoints: rivalProfile?.summaryOverallPoints ?? rival.overallPoints
                    )
                )
            } catch {
                continue
            }
        }

        return refreshedRivals.sorted { lhs, rhs in
            let left = lhs.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
            let right = rhs.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
            if left.caseInsensitiveCompare(right) != .orderedSame {
                return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
            }
            return lhs.entryID < rhs.entryID
        }
    }

    private func fetchTrackedLeagueStandings(
        trackedLeagues: [FantasyTrackedLeague],
        managerEntryID: Int
    ) async -> [FantasyTrackedLeagueStanding] {
        var snapshots: [FantasyTrackedLeagueStanding] = []

        for trackedLeague in trackedLeagues {
            do {
                let snapshot = try await fetchLeagueStandingSnapshot(
                    leagueID: trackedLeague.leagueID,
                    managerEntryID: managerEntryID
                )
                snapshots.append(snapshot)
            } catch {
                continue
            }
        }

        return snapshots.sorted { lhs, rhs in
            if lhs.leagueName.localizedCaseInsensitiveCompare(rhs.leagueName) != .orderedSame {
                return lhs.leagueName.localizedCaseInsensitiveCompare(rhs.leagueName) == .orderedAscending
            }
            return lhs.leagueID < rhs.leagueID
        }
    }

    private func fetchLeagueStandingSnapshot(
        leagueID: Int,
        managerEntryID: Int
    ) async throws -> FantasyTrackedLeagueStanding {
        let response = try await fetchFullLeagueStandings(leagueID: leagueID)
        let myEntry = response.standings.results.first(where: { $0.entry == managerEntryID })
        return FantasyTrackedLeagueStanding(
            leagueID: response.league.id,
            leagueName: response.league.name,
            myEntryID: managerEntryID,
            myRank: myEntry?.rank,
            myLastRank: myEntry?.lastRank,
            myEventTotal: myEntry?.eventTotal,
            myOverallTotal: myEntry?.total,
            myEntryName: myEntry?.entryName,
            standings: response.standings.results
        )
    }

    private func fetchFullLeagueStandings(leagueID: Int) async throws -> FantasyLeagueStandingsResponse {
        var page = 1
        var combinedResults: [FantasyClassicLeagueStandingEntry] = []
        var firstResponse: FantasyLeagueStandingsResponse?

        while true {
            let response = try await timed("league_standings league_id=\(leagueID) page=\(page)") {
                try await fantasyPublicClient.fetchLeagueStandings(leagueID: leagueID, page: page)
            }
            if firstResponse == nil {
                firstResponse = response
            }
            combinedResults.append(contentsOf: response.standings.results)

            guard response.standings.hasNext else { break }
            page += 1
            if page > 30 {
                break
            }
        }

        guard let firstResponse else {
            throw FantasyPublicAPIError.invalidHTTPResponse
        }

        return FantasyLeagueStandingsResponse(
            newEntries: firstResponse.newEntries,
            lastUpdatedData: firstResponse.lastUpdatedData,
            league: firstResponse.league,
            standings: FantasyClassicLeagueStandings(
                hasNext: false,
                page: 1,
                results: combinedResults
            )
        )
    }

    private func fetchSeasonFixtures() async throws -> [FantasyFixture] {
        let now = Date()
        if let cachedSeasonFixturesFetchedAt,
           now.timeIntervalSince(cachedSeasonFixturesFetchedAt) < seasonFixturesCacheTTL,
           !cachedSeasonFixtures.isEmpty {
            let age = Int(now.timeIntervalSince(cachedSeasonFixturesFetchedAt))
            logPerf("season_fixtures_cache_hit age_s=\(age)")
            return cachedSeasonFixtures
        }

        let fixtures = try await timed("season_fixtures") {
            try await fantasyPublicClient.fetchAllFixtures()
        }
        cachedSeasonFixtures = fixtures
        cachedSeasonFixturesFetchedAt = now
        return fixtures
    }

    private func fetchBootstrapLookup(
        serverClient: APIClient,
        baseURLKey: String
    ) async throws -> FantasyBootstrapLookup {
        let now = Date()
        if cachedBootstrapBaseURL == baseURLKey,
           let cachedBootstrapLookup,
           let cachedBootstrapFetchedAt,
           now.timeIntervalSince(cachedBootstrapFetchedAt) < bootstrapCacheTTL {
            let age = Int(now.timeIntervalSince(cachedBootstrapFetchedAt))
            logPerf("bootstrap_lookup_cache_hit age_s=\(age)")
            return cachedBootstrapLookup
        }

        let lookup = try await timed("bootstrap_lookup_fetch") {
            try await serverClient.fetchFantasyBootstrapLookup()
        }
        cachedBootstrapLookup = lookup
        cachedBootstrapFetchedAt = now
        cachedBootstrapBaseURL = baseURLKey
        return lookup
    }

    private func fetchMyProfile(entryID: Int) async -> FantasyEntryProfile? {
        do {
            return try await timed("my_profile") {
                try await fantasyPublicClient.fetchEntryProfile(entryID: entryID)
            }
        } catch {
            return nil
        }
    }

    private func userFriendlyErrorMessage(for error: Error) -> String {
        if let fantasyError = error as? FantasyPublicAPIError,
           case .gameUpdating = fantasyError {
            return Self.gameUpdatingUserMessage
        }

        if let apiError = error as? APIClientError,
           case let .badStatus(_, _, bodySnippet) = apiError,
           Self.containsGameUpdatingText(bodySnippet) {
            return Self.gameUpdatingUserMessage
        }

        let message = error.localizedDescription
        if Self.containsGameUpdatingText(message) {
            return Self.gameUpdatingUserMessage
        }
        return message
    }

    private static func containsGameUpdatingText(_ value: String) -> Bool {
        let normalized = value
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized.contains("the game is being updated") {
            return true
        }
        if normalized.contains("game is being updated") {
            return true
        }
        if normalized.contains("temporarily unavailable"),
           normalized.contains("game"),
           normalized.contains("updated") {
            return true
        }
        return false
    }

    private func timed<T>(_ label: String, operation: () async throws -> T) async throws -> T {
        let started = Date()
        do {
            let value = try await operation()
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            logPerf("\(label) ok duration_ms=\(ms)")
            return value
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            logPerf("\(label) failed duration_ms=\(ms) error=\"\(error.localizedDescription)\"")
            throw error
        }
    }

    private func logPerf(_ message: String) {
        #if DEBUG
        print("[FantasyPerf] \(message)")
        #endif
    }
}

private enum RivalValidationError: LocalizedError {
    case empty
    case nonNumeric
    case invalidNumber

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter a manager ID to continue."
        case .nonNumeric:
            return "Manager ID must contain numbers only."
        case .invalidNumber:
            return "Manager ID is invalid."
        }
    }
}

private enum LeagueValidationError: LocalizedError {
    case empty
    case nonNumeric
    case invalidNumber
    case missingManager

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter a league ID to continue."
        case .nonNumeric:
            return "League ID must contain numbers only."
        case .invalidNumber:
            return "League ID is invalid."
        case .missingManager:
            return "Link your Fantasy manager account before adding leagues."
        }
    }
}
