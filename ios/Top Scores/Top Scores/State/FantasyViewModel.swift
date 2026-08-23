import Foundation
import Combine
import os

@MainActor
final class FantasyViewModel: ObservableObject {
    private static let gameUpdatingUserMessage = "Fantasy Premier League data is temporarily unavailable while the official game is being updated. Please try again in a few minutes."

    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var data: FantasySquadDisplayData?
    @Published private(set) var previousTeamData: FantasySquadDisplayData?
    @Published private(set) var rivalSquads: [FantasyRivalSquad] = []
    @Published private(set) var trackedLeagueStandings: [FantasyTrackedLeagueStanding] = []
    @Published private(set) var myProfile: FantasyEntryProfile?
    @Published private(set) var lastUpdated: Date?
    // Whether the Premier League season is currently active, per the server's daily
    // bsd_leagues check. Gates the bottom-nav FPL badge so it doesn't show outside
    // the season. Defaults to false until the server/cache confirms the season.
    @Published private(set) var isSeasonActive = false
    @Published private(set) var requiresAuthentication = false
    @Published private(set) var authenticatedEntryID: Int?
    @Published var errorMessage: String?
    /// Pre-computed context for MatchRow. Updated whenever squad data, expected points, or the
    /// bootstrap lookup changes. MatchRow observes this value rather than the whole FantasyViewModel,
    /// so rows only re-render when fantasy data actually changes (not on isLoading / isRefreshing etc).
    @Published private(set) var matchRowContext: FantasyMatchRowContext = .empty

    private var matchRowContextVersion = 0

    private let fantasyPublicClient = FantasyPublicAPIClient()
    private let fantasyAuthenticatedClient = FantasyAuthenticatedAPIClient()
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
    private let seasonActiveCacheTTL: TimeInterval = 24 * 60 * 60
    private let seasonActiveDefaultsKey = "fantasy.seasonActive.events.value"
    private let seasonActiveCheckedAtDefaultsKey = "fantasy.seasonActive.events.checkedAt"
    private var rivalRefreshToken = UUID()
    private var leagueRefreshToken = UUID()
    private var rivalRefreshTask: Task<Void, Never>?
    private var leagueRefreshTask: Task<Void, Never>?
    private var assistantManagerPrewarmTask: Task<Void, Never>?
    private var detailedExpectedPointsTask: Task<Void, Never>?
    private var currentSquadSnapshot: FantasySquadSnapshot?
    private var currentSquadBootstrap: FantasyBootstrapLookup?
    private var currentSquadSeasonFixtures: [FantasyFixture] = []
    private var isRefreshingCurrentScores = false
    private let trackedLeaguePageWindowRadius = 1
    private let setupRivalPageWindowRadius = 1
    private let leagueStandingsPageSize = 50
    private let setupRivalCandidateLimit = 200

    var isShowingGameUpdatingState: Bool {
        guard let errorMessage else { return false }
        return Self.containsGameUpdatingText(errorMessage)
    }

    func playerProfileImageURL(for elementID: Int) -> URL? {
        let code = cachedBootstrapLookup?.elements.first(where: { $0.id == elementID })?.playerCode
        return FantasyPlayerProfileImageURL.make(fromPlayerCode: code)
    }

    func refreshSeasonActiveStatus(apiBaseURL: String) async {
        guard let baseURL = URL(string: apiBaseURL) else {
            isSeasonActive = false
            return
        }
        await refreshSeasonActiveIfNeeded(serverClient: APIClient(baseURL: baseURL))
    }

    func refreshInBackground(
        managerEntryID: String,
        apiBaseURL: String,
        rivalManagers: [FantasyRivalManager],
        trackedLeagues: [FantasyTrackedLeague]
    ) async {
        guard !isLoading, !isRefreshing else { return }
        await refresh(
            managerEntryID: managerEntryID,
            apiBaseURL: apiBaseURL,
            rivalManagers: rivalManagers,
            trackedLeagues: trackedLeagues
        )
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
        previousTeamData = nil
        rivalSquads = []
        trackedLeagueStandings = []
        myProfile = nil
        lastUpdated = nil
        requiresAuthentication = false
        authenticatedEntryID = nil
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
        currentSquadSnapshot = nil
        currentSquadBootstrap = nil
        currentSquadSeasonFixtures = []
        isRefreshingCurrentScores = false
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
        detailedExpectedPointsTask?.cancel()
        detailedExpectedPointsTask = nil
    }

    /// Rebuilds the pre-computed FantasyMatchRowContext published to MatchRow.
    /// Must be called whenever squad data or the bootstrap lookup changes.
    private func rebuildMatchRowContext() {
        matchRowContextVersion += 1
        let expectedPoints = buildExpectedPointsDictionary()
        let lookup = FantasySquadMembershipLookup(squad: data, expectedPointsByElementID: expectedPoints)
        let eligibleKeys = Set(
            (cachedBootstrapLookup?.teams ?? []).flatMap {
                fantasyTeamLookupKeys($0.name)
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
        guard let squad = data else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: squad.allPlayers.compactMap { player in
                guard player.hasRemainingFixtureThisGameweek,
                      let expectedPoints = player.expectedPointsThisGameweek else {
                    return nil
                }
                return (player.elementID, Int(expectedPoints.rounded()))
            }
        )
    }

    private func isFreshAssistantManagerResponse(_ response: FantasyAssistantManagerResponse?) -> Bool {
        guard let response else { return false }
        return response.ready && response.stale != true
    }

    var currentSquadProjectedGameweekPoints: Double? {
        data?.detailedExpectedPointsThisGameweek
    }

    var automaticScoreRefreshMinimumInterval: TimeInterval {
        guard let data, let snapshot = currentSquadSnapshot else { return 15 * 60 }
        if data.hasActiveFixtures { return 30 }
        if data.scorePhase == .provisional {
            let hasUpcomingRelevantFixture = snapshot.fixtures.contains { fixture in
                guard fixture.started != true,
                      fixture.finished != true,
                      fixture.finishedProvisional != true else {
                    return false
                }
                return squadTeamIDs(in: snapshot).contains(fixture.teamH) ||
                    squadTeamIDs(in: snapshot).contains(fixture.teamA)
            }
            return hasUpcomingRelevantFixture ? 5 * 60 : 60
        }

        let now = Date()
        let nextKickoff = snapshot.fixtures
            .filter { fixture in
                guard fixture.started != true,
                      fixture.finished != true,
                      fixture.finishedProvisional != true else {
                    return false
                }
                let teamIDs = squadTeamIDs(in: snapshot)
                return teamIDs.contains(fixture.teamH) || teamIDs.contains(fixture.teamA)
            }
            .compactMap { Self.parseISO8601Date($0.kickoffTime) }
            .filter { $0 > now }
            .min()

        guard let nextKickoff else { return 15 * 60 }
        return min(15 * 60, max(30, nextKickoff.timeIntervalSince(now)))
    }

    /// Refreshes the locked active-gameweek picks, fixture state, and official live points
    /// without repeating profile, rival, league, or authenticated-team work.
    /// Returns true when FPL has just confirmed the gameweek via `data_checked`.
    func refreshCurrentScores() async -> Bool {
        guard !isLoading, !isRefreshing, !isRefreshingCurrentScores,
              let snapshot = currentSquadSnapshot,
              let entryID = authenticatedEntryID,
              currentSquadBootstrap != nil else {
            return false
        }

        isRefreshingCurrentScores = true
        defer { isRefreshingCurrentScores = false }

        do {
            let refreshedBootstrap = try await timed("current_score_bootstrap") {
                try await fantasyPublicClient.fetchBootstrapStatic()
            }
            let refreshedGameweek = refreshedBootstrap.events.first(where: { $0.id == snapshot.gameweek.id })
                ?? snapshot.gameweek
            let previousDataChecked = snapshot.gameweek.dataChecked == true

            let refreshedPicks: FantasyPicksResponse
            let refreshedLive: FantasyEventLiveResponse
            let refreshedFixtures: [FantasyFixture]
            if refreshedGameweek.isCurrent == true || refreshedGameweek.dataChecked == true {
                async let picksTask = fantasyPublicClient.fetchPicks(
                    entryID: entryID,
                    eventID: refreshedGameweek.id
                )
                async let liveTask = fantasyPublicClient.fetchEventLive(eventID: refreshedGameweek.id)
                async let fixturesTask = fantasyPublicClient.fetchEventFixtures(eventID: refreshedGameweek.id)
                (refreshedPicks, refreshedLive, refreshedFixtures) = try await (
                    picksTask,
                    liveTask,
                    fixturesTask
                )
            } else {
                refreshedPicks = snapshot.picksResponse
                refreshedLive = FantasyEventLiveResponse(elements: [])
                refreshedFixtures = try await fantasyPublicClient.fetchEventFixtures(
                    eventID: refreshedGameweek.id
                )
            }

            let mergedSeasonFixtures = Self.mergingFixtures(
                refreshedFixtures,
                into: currentSquadSeasonFixtures
            )
            let refreshedData = await buildSquadDisplayData(
                gameweek: refreshedGameweek,
                picksResponse: refreshedPicks,
                liveResponse: refreshedLive,
                fixtures: refreshedFixtures,
                seasonFixtures: mergedSeasonFixtures,
                bootstrap: refreshedBootstrap
            )

            currentSquadSnapshot = FantasySquadSnapshot(
                gameweek: refreshedGameweek,
                picksResponse: refreshedPicks,
                liveResponse: refreshedLive,
                fixtures: refreshedFixtures
            )
            currentSquadBootstrap = refreshedBootstrap
            currentSquadSeasonFixtures = mergedSeasonFixtures
            cachedBootstrapLookup = refreshedBootstrap
            cachedBootstrapFetchedAt = Date()
            cachedSeasonFixtures = mergedSeasonFixtures
            cachedSeasonFixturesFetchedAt = Date()
            data = refreshedData
            lastUpdated = Date()
            rebuildMatchRowContext()
            errorMessage = nil

            return !previousDataChecked && refreshedGameweek.dataChecked == true
        } catch {
            if !Self.isCancellationError(error) {
                logPerf("current_score_refresh_failed error=\"\(error.localizedDescription)\"")
            }
            return false
        }
    }

    private func squadTeamIDs(in snapshot: FantasySquadSnapshot) -> Set<Int> {
        guard let bootstrap = currentSquadBootstrap else { return [] }
        let elementsByID = Dictionary(uniqueKeysWithValues: bootstrap.elements.map { ($0.id, $0) })
        return Set(snapshot.picksResponse.picks.compactMap { elementsByID[$0.element]?.team })
    }

    private static func mergingFixtures(
        _ refreshedFixtures: [FantasyFixture],
        into seasonFixtures: [FantasyFixture]
    ) -> [FantasyFixture] {
        let refreshedByID = Dictionary(uniqueKeysWithValues: refreshedFixtures.map { ($0.id, $0) })
        let refreshedIDs = Set(refreshedByID.keys)
        return seasonFixtures.filter { !refreshedIDs.contains($0.id) } + refreshedFixtures
    }

    private static func parseISO8601Date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    func isEligibleFantasyFixture(_ match: Match) -> Bool {
        guard match.league.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare("Premier League") == .orderedSame
        else {
            return false
        }

        let premierLeagueTeamKeys = Set(
            (cachedBootstrapLookup?.teams ?? []).flatMap { team in
                fantasyTeamLookupKeys(team.name)
            }
        )

        guard !premierLeagueTeamKeys.isEmpty else {
            return true
        }

        let homeTeamKeys = fantasyTeamLookupKeys(match.homeTeam)
        let awayTeamKeys = fantasyTeamLookupKeys(match.awayTeam)

        return !homeTeamKeys.isDisjoint(with: premierLeagueTeamKeys) &&
            !awayTeamKeys.isDisjoint(with: premierLeagueTeamKeys)
    }

    func refresh(
        managerEntryID: String,
        apiBaseURL: String,
        rivalManagers: [FantasyRivalManager],
        trackedLeagues: [FantasyTrackedLeague]
    ) async {
        let signpost = PerformanceSignposter.fantasy.beginInterval("FantasyRefresh")
        defer { PerformanceSignposter.fantasy.endInterval("FantasyRefresh", signpost) }

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
        requiresAuthentication = false

        defer {
            isLoading = false
            isRefreshing = false
        }

        do {
            cancelBackgroundRefreshWork()
            let serverClient = APIClient(baseURL: baseURL)
            logPerf("refresh_start entry_id=\(entryID) rivals=\(rivalManagers.count) leagues=\(trackedLeagues.count)")

            let bootstrapBaseURLKey = baseURL.absoluteString
            async let bootstrapLookupTask = fetchBootstrapLookup(
                serverClient: serverClient,
                baseURLKey: bootstrapBaseURLKey
            )
            async let seasonFixturesTask = fetchSeasonFixtures()
            async let seasonActiveTask: Void = refreshSeasonActiveIfNeeded(serverClient: serverClient)
            let currentTeamResult = try await timed("current_team entry_id=\(entryID)") {
                try await fantasyAuthenticatedClient.fetchCurrentTeam(entryID: entryID)
            }
            let activeEntryID = currentTeamResult.entryID
            async let myProfileTask = fetchMyProfile(entryID: activeEntryID)

            let (bootstrapLookup, myProfile, seasonFixtures, _) = try await (
                bootstrapLookupTask,
                myProfileTask,
                seasonFixturesTask,
                seasonActiveTask
            )
            self.myProfile = myProfile

            let currentTeamGameweek = resolvedCurrentTeamGameweek(events: bootstrapLookup.events)
            let currentSnapshot: FantasySquadSnapshot
            if currentTeamGameweek.isCurrent == true && currentTeamGameweek.dataChecked != true {
                currentSnapshot = try await fetchSquadSnapshot(
                    entryID: activeEntryID,
                    gameweek: currentTeamGameweek,
                    labelPrefix: "current"
                )
            } else {
                currentSnapshot = FantasySquadSnapshot(
                    gameweek: currentTeamGameweek,
                    picksResponse: currentTeamResult.team.asPicksResponse(eventID: currentTeamGameweek.id),
                    liveResponse: FantasyEventLiveResponse(elements: []),
                    fixtures: seasonFixtures.filter { $0.event == currentTeamGameweek.id }
                )
            }
            let mergedSeasonFixtures = Self.mergingFixtures(
                currentSnapshot.fixtures,
                into: seasonFixtures
            )
            data = await buildSquadDisplayData(
                gameweek: currentTeamGameweek,
                picksResponse: currentSnapshot.picksResponse,
                liveResponse: currentSnapshot.liveResponse,
                fixtures: currentSnapshot.fixtures,
                seasonFixtures: mergedSeasonFixtures,
                bootstrap: bootstrapLookup
            )
            currentSquadSnapshot = currentSnapshot
            currentSquadBootstrap = bootstrapLookup
            currentSquadSeasonFixtures = mergedSeasonFixtures
            rebuildMatchRowContext()
            detailedExpectedPointsTask?.cancel()
            detailedExpectedPointsTask = Task(priority: .utility) { [weak self] in
                guard let self else { return }
                await self.populateDetailedExpectedPoints(
                    gameweekID: currentTeamGameweek.id,
                    apiBaseURL: apiBaseURL
                )
            }

            let previousSnapshot: FantasySquadSnapshot?
            if let previousGameweek = FantasyTeamGameweekResolver.previousTeamGameweek(
                from: bootstrapLookup.events
            ) {
                do {
                    let snapshot = try await fetchSquadSnapshot(
                        entryID: activeEntryID,
                        gameweek: previousGameweek,
                        labelPrefix: "previous"
                    )
                    previousTeamData = await buildSquadDisplayData(
                        gameweek: snapshot.gameweek,
                        picksResponse: snapshot.picksResponse,
                        liveResponse: snapshot.liveResponse,
                        fixtures: snapshot.fixtures,
                        seasonFixtures: mergedSeasonFixtures,
                        bootstrap: bootstrapLookup
                    )
                    previousSnapshot = snapshot
                } catch {
                    logPerf("previous_team_unavailable error=\"\(error.localizedDescription)\"")
                    previousTeamData = nil
                    previousSnapshot = nil
                }
            } else {
                previousTeamData = nil
                previousSnapshot = nil
            }

            let normalizedRivals = deduplicatedRivals(
                rivalManagers: rivalManagers,
                excludingEntryID: activeEntryID
            )
            if normalizedRivals.isEmpty || previousSnapshot == nil {
                rivalSquads = []
            } else if let previousSnapshot {
                let refreshToken = UUID()
                rivalRefreshToken = refreshToken
                rivalRefreshTask = Task(priority: .utility) { [weak self] in
                    guard let self else { return }
                    let refreshedRivals = await self.fetchRivalSquads(
                        rivals: normalizedRivals,
                        gameweek: previousSnapshot.gameweek,
                        liveResponse: previousSnapshot.liveResponse,
                        fixtures: previousSnapshot.fixtures,
                        seasonFixtures: mergedSeasonFixtures,
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
                        managerEntryID: activeEntryID,
                        managerProfile: myProfile
                    )
                    guard self.leagueRefreshToken == refreshToken else { return }
                    self.trackedLeagueStandings = refreshedLeagues
                    self.logPerf("leagues_complete count=\(refreshedLeagues.count)")
                }
            }
            lastUpdated = Date()
            errorMessage = nil
            requiresAuthentication = false
            authenticatedEntryID = activeEntryID
            let totalDurationMs = Date().timeIntervalSince(refreshStartedAt) * 1000
            logPerf("refresh_complete entry_id=\(activeEntryID) rivals_loaded=\(rivalSquads.count) duration_ms=\(Int(totalDurationMs))")
        } catch {
            if Self.isCancellationError(error) {
                logPerf("refresh_cancelled entry_id=\(entryID)")
                return
            }
            let totalDurationMs = Date().timeIntervalSince(refreshStartedAt) * 1000
            logPerf("refresh_failed entry_id=\(entryID) duration_ms=\(Int(totalDurationMs)) error=\"\(error.localizedDescription)\"")
            if let fantasyError = error as? FantasyPublicAPIError,
               case .authenticationRequired = fantasyError {
                requiresAuthentication = true
            }
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

    private func populateDetailedExpectedPoints(
        gameweekID: Int,
        apiBaseURL: String
    ) async {
        guard let squad = data else { return }
        let playerIDs = squad.allPlayers
            .filter(\.hasRemainingFixtureThisGameweek)
            .map(\.elementID)

        guard !playerIDs.isEmpty else { return }

        var expectedPointsByElementID: [Int: Double] = [:]
        for elementID in playerIDs {
            guard !Task.isCancelled else { return }
            do {
                let details = try await loadPlayerDetails(
                    elementID: elementID,
                    gameweekID: gameweekID,
                    apiBaseURL: apiBaseURL
                )
                guard let fixtureIndex = details.upcomingFixtures.firstIndex(where: {
                    !$0.isBlank && $0.gameweek == gameweekID
                }) else {
                    continue
                }
                let fixture = details.upcomingFixtures[fixtureIndex]
                expectedPointsByElementID[elementID] = FantasyExpectedPointsEstimator.estimate(
                    details: details,
                    fixture: fixture,
                    fixtureIndex: fixtureIndex
                )
            } catch {
                logPerf("pitch_expected_points_unavailable element_id=\(elementID)")
            }
        }

        guard !Task.isCancelled,
              !expectedPointsByElementID.isEmpty,
              data?.gameweekID == squad.gameweekID else {
            return
        }
        data = squad.applyingExpectedPoints(expectedPointsByElementID)
        rebuildMatchRowContext()
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
            var response = try await timed("assistant_manager_sync entry_id=\(entryID)") {
                try await serverClient.syncFantasyAssistantManager(entryID: entryID)
            }

            // A sync can legitimately return while the server is still warming its
            // in-memory prediction cache. Poll the read endpoint briefly so the
            // current-team summary resolves instead of leaving its xP spinner up
            // until the next manual refresh.
            for _ in 0..<5 where !isFreshAssistantManagerResponse(response) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                response = try await timed("assistant_manager_poll entry_id=\(entryID)") {
                    try await serverClient.fetchFantasyAssistantManager(entryID: entryID)
                }
            }

            if isFreshAssistantManagerResponse(response) {
                cachedAssistantManagerResponses[cacheKey] = (payload: response, fetchedAt: Date())
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

    private func resolvedCurrentTeamGameweek(events: [FantasyGameweek]) -> FantasyGameweek {
        if let resolved = FantasyTeamGameweekResolver.currentTeamGameweek(from: events) {
            return resolved
        }

        return FantasyGameweek(
            id: 1,
            name: "Gameweek 1",
            isCurrent: false,
            isNext: true,
            finished: false,
            deadlineTime: nil
        )
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

    private func fetchRivalSquads(
        rivals: [FantasyRivalManager],
        gameweek: FantasyGameweek,
        liveResponse: FantasyEventLiveResponse,
        fixtures: [FantasyFixture],
        seasonFixtures: [FantasyFixture],
        bootstrapLookup: FantasyBootstrapLookup
    ) async -> [FantasyRivalSquad] {
        let signpost = PerformanceSignposter.fantasy.beginInterval("FantasyFetchRivalSquads")
        defer { PerformanceSignposter.fantasy.endInterval("FantasyFetchRivalSquads", signpost) }

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
        let signpost = PerformanceSignposter.fantasy.beginInterval("FantasyFetchTrackedLeagues")
        defer { PerformanceSignposter.fantasy.endInterval("FantasyFetchTrackedLeagues", signpost) }

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
        let gameweekCopy = gameweek
        let picksResponseCopy = picksResponse
        let liveResponseCopy = liveResponse
        let fixturesCopy = fixtures
        let seasonFixturesCopy = seasonFixtures
        let bootstrapCopy = bootstrap
        return await Task.detached(priority: .utility) {
            let signpost = PerformanceSignposter.fantasy.beginInterval("FantasyBuildSquadDisplayData")
            defer { PerformanceSignposter.fantasy.endInterval("FantasyBuildSquadDisplayData", signpost) }
            return FantasySquadBuilder.build(
                gameweek: gameweekCopy,
                picksResponse: picksResponseCopy,
                liveResponse: liveResponseCopy,
                fixtures: fixturesCopy,
                seasonFixtures: seasonFixturesCopy,
                bootstrap: bootstrapCopy
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

    // Best-effort: a stale or missing flag should never block the rest of the
    // fantasy refresh. The presentation fails closed until a fresh server check exists.
    private func refreshSeasonActiveIfNeeded(serverClient: APIClient) async {
        let defaults = UserDefaults.standard
        let now = Date()
        let checkedAt = defaults.object(forKey: seasonActiveCheckedAtDefaultsKey) as? Date
        if let checkedAt, now.timeIntervalSince(checkedAt) < seasonActiveCacheTTL {
            isSeasonActive = defaults.bool(forKey: seasonActiveDefaultsKey)
            return
        }

        do {
            let status = try await serverClient.fetchFantasySeasonActive()
            guard let serverCheckedAt = Self.parseSeasonStatusCheckedAt(status.checkedAt) else {
                isSeasonActive = false
                return
            }
            defaults.set(status.active, forKey: seasonActiveDefaultsKey)
            defaults.set(serverCheckedAt, forKey: seasonActiveCheckedAtDefaultsKey)
            isSeasonActive = status.active
        } catch {
            if let checkedAt, now.timeIntervalSince(checkedAt) < seasonActiveCacheTTL {
                isSeasonActive = defaults.bool(forKey: seasonActiveDefaultsKey)
            } else {
                isSeasonActive = false
            }
            logPerf("season_active_fetch_failed error=\(error)")
        }
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
            if Self.bootstrapLookupHasUsablePlayerCosts(cachedBootstrapLookup),
               Self.bootstrapLookupHasUsableExpectedPoints(cachedBootstrapLookup),
               Self.bootstrapLookupHasUsableGameweekStatus(cachedBootstrapLookup),
               !Self.bootstrapLookupNeedsFreshGameweekStatus(cachedBootstrapLookup) {
                let age = Int(now.timeIntervalSince(cachedBootstrapFetchedAt))
                logPerf("bootstrap_lookup_cache_hit age_s=\(age)")
                return cachedBootstrapLookup
            }
            logPerf("bootstrap_lookup_cache_invalidated reason=missing_player_costs_expected_points_or_gameweek_status")
            self.cachedBootstrapLookup = nil
            self.cachedBootstrapFetchedAt = nil
            rebuildMatchRowContext()
        }

        var lookup = try await timed("bootstrap_lookup_fetch") {
            try await serverClient.fetchFantasyBootstrapLookup()
        }
        if !Self.bootstrapLookupHasUsablePlayerCosts(lookup) ||
            !Self.bootstrapLookupHasUsableExpectedPoints(lookup) ||
            !Self.bootstrapLookupHasUsableGameweekStatus(lookup) ||
            Self.bootstrapLookupNeedsFreshGameweekStatus(lookup) {
            logPerf("bootstrap_lookup_incomplete fallback=bootstrap_static")
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

    private static func bootstrapLookupHasUsableExpectedPoints(_ lookup: FantasyBootstrapLookup) -> Bool {
        let hasCurrentProjection = lookup.elements.contains {
            Double($0.expectedPointsThisGameweek ?? "") != nil
        }
        let hasNextProjection = lookup.elements.contains {
            Double($0.expectedPointsNextGameweek ?? "") != nil
        }
        return hasCurrentProjection || hasNextProjection
    }

    private static func bootstrapLookupHasUsableGameweekStatus(_ lookup: FantasyBootstrapLookup) -> Bool {
        lookup.events.contains { $0.dataChecked != nil }
    }

    private static func bootstrapLookupNeedsFreshGameweekStatus(_ lookup: FantasyBootstrapLookup) -> Bool {
        lookup.events.contains { $0.isCurrent == true && $0.dataChecked != true }
    }

    private static func parseSeasonStatusCheckedAt(_ value: String?) -> Date? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: trimmed) {
            return date
        }
        return ISO8601DateFormatter().date(from: trimmed)
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
        diagnosticPrint("[FantasyPerf] \(message)")
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
