import Combine
import Foundation

@MainActor
final class PredictionGameStore: ObservableObject {
    static let enabledPreferenceKey = "predictionGame.enabled"

    @Published private(set) var enabled: Bool
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var isLoadingLeaderboard = false
    @Published private(set) var isSaving = false
    @Published private(set) var isConnectingGameCenter = false
    @Published private(set) var gameCenterStatusMessage: String?
    @Published private(set) var playerScopeID = UUID()
    @Published private(set) var playerDraftScopeID = UUID()
    @Published private(set) var privateLeagueScopeID = UUID()
    @Published var errorMessage: String?
    @Published var requiresGameCenterRestore = false
    @Published private(set) var player: PredictionGamePlayer?
    @Published private(set) var selectedCompetitionID = "1"
    @Published private(set) var availableCompetitions: [PredictionGameCompetition] = [.premierLeague]
    @Published private(set) var gameCenterLeaderboardID: String?
    @Published private(set) var summary: PredictionGameSummary = .empty
    @Published private(set) var history: [PredictionGameFixture] = []
    @Published private(set) var challenge: PredictionGameChallenge?
    @Published private(set) var fixtures: [String: PredictionGameFixture] = [:]
    @Published private(set) var achievements: [PredictionGameAchievement] = []
    @Published private(set) var seasons: [PredictionGameSeason] = []
    @Published private(set) var recentGameweeks: [PredictionGameRecentGameweek] = []
    @Published private(set) var latestResult: PredictionGameRecentGameweek?
    @Published private(set) var inPlayRound: PredictionGameInPlayRound?
    @Published private(set) var leaderboards: [PredictionGameLeaderboardRow] = []
    @Published private(set) var hasMoreHistory = false

    private let userDefaults: UserDefaults
    private let apiSession: URLSession
    private let credentialStorage: any PredictionGameCredentialStorage
    private let gameCenterFactory: @MainActor () -> any PredictionGameCenterServing
    private var configuredServer: String?
    private var sessionGeneration = UUID() { didSet { playerScopeID = sessionGeneration } }
    private var draftScopes: [String: UUID] = [:]
    private var credential: String?
    private var credentialTask: Task<String, Error>?
    private var dashboardRequestID: UUID?
    private var historyRequestID: UUID?
    private var leaderboardRequestID: UUID?
    private var historySeasonId: String?
    private var historyNextOffset = 0
    private var selectedSeasonId: String?
    private var competitionGeneration = UUID()
    private var fetchedAt: [String: Date] = [:]
    private var loadingFixtureIDs: Set<String> = []
    private var serverClockOffset: TimeInterval = 0
    private var linkedTeamPlayerID: String?
    private var privateSessionExpiresAt: Date?
    private var privateSessionTeamPlayerID: String?
    private var credentialTeamPlayerID: String?
    private var gameCenter: (any PredictionGameCenterServing)?
    private var gameCenterStateObservation: AnyCancellable?
    private var gameCenterConnectionTask: Task<Void, Never>?
    private var gameCenterLifecycleTask: Task<Void, Never>?
    private var gameCenterSyncTask: Task<Void, Never>?
    private var gameCenterSyncID: UUID?
    private var gameScreenVisible = false
    private var gamePresentationID = UUID()
    private var automaticGameCenterAttempt: String?
    private var automaticGameCenterServer: String?
    private var predictionEditingActive = false
    private struct PendingGameCenterRestore {
        let context: Session
        let response: PredictionGamePlayerResponse
        let teamPlayerID: String
        let apiBaseURL: String
    }
    private var pendingGameCenterRestore: PendingGameCenterRestore?
    private enum GameCenterDestination {
        case leaderboards(competitionID: String, leaderboardID: String)
        case achievements
    }
    private var pendingGameCenterDestination: GameCenterDestination?

    init(
        userDefaults: UserDefaults = .standard,
        apiSession: URLSession = .shared,
        credentialStorage: any PredictionGameCredentialStorage = PredictionGameCredentialStore(),
        gameCenterFactory: @escaping @MainActor () -> any PredictionGameCenterServing = { PredictionGameCenterService() }
    ) {
        self.userDefaults = userDefaults
        self.apiSession = apiSession
        self.credentialStorage = credentialStorage
        self.gameCenterFactory = gameCenterFactory
        playerScopeID = sessionGeneration
        enabled = userDefaults.bool(forKey: Self.enabledPreferenceKey)
    }

    var selectedCompetition: PredictionGameCompetition {
        availableCompetitions.first { $0.id == selectedCompetitionID }
            ?? PredictionGameCompetition(id: selectedCompetitionID,
                name: selectedCompetitionID == "1" ? "Premier League" : "Competition \(selectedCompetitionID)")
    }

    func selectCompetition(_ competitionID: String, apiBaseURL: String) async {
        guard Int(competitionID).map({ $0 > 0 }) == true, competitionID != selectedCompetitionID else { return }
        selectedCompetitionID = competitionID
        competitionGeneration = UUID()
        dashboardRequestID = nil
        historyRequestID = nil
        leaderboardRequestID = nil
        isLoading = false
        isLoadingHistory = false
        isLoadingLeaderboard = false
        pendingGameCenterDestination = nil
        clearCompetitionData()
        await loadDashboard(apiBaseURL: apiBaseURL)
    }

    func activate(apiBaseURL: String, loadDashboard: Bool = true) async {
        enabled = true
        userDefaults.set(true, forKey: Self.enabledPreferenceKey)
        if loadDashboard { await self.loadDashboard(apiBaseURL: apiBaseURL) }
    }

    /// Only the outer Beat the AI presentation calls this. Authentication runs
    /// independently from data loads and declining sign-in leaves guest play ready.
    func gameScreenDidAppear(apiBaseURL: String) async {
        await activate(apiBaseURL: apiBaseURL, loadDashboard: false)
        if !gameScreenVisible { automaticGameCenterAttempt = nil; gamePresentationID = UUID() }
        gameScreenVisible = true
        let server = normalizedServer(apiBaseURL)
        if let previousServer = automaticGameCenterServer, previousServer != server {
            cancelGameCenterSync()
            gameCenterLifecycleTask?.cancel()
            gameCenterConnectionTask?.cancel()
            gameCenter?.cancelAuthentication()
            gamePresentationID = UUID()
            automaticGameCenterAttempt = nil
        }
        automaticGameCenterServer = server
        if pendingGameCenterRestore?.context.server != server { pendingGameCenterRestore = nil }
        applyPendingGameCenterRestore()
        let key = server + "|" + (gameCenter?.currentTeamPlayerID ?? "guest")
        guard automaticGameCenterAttempt != key,
              gameCenterLifecycleTask == nil || gameCenterLifecycleTask?.isCancelled == true else { return }
        let previous = gameCenterLifecycleTask
        let presentation = gamePresentationID
        automaticGameCenterAttempt = key
        gameCenterLifecycleTask = Task { [weak self] in
            guard let self else { return }
            await previous?.value
            guard gameScreenVisible, presentation == gamePresentationID, !Task.isCancelled else { return }
            _ = await runGameCenterConnection(apiBaseURL: apiBaseURL, restore: true)
            if gameScreenVisible, presentation == gamePresentationID {
                automaticGameCenterAttempt = server + "|" + (gameCenter?.currentTeamPlayerID ?? "guest")
            }
            if presentation == gamePresentationID { gameCenterLifecycleTask = nil }
        }
    }

    func setPredictionEditingActive(_ active: Bool) {
        if !active, gameCenter?.isPresentingAuthentication == true { return }
        predictionEditingActive = active
        if !active { applyPendingGameCenterRestore() }
    }

    func deactivate() {
        enabled = false
        userDefaults.set(false, forKey: Self.enabledPreferenceKey)
        sessionGeneration = UUID()
        invalidatePrivateLeagueSession()
        credentialTask?.cancel()
        credentialTask = nil
        dashboardRequestID = nil
        historyRequestID = nil
        leaderboardRequestID = nil
        loadingFixtureIDs.removeAll()
        isLoading = false
        isLoadingHistory = false
        isLoadingLeaderboard = false
        cancelGameCenterConnection()
        gameScreenVisible = false
        pendingGameCenterRestore = nil
        errorMessage = nil
        requiresGameCenterRestore = false
    }

    func fixture(for id: String) -> PredictionGameFixture? {
        guard let normalized = PredictionGameFixtureID.normalized(id) else { return nil }
        return fixtures[normalized]
    }

    /// Reuse a just-loaded prediction set only for the same player and server.
    func freshCachedFixture(fixtureID: String, apiBaseURL: String) -> PredictionGameFixture? {
        let server = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard enabled, configuredServer == server,
              let id = PredictionGameFixtureID.normalized(fixtureID),
              let fetched = fetchedAt[id], (0..<30).contains(Date().timeIntervalSince(fetched)) else {
            return nil
        }
        return fixtures[id]
    }

    func serverNow(relativeTo date: Date = Date()) -> Date {
        date.addingTimeInterval(serverClockOffset)
    }

    func canEdit(fixture: PredictionGameFixture, at date: Date = Date()) -> Bool {
        fixture.predictionAvailability(at: serverNow(relativeTo: date)) == .editable
    }

    func loadDashboard(apiBaseURL: String, seasonId: String? = nil) async {
        guard enabled else { return }
        let requestID = UUID()
        dashboardRequestID = requestID
        isLoading = true
        errorMessage = nil
        selectedSeasonId = seasonId
        let competitionID = selectedCompetitionID
        let competitionScope = competitionGeneration
        defer {
            if dashboardRequestID == requestID { isLoading = false }
        }
        do {
            let context = try await session(apiBaseURL: apiBaseURL)
            let state = try await context.client.state(credential: context.credential, competitionId: competitionID)
            try check(context)
            guard dashboardRequestID == requestID, competitionGeneration == competitionScope else { return }
            guard state.competitionId == competitionID || (state.competitionId == nil && competitionID == "1") else {
                throw PredictionGameAPIError.invalidResponse
            }
            if let competitions = state.competitions, !competitions.isEmpty { availableCompetitions = competitions }
            if player?.id != state.player.id || player?.gameCenterLinked != true || state.player.gameCenterLinked {
                player = state.player
            }
            syncClock(state.serverTime)
            challenge = state.challenge
            merge(state.fixtures)
            seasons = state.seasons
            achievements = state.achievements
            recentGameweeks = state.recentGameweeks ?? []
            latestResult = state.latestResult ?? PredictionGameRecentGameweek.latestCompleted(in: recentGameweeks)
            if let seasonId {
                let stats = try await context.client.stats(credential: context.credential, seasonId: seasonId, competitionId: competitionID)
                try check(context)
                guard dashboardRequestID == requestID, competitionGeneration == competitionScope else { return }
                guard stats.competitionId == competitionID || (stats.competitionId == nil && competitionID == "1") else {
                    throw PredictionGameAPIError.invalidResponse
                }
                summary = stats.summary
                seasons = stats.seasons
                achievements = stats.achievements
                recentGameweeks = stats.recentGameweeks ?? []
            } else {
                summary = state.summary
            }
            await loadHistory(apiBaseURL: apiBaseURL, seasonId: seasonId)
            if linkedTeamPlayerID != nil, dashboardRequestID == requestID {
                scheduleGameCenterSync(context: context)
            }
        } catch {
            if dashboardRequestID == requestID { report(error) }
        }
    }

    /// One batch request hydrates visible rows; ordinary app use does not create a player.
    func loadEntries(fixtureIDs: [String], apiBaseURL: String, force: Bool = false) async {
        guard enabled else { return }
        let candidates = Array(Set(fixtureIDs.compactMap(PredictionGameFixtureID.normalized))).sorted()
        guard !candidates.isEmpty else { return }
        do {
            // Resolve the server before consulting its cache; changing API environments
            // must never display entries belonging to the previous server's player.
            let context = try await session(apiBaseURL: apiBaseURL)
            let now = Date()
            let ids = candidates.filter { id in
                force || (!loadingFixtureIDs.contains(id) && fetchedAt[id].map { now.timeIntervalSince($0) < 30 } != true)
            }
            guard !ids.isEmpty else { return }
            loadingFixtureIDs.formUnion(ids)
            defer { loadingFixtureIDs.subtract(ids) }
            for offset in stride(from: 0, to: ids.count, by: 200) {
                let batch = Array(ids[offset..<min(offset + 200, ids.count)])
                let response = try await context.client.fixtures(ids: batch, credential: context.credential)
                try check(context)
                syncClock(response.serverTime)
                merge(response.fixtures)
                for id in batch { fetchedAt[id] = Date() }
            }
        } catch {
            report(error)
        }
    }

    /// Poll the server-owned current-round score only while the game menu is visible.
    func refreshInPlayRound(apiBaseURL: String) async {
        let competitionID = selectedCompetitionID
        let competitionScope = competitionGeneration
        let hadLiveRound = inPlayRound != nil
        do {
            let context = try await session(apiBaseURL: apiBaseURL)
            let response = try await context.client.inPlay(
                credential: context.credential,
                competitionId: competitionID
            )
            try check(context)
            guard competitionGeneration == competitionScope,
                  selectedCompetitionID == competitionID,
                  response.competitionId == competitionID else { return }
            syncClock(response.serverTime)
            inPlayRound = response.round
            if hadLiveRound, response.round == nil {
                await loadDashboard(apiBaseURL: apiBaseURL)
            }
        } catch {
            // A transient score refresh should not replace the usable dashboard.
        }
    }

    func loadFixture(fixtureID: String, apiBaseURL: String) async -> PredictionGameFixture? {
        guard enabled else { return nil }
        errorMessage = nil
        guard let id = PredictionGameFixtureID.normalized(fixtureID) else {
            errorMessage = PredictionGameAPIError.invalidFixture.localizedDescription
            return nil
        }
        do {
            let context = try await session(apiBaseURL: apiBaseURL)
            let response = try await context.client.fixtures(ids: [id], credential: context.credential)
            try check(context)
            syncClock(response.serverTime)
            merge(response.fixtures)
            guard let fixture = response.fixtures.first(where: { $0.id == id }) else {
                errorMessage = "This match does not currently have an AI score prediction available for the game."
                return nil
            }
            return fixture
        } catch {
            report(error)
            return nil
        }
    }

    func save(fixtureID: String, homeScore: Int, awayScore: Int, expectedAIRevision: String? = nil, apiBaseURL: String, penaltyWinner: String? = nil) async -> Bool {
        guard enabled, !isSaving else { return false }
        guard (0...20).contains(homeScore), (0...20).contains(awayScore) else {
            errorMessage = "Choose a score between 0 and 20 for each team."
            return false
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false; applyPendingGameCenterRestore() }
        do {
            var context = try await session(apiBaseURL: apiBaseURL)
            let draftScope = playerDraftScopeID
            if let credentialTeamPlayerID,
               gameCenter?.isAuthenticated(expectedTeamPlayerID: credentialTeamPlayerID) != true {
                if let connection = gameCenterConnectionTask { await connection.value }
                _ = await runGameCenterConnection(apiBaseURL: apiBaseURL, restore: true)
                guard pendingGameCenterRestore == nil,
                      gameCenter?.isAuthenticated(expectedTeamPlayerID: credentialTeamPlayerID) == true,
                      draftScope == playerDraftScopeID else {
                    throw PredictionMiniLeagueError.gameCenterRequired
                }
                context = try await session(apiBaseURL: apiBaseURL)
            }
            let response: PredictionGameSaveResponse
            do {
                response = try await context.client.save(
                    fixtureID: fixtureID, homeScore: homeScore, awayScore: awayScore,
                    expectedAIRevision: expectedAIRevision,
                    credential: context.credential, penaltyWinner: penaltyWinner
                )
            } catch let error as PredictionGameAPIError where error.requiresVerifiedGameCenter {
                // A league member's canonical picks need proof-backed identity even when
                // entered from Fixtures. Refresh automatically and retry this exact draft once.
                if let connection = gameCenterConnectionTask { await connection.value }
                _ = await runGameCenterConnection(apiBaseURL: apiBaseURL, restore: true)
                guard pendingGameCenterRestore == nil, let teamPlayerID = linkedTeamPlayerID,
                      gameCenter?.isAuthenticated(expectedTeamPlayerID: teamPlayerID) == true,
                      privateSessionExpiresAt.map({ $0 > serverNow() }) == true else {
                    throw PredictionMiniLeagueError.gameCenterRequired
                }
                let refreshed = try await session(apiBaseURL: apiBaseURL)
                guard refreshed.generation == context.generation, playerDraftScopeID == draftScope else {
                    throw CancellationError()
                }
                context = refreshed
                response = try await context.client.save(
                    fixtureID: fixtureID, homeScore: homeScore, awayScore: awayScore,
                    expectedAIRevision: expectedAIRevision,
                    credential: context.credential, penaltyWinner: penaltyWinner
                )
            }
            try check(context)
            syncClock(response.serverTime)
            merge([response.fixture])
            if response.fixture.resolvedCompetitionID == selectedCompetitionID,
               let index = history.firstIndex(where: { $0.id == response.fixture.id }) {
                history[index] = response.fixture
            } else if response.fixture.resolvedCompetitionID == selectedCompetitionID,
                      historySeasonId == nil || historySeasonId == response.fixture.seasonId {
                history.insert(response.fixture, at: 0)
                history.sort { $0.kickoffAt > $1.kickoffAt }
                historyNextOffset += 1
            }
            return true
        } catch let error as PredictionGameAPIError where error.requiresAIReview {
            _ = await loadFixture(fixtureID: fixtureID, apiBaseURL: apiBaseURL)
            errorMessage = "The AI prediction changed before your first save. Review its updated score, then save again. Your draft is unchanged."
            return false
        } catch {
            report(error)
            return false
        }
    }

    func loadPredictionSet(fixtureID: String? = nil, apiBaseURL: String, reportErrors: Bool = true, includeLocked: Bool = false) async -> PredictionGamePredictionSet? {
        guard enabled else { return nil }
        if reportErrors { errorMessage = nil }
        let competitionID = selectedCompetitionID
        let competitionScope = competitionGeneration
        do {
            let context = try await session(apiBaseURL: apiBaseURL)
            let response = try await context.client.nextPredictions(fixtureID: fixtureID, credential: context.credential,
                includeLocked: includeLocked, competitionId: fixtureID == nil ? competitionID : nil)
            try check(context)
            if fixtureID == nil {
                guard competitionGeneration == competitionScope else { return nil }
                guard response.resolvedCompetitionID == competitionID else { throw PredictionGameAPIError.invalidResponse }
            }
            syncClock(response.serverTime)
            merge(response.fixtures)
            return response
        } catch {
            if reportErrors, fixtureID != nil || competitionGeneration == competitionScope { report(error) }
            return nil
        }
    }

    func loadHistory(apiBaseURL: String, seasonId: String? = nil) async {
        await fetchHistory(apiBaseURL: apiBaseURL, seasonId: seasonId, append: false)
    }

    func loadMoreHistory(apiBaseURL: String) async {
        guard hasMoreHistory, !isLoadingHistory else { return }
        await fetchHistory(apiBaseURL: apiBaseURL, seasonId: historySeasonId, append: true)
    }

    func loadLeaderboard(category: PredictionGameLeaderboardCategory, apiBaseURL: String, seasonId: String? = nil) async {
        guard enabled else { return }
        let requestID = UUID()
        leaderboardRequestID = requestID
        let competitionID = selectedCompetitionID
        let competitionScope = competitionGeneration
        gameCenterLeaderboardID = nil
        isLoadingLeaderboard = true
        errorMessage = nil
        defer { if leaderboardRequestID == requestID { isLoadingLeaderboard = false } }
        do {
            let context = try await session(apiBaseURL: apiBaseURL)
            let response = try await context.client.leaderboard(
                category: category, challengeId: category == .weekly ? challenge?.id : nil,
                seasonId: seasonId ?? challenge?.seasonId, credential: context.credential, competitionId: competitionID
            )
            try check(context)
            guard leaderboardRequestID == requestID, competitionGeneration == competitionScope else { return }
            guard response.competitionId == competitionID || (response.competitionId == nil && competitionID == "1") else {
                throw PredictionGameAPIError.invalidResponse
            }
            leaderboards = response.rows
            gameCenterLeaderboardID = response.gameCenterLeaderboardId
        } catch {
            if leaderboardRequestID == requestID { report(error) }
        }
    }

    func connectGameCenter(apiBaseURL: String) async {
        pendingGameCenterDestination = nil
        _ = await runGameCenterConnection(apiBaseURL: apiBaseURL, restore: false)
    }

    func restoreGameCenter(apiBaseURL: String) async {
        let connected = await runGameCenterConnection(apiBaseURL: apiBaseURL, restore: true)
        if connected, let destination = pendingGameCenterDestination {
            pendingGameCenterDestination = nil
            presentGameCenter(destination)
        }
    }

    func openGameCenterLeaderboards(apiBaseURL: String, category: PredictionGameLeaderboardCategory = .weekly, seasonId: String? = nil) async {
        let competitionID = selectedCompetitionID
        let scope = competitionGeneration
        await loadLeaderboard(category: category, apiBaseURL: apiBaseURL, seasonId: seasonId)
        guard scope == competitionGeneration else { return }
        guard let leaderboardID = gameCenterLeaderboardID else {
            gameCenterStatusMessage = "Friends’ leaderboards for \(selectedCompetition.name) are not available in Game Center yet. Your predictions and competition record are saved."
            return
        }
        await openGameCenter(.leaderboards(competitionID: competitionID, leaderboardID: leaderboardID), apiBaseURL: apiBaseURL)
    }

    func openGameCenterAchievements(apiBaseURL: String) async {
        await openGameCenter(.achievements, apiBaseURL: apiBaseURL)
    }

    func cancelGameCenterConnection() {
        cancelGameCenterSync()
        pendingGameCenterDestination = nil
        gameCenterConnectionTask?.cancel()
        gameCenterLifecycleTask?.cancel()
        gameCenter?.cancelAuthentication()
    }

    func gameScreenDidDisappear() {
        // GameKit may cover the hosting controller with a full-screen sign-in. That
        // disappearance belongs to this connection, rather than navigation away.
        guard gameCenter?.isPresentingAuthentication != true else { return }
        gameScreenVisible = false
        inPlayRound = nil
        invalidatePrivateLeagueSession()
        automaticGameCenterAttempt = nil
        cancelGameCenterConnection()
    }

    func showGameCenterLeaderboards() {
        guard let leaderboardID = gameCenterLeaderboardID else {
            gameCenterStatusMessage = "Friends’ leaderboards for \(selectedCompetition.name) are not available in Game Center yet."
            return
        }
        showGameCenterLeaderboard(leaderboardID)
    }

    private func showGameCenterLeaderboard(_ leaderboardID: String) {
        guard enabled, let gameCenter, let linkedTeamPlayerID else {
            gameCenterStatusMessage = "Game Center is unavailable. You can keep playing as a guest."
            return
        }
        do { try gameCenter.showLeaderboards(expectedTeamPlayerID: linkedTeamPlayerID, leaderboardID: leaderboardID) }
        catch { reportGameCenter(error, operation: .dashboard) }
    }

    func showGameCenterAchievements() {
        guard enabled, let gameCenter, let linkedTeamPlayerID else {
            gameCenterStatusMessage = "Game Center is unavailable. You can keep playing as a guest."
            return
        }
        do { try gameCenter.showAchievements(expectedTeamPlayerID: linkedTeamPlayerID) }
        catch { reportGameCenter(error, operation: .dashboard) }
    }

    /// Private data never uses a cached guest session, even if that player was linked previously.
    /// The server independently verifies this proof-bound credential and its expiry.
    func withMiniLeagueClient<Response: Sendable>(
        apiBaseURL: String,
        operation: (PredictionGameAPIClient, String) async throws -> Response
    ) async throws -> Response {
        guard enabled, gameScreenVisible else { throw PredictionMiniLeagueError.gameCenterRequired }
        _ = try await session(apiBaseURL: apiBaseURL)
        if let linkedTeamPlayerID,
           gameCenter?.isAuthenticated(expectedTeamPlayerID: linkedTeamPlayerID) != true {
            self.linkedTeamPlayerID = nil
            invalidatePrivateLeagueSession()
        }
        if let connection = gameCenterConnectionTask { await connection.value }
        let needsVerification = linkedTeamPlayerID == nil
            || (privateSessionExpiresAt.map { $0 <= serverNow().addingTimeInterval(60) } ?? true)
        if needsVerification {
            _ = await runGameCenterConnection(apiBaseURL: apiBaseURL, restore: true)
        }
        if pendingGameCenterRestore != nil { throw PredictionMiniLeagueError.finishingPrediction }
        guard let teamPlayerID = linkedTeamPlayerID,
              gameCenter?.isAuthenticated(expectedTeamPlayerID: teamPlayerID) == true,
              let expiresAt = privateSessionExpiresAt, expiresAt > serverNow() else {
            throw PredictionMiniLeagueError.gameCenterRequired
        }
        guard gameCenter?.isMultiplayerGamingRestricted == false else {
            invalidatePrivateLeagueSession()
            throw PredictionMiniLeagueError.multiplayerRestricted
        }
        var context = try await session(apiBaseURL: apiBaseURL)
        var scope = privateLeagueScopeID
        let response: Response
        do {
            response = try await operation(context.client, context.credential)
        } catch let error as PredictionGameAPIError where error.requiresVerifiedGameCenter {
            // Server expiry or revocation takes precedence over the local expiry estimate.
            invalidatePrivateLeagueSession()
            if let connection = gameCenterConnectionTask { await connection.value }
            _ = await runGameCenterConnection(apiBaseURL: apiBaseURL, restore: true)
            guard pendingGameCenterRestore == nil,
                  gameCenter?.isAuthenticated(expectedTeamPlayerID: teamPlayerID) == true,
                  privateSessionExpiresAt.map({ $0 > serverNow() }) == true else {
                throw PredictionMiniLeagueError.gameCenterRequired
            }
            context = try await session(apiBaseURL: apiBaseURL)
            scope = privateLeagueScopeID
            response = try await operation(context.client, context.credential)
        }
        try check(context)
        guard scope == privateLeagueScopeID, gameScreenVisible,
              privateSessionExpiresAt.map({ $0 > serverNow() }) == true,
              gameCenter?.isAuthenticated(expectedTeamPlayerID: teamPlayerID) == true else {
            invalidatePrivateLeagueSession()
            throw CancellationError()
        }
        guard gameCenter?.isMultiplayerGamingRestricted == false else {
            invalidatePrivateLeagueSession()
            throw PredictionMiniLeagueError.multiplayerRestricted
        }
        return response
    }

    func acceptMiniLeagueFixtures(_ response: PredictionMiniLeagueFixtureResponse) {
        syncClock(response.serverTime)
        merge(response.fixtures)
    }

    /// Called on GameKit account notifications and app activation without starting GameKit in normal browsing.
    func refreshMiniLeagueAuthorization() {
        guard let gameCenter else { return }
        let expectedPlayerID = privateSessionTeamPlayerID ?? linkedTeamPlayerID
        let changedAccount = expectedPlayerID.map { !gameCenter.isAuthenticated(expectedTeamPlayerID: $0) } ?? false
        let restricted = gameCenter.isMultiplayerGamingRestricted
        guard changedAccount || restricted else { return }
        if changedAccount { linkedTeamPlayerID = nil; cancelGameCenterSync() }
        invalidatePrivateLeagueSession()
    }

    private func invalidatePrivateLeagueSession() {
        privateSessionExpiresAt = nil
        privateSessionTeamPlayerID = nil
        privateLeagueScopeID = UUID()
    }

    private struct Session {
        let client: PredictionGameAPIClient
        let credential: String
        let server: String
        let generation: UUID
    }

    private func session(apiBaseURL: String) async throws -> Session {
        try Task.checkCancellation()
        guard enabled else { throw CancellationError() }
        let server = normalizedServer(apiBaseURL)
        let client = try PredictionGameAPIClient(apiBaseURL: server, session: apiSession)
        if configuredServer != server {
            cancelGameCenterSync()
            configuredServer = server
            sessionGeneration = UUID()
            credentialTask?.cancel()
            credentialTask = nil
            credential = nil
            linkedTeamPlayerID = nil
            credentialTeamPlayerID = nil
            invalidatePrivateLeagueSession()
            pendingGameCenterRestore = nil
            clearPlayerData()
        }
        let generation = sessionGeneration
        if credential == nil {
            if credentialTask == nil {
                // Keychain calls synchronously wait on securityd; keep them off the UI actor.
                credentialTask = Task.detached(priority: .userInitiated) { [credentialStorage] in
                    try Task.checkCancellation()
                    let saved = try credentialStorage.load(server: server)
                    try Task.checkCancellation()
                    if let saved { return saved }
                    let response = try await client.createPlayer()
                    guard let created = response.credential, !created.isEmpty else {
                        throw PredictionGameAPIError.missingCredential
                    }
                    // Persist a successfully created identity even if its caller has since left.
                    try credentialStorage.save(created, server: server)
                    try Task.checkCancellation()
                    return created
                }
            }
            guard let credentialTask else { throw PredictionGameAPIError.missingCredential }
            do {
                let resolved = try await credentialTask.value
                guard generation == sessionGeneration, enabled else { throw CancellationError() }
                credential = resolved
                updateDraftScope(server: server, credential: resolved)
                self.credentialTask = nil
            } catch {
                if generation == sessionGeneration { self.credentialTask = nil }
                throw error
            }
        }
        try Task.checkCancellation()
        guard let credential else { throw PredictionGameAPIError.missingCredential }
        return Session(client: client, credential: credential, server: server, generation: generation)
    }

    private func check(_ context: Session) throws {
        try Task.checkCancellation()
        guard enabled, context.generation == sessionGeneration else { throw CancellationError() }
    }

    private func normalizedServer(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func updateDraftScope(server: String, credential: String) {
        let key = server + "|" + credential
        let scope = draftScopes[key] ?? UUID()
        draftScopes[key] = scope
        playerDraftScopeID = scope
    }

    private func applyPendingGameCenterRestore() {
        guard enabled, gameScreenVisible, !isSaving, !predictionEditingActive,
              let pending = pendingGameCenterRestore else { return }
        guard pending.context.generation == sessionGeneration,
              let replacement = pending.response.credential else {
            pendingGameCenterRestore = nil
            return
        }
        guard gameCenter?.isAuthenticated(expectedTeamPlayerID: pending.teamPlayerID) == true else {
            pendingGameCenterRestore = nil
            gameCenterStatusMessage = "Game Center account changed. Your current game is unchanged."
            return
        }
        do {
            try credentialStorage.preserveGuest(pending.context.credential, server: pending.context.server)
            try credentialStorage.save(replacement, server: pending.context.server)
            cancelGameCenterSync()
            credential = replacement
            sessionGeneration = UUID()
            updateDraftScope(server: pending.context.server, credential: replacement)
            clearPlayerData()
            linkedTeamPlayerID = pending.teamPlayerID
            invalidatePrivateLeagueSession()
            privateSessionExpiresAt = pending.response.privateSessionExpiresAt
            privateSessionTeamPlayerID = pending.response.privateSessionExpiresAt == nil ? nil : pending.teamPlayerID
            credentialTeamPlayerID = pending.teamPlayerID
            player = pending.response.player
            pendingGameCenterRestore = nil
            requiresGameCenterRestore = false
            gameCenterStatusMessage = "Your Game Center history is restored. Your guest game is preserved."
            Task { [weak self] in await self?.loadDashboard(apiBaseURL: pending.apiBaseURL) }
        } catch { reportGameCenter(error) }
    }

    private func fetchHistory(apiBaseURL: String, seasonId: String?, append: Bool) async {
        guard enabled else { return }
        let requestID = UUID()
        historyRequestID = requestID
        isLoadingHistory = true
        let competitionID = selectedCompetitionID
        let competitionScope = competitionGeneration
        let offset = append ? historyNextOffset : 0
        defer { if historyRequestID == requestID { isLoadingHistory = false } }
        do {
            let context = try await session(apiBaseURL: apiBaseURL)
            let response = try await context.client.history(credential: context.credential, seasonId: seasonId, offset: offset, competitionId: competitionID)
            try check(context)
            guard historyRequestID == requestID, competitionGeneration == competitionScope else { return }
            guard response.fixtures.allSatisfy({ $0.resolvedCompetitionID == competitionID }) else {
                throw PredictionGameAPIError.invalidResponse
            }
            historySeasonId = seasonId
            if append {
                let existing = Set(history.map(\.id))
                history.append(contentsOf: response.fixtures.filter { !existing.contains($0.id) })
            } else {
                history = response.fixtures
            }
            hasMoreHistory = response.hasMore
            historyNextOffset = response.offset + response.fixtures.count
            merge(response.fixtures)
        } catch {
            if historyRequestID == requestID { report(error) }
        }
    }

    private func linkGameCenter(apiBaseURL: String, restore: Bool) async {
        guard enabled, !isConnectingGameCenter else { return }
        isConnectingGameCenter = true
        cancelGameCenterSync()
        linkedTeamPlayerID = nil
        gameCenterStatusMessage = nil
        defer { isConnectingGameCenter = false }
        var operation = PredictionGameCenterService.Operation.connection
        do {
            let context = try await session(apiBaseURL: apiBaseURL)
            let service = gameCenter ?? gameCenterFactory()
            gameCenter = service
            if gameCenterStateObservation == nil {
                gameCenterStateObservation = service.authenticationChanges.sink { [weak self] in
                    Task { @MainActor in self?.refreshMiniLeagueAuthorization() }
                }
            }
            var identity = try await service.authenticate()
            try check(context)
            identity.restoreExisting = restore
            operation = .linking
            let response = try await context.client.linkGameCenter(identity: identity, credential: context.credential)
            try check(context)
            guard service.isAuthenticated(expectedTeamPlayerID: identity.teamPlayerId) else {
                throw PredictionGameAPIError.server(status: 409, code: "game_center_account_changed", message: "Game Center account changed. Your current game is unchanged.")
            }
            if let replacement = response.credential, replacement != context.credential {
                let restoresAnotherPlayer = response.restoredExisting
                    ?? (player.map { $0.id != response.player.id } ?? true)
                if !restoresAnotherPlayer {
                    // Rotating a verified credential does not change the person or their drafts.
                    try credentialStorage.save(replacement, server: context.server)
                    credential = replacement
                    draftScopes[context.server + "|" + replacement] = playerDraftScopeID
                    linkedTeamPlayerID = identity.teamPlayerId
                    privateSessionExpiresAt = response.privateSessionExpiresAt
                    privateSessionTeamPlayerID = response.privateSessionExpiresAt == nil ? nil : identity.teamPlayerId
                    credentialTeamPlayerID = identity.teamPlayerId
                    player = response.player
                    requiresGameCenterRestore = false
                    gameCenterStatusMessage = "Connected to Game Center."
                    scheduleGameCenterSync(context: Session(client: context.client, credential: replacement,
                        server: context.server, generation: context.generation))
                    return
                }
                invalidatePrivateLeagueSession()
                pendingGameCenterRestore = PendingGameCenterRestore(context: context, response: response, teamPlayerID: identity.teamPlayerId, apiBaseURL: apiBaseURL)
                gameCenterStatusMessage = "Your Game Center history will open when you finish editing. Your guest game is preserved."
                applyPendingGameCenterRestore()
                return
            }
            linkedTeamPlayerID = identity.teamPlayerId
            privateSessionExpiresAt = response.privateSessionExpiresAt
            privateSessionTeamPlayerID = response.privateSessionExpiresAt == nil ? nil : identity.teamPlayerId
            credentialTeamPlayerID = identity.teamPlayerId
            player = response.player
            requiresGameCenterRestore = false
            gameCenterStatusMessage = "Connected to Game Center."
            scheduleGameCenterSync(context: context)
        } catch let error as PredictionGameAPIError where error.requiresGameCenterRestore {
            requiresGameCenterRestore = true
        } catch {
            reportGameCenter(error, operation: operation)
        }
    }

    private func runGameCenterConnection(apiBaseURL: String, restore: Bool) async -> Bool {
        guard enabled, gameCenterConnectionTask == nil else { return false }
        let task = Task { await linkGameCenter(apiBaseURL: apiBaseURL, restore: restore) }
        gameCenterConnectionTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        gameCenterConnectionTask = nil
        return !task.isCancelled && linkedTeamPlayerID != nil && !requiresGameCenterRestore
    }

    private func openGameCenter(_ destination: GameCenterDestination, apiBaseURL: String) async {
        guard enabled, !isConnectingGameCenter else { return }
        pendingGameCenterDestination = destination
        if let linkedTeamPlayerID, gameCenter?.isAuthenticated(expectedTeamPlayerID: linkedTeamPlayerID) == true {
            pendingGameCenterDestination = nil
            presentGameCenter(destination)
        } else if await runGameCenterConnection(apiBaseURL: apiBaseURL, restore: false) {
            pendingGameCenterDestination = nil
            presentGameCenter(destination)
        } else if !requiresGameCenterRestore {
            pendingGameCenterDestination = nil
        }
    }

    private func presentGameCenter(_ destination: GameCenterDestination) {
        switch destination {
        case .leaderboards(let competitionID, let leaderboardID):
            guard competitionID == selectedCompetitionID else { return }
            showGameCenterLeaderboard(leaderboardID)
        case .achievements: showGameCenterAchievements()
        }
    }

    private func cancelGameCenterSync() {
        gameCenterSyncTask?.cancel()
        gameCenterSyncTask = nil
        gameCenterSyncID = nil
    }

    /// Game data is ready independently of optional Game Center publication.
    private func scheduleGameCenterSync(context: Session) {
        guard enabled, gameScreenVisible, context.generation == sessionGeneration,
              gameCenterSyncTask == nil, let gameCenter, let teamPlayerID = linkedTeamPlayerID,
              gameCenter.isAuthenticated(expectedTeamPlayerID: teamPlayerID) else { return }
        let requestID = UUID()
        gameCenterSyncID = requestID
        gameCenterSyncTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if gameCenterSyncID == requestID {
                    gameCenterSyncTask = nil
                    gameCenterSyncID = nil
                }
            }
            do {
                try check(context)
                let submissions = try await context.client.gameCenterSubmissions(credential: context.credential)
                try check(context)
                guard gameScreenVisible, gameCenterSyncID == requestID,
                      linkedTeamPlayerID == teamPlayerID,
                      gameCenter.isAuthenticated(expectedTeamPlayerID: teamPlayerID) else { return }
                try await gameCenter.submit(submissions, expectedTeamPlayerID: teamPlayerID)
            } catch {
                guard !(error is CancellationError), (error as? URLError)?.code != .cancelled,
                      enabled, gameScreenVisible, context.generation == sessionGeneration,
                      gameCenterSyncID == requestID, linkedTeamPlayerID == teamPlayerID else { return }
                reportGameCenter(error, operation: .publication)
            }
        }
    }

    private func merge(_ incoming: [PredictionGameFixture]) {
        var updated = fixtures
        var changed = false
        for fixture in incoming {
            guard let id = PredictionGameFixtureID.normalized(fixture.id) else { continue }
            // A batch requested before a save may finish afterwards. Never erase or roll
            // back the accepted entry and its frozen opponent with that older response.
            if let existing = updated[id]?.prediction,
               fixture.prediction.map({ $0.savedAt < existing.savedAt }) != false {
                continue
            }
            if updated[id] != fixture {
                updated[id] = fixture
                changed = true
            }
            fetchedAt[id] = Date()
        }
        if changed { fixtures = updated }
    }

    private func syncClock(_ serverTime: Date) {
        serverClockOffset = serverTime.timeIntervalSinceNow
    }

    private func clearPlayerData() {
        player = nil
        latestResult = nil
        clearCompetitionData()
        availableCompetitions = [.premierLeague]
        fixtures = [:]
        fetchedAt = [:]
        loadingFixtureIDs = []
    }

    private func clearCompetitionData() {
        summary = .empty
        history = []
        challenge = nil
        achievements = []
        seasons = []
        recentGameweeks = []
        inPlayRound = nil
        leaderboards = []
        gameCenterLeaderboardID = nil
        hasMoreHistory = false
        historyNextOffset = 0
        historySeasonId = nil
        selectedSeasonId = nil
    }

    private func report(_ error: Error) {
        guard enabled, !(error is CancellationError),
              (error as? URLError)?.code != .cancelled else { return }
        errorMessage = error.localizedDescription
    }

    private func reportGameCenter(_ error: Error, operation: PredictionGameCenterService.Operation = .connection) {
        guard enabled, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
        gameCenterStatusMessage = PredictionGameCenterService.statusMessage(
            for: error, operation: operation,
            isSignedIn: gameCenter?.currentTeamPlayerID != nil,
            hasLinkedPlayer: player?.gameCenterLinked == true
        )
    }
}
