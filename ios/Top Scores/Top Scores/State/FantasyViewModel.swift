import Foundation
import Combine

@MainActor
final class FantasyViewModel: ObservableObject {
    private struct DetachedBox<T>: @unchecked Sendable {
        let value: T
    }

    private static let gameUpdatingUserMessage = "Fantasy Premier League data is temporarily unavailable while the official game is being updated. Please try again in a few minutes."

    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var data: FantasySquadDisplayData?
    @Published private(set) var rivalSquads: [FantasyRivalSquad] = []
    @Published private(set) var trackedLeagueStandings: [FantasyTrackedLeagueStanding] = []
    @Published private(set) var myProfile: FantasyEntryProfile?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var assistantManagerPreview: FantasyAssistantManagerResponse?
    @Published var errorMessage: String?
    /// Pre-computed context for MatchRow. Updated whenever squad data, expected points, or the
    /// bootstrap lookup changes. MatchRow observes this value rather than the whole FantasyViewModel,
    /// so rows only re-render when fantasy data actually changes (not on isLoading / isRefreshing etc).
    @Published private(set) var matchRowContext: FantasyMatchRowContext = .empty

    private var matchRowContextVersion = 0

    private let fantasyPublicClient = FantasyPublicAPIClient()
    private var cachedBootstrapLookup: FantasyBootstrapLookup?
    private var cachedBootstrapFetchedAt: Date?
    private var cachedBootstrapBaseURL: String?
    private let bootstrapCacheTTL: TimeInterval = 12 * 60 * 60
    private var cachedTransferRecommendations: [String: (payload: FantasyTransferRecommendationsResponse, fetchedAt: Date)] = [:]
    private let transferRecommendationsCacheTTL: TimeInterval = 10 * 60
    private var cachedAssistantManagerResponses: [String: (payload: FantasyAssistantManagerResponse, fetchedAt: Date)] = [:]
    private let assistantManagerCacheTTL: TimeInterval = 60
    private var assistantManagerSyncStartedAtByKey: [String: Date] = [:]
    private let assistantManagerSyncCooldown: TimeInterval = 20
    private var cachedPlayerDetailsBootstrap: FantasyBootstrapLookup?
    private var cachedPlayerDetailsBootstrapFetchedAt: Date?
    private let playerDetailsBootstrapCacheTTL: TimeInterval = 6 * 60 * 60
    private var cachedSeasonFixtures: [FantasyFixture] = []
    private var cachedSeasonFixturesFetchedAt: Date?
    private let seasonFixturesCacheTTL: TimeInterval = 30 * 60
    private var rivalRefreshToken = UUID()
    private var leagueRefreshToken = UUID()
    private var rivalRefreshTask: Task<Void, Never>?
    private var leagueRefreshTask: Task<Void, Never>?
    private var assistantManagerPrewarmTask: Task<Void, Never>?
    private let trackedLeaguePageWindowRadius = 1
    private let setupRivalPageWindowRadius = 1
    private let leagueStandingsPageSize = 50
    private let setupRivalCandidateLimit = 200

    var isShowingGameUpdatingState: Bool {
        guard let errorMessage else { return false }
        return Self.containsGameUpdatingText(errorMessage)
    }

    private struct FantasySquadSnapshot {
        let gameweek: FantasyGameweek
        let picksResponse: FantasyPicksResponse
        let liveResponse: FantasyEventLiveResponse
        let fixtures: [FantasyFixture]
    }

    private struct SetupRivalAccumulator {
        let entryID: Int
        let teamName: String
        let managerName: String
        let totalPoints: Int
        let eventPoints: Int
        let clubBadgeSrc: String?
        let sharedLeagueCount: Int
        let closestRankGap: Int

        func merged(with entry: FantasyClassicLeagueStandingEntry, rankGap: Int) -> SetupRivalAccumulator {
            SetupRivalAccumulator(
                entryID: entryID,
                teamName: teamName,
                managerName: managerName,
                totalPoints: max(totalPoints, entry.total),
                eventPoints: max(eventPoints, entry.eventTotal),
                clubBadgeSrc: clubBadgeSrc ?? entry.clubBadgeSrc,
                sharedLeagueCount: sharedLeagueCount + 1,
                closestRankGap: min(closestRankGap, rankGap)
            )
        }

        var candidate: FantasySetupRivalCandidate {
            FantasySetupRivalCandidate(
                entryID: entryID,
                teamName: teamName,
                managerName: managerName,
                totalPoints: totalPoints,
                eventPoints: eventPoints,
                clubBadgeSrc: clubBadgeSrc,
                sharedLeagueCount: sharedLeagueCount,
                closestRankGap: closestRankGap
            )
        }
    }

    func reset() {
        cancelBackgroundRefreshWork()
        isLoading = false
        isRefreshing = false
        data = nil
        rivalSquads = []
        trackedLeagueStandings = []
        myProfile = nil
        lastUpdated = nil
        assistantManagerPreview = nil
        errorMessage = nil
        cachedBootstrapLookup = nil
        cachedBootstrapFetchedAt = nil
        cachedBootstrapBaseURL = nil
        cachedTransferRecommendations = [:]
        cachedAssistantManagerResponses = [:]
        assistantManagerSyncStartedAtByKey = [:]
        cachedPlayerDetailsBootstrap = nil
        cachedPlayerDetailsBootstrapFetchedAt = nil
        cachedSeasonFixtures = []
        cachedSeasonFixturesFetchedAt = nil
        rebuildMatchRowContext()
    }

    func cancelBackgroundRefreshWork() {
        rivalRefreshToken = UUID()
        leagueRefreshToken = UUID()
        rivalRefreshTask?.cancel()
        rivalRefreshTask = nil
        leagueRefreshTask?.cancel()
        leagueRefreshTask = nil
        assistantManagerPrewarmTask?.cancel()
        assistantManagerPrewarmTask = nil
    }

    /// Rebuilds the pre-computed FantasyMatchRowContext published to MatchRow.
    /// Must be called whenever data, assistantManagerPreview, or cachedBootstrapLookup changes.
    private func rebuildMatchRowContext() {
        matchRowContextVersion += 1
        let expectedPoints = buildExpectedPointsDictionary()
        let lookup = FantasySquadMembershipLookup(squad: data, expectedPointsByElementID: expectedPoints)
        let eligibleKeys = Set(
            (cachedBootstrapLookup?.teams ?? []).flatMap {
                TeamIdentityStore.shared.normalizedKeys(for: $0.name)
            }
        )
        matchRowContext = FantasyMatchRowContext(
            lookup: lookup,
            eligibleLeagueTeamKeys: eligibleKeys,
            version: matchRowContextVersion
        )
    }

    /// Builds the expected-points dictionary that was previously computed inline inside each MatchRow body.
    private func buildExpectedPointsDictionary() -> [Int: Int] {
        guard let squad = data,
              let section = currentSquadExpectedPointsSection
        else { return [:] }

        let starterExpectedPoints = Dictionary(
            uniqueKeysWithValues: section.starters.map { ($0.elementID, $0.expectedPointsNextGameweek) }
        )
        let benchExpectedPoints = Dictionary(
            uniqueKeysWithValues: section.bench.map { ($0.elementID, $0.expectedPointsNextGameweek) }
        )

        var result: [Int: Int] = [:]
        for player in squad.starters {
            guard player.hasRemainingFixtureThisGameweek,
                  let pts = starterExpectedPoints[player.elementID]
            else { continue }
            result[player.elementID] = Int(pts.rounded())
        }
        for player in squad.bench {
            guard player.hasRemainingFixtureThisGameweek,
                  let pts = benchExpectedPoints[player.elementID]
            else { continue }
            result[player.elementID] = Int(pts.rounded())
        }
        return result
    }

    private func isFreshAssistantManagerResponse(_ response: FantasyAssistantManagerResponse?) -> Bool {
        guard let response else { return false }
        return response.ready && response.stale != true
    }

    var currentSquadExpectedPointsSection: FantasyAssistantManagerResponse.ExpectedPointsSection? {
        guard let squad = data,
              let response = assistantManagerPreview,
              isFreshAssistantManagerResponse(response),
              squad.matchesAssistantExpectedPointsSection(
                  response.expectedPoints,
                  eventID: response.currentEventID
              )
        else {
            return nil
        }

        return response.expectedPoints
    }

    var currentSquadProjectedGameweekPoints: Double? {
        guard let squad = data,
              let section = currentSquadExpectedPointsSection
        else {
            return nil
        }

        return squad.projectedGameweekPoints(using: section)
    }

    var isCurrentSquadExpectedPointsLoading: Bool {
        currentSquadExpectedPointsSection == nil
    }

    func isEligibleFantasyFixture(_ match: Match) -> Bool {
        guard match.league.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare("Premier League") == .orderedSame
        else {
            return false
        }

        let premierLeagueTeamKeys = Set(
            (cachedBootstrapLookup?.teams ?? []).flatMap { team in
                TeamIdentityStore.shared.normalizedKeys(for: team.name)
            }
        )

        guard !premierLeagueTeamKeys.isEmpty else {
            return true
        }

        let homeTeamKeys = TeamIdentityStore.shared.normalizedKeys(for: match.homeTeam)
        let awayTeamKeys = TeamIdentityStore.shared.normalizedKeys(for: match.awayTeam)

        return !homeTeamKeys.isDisjoint(with: premierLeagueTeamKeys) &&
            !awayTeamKeys.isDisjoint(with: premierLeagueTeamKeys)
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
            cancelBackgroundRefreshWork()
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
            async let nextGameweekTask = fetchNextGameweekIfNeeded(
                currentGameweek: currentGameweek,
                serverClient: serverClient
            )
            async let seasonFixturesTask = fetchSeasonFixtures()

            let (bootstrapLookup, myProfile, nextGameweek, seasonFixtures) = try await (
                bootstrapLookupTask,
                myProfileTask,
                nextGameweekTask,
                seasonFixturesTask
            )
            self.myProfile = myProfile

            let preferredSquadGameweek = FantasySquadGameweekResolver.resolve(
                currentGameweek: currentGameweek,
                nextGameweek: nextGameweek,
                events: bootstrapLookup.events
            )
            if preferredSquadGameweek.id != currentGameweek.id {
                logPerf(
                    "squad_gameweek_switched current=\(currentGameweek.id) squad=\(preferredSquadGameweek.id)"
                )
            }

            let squadSnapshot = try await fetchSquadSnapshotWithFallback(
                entryID: entryID,
                preferredGameweek: preferredSquadGameweek,
                fallbackGameweek: preferredSquadGameweek.id == currentGameweek.id ? nil : currentGameweek,
                labelPrefix: "my"
            )

            data = await buildSquadDisplayData(
                gameweek: squadSnapshot.gameweek,
                picksResponse: squadSnapshot.picksResponse,
                liveResponse: squadSnapshot.liveResponse,
                fixtures: squadSnapshot.fixtures,
                seasonFixtures: seasonFixtures,
                bootstrap: bootstrapLookup
            )
            rebuildMatchRowContext()

            let normalizedRivals = deduplicatedRivals(
                rivalManagers: rivalManagers,
                excludingEntryID: entryID
            )
            if normalizedRivals.isEmpty {
                rivalSquads = []
            } else {
                let refreshToken = UUID()
                rivalRefreshToken = refreshToken
                rivalRefreshTask = Task(priority: .utility) { [weak self] in
                    guard let self else { return }
                    let refreshedRivals = await self.fetchRivalSquads(
                        rivals: normalizedRivals,
                        gameweek: squadSnapshot.gameweek,
                        liveResponse: squadSnapshot.liveResponse,
                        fixtures: squadSnapshot.fixtures,
                        seasonFixtures: seasonFixtures,
                        bootstrapLookup: bootstrapLookup
                    )
                    guard self.rivalRefreshToken == refreshToken else { return }
                    self.rivalSquads = refreshedRivals
                    self.logPerf("rivals_complete count=\(refreshedRivals.count)")
                    await self.populateRivalExpectedPoints(
                        apiBaseURL: apiBaseURL,
                        refreshToken: refreshToken
                    )
                }
            }

            let normalizedTrackedLeagues = deduplicatedTrackedLeagues(trackedLeagues: trackedLeagues)
            if normalizedTrackedLeagues.isEmpty {
                trackedLeagueStandings = []
            } else {
                let refreshToken = UUID()
                leagueRefreshToken = refreshToken
                leagueRefreshTask = Task(priority: .utility) { [weak self] in
                    guard let self else { return }
                    let refreshedLeagues = await self.fetchTrackedLeagueStandings(
                        trackedLeagues: normalizedTrackedLeagues,
                        managerEntryID: entryID,
                        managerProfile: myProfile
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
            if Self.isCancellationError(error) {
                logPerf("refresh_cancelled entry_id=\(entryID)")
                return
            }
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

    func prepareInitialSetup(managerEntryID: String) async throws -> FantasyInitialSetupPayload {
        let trimmedManagerID = managerEntryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let entryID = Int(trimmedManagerID), entryID > 0 else {
            throw RivalValidationError.invalidNumber
        }

        let managerProfile = try await fantasyPublicClient.fetchEntryProfile(entryID: entryID)
        let trackedLeagues = deduplicatedTrackedLeagues(
            trackedLeagues: (managerProfile.leagues?.classic ?? []).map { FantasyTrackedLeague(leagueID: $0.id) }
        )
        let rivalCandidates = try await buildSetupRivalCandidates(
            managerEntryID: entryID,
            managerProfile: managerProfile
        )

        return FantasyInitialSetupPayload(
            managerProfile: managerProfile,
            trackedLeagues: trackedLeagues,
            rivalCandidates: rivalCandidates
        )
    }

    func loadLeagueStandingDetails(
        leagueID: Int,
        managerEntryID: String
    ) async throws -> FantasyTrackedLeagueStanding {
        let trimmedManagerID = managerEntryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let entryID = Int(trimmedManagerID), entryID > 0 else {
            throw LeagueValidationError.missingManager
        }
        return try await fetchLeagueStandingSnapshot(leagueID: leagueID, managerEntryID: entryID)
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
        gameweekID: Int,
        apiBaseURL: String
    ) async throws -> FantasyTransferRecommendationsResponse {
        guard let baseURL = URL(string: apiBaseURL) else {
            throw FantasyPublicAPIError.invalidURL
        }

        let cacheKey = "\(baseURL.absoluteString)|\(gameweekID)|\(elementID)"
        let now = Date()
        if let cached = cachedTransferRecommendations[cacheKey],
           now.timeIntervalSince(cached.fetchedAt) < transferRecommendationsCacheTTL {
            let age = Int(now.timeIntervalSince(cached.fetchedAt))
            logPerf("transfer_recommendations_cache_hit element_id=\(elementID) gameweek_id=\(gameweekID) age_s=\(age)")
            return cached.payload
        }

        let serverClient = APIClient(baseURL: baseURL)
        let response = try await timed("transfer_recommendations element_id=\(elementID)") {
            try await serverClient.fetchFantasyTransferRecommendations(elementID: elementID)
        }
        cachedTransferRecommendations[cacheKey] = (payload: response, fetchedAt: now)
        return response
    }

    func fetchAssistantManager(
        entryID: Int,
        apiBaseURL: String,
        forceRefresh: Bool = false
    ) async throws -> FantasyAssistantManagerResponse {
        let response = try await loadAssistantManagerResponse(
            entryID: entryID,
            apiBaseURL: apiBaseURL,
            forceRefresh: forceRefresh
        )
        if isFreshAssistantManagerResponse(response) {
            assistantManagerPreview = response
            rebuildMatchRowContext()
        }
        return response
    }

    private func loadAssistantManagerResponse(
        entryID: Int,
        apiBaseURL: String,
        forceRefresh: Bool = false
    ) async throws -> FantasyAssistantManagerResponse {
        guard let baseURL = URL(string: apiBaseURL) else {
            throw FantasyPublicAPIError.invalidURL
        }

        let cacheKey = "\(baseURL.absoluteString)|assistant|\(entryID)"
        let now = Date()
        if !forceRefresh,
           let cached = cachedAssistantManagerResponses[cacheKey],
           now.timeIntervalSince(cached.fetchedAt) < assistantManagerCacheTTL {
            let age = Int(now.timeIntervalSince(cached.fetchedAt))
            logPerf("assistant_manager_cache_hit entry_id=\(entryID) age_s=\(age)")
            return cached.payload
        }

        let serverClient = APIClient(baseURL: baseURL)
        let response = try await timed("assistant_manager entry_id=\(entryID)") {
            try await serverClient.fetchFantasyAssistantManager(entryID: entryID)
        }
        if isFreshAssistantManagerResponse(response) {
            cachedAssistantManagerResponses[cacheKey] = (payload: response, fetchedAt: now)
        } else {
            cachedAssistantManagerResponses.removeValue(forKey: cacheKey)
        }
        return response
    }

    private func syncAssistantManagerResponse(
        entryID: Int,
        apiBaseURL: String
    ) async throws -> FantasyAssistantManagerResponse {
        guard let baseURL = URL(string: apiBaseURL) else {
            throw FantasyPublicAPIError.invalidURL
        }

        let cacheKey = "\(baseURL.absoluteString)|assistant|\(entryID)"
        let serverClient = APIClient(baseURL: baseURL)
        let response = try await timed("assistant_manager_sync entry_id=\(entryID)") {
            try await serverClient.syncFantasyAssistantManager(entryID: entryID)
        }
        if isFreshAssistantManagerResponse(response) {
            cachedAssistantManagerResponses[cacheKey] = (payload: response, fetchedAt: Date())
        } else {
            cachedAssistantManagerResponses.removeValue(forKey: cacheKey)
        }
        return response
    }

    func prewarmAssistantManagerCache(
        entryID: Int,
        apiBaseURL: String,
        force: Bool = false
    ) async {
        guard let baseURL = URL(string: apiBaseURL) else { return }

        let cacheKey = "\(baseURL.absoluteString)|assistant|\(entryID)"
        let now = Date()
        if !force,
           let startedAt = assistantManagerSyncStartedAtByKey[cacheKey],
           now.timeIntervalSince(startedAt) < assistantManagerSyncCooldown {
            return
        }

        assistantManagerSyncStartedAtByKey[cacheKey] = now
        let serverClient = APIClient(baseURL: baseURL)

        do {
            let response = try await timed("assistant_manager_sync entry_id=\(entryID)") {
                try await serverClient.syncFantasyAssistantManager(entryID: entryID)
            }
            if isFreshAssistantManagerResponse(response) {
                cachedAssistantManagerResponses[cacheKey] = (payload: response, fetchedAt: Date())
                assistantManagerPreview = response
                rebuildMatchRowContext()
            } else {
                cachedAssistantManagerResponses.removeValue(forKey: cacheKey)
            }
        } catch {
            logPerf("assistant_manager_sync_failed entry_id=\(entryID) error=\"\(error.localizedDescription)\"")
        }
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

    private func fetchNextGameweekIfNeeded(
        currentGameweek: FantasyGameweek,
        serverClient: APIClient
    ) async -> FantasyGameweek? {
        guard currentGameweek.finished == true else {
            return nil
        }

        do {
            return try await timed("next_gameweek") {
                try await serverClient.fetchFantasyNextGameweek()
            }
        } catch {
            return nil
        }
    }

    private func fetchSquadSnapshot(
        entryID: Int,
        gameweek: FantasyGameweek,
        labelPrefix: String
    ) async throws -> FantasySquadSnapshot {
        async let picksTask = timed("\(labelPrefix)_picks entry_id=\(entryID) event_id=\(gameweek.id)") {
            try await fantasyPublicClient.fetchPicks(
                entryID: entryID,
                eventID: gameweek.id
            )
        }
        async let liveTask = timed("\(labelPrefix)_live event_id=\(gameweek.id)") {
            try await fantasyPublicClient.fetchEventLive(eventID: gameweek.id)
        }
        async let fixturesTask = timed("\(labelPrefix)_fixtures event_id=\(gameweek.id)") {
            try await fantasyPublicClient.fetchEventFixtures(eventID: gameweek.id)
        }

        let (picksResponse, liveResponse, fixtures) = try await (
            picksTask,
            liveTask,
            fixturesTask
        )
        return FantasySquadSnapshot(
            gameweek: gameweek,
            picksResponse: picksResponse,
            liveResponse: liveResponse,
            fixtures: fixtures
        )
    }

    private func fetchSquadSnapshotWithFallback(
        entryID: Int,
        preferredGameweek: FantasyGameweek,
        fallbackGameweek: FantasyGameweek?,
        labelPrefix: String
    ) async throws -> FantasySquadSnapshot {
        do {
            return try await fetchSquadSnapshot(
                entryID: entryID,
                gameweek: preferredGameweek,
                labelPrefix: labelPrefix
            )
        } catch {
            guard shouldFallbackToCurrentGameweek(
                after: error,
                preferredGameweek: preferredGameweek,
                fallbackGameweek: fallbackGameweek
            ), let fallbackGameweek else {
                throw error
            }

            logPerf(
                "squad_gameweek_fallback entry_id=\(entryID) preferred=\(preferredGameweek.id) fallback=\(fallbackGameweek.id)"
            )
            return try await fetchSquadSnapshot(
                entryID: entryID,
                gameweek: fallbackGameweek,
                labelPrefix: labelPrefix
            )
        }
    }

    private func shouldFallbackToCurrentGameweek(
        after error: Error,
        preferredGameweek: FantasyGameweek,
        fallbackGameweek: FantasyGameweek?
    ) -> Bool {
        guard let fallbackGameweek, fallbackGameweek.id != preferredGameweek.id else {
            return false
        }
        guard let fantasyError = error as? FantasyPublicAPIError else {
            return false
        }

        if case let .badStatus(statusCode, operation, _) = fantasyError,
           statusCode == 404,
           operation == "fpl_picks" {
            return true
        }

        return false
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
            if Task.isCancelled { break }
            do {
                let rivalProfile = await fetchMyProfile(entryID: rival.entryID)
                if Task.isCancelled { break }
                let rivalPicks = try await timed("rival_picks entry_id=\(rival.entryID)") {
                    try await fantasyPublicClient.fetchPicks(
                        entryID: rival.entryID,
                        eventID: gameweek.id
                    )
                }
                if Task.isCancelled { break }
                let rivalSquad = await buildSquadDisplayData(
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
                        clubBadgeSrc: rivalProfile?.clubBadgeSrc ?? rival.clubBadgeSrc,
                        squad: rivalSquad,
                        allGameweeksPoints: rivalProfile?.summaryOverallPoints ?? rival.overallPoints,
                        projectedGameweekPoints: nil,
                        expectedPointsSection: nil,
                        isExpectedPointsLoading: true
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

    private func populateRivalExpectedPoints(
        apiBaseURL: String,
        refreshToken: UUID
    ) async {
        let rivalsSnapshot = rivalSquads

        for rival in rivalsSnapshot {
            if Task.isCancelled { return }
            guard rivalRefreshToken == refreshToken else { return }

            let response: FantasyAssistantManagerResponse?
            do {
                let loaded = try await loadAssistantManagerResponse(
                    entryID: rival.entryID,
                    apiBaseURL: apiBaseURL,
                    forceRefresh: false
                )
                if loaded.ready {
                    response = loaded
                } else {
                    let synced = try? await syncAssistantManagerResponse(
                        entryID: rival.entryID,
                        apiBaseURL: apiBaseURL
                    )
                    response = synced?.ready == true ? synced : nil
                }
            } catch {
                response = nil
            }

            if Task.isCancelled { return }
            guard rivalRefreshToken == refreshToken else { return }
            guard let index = rivalSquads.firstIndex(where: { $0.entryID == rival.entryID }) else { continue }

            let projectedGameweekPoints = response?.expectedPoints.map { section in
                rivalSquads[index].squad.projectedGameweekPoints(using: section)
            }
            let updated = FantasyRivalSquad(
                entryID: rivalSquads[index].entryID,
                teamName: rivalSquads[index].teamName,
                managerName: rivalSquads[index].managerName,
                clubBadgeSrc: rivalSquads[index].clubBadgeSrc,
                squad: rivalSquads[index].squad,
                allGameweeksPoints: rivalSquads[index].allGameweeksPoints,
                projectedGameweekPoints: projectedGameweekPoints,
                expectedPointsSection: response?.expectedPoints,
                isExpectedPointsLoading: projectedGameweekPoints == nil
            )
            rivalSquads[index] = updated
        }
    }

    private func fetchTrackedLeagueStandings(
        trackedLeagues: [FantasyTrackedLeague],
        managerEntryID: Int,
        managerProfile: FantasyEntryProfile?
    ) async -> [FantasyTrackedLeagueStanding] {
        var snapshots: [FantasyTrackedLeagueStanding] = []
        let leagueMetadataByID = Dictionary(
            uniqueKeysWithValues: (managerProfile?.leagues?.classic ?? []).map { ($0.id, $0) }
        )

        for trackedLeague in trackedLeagues {
            if Task.isCancelled { break }
            guard let leagueMetadata = leagueMetadataByID[trackedLeague.leagueID] else {
                continue
            }

            var standings: [FantasyClassicLeagueStandingEntry] = []
            if leagueMetadata.leagueType == "x" {
                do {
                    standings = try await fetchLeagueStandingWindow(
                        leagueID: leagueMetadata.id,
                        aroundRank: leagueMetadata.resolvedEntryRank,
                        pageWindowRadius: trackedLeaguePageWindowRadius
                    )
                } catch {
                    standings = []
                }
            }

            snapshots.append(
                trackedLeagueStanding(
                    from: leagueMetadata,
                    managerEntryID: managerEntryID,
                    standings: standings
                )
            )
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
            standings: response.standings.results,
            leagueType: nil,
            rankCount: response.standings.results.count
        )
    }

    private func trackedLeagueStanding(
        from league: FantasyEntryClassicLeague,
        managerEntryID: Int,
        standings: [FantasyClassicLeagueStandingEntry]
    ) -> FantasyTrackedLeagueStanding {
        let myStandingEntry = standings.first(where: { $0.entry == managerEntryID })
        return FantasyTrackedLeagueStanding(
            leagueID: league.id,
            leagueName: league.name,
            myEntryID: managerEntryID,
            myRank: myStandingEntry?.rank ?? league.resolvedEntryRank,
            myLastRank: myStandingEntry?.lastRank ?? league.resolvedEntryLastRank,
            myEventTotal: myStandingEntry?.eventTotal,
            myOverallTotal: myStandingEntry?.total ?? league.resolvedTotalPoints,
            myEntryName: myStandingEntry?.entryName,
            standings: standings,
            leagueType: league.leagueType,
            rankCount: league.rankCount
        )
    }

    private func buildSetupRivalCandidates(
        managerEntryID: Int,
        managerProfile: FantasyEntryProfile
    ) async throws -> [FantasySetupRivalCandidate] {
        let playerCreatedLeagues = (managerProfile.leagues?.classic ?? [])
            .filter { $0.leagueType == "x" }
        guard !playerCreatedLeagues.isEmpty else { return [] }

        var candidatesByEntryID: [Int: SetupRivalAccumulator] = [:]

        for league in playerCreatedLeagues {
            let standings: [FantasyClassicLeagueStandingEntry]
            do {
                standings = try await fetchLeagueStandingWindow(
                    leagueID: league.id,
                    aroundRank: league.resolvedEntryRank,
                    pageWindowRadius: setupRivalPageWindowRadius
                )
            } catch {
                continue
            }
            let managerRank = standings.first(where: { $0.entry == managerEntryID })?.rank
                ?? league.resolvedEntryRank
            for standing in standings {
                guard standing.entry != managerEntryID else { continue }
                let rankGap = {
                    guard let managerRank else { return Int.max }
                    return abs(standing.rank - managerRank)
                }()
                if let existing = candidatesByEntryID[standing.entry] {
                    candidatesByEntryID[standing.entry] = existing.merged(with: standing, rankGap: rankGap)
                } else {
                    candidatesByEntryID[standing.entry] = SetupRivalAccumulator(
                        entryID: standing.entry,
                        teamName: standing.entryName,
                        managerName: standing.playerName,
                        totalPoints: standing.total,
                        eventPoints: standing.eventTotal,
                        clubBadgeSrc: standing.clubBadgeSrc,
                        sharedLeagueCount: 1,
                        closestRankGap: rankGap
                    )
                }
            }
        }

        return candidatesByEntryID.values
            .map(\.candidate)
            .sorted { lhs, rhs in
                if lhs.closestRankGap != rhs.closestRankGap {
                    return lhs.closestRankGap < rhs.closestRankGap
                }
                if lhs.sharedLeagueCount != rhs.sharedLeagueCount {
                    return lhs.sharedLeagueCount > rhs.sharedLeagueCount
                }
                if lhs.totalPoints != rhs.totalPoints {
                    return lhs.totalPoints > rhs.totalPoints
                }
                let leftManager = lhs.managerName.trimmingCharacters(in: .whitespacesAndNewlines)
                let rightManager = rhs.managerName.trimmingCharacters(in: .whitespacesAndNewlines)
                if leftManager.localizedCaseInsensitiveCompare(rightManager) != .orderedSame {
                    return leftManager.localizedCaseInsensitiveCompare(rightManager) == .orderedAscending
                }
                let leftTeam = lhs.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
                let rightTeam = rhs.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
                if leftTeam.localizedCaseInsensitiveCompare(rightTeam) != .orderedSame {
                    return leftTeam.localizedCaseInsensitiveCompare(rightTeam) == .orderedAscending
                }
                return lhs.entryID < rhs.entryID
            }
            .prefix(setupRivalCandidateLimit)
            .map { $0 }
    }

    private func fetchLeagueStandingWindow(
        leagueID: Int,
        aroundRank: Int?,
        pageWindowRadius: Int
    ) async throws -> [FantasyClassicLeagueStandingEntry] {
        let targetPage = page(forRank: aroundRank)
        let pageRange = max(1, targetPage - pageWindowRadius)...max(1, targetPage + pageWindowRadius)
        var combinedResults: [FantasyClassicLeagueStandingEntry] = []

        for page in pageRange {
            let response = try await timed("league_standings league_id=\(leagueID) page=\(page)") {
                try await fantasyPublicClient.fetchLeagueStandings(leagueID: leagueID, page: page)
            }
            combinedResults.append(contentsOf: response.standings.results)
            if !response.standings.hasNext {
                break
            }
        }

        var seen = Set<Int>()
        return combinedResults.filter { entry in
            guard !seen.contains(entry.entry) else { return false }
            seen.insert(entry.entry)
            return true
        }
    }

    private func buildSquadDisplayData(
        gameweek: FantasyGameweek,
        picksResponse: FantasyPicksResponse,
        liveResponse: FantasyEventLiveResponse,
        fixtures: [FantasyFixture],
        seasonFixtures: [FantasyFixture],
        bootstrap: FantasyBootstrapLookup
    ) async -> FantasySquadDisplayData {
        let input = DetachedBox(
            value: (
                gameweek,
                picksResponse,
                liveResponse,
                fixtures,
                seasonFixtures,
                bootstrap
            )
        )
        return await Task.detached(priority: .utility) {
            let (
                gameweek,
                picksResponse,
                liveResponse,
                fixtures,
                seasonFixtures,
                bootstrap
            ) = input.value
            return FantasySquadBuilder.build(
                gameweek: gameweek,
                picksResponse: picksResponse,
                liveResponse: liveResponse,
                fixtures: fixtures,
                seasonFixtures: seasonFixtures,
                bootstrap: bootstrap
            )
        }.value
    }

    private func page(forRank rank: Int?) -> Int {
        guard let rank, rank > 0 else { return 1 }
        return max(1, Int(ceil(Double(rank) / Double(leagueStandingsPageSize))))
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
            if Self.bootstrapLookupHasUsablePlayerCosts(cachedBootstrapLookup) {
                let age = Int(now.timeIntervalSince(cachedBootstrapFetchedAt))
                logPerf("bootstrap_lookup_cache_hit age_s=\(age)")
                return cachedBootstrapLookup
            }
            logPerf("bootstrap_lookup_cache_invalidated reason=missing_player_costs")
            self.cachedBootstrapLookup = nil
            self.cachedBootstrapFetchedAt = nil
            rebuildMatchRowContext()
        }

        var lookup = try await timed("bootstrap_lookup_fetch") {
            try await serverClient.fetchFantasyBootstrapLookup()
        }
        if !Self.bootstrapLookupHasUsablePlayerCosts(lookup) {
            logPerf("bootstrap_lookup_missing_costs fallback=bootstrap_static")
            lookup = try await timed("bootstrap_static_fallback_fetch") {
                try await fantasyPublicClient.fetchBootstrapStatic()
            }
        }
        cachedBootstrapLookup = lookup
        cachedBootstrapFetchedAt = now
        cachedBootstrapBaseURL = baseURLKey
        rebuildMatchRowContext()
        return lookup
    }

    private static func bootstrapLookupHasUsablePlayerCosts(_ lookup: FantasyBootstrapLookup) -> Bool {
        lookup.elements.contains { element in
            if let nowCost = element.nowCost {
                return nowCost > 0
            }
            return false
        }
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

    private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        return false
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
