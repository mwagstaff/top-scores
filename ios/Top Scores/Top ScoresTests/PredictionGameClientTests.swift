import Foundation
import GameKit
import Testing
@testable import Top_Scores

@Suite(.serialized)
struct PredictionGameClientTests {
    @Test func recentGameweeksAreBackwardCompatibleAndWholeBoardFlagIsOptIn() async throws {
        let summary = try #require(String(data: JSONEncoder().encode(PredictionGameSummary.empty), encoding: .utf8))
        let old = try PredictionGameAPIClient.decoder().decode(PredictionGameStatsResponse.self,
            from: Data("{\"summary\":\(summary),\"seasons\":[],\"achievements\":[]}".utf8))
        #expect(old.recentGameweeks == nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PredictionGameTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); PredictionGameTestURLProtocol.responseHandler = nil }
        PredictionGameTestURLProtocol.responseHandler = { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            #expect(items?.contains(URLQueryItem(name: "includeLocked", value: "true")) == true)
            return (200, Data(#"{"serverTime":"2026-09-10T12:00:00Z","gameweekId":"203:round:1","gameweekLabel":"Gameweek 1","fixtures":[]}"#.utf8))
        }
        let client = try PredictionGameAPIClient(apiBaseURL: "https://example.test/api/v1", session: session)
        _ = try await client.nextPredictions(credential: "guest", includeLocked: true)
    }

    @Test func competitionMetadataAndPenaltyChoiceDecodeWithoutBreakingExistingSavedGames() throws {
        let oldFixture = try PredictionGameAPIClient.decoder().decode(PredictionGameFixture.self, from: Data(Self.fixtureJSON.utf8))
        #expect(oldFixture.resolvedCompetitionID == "1")
        #expect(oldFixture.resolvedCompetitionName == "Premier League")
        #expect(oldFixture.prediction?.penaltyWinner == nil)
        #expect(oldFixture.isSecondLeg != true)
        var payload = try #require(JSONSerialization.jsonObject(with: Data(Self.fixtureJSON.utf8)) as? [String: Any])
        payload["competitionId"] = "2"
        payload["competitionName"] = "Champions League"
        payload["isSecondLeg"] = true
        var prediction = try #require(payload["prediction"] as? [String: Any])
        prediction["penaltyWinner"] = "away"
        payload["prediction"] = prediction
        let fixture = try PredictionGameAPIClient.decoder().decode(PredictionGameFixture.self,
            from: JSONSerialization.data(withJSONObject: payload))
        #expect(fixture.resolvedCompetitionID == "2")
        #expect(fixture.resolvedCompetitionName == "Champions League")
        #expect(fixture.prediction?.penaltyWinner == "away")
        #expect(fixture.isSecondLeg == true)
        #expect(fixture.prediction?.homeScore != fixture.prediction?.awayScore)
    }

    @MainActor
    @Test func dashboardKeepsLatestCompletedResultAcrossCompetitionSelection() async throws {
        let suite = "PredictionLatestResult.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: PredictionGameStore.enabledPreferenceKey)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PredictionGameTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let base = "https://example.test/api/v1"
        let summary = try #require(String(data: JSONEncoder().encode(PredictionGameSummary.empty), encoding: .utf8))
        defer {
            defaults.removePersistentDomain(forName: suite)
            session.invalidateAndCancel()
            PredictionGameTestURLProtocol.responseHandler = nil
        }
        PredictionGameTestURLProtocol.responseHandler = { request in
            switch request.url?.lastPathComponent {
            case "state":
                let latest = #"{"competitionId":"7","competitionName":"Champions League","id":"competition:7:1112:round:1","label":"Gameweek 1","startsAt":"2026-07-07T16:00:00Z","latestPlayedAt":"2026-09-10T19:00:00Z","youPoints":4,"aiPoints":3,"played":4,"predicted":4,"totalMatches":46,"completed":true}"#
                return (200, Data("{\"player\":{\"id\":\"guest\",\"displayName\":\"Guest\",\"gameCenterLinked\":false},\"serverTime\":\"2026-09-11T00:00:00Z\",\"summary\":\(summary),\"seasons\":[],\"achievements\":[],\"fixtures\":[],\"recentGameweeks\":[],\"latestResult\":\(latest),\"competitionId\":\"1\",\"competitions\":[{\"id\":\"1\",\"name\":\"Premier League\"},{\"id\":\"7\",\"name\":\"Champions League\"}]}".utf8))
            case "history":
                return (200, Data(#"{"fixtures":[],"total":0,"offset":0,"hasMore":false}"#.utf8))
            default:
                throw URLError(.badURL)
            }
        }

        let game = PredictionGameStore(
            userDefaults: defaults, apiSession: session,
            credentialStorage: PredictionGameTestCredentials([base: "guest"])
        )
        await game.loadDashboard(apiBaseURL: base)

        #expect(game.selectedCompetitionID == "1")
        #expect(game.recentGameweeks.isEmpty)
        #expect(game.latestResult?.resolvedCompetitionID == "7")
        #expect(game.latestResult?.youPoints == 4)
        #expect(game.latestResult?.aiPoints == 3)
    }

    @Test func allCompetitionScopedReadsCarryTheirCompetitionAndFixtureLookupStaysMixed() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PredictionGameTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); PredictionGameTestURLProtocol.responseHandler = nil }
        let summary = try #require(String(data: JSONEncoder().encode(PredictionGameSummary.empty), encoding: .utf8))
        PredictionGameTestURLProtocol.responseHandler = { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let competition = items.first { $0.name == "competitionId" }?.value
            if request.url?.lastPathComponent == "fixtures" || items.contains(where: { $0.name == "fixtureId" }) {
                #expect(competition == nil)
            } else { #expect(competition == "2") }
            switch request.url?.lastPathComponent {
            case "state": return (200, Self.stateData(competition: "2", points: 0, summaryJSON: summary))
            case "stats": return (200, Data("{\"summary\":\(summary),\"seasons\":[],\"achievements\":[],\"competitionId\":\"2\"}".utf8))
            case "history": return (200, Data(#"{"fixtures":[],"total":0,"offset":0,"hasMore":false}"#.utf8))
            case "leaderboards": return (200, Data(#"{"rows":[],"category":"season","competitionId":"2","gameCenterLeaderboardId":"ucl.season"}"#.utf8))
            case "next-predictions": return (200, Data(#"{"serverTime":"2026-09-10T12:00:00Z","fixtures":[],"competitionId":"2"}"#.utf8))
            case "fixtures": return (200, Data(#"{"serverTime":"2026-09-10T12:00:00Z","fixtures":[]}"#.utf8))
            default: throw URLError(.badURL)
            }
        }
        let client = try PredictionGameAPIClient(apiBaseURL: "https://example.test/api/v1", session: session)
        _ = try await client.state(credential: "guest", competitionId: "2")
        _ = try await client.stats(credential: "guest", seasonId: "203", competitionId: "2")
        _ = try await client.history(credential: "guest", seasonId: nil, offset: 50, competitionId: "2")
        let board = try await client.leaderboard(category: .season, challengeId: nil, seasonId: nil, credential: "guest", competitionId: "2")
        #expect(board.gameCenterLeaderboardId == "ucl.season")
        _ = try await client.nextPredictions(credential: "guest", competitionId: "2")
        _ = try await client.nextPredictions(fixtureID: "123", credential: "guest")
        _ = try await client.fixtures(ids: ["123", "456"], credential: "guest")
    }

    @MainActor
    @Test func switchingCompetitionRejectsLateDashboardAndPredictionSetWithoutChangingPlayerScope() async throws {
        let suite = "PredictionCompetitionRace.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: PredictionGameStore.enabledPreferenceKey)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PredictionGameTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let base = "https://example.test/api/v1"
        let log = PredictionGameRequestLog()
        let summary = try #require(String(data: JSONEncoder().encode(PredictionGameSummary.empty), encoding: .utf8))
        defer {
            defaults.removePersistentDomain(forName: suite); session.invalidateAndCancel()
            PredictionGameTestURLProtocol.responseHandler = nil; PredictionGameTestURLProtocol.responseDelay = 0
        }
        PredictionGameTestURLProtocol.responseHandler = { request in
            log.record(request)
            let competition = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "competitionId" }?.value ?? "1"
            switch request.url?.lastPathComponent {
            case "state": return (200, Self.stateData(competition: competition, points: competition == "1" ? 90 : 7, summaryJSON: summary))
            case "history": return (200, Data(#"{"fixtures":[],"total":0,"offset":0,"hasMore":false}"#.utf8))
            case "next-predictions": return (200, Data("{\"serverTime\":\"2026-09-10T12:00:00Z\",\"fixtures\":[],\"competitionId\":\"\(competition)\"}".utf8))
            default: throw URLError(.badURL)
            }
        }
        let game = PredictionGameStore(userDefaults: defaults, apiSession: session,
            credentialStorage: PredictionGameTestCredentials([base: "guest"]))
        // Resolve the credential scope, then deliberately finish the first competition last.
        _ = await game.loadPredictionSet(apiBaseURL: base)
        let scope = game.playerScopeID
        let draftScope = game.playerDraftScopeID
        PredictionGameTestURLProtocol.responseDelay = 0.2
        let oldDashboard = Task { await game.loadDashboard(apiBaseURL: base) }
        let oldSet = Task { await game.loadPredictionSet(apiBaseURL: base) }
        for _ in 0..<100 where log.count(pathComponent: "state") == 0 || log.count(pathComponent: "next-predictions") < 2 {
            try await Task.sleep(for: .milliseconds(2))
        }
        PredictionGameTestURLProtocol.responseDelay = 0
        await game.selectCompetition("2", apiBaseURL: base)
        await oldDashboard.value
        #expect(await oldSet.value == nil)
        #expect(game.selectedCompetitionID == "2")
        #expect(game.selectedCompetition.name == "Champions League")
        #expect(game.summary.youPoints == 7)
        #expect(game.playerScopeID == scope)
        #expect(game.playerDraftScopeID == draftScope)
        #expect(!game.isLoading)
        #expect(game.errorMessage == nil)
    }

    @MainActor
    @Test func switchingCompetitionDropsOldHistoryPageAndDoesNotMixSavedFixturesIntoNewHistory() async throws {
        let suite = "PredictionCompetitionHistory.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: PredictionGameStore.enabledPreferenceKey)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PredictionGameTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let base = "https://example.test/api/v1"
        let log = PredictionGameRequestLog()
        let summary = try #require(String(data: JSONEncoder().encode(PredictionGameSummary.empty), encoding: .utf8))
        defer {
            defaults.removePersistentDomain(forName: suite); session.invalidateAndCancel()
            PredictionGameTestURLProtocol.responseHandler = nil; PredictionGameTestURLProtocol.responseDelay = 0
        }
        PredictionGameTestURLProtocol.responseHandler = { request in
            log.record(request)
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let competition = items.first { $0.name == "competitionId" }?.value ?? "1"
            switch request.url?.lastPathComponent {
            case "state": return (200, Self.stateData(competition: competition, points: 0, summaryJSON: summary))
            case "history":
                if competition == "1" {
                    let offset = items.first { $0.name == "offset" }?.value ?? "0"
                    return (200, Data("{\"fixtures\":[\(Self.fixtureJSON)],\"total\":2,\"offset\":\(offset),\"hasMore\":true}".utf8))
                }
                return (200, Data(#"{"fixtures":[],"total":0,"offset":0,"hasMore":false}"#.utf8))
            case "123": return (200, Data("{\"fixture\":\(Self.fixtureJSON),\"serverTime\":\"2026-09-10T12:00:00Z\"}".utf8))
            default: throw URLError(.badURL)
            }
        }
        let game = PredictionGameStore(userDefaults: defaults, apiSession: session,
            credentialStorage: PredictionGameTestCredentials([base: "guest"]))
        await game.loadDashboard(apiBaseURL: base)
        #expect(game.history.count == 1)
        #expect(game.hasMoreHistory)
        PredictionGameTestURLProtocol.responseDelay = 0.2
        let oldPage = Task { await game.loadMoreHistory(apiBaseURL: base) }
        for _ in 0..<100 where log.count(pathComponent: "history") < 2 { try await Task.sleep(for: .milliseconds(2)) }
        PredictionGameTestURLProtocol.responseDelay = 0
        await game.selectCompetition("2", apiBaseURL: base)
        await oldPage.value
        #expect(game.history.isEmpty)
        #expect(!game.hasMoreHistory)
        #expect(!game.isLoadingHistory)
        #expect(await game.save(fixtureID: "123", homeScore: 1, awayScore: 3, apiBaseURL: base))
        #expect(game.history.isEmpty)
        #expect(game.fixture(for: "123")?.prediction?.displayText == "1–3")
    }

    @MainActor
    @Test func friendsDashboardUsesOnlyConfiguredCompetitionBoardAndNeverFallsBackToGlobalRanks() async throws {
        let suite = "PredictionCompetitionFriends.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PredictionGameTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let base = "https://example.test/api/v1"
        let center = PredictionGameTestCenter()
        let summary = try #require(String(data: JSONEncoder().encode(PredictionGameSummary.empty), encoding: .utf8))
        defer {
            defaults.removePersistentDomain(forName: suite); session.invalidateAndCancel()
            PredictionGameTestURLProtocol.responseHandler = nil
        }
        PredictionGameTestURLProtocol.responseHandler = { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let competition = items.first { $0.name == "competitionId" }?.value ?? "1"
            switch request.url?.lastPathComponent {
            case "game-center": return (200, Data(#"{"player":{"id":"linked","displayName":"Linked","gameCenterLinked":true}}"#.utf8))
            case "submissions": return (200, Data(#"{"leaderboards":[],"achievements":[]}"#.utf8))
            case "state": return (200, Self.stateData(competition: competition, points: 0, summaryJSON: summary))
            case "history": return (200, Data(#"{"fixtures":[],"total":0,"offset":0,"hasMore":false}"#.utf8))
            case "leaderboards":
                let category = items.first { $0.name == "category" }?.value ?? "weekly"
                let identifier = competition == "1" ? "\"epl.\(category)\"" : "null"
                return (200, Data("{\"rows\":[],\"category\":\"\(category)\",\"competitionId\":\"\(competition)\",\"gameCenterLeaderboardId\":\(identifier)}".utf8))
            default: throw URLError(.badURL)
            }
        }
        let game = PredictionGameStore(userDefaults: defaults, apiSession: session,
            credentialStorage: PredictionGameTestCredentials([base: "guest"]), gameCenterFactory: { center })
        await game.gameScreenDidAppear(apiBaseURL: base)
        for _ in 0..<100 where center.authenticationCount == 0 || game.isConnectingGameCenter { try await Task.sleep(for: .milliseconds(2)) }
        await game.openGameCenterLeaderboards(apiBaseURL: base, category: .season)
        #expect(center.dashboardCount == 1)
        #expect(center.lastLeaderboardID == "epl.season")
        await game.selectCompetition("2", apiBaseURL: base)
        await game.openGameCenterLeaderboards(apiBaseURL: base, category: .season)
        #expect(center.dashboardCount == 1)
        #expect(game.gameCenterLeaderboardID == nil)
        #expect(game.gameCenterStatusMessage?.contains("Champions League") == true)
        #expect(game.gameCenterStatusMessage?.contains("not available") == true)
        game.gameScreenDidDisappear()
    }

    private static func stateData(competition: String, points: Int, summaryJSON: String) -> Data {
        let scopedSummary = summaryJSON.replacingOccurrences(of: "\"youPoints\":0", with: "\"youPoints\":\(points)")
        return Data("{\"player\":{\"id\":\"guest\",\"displayName\":\"Guest\",\"gameCenterLinked\":false},\"serverTime\":\"2026-09-10T12:00:00Z\",\"summary\":\(scopedSummary),\"seasons\":[],\"achievements\":[],\"fixtures\":[],\"competitionId\":\"\(competition)\",\"competitions\":[{\"id\":\"1\",\"name\":\"Premier League\"},{\"id\":\"2\",\"name\":\"Champions League\"}]}".utf8)
    }

    @MainActor
    @Test func automaticGameCenterRunsOnlyInsideGameOncePerPresentationAfterDecline() async throws {
        let suite = "GameCenterLifecycle.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = "https://example.test/api/v1"
        let center = PredictionGameTestCenter()
        center.authenticationError = NSError(domain: "GameCenterTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sign-in was declined."])
        let game = PredictionGameStore(userDefaults: defaults, credentialStorage: PredictionGameTestCredentials([base: "guest"]), gameCenterFactory: { center })
        await game.activate(apiBaseURL: base, loadDashboard: false)
        #expect(center.authenticationCount == 0)
        game.errorMessage = "An unrelated match error"
        await game.gameScreenDidAppear(apiBaseURL: base)
        for _ in 0..<100 where center.authenticationCount == 0 || game.isConnectingGameCenter { try await Task.sleep(for: .milliseconds(2)) }
        #expect(center.authenticationCount == 1)
        #expect(game.errorMessage == "An unrelated match error")
        #expect(game.gameCenterStatusMessage?.contains("Playing as a guest") == true)
        await game.gameScreenDidAppear(apiBaseURL: base)
        await Task.yield()
        #expect(center.authenticationCount == 1)
        game.gameScreenDidDisappear()
        await game.gameScreenDidAppear(apiBaseURL: base)
        for _ in 0..<100 where center.authenticationCount < 2 || game.isConnectingGameCenter { try await Task.sleep(for: .milliseconds(2)) }
        #expect(center.authenticationCount == 2)
        game.gameScreenDidDisappear()
    }

    @MainActor
    @Test func signedInAppleAccountWithUnrecognisedAppKeepsGuestPredictionsAvailable() async throws {
        let suite = "GameCenterRegistration.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let base = "https://example.test/api/v1"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PredictionGameTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let credentials = PredictionGameTestCredentials([base: "guest"])
        let center = PredictionGameTestCenter()
        center.currentTeamPlayerID = "team"
        center.authenticationError = NSError(domain: GKErrorDomain, code: GKError.Code.gameUnrecognized.rawValue)
        let log = PredictionGameRequestLog()
        defer { defaults.removePersistentDomain(forName: suite); session.invalidateAndCancel(); PredictionGameTestURLProtocol.responseHandler = nil }
        PredictionGameTestURLProtocol.responseHandler = { request in
            log.record(request)
            #expect(request.httpMethod == "PUT")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer guest")
            return (200, Data("{\"fixture\":\(Self.fixtureJSON),\"serverTime\":\"2026-09-10T12:00:00Z\"}".utf8))
        }
        let game = PredictionGameStore(userDefaults: defaults, apiSession: session, credentialStorage: credentials, gameCenterFactory: { center })
        await game.gameScreenDidAppear(apiBaseURL: base)
        for _ in 0..<100 where center.authenticationCount == 0 || game.isConnectingGameCenter { try await Task.sleep(for: .milliseconds(2)) }
        #expect(game.gameCenterStatusMessage?.contains("account is signed in") == true)
        #expect(game.gameCenterStatusMessage?.contains("hasn’t recognised this version of Top Scores") == true)
        #expect(game.gameCenterStatusMessage?.contains("Playing as a guest") == false)
        #expect(log.count(pathComponent: "game-center") == 0)
        #expect(await game.save(fixtureID: "123", homeScore: 1, awayScore: 3, apiBaseURL: base))
        #expect(game.fixture(for: "123")?.prediction?.awayScore == 3)
        #expect(credentials.load(server: base) == "guest")
        #expect(game.errorMessage == nil)
        game.gameScreenDidDisappear()
    }

    @MainActor
    @Test func verifiedAppleSignInWithFailedBackendLinkDoesNotReportSignInFailure() async throws {
        let suite = "GameCenterLinkFailure.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let base = "https://example.test/api/v1"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PredictionGameTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let credentials = PredictionGameTestCredentials([base: "guest"])
        let center = PredictionGameTestCenter()
        defer { defaults.removePersistentDomain(forName: suite); session.invalidateAndCancel(); PredictionGameTestURLProtocol.responseHandler = nil }
        PredictionGameTestURLProtocol.responseHandler = { request in
            #expect(request.url?.lastPathComponent == "game-center")
            return (503, Data(#"{"error":"game_center_unavailable","message":"Account linking is temporarily unavailable."}"#.utf8))
        }
        let game = PredictionGameStore(userDefaults: defaults, apiSession: session, credentialStorage: credentials, gameCenterFactory: { center })
        await game.gameScreenDidAppear(apiBaseURL: base)
        for _ in 0..<100 where center.authenticationCount == 0 || game.isConnectingGameCenter { try await Task.sleep(for: .milliseconds(2)) }
        #expect(game.gameCenterStatusMessage?.contains("account is signed in") == true)
        #expect(game.gameCenterStatusMessage?.contains("couldn’t link your game") == true)
        #expect(game.gameCenterStatusMessage?.contains("Playing as a guest") == false)
        #expect(game.player == nil)
        #expect(credentials.load(server: base) == "guest")
        #expect(game.errorMessage == nil)
        game.gameScreenDidDisappear()
    }

    @MainActor
    @Test func gameCenterPublicationAndDashboardFailuresKeepVerifiedPlayerLinked() async throws {
        let suite = "GameCenterPublicationFailure.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let base = "https://example.test/api/v1"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PredictionGameTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let credentials = PredictionGameTestCredentials([base: "linked-credential"])
        let center = PredictionGameTestCenter()
        center.submissionError = NSError(domain: GKErrorDomain, code: GKError.Code.gameUnrecognized.rawValue)
        center.dashboardError = NSError(domain: GKErrorDomain, code: GKError.Code.communicationsFailure.rawValue)
        defer { defaults.removePersistentDomain(forName: suite); session.invalidateAndCancel(); PredictionGameTestURLProtocol.responseHandler = nil }
        PredictionGameTestURLProtocol.responseHandler = { request in
            switch request.url?.lastPathComponent {
            case "game-center": return (200, Data(#"{"player":{"id":"linked","displayName":"Linked","gameCenterLinked":true}}"#.utf8))
            case "submissions": return (200, Data(#"{"leaderboards":[],"achievements":[]}"#.utf8))
            case "leaderboards": return (200, Data(#"{"rows":[],"category":"weekly","competitionId":"1","gameCenterLeaderboardId":"test.epl.weekly"}"#.utf8))
            default: throw URLError(.badURL)
            }
        }
        let game = PredictionGameStore(userDefaults: defaults, apiSession: session, credentialStorage: credentials, gameCenterFactory: { center })
        await game.gameScreenDidAppear(apiBaseURL: base)
        for _ in 0..<100 where center.submissionCount == 0 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(center.submissionCount == 1)
        #expect(game.gameCenterStatusMessage?.contains("hasn’t recognised this version of Top Scores") == true)
        #expect(game.player?.gameCenterLinked == true)
        await game.openGameCenterLeaderboards(apiBaseURL: base)
        #expect(center.dashboardCount == 1)
        #expect(center.authenticationCount == 1)
        #expect(game.gameCenterStatusMessage?.contains("Game Center couldn’t open") == true)
        #expect(game.gameCenterStatusMessage?.contains("Playing as a guest") == false)
        #expect(game.player?.id == "linked")
        #expect(game.player?.gameCenterLinked == true)
        #expect(credentials.load(server: base) == "linked-credential")
        #expect(game.errorMessage == nil)
        game.gameScreenDidDisappear()
    }

    @MainActor
    @Test func pendingAuthenticationDoesNotBlockFixtureReadsAndFinalDismissCancelsIt() async throws {
        let suite = "GameCenterPending.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let base = "https://example.test/api/v1"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PredictionGameTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { defaults.removePersistentDomain(forName: suite); session.invalidateAndCancel(); PredictionGameTestURLProtocol.responseHandler = nil }
        let center = PredictionGameTestCenter(); center.suspendsAuthentication = true
        PredictionGameTestURLProtocol.responseHandler = { request in
            #expect(request.url?.lastPathComponent == "fixtures")
            return (200, Data("{\"fixtures\":[\(Self.fixtureJSON)],\"serverTime\":\"2026-09-10T12:00:00Z\"}".utf8))
        }
        let game = PredictionGameStore(userDefaults: defaults, apiSession: session, credentialStorage: PredictionGameTestCredentials([base: "guest"]), gameCenterFactory: { center })
        await game.gameScreenDidAppear(apiBaseURL: base)
        for _ in 0..<100 where center.authenticationCount == 0 { try await Task.sleep(for: .milliseconds(2)) }
        let fixture = await game.loadFixture(fixtureID: "123", apiBaseURL: base)
        #expect(fixture?.id == "123")
        #expect(game.isConnectingGameCenter)
        center.isPresentingAuthentication = true
        game.gameScreenDidDisappear()
        #expect(center.cancellationCount == 0)
        center.isPresentingAuthentication = false
        game.gameScreenDidDisappear()
        for _ in 0..<100 where game.isConnectingGameCenter { try await Task.sleep(for: .milliseconds(2)) }
        #expect(center.cancellationCount == 1)
        #expect(!game.isConnectingGameCenter)
        #expect(game.errorMessage == nil)
    }

    @MainActor
    @Test func automaticRestoreWaitsForDraftEditingAndPreservesGuestCredential() async throws {
        let suite = "GameCenterRestore.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let base = "https://example.test/api/v1"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PredictionGameTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let credentials = PredictionGameTestCredentials([base: "guest"])
        let center = PredictionGameTestCenter()
        let summary = try #require(String(data: JSONEncoder().encode(PredictionGameSummary.empty), encoding: .utf8))
        defer { defaults.removePersistentDomain(forName: suite); session.invalidateAndCancel(); PredictionGameTestURLProtocol.responseHandler = nil }
        PredictionGameTestURLProtocol.responseHandler = { request in
            switch request.url?.lastPathComponent {
            case "fixtures": return (200, Data("{\"fixtures\":[\(Self.fixtureJSON)],\"serverTime\":\"2026-09-10T12:00:00Z\"}".utf8))
            case "game-center": return (200, Data(#"{"player":{"id":"restored","displayName":"Restored","gameCenterLinked":true},"credential":"restored-credential"}"#.utf8))
            case "state": return (200, Data("{\"player\":{\"id\":\"restored\",\"displayName\":\"Restored\",\"gameCenterLinked\":true},\"serverTime\":\"2026-09-10T12:00:00Z\",\"summary\":\(summary),\"seasons\":[],\"achievements\":[],\"challenge\":null,\"fixtures\":[],\"recentGameweeks\":[]}".utf8))
            case "history": return (200, Data(#"{"fixtures":[],"total":0,"offset":0,"hasMore":false}"#.utf8))
            case "submissions": return (200, Data(#"{"leaderboards":[],"achievements":[]}"#.utf8))
            default: throw URLError(.badURL)
            }
        }
        let game = PredictionGameStore(userDefaults: defaults, apiSession: session, credentialStorage: credentials, gameCenterFactory: { center })
        await game.activate(apiBaseURL: base, loadDashboard: false)
        _ = await game.loadFixture(fixtureID: "123", apiBaseURL: base)
        let guestScope = game.playerScopeID; let guestDraftScope = game.playerDraftScopeID
        game.setPredictionEditingActive(true)
        await game.gameScreenDidAppear(apiBaseURL: base)
        for _ in 0..<100 where center.authenticationCount == 0 || game.isConnectingGameCenter { try await Task.sleep(for: .milliseconds(2)) }
        #expect(credentials.load(server: base) == "guest")
        #expect(game.playerScopeID == guestScope)
        #expect(game.gameCenterStatusMessage?.contains("finish editing") == true)
        center.isPresentingAuthentication = true
        game.setPredictionEditingActive(false)
        #expect(credentials.load(server: base) == "guest")
        #expect(game.playerScopeID == guestScope)
        center.isPresentingAuthentication = false
        game.setPredictionEditingActive(false)
        #expect(credentials.load(server: base) == "restored-credential")
        #expect(credentials.load(server: "\(base)#preserved-guest") == "guest")
        #expect(game.playerScopeID != guestScope)
        #expect(game.playerDraftScopeID != guestDraftScope)
        #expect(game.player?.id == "restored")
        for _ in 0..<100 where game.isLoading { try await Task.sleep(for: .milliseconds(2)) }
        game.gameScreenDidDisappear()
    }

    @MainActor
    @Test func changingServerRestartsPendingAutomaticAuthenticationWithoutBlockingAppearance() async throws {
        let suite = "GameCenterServerChange.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = "https://first.test/api/v1"; let second = "https://second.test/api/v1"
        let center = PredictionGameTestCenter(); center.suspendsAuthentication = true
        let game = PredictionGameStore(userDefaults: defaults,
            credentialStorage: PredictionGameTestCredentials([first: "first-guest", second: "second-guest"]), gameCenterFactory: { center })
        await game.gameScreenDidAppear(apiBaseURL: first)
        for _ in 0..<100 where center.authenticationCount < 1 { try await Task.sleep(for: .milliseconds(2)) }
        let firstScope = game.playerScopeID
        await game.gameScreenDidAppear(apiBaseURL: second)
        for _ in 0..<100 where center.authenticationCount < 2 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(center.authenticationCount == 2)
        #expect(center.cancellationCount == 1)
        #expect(game.playerScopeID != firstScope)
        #expect(game.isConnectingGameCenter)
        game.gameScreenDidDisappear()
        for _ in 0..<100 where game.isConnectingGameCenter { try await Task.sleep(for: .milliseconds(2)) }
    }

    @MainActor
    @Test func stalledGameCenterPublicationDoesNotBlockDashboardAndCancelsOnDismissal() async throws {
        let suite = "GameCenterSync.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let base = "https://example.test/api/v1"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PredictionGameTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let center = PredictionGameTestCenter()
        let log = PredictionGameRequestLog()
        let summary = try #require(String(data: JSONEncoder().encode(PredictionGameSummary.empty), encoding: .utf8))
        PredictionGameTestURLProtocol.submissionsDelay = 1
        defer {
            defaults.removePersistentDomain(forName: suite)
            session.invalidateAndCancel()
            PredictionGameTestURLProtocol.responseHandler = nil
            PredictionGameTestURLProtocol.submissionsDelay = 0
        }
        PredictionGameTestURLProtocol.responseHandler = { request in
            log.record(request)
            switch request.url?.lastPathComponent {
            case "game-center": return (200, Data(#"{"player":{"id":"linked","displayName":"Linked","gameCenterLinked":true}}"#.utf8))
            case "state": return (200, Data("{\"player\":{\"id\":\"linked\",\"displayName\":\"Linked\",\"gameCenterLinked\":true},\"serverTime\":\"2026-09-10T12:00:00Z\",\"summary\":\(summary),\"seasons\":[],\"achievements\":[],\"challenge\":null,\"fixtures\":[],\"recentGameweeks\":[]}".utf8))
            case "history": return (200, Data(#"{"fixtures":[],"total":0,"offset":0,"hasMore":false}"#.utf8))
            case "submissions": return (200, Data(#"{"leaderboards":[],"achievements":[]}"#.utf8))
            default: throw URLError(.badURL)
            }
        }
        let game = PredictionGameStore(userDefaults: defaults, apiSession: session,
            credentialStorage: PredictionGameTestCredentials([base: "linked-credential"]), gameCenterFactory: { center })
        await game.gameScreenDidAppear(apiBaseURL: base)
        for _ in 0..<100 where log.count(pathComponent: "submissions") == 0 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(log.count(pathComponent: "submissions") == 1)
        var dashboardReturned = false
        let dashboard = Task {
            await game.loadDashboard(apiBaseURL: base)
            dashboardReturned = true
        }
        for _ in 0..<100 where !dashboardReturned { try await Task.sleep(for: .milliseconds(2)) }
        #expect(dashboardReturned)
        #expect(!game.isLoading)
        #expect(game.player?.id == "linked")
        #expect(center.submissionCount == 0)
        if dashboardReturned { await game.loadDashboard(apiBaseURL: base) }
        #expect(log.count(pathComponent: "submissions") == 1)
        game.gameScreenDidDisappear()
        dashboard.cancel()
        await dashboard.value
        try await Task.sleep(for: .milliseconds(1100))
        #expect(center.submissionCount == 0)
        #expect(game.errorMessage == nil)
    }

    @Test func decodesFrozenPredictionAndOptionalSettlement() throws {
        let fixture = try PredictionGameAPIClient.decoder().decode(
            PredictionGameFixture.self, from: Data(Self.fixtureJSON.utf8)
        )

        #expect(fixture.ai?.displayText == "0–2")
        #expect(fixture.ai?.frozenAt != nil)
        #expect(fixture.prediction?.displayText == "1–3")
        #expect(fixture.prediction?.youPoints == nil)
        #expect(fixture.canPredict)
        #expect(fixture.result == nil)
    }

    @Test func acceptsOnlyBSDNumericFixtureIDs() {
        #expect(PredictionGameFixtureID.normalized("bsd:123") == "123")
        #expect(PredictionGameFixtureID.normalized("00123") == "123")
        #expect(PredictionGameFixtureID.normalized("123") == "123")
        #expect(PredictionGameFixtureID.normalized("bbc:123") == nil)
        #expect(PredictionGameFixtureID.normalized("0") == nil)
        #expect(PredictionGameFixtureID.normalized("bsd:123/../../players") == nil)
    }

    @MainActor
    @Test func gameRemainsInactiveWithoutCreatingPlayerOrContactingServer() async throws {
        let suiteName = "PredictionGameClientTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PredictionGameTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        PredictionGameTestURLProtocol.responseHandler = { _ in
            Issue.record("An inactive game must not contact the server")
            throw URLError(.cancelled)
        }
        defer { PredictionGameTestURLProtocol.responseHandler = nil }
        let game = PredictionGameStore(userDefaults: defaults, apiSession: session)

        await game.loadEntries(fixtureIDs: ["bsd:123"], apiBaseURL: "https://example.test/api/v1")
        await game.loadDashboard(apiBaseURL: "https://example.test/api/v1")
        _ = await game.loadPredictionSet(apiBaseURL: "https://example.test/api/v1")
        await game.connectGameCenter(apiBaseURL: "https://example.test/api/v1")

        #expect(!game.enabled)
        #expect(game.player == nil)
        #expect(game.errorMessage == nil)
        #expect(game.fixtures.isEmpty)
    }

    @MainActor
    @Test func predictionEntryActivationSkipsDashboardAndCanLoadItsFixture() async throws {
        let suiteName = "PredictionGameActivationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PredictionGameTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let requestLog = PredictionGameRequestLog()
        let credentials = PredictionGameTestCredentials([:])
        defer {
            session.invalidateAndCancel()
            PredictionGameTestURLProtocol.responseHandler = nil
        }
        PredictionGameTestURLProtocol.responseHandler = { request in
            requestLog.record(request)
            switch request.url?.lastPathComponent {
            case "players":
                #expect(request.httpMethod == "POST")
                return (200, Data(#"{"player":{"id":"guest","displayName":"Guest","gameCenterLinked":false},"credential":"entry-credential"}"#.utf8))
            case "fixtures":
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer entry-credential")
                return (200, Data("{\"fixtures\":[\(Self.fixtureJSON)],\"serverTime\":\"2026-09-10T12:00:00Z\"}".utf8))
            default:
                Issue.record("Opening a prediction must not request dashboard, history, or Game Center data")
                throw URLError(.badServerResponse)
            }
        }
        let game = PredictionGameStore(userDefaults: defaults, apiSession: session, credentialStorage: credentials)
        let baseURL = "https://example.test/api/v1"

        await game.activate(apiBaseURL: baseURL, loadDashboard: false)

        #expect(game.enabled)
        #expect(defaults.bool(forKey: PredictionGameStore.enabledPreferenceKey))
        #expect(requestLog.count == 0)
        #expect(!game.isLoading)
        #expect(!game.isConnectingGameCenter)

        let fixture = await game.loadFixture(fixtureID: "123", apiBaseURL: baseURL)

        #expect(fixture?.id == "123")
        #expect(game.fixture(for: "123") == fixture)
        #expect(requestLog.count == 2)
        #expect(game.errorMessage == nil)
        #expect(!game.isConnectingGameCenter)
    }

    @MainActor
    @Test func initialCredentialIOAvoidsMainThreadAndSharesPlayerCreation() async throws {
        let suiteName = "PredictionGameCredentialThreadTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PredictionGameTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let requestLog = PredictionGameRequestLog()
        let storedCredentials = PredictionGameTestCredentials([:])
        let credentials = PredictionGameBackgroundTestCredentials(storage: storedCredentials)
        defer {
            session.invalidateAndCancel()
            PredictionGameTestURLProtocol.responseHandler = nil
        }
        PredictionGameTestURLProtocol.responseHandler = { request in
            requestLog.record(request)
            switch request.url?.lastPathComponent {
            case "players":
                return (200, Data(#"{"player":{"id":"guest","displayName":"Guest","gameCenterLinked":false},"credential":"entry-credential"}"#.utf8))
            case "fixtures":
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer entry-credential")
                return (200, Data("{\"fixtures\":[\(Self.fixtureJSON)],\"serverTime\":\"2026-09-10T12:00:00Z\"}".utf8))
            default:
                throw URLError(.badServerResponse)
            }
        }
        let game = PredictionGameStore(userDefaults: defaults, apiSession: session, credentialStorage: credentials)
        let baseURL = "https://example.test/api/v1"
        await game.activate(apiBaseURL: baseURL, loadDashboard: false)

        async let first = game.loadFixture(fixtureID: "123", apiBaseURL: baseURL)
        async let second = game.loadFixture(fixtureID: "123", apiBaseURL: baseURL)
        let fixtures = await [first, second]

        #expect(fixtures.allSatisfy { $0?.id == "123" })
        #expect(requestLog.count(pathComponent: "players") == 1)
        #expect(storedCredentials.load(server: baseURL) == "entry-credential")
        #expect(game.errorMessage == nil)
    }

    @MainActor
    @Test func editorLocksExactlyAtKickoff() throws {
        let fixture = try PredictionGameAPIClient.decoder().decode(
            PredictionGameFixture.self, from: Data(Self.fixtureJSON.utf8)
        )
        let game = PredictionGameStore()

        #expect(game.canEdit(fixture: fixture, at: fixture.kickoffAt.addingTimeInterval(-1)))
        #expect(!game.canEdit(fixture: fixture, at: fixture.kickoffAt))
        #expect(!game.canEdit(fixture: fixture, at: fixture.kickoffAt.addingTimeInterval(1)))
    }

    @Test func saveKeepsConfiguredAPIPrefixAndUsesBearerCredential() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PredictionGameTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            PredictionGameTestURLProtocol.responseHandler = nil
        }
        PredictionGameTestURLProtocol.responseHandler = { request in
            #expect(request.url?.path == "/top-scores/api/v1/prediction-game/predictions/123")
            #expect(request.httpMethod == "PUT")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer guest-credential")
            return (200, Data("{\"fixture\":\(Self.fixtureJSON),\"serverTime\":\"2026-09-10T12:00:00Z\"}".utf8))
        }
        let client = try PredictionGameAPIClient(apiBaseURL: "https://example.test/top-scores/api/v1", session: session)
        let result = try await client.save(fixtureID: "bsd:123", homeScore: 1, awayScore: 3, expectedAIRevision: "revision-1", credential: "guest-credential")

        #expect(result.fixture.id == "123")
        #expect(result.fixture.prediction?.homeScore == 1)
    }

    @Test func existingGameCenterAccountRequiresExplicitRestore() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PredictionGameTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            PredictionGameTestURLProtocol.responseHandler = nil
        }
        PredictionGameTestURLProtocol.responseHandler = { _ in
            (409, Data(#"{"error":"Existing player history is available.","code":"existing_game_center_player"}"#.utf8))
        }
        let client = try PredictionGameAPIClient(apiBaseURL: "https://example.test/api/v1", session: session)
        do {
            _ = try await client.linkGameCenter(identity: PredictionGameCenterIdentity(
                gamePlayerId: "game", teamPlayerId: "team", publicKeyUrl: "https://example.test/key",
                signature: "signature", salt: "salt", timestamp: 1, displayName: "Player"
            ), credential: "guest-credential")
            Issue.record("An existing account must require confirmation before switching players")
        } catch let error as PredictionGameAPIError {
            #expect(error.requiresGameCenterRestore)
        }
    }

    @MainActor
    @Test func lateFixtureResponseCannotEraseAcceptedPrediction() async throws {
        let suiteName = "PredictionGameRaceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: PredictionGameStore.enabledPreferenceKey)
        let baseURL = "https://prediction-game-\(UUID().uuidString).test/api/v1"
        let credentials = PredictionGameTestCredentials([baseURL: "race-test-credential"])
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PredictionGameTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let requestLog = PredictionGameRequestLog()
        PredictionGameTestURLProtocol.responseDelay = 0.15
        defer {
            session.invalidateAndCancel()
            PredictionGameTestURLProtocol.responseHandler = nil
            PredictionGameTestURLProtocol.responseDelay = 0
        }
        var earlyFixture = try #require(JSONSerialization.jsonObject(with: Data(Self.fixtureJSON.utf8)) as? [String: Any])
        earlyFixture["prediction"] = NSNull()
        let earlyFixtureData = try JSONSerialization.data(withJSONObject: earlyFixture)
        let earlyFixtureJSON = try #require(String(data: earlyFixtureData, encoding: .utf8))
        PredictionGameTestURLProtocol.responseHandler = { request in
            requestLog.record(request)
            if request.httpMethod == "PUT" {
                return (200, Data("{\"fixture\":\(Self.fixtureJSON),\"serverTime\":\"2026-09-10T12:00:00Z\"}".utf8))
            }
            return (200, Data("{\"fixtures\":[\(earlyFixtureJSON)],\"serverTime\":\"2026-09-10T11:59:59Z\"}".utf8))
        }
        let game = PredictionGameStore(userDefaults: defaults, apiSession: session, credentialStorage: credentials)
        let pendingRead = Task { await game.loadEntries(fixtureIDs: ["123"], apiBaseURL: baseURL) }
        for _ in 0..<100 where requestLog.count == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        // Only fixture reads are delayed. The accepted PUT is delivered first.
        let saved = await game.save(fixtureID: "123", homeScore: 1, awayScore: 3, expectedAIRevision: "revision-1", apiBaseURL: baseURL)
        await pendingRead.value

        #expect(saved)
        #expect(game.fixture(for: "123")?.prediction?.displayText == "1–3")
        #expect(game.fixture(for: "123")?.ai?.frozenAt != nil)
    }

    @MainActor
    @Test func changingServersBypassesPreviousServersFreshFixtureCache() async throws {
        let suiteName = "PredictionGameScopeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: PredictionGameStore.enabledPreferenceKey)
        let firstServer = "https://prediction-game-a-\(UUID().uuidString).test/api/v1"
        let secondServer = "https://prediction-game-b-\(UUID().uuidString).test/api/v1"
        let credentials = PredictionGameTestCredentials([
            firstServer: "first-credential", secondServer: "second-credential"
        ])
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PredictionGameTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let requestLog = PredictionGameRequestLog()
        defer {
            session.invalidateAndCancel()
            PredictionGameTestURLProtocol.responseHandler = nil
        }
        PredictionGameTestURLProtocol.responseHandler = { request in
            requestLog.record(request)
            let payload = request.value(forHTTPHeaderField: "Authorization") == "Bearer second-credential" ? "[]" : "[\(Self.fixtureJSON)]"
            return (200, Data("{\"fixtures\":\(payload),\"serverTime\":\"2026-09-10T12:00:00Z\"}".utf8))
        }
        let game = PredictionGameStore(userDefaults: defaults, apiSession: session, credentialStorage: credentials)
        await game.loadEntries(fixtureIDs: ["123"], apiBaseURL: firstServer)
        #expect(game.fixture(for: "123") != nil)
        await game.loadEntries(fixtureIDs: ["123"], apiBaseURL: secondServer)

        #expect(requestLog.count == 2)
        #expect(game.fixture(for: "123") == nil)
    }

    private static let fixtureJSON = #"""
    {
      "id":"123","homeTeam":"Arsenal","awayTeam":"Chelsea",
      "seasonId":"2026","seasonLabel":"2026/27","kickoffAt":"2026-09-12T14:00:00.000Z",
      "status":"notstarted","locked":false,"settled":false,"void":false,"challengeId":"2026-W37",
      "ai":{"homeScore":0,"awayScore":2,"modelVersion":"v1","sourceRevision":"revision-1","frozenAt":"2026-09-10T12:00:00Z"},
      "prediction":{"homeScore":1,"awayScore":3,"savedAt":"2026-09-10T12:00:00.000Z","youPoints":null,"aiPoints":null,"outcome":null},
      "result":null
    }
    """#
}

private final class PredictionGameTestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseHandler: (@Sendable (URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var responseDelay: TimeInterval = 0
    nonisolated(unsafe) static var submissionsDelay: TimeInterval = 0
    private let lock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.responseHandler, let url = request.url else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            let delay = request.url?.lastPathComponent == "submissions" ? Self.submissionsDelay : (request.httpMethod == "GET" ? Self.responseDelay : 0)
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.lock.withLock({ self.stopped }) else { return }
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { lock.withLock { stopped = true } }
}

private final class PredictionGameRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var count: Int { lock.withLock { requests.count } }
    func record(_ request: URLRequest) { lock.withLock { requests.append(request) } }
    func count(pathComponent: String) -> Int { lock.withLock { requests.filter { $0.url?.lastPathComponent == pathComponent }.count } }
}

private final class PredictionGameTestCredentials: PredictionGameCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [String: String]

    init(_ credentials: [String: String]) { self.credentials = credentials }
    func load(server: String) -> String? { lock.withLock { credentials[server] } }
    func save(_ credential: String, server: String) {
        lock.withLock { credentials[server] = credential }
    }
    func preserveGuest(_ credential: String, server: String) {
        save(credential, server: "\(server)#preserved-guest")
    }
}

private struct PredictionGameBackgroundTestCredentials: PredictionGameCredentialStorage {
    let storage: PredictionGameTestCredentials

    func load(server: String) -> String? {
        #expect(!Thread.isMainThread, "Initial Keychain reads must not block match navigation")
        return storage.load(server: server)
    }

    func save(_ credential: String, server: String) {
        #expect(!Thread.isMainThread, "Initial Keychain writes must not block match navigation")
        storage.save(credential, server: server)
    }

    func preserveGuest(_ credential: String, server: String) {
        storage.preserveGuest(credential, server: server)
    }
}

@MainActor
private final class PredictionGameTestCenter: PredictionGameCenterServing {
    var isPresentingAuthentication = false
    var currentTeamPlayerID: String?
    var authenticationCount = 0
    var cancellationCount = 0
    var submissionCount = 0
    var dashboardCount = 0
    var lastLeaderboardID: String?
    var authenticationError: Error?
    var submissionError: Error?
    var dashboardError: Error?
    var suspendsAuthentication = false
    private var continuation: CheckedContinuation<PredictionGameCenterIdentity, Error>?

    func authenticate() async throws -> PredictionGameCenterIdentity {
        authenticationCount += 1
        if let authenticationError { throw authenticationError }
        if suspendsAuthentication {
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        currentTeamPlayerID = "team"
        return PredictionGameCenterIdentity(gamePlayerId: "game", teamPlayerId: "team", publicKeyUrl: "https://static.gc.apple.com/public-key/test.cer", signature: "signature", salt: "salt", timestamp: 1, displayName: "Player")
    }
    func cancelAuthentication() {
        cancellationCount += 1
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
    func isAuthenticated(expectedTeamPlayerID: String) -> Bool { currentTeamPlayerID == expectedTeamPlayerID }
    func showLeaderboards(expectedTeamPlayerID: String, leaderboardID: String?) throws {
        lastLeaderboardID = leaderboardID
        dashboardCount += 1
        if let dashboardError { throw dashboardError }
    }
    func showAchievements(expectedTeamPlayerID: String) throws {
        dashboardCount += 1
        if let dashboardError { throw dashboardError }
    }
    func submit(_ submissions: PredictionGameCenterSubmissions, expectedTeamPlayerID: String) async throws {
        submissionCount += 1
        if let submissionError { throw submissionError }
    }
}
