import Combine
import Foundation
import Testing
@testable import Top_Scores

@Suite(.serialized)
@MainActor
struct PredictionMiniLeagueClientTests {
    @Test func verifiedCredentialRotationPreservesDraftsAndClearsPrivateDataOnExit() async throws {
        let harness = try MiniLeagueHarness()
        defer { harness.finish() }
        await harness.game.activate(apiBaseURL: harness.base, loadDashboard: false)
        _ = await harness.game.loadFixture(fixtureID: "123", apiBaseURL: harness.base)
        let draftScope = harness.game.playerDraftScopeID
        await harness.game.gameScreenDidAppear(apiBaseURL: harness.base)
        let leagues = PredictionMiniLeagueStore()
        await leagues.load(game: harness.game, apiBaseURL: harness.base)
        #expect(harness.game.playerDraftScopeID == draftScope)
        #expect(leagues.leagues.first?.name == "Sunday Legends")
        #expect(harness.log.privateCredentials == ["Bearer verified-credential"])
        #expect(harness.credentials.load(server: harness.base) == "verified-credential")
        #expect(harness.game.gameCenterStatusMessage == "Connected to Game Center.")
        harness.game.gameScreenDidDisappear()
        #expect(leagues.leagues.isEmpty)
    }

    @Test func expiredPrivateCredentialRefreshesAutomaticallyWhenSavingFromFixtures() async throws {
        let harness = try MiniLeagueHarness()
        defer { harness.finish() }
        await harness.game.activate(apiBaseURL: harness.base, loadDashboard: false)
        let saved = await harness.game.save(fixtureID: "123", homeScore: 2, awayScore: 1,
            expectedAIRevision: "revision-1", apiBaseURL: harness.base)
        #expect(saved)
        #expect(harness.log.paths.filter { $0.hasSuffix("/predictions/123") }.count == 2)
        #expect(harness.game.fixture(for: "123")?.prediction?.displayText == "2–1")
        #expect(harness.credentials.load(server: harness.base) == "verified-credential")
    }

    @Test func guestCannotReadPrivateLeagues() async throws {
        let harness = try MiniLeagueHarness()
        defer { harness.finish() }
        harness.center.failure = URLError(.userAuthenticationRequired)
        await harness.game.gameScreenDidAppear(apiBaseURL: harness.base)
        let leagues = PredictionMiniLeagueStore()
        await leagues.load(game: harness.game, apiBaseURL: harness.base)
        #expect(leagues.leagues.isEmpty)
        #expect(leagues.errorMessage?.contains("Game Center") == true)
        #expect(harness.log.privateCredentials.isEmpty)
    }

    @Test func linkedPlayerWithoutProofBoundExpiryCannotUseOldGuestSession() async throws {
        let harness = try MiniLeagueHarness(verified: false)
        defer { harness.finish() }
        await harness.game.gameScreenDidAppear(apiBaseURL: harness.base)
        let leagues = PredictionMiniLeagueStore()
        await leagues.load(game: harness.game, apiBaseURL: harness.base)
        #expect(harness.game.player?.gameCenterLinked == true)
        #expect(leagues.leagues.isEmpty)
        #expect(harness.log.privateCredentials.isEmpty)
        #expect(leagues.errorMessage?.contains("Game Center") == true)
    }

    @Test func screenTimeMultiplayerRestrictionBlocksPrivateRequests() async throws {
        let harness = try MiniLeagueHarness()
        defer { harness.finish() }
        harness.center.isMultiplayerGamingRestricted = true
        await harness.game.gameScreenDidAppear(apiBaseURL: harness.base)
        let leagues = PredictionMiniLeagueStore()
        await leagues.load(game: harness.game, apiBaseURL: harness.base)
        #expect(leagues.leagues.isEmpty)
        #expect(leagues.errorMessage?.contains("Screen Time") == true)
        #expect(harness.log.privateCredentials.isEmpty)
        #expect(harness.game.enabled)
    }

    @Test func accountChangeDuringPrivateReadDiscardsResponse() async throws {
        let harness = try MiniLeagueHarness()
        defer { harness.finish() }
        MiniLeagueURLProtocol.privateDelay = 0.15
        await harness.game.gameScreenDidAppear(apiBaseURL: harness.base)
        let leagues = PredictionMiniLeagueStore()
        let loading = Task { await leagues.load(game: harness.game, apiBaseURL: harness.base) }
        for _ in 0..<100 where harness.log.privateCredentials.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        harness.center.currentTeamPlayerID = "another-account"
        await loading.value
        #expect(leagues.leagues.isEmpty)
        #expect(leagues.invitation == nil)
    }

    @Test func invitationPreviewDoesNotJoinAndCreationNeverSendsPointsOrPlayerIdentity() async throws {
        let harness = try MiniLeagueHarness()
        defer { harness.finish() }
        await harness.game.gameScreenDidAppear(apiBaseURL: harness.base)
        let leagues = PredictionMiniLeagueStore()
        #expect(await leagues.preview(code: "ABCD2345EFGH", game: harness.game, apiBaseURL: harness.base))
        #expect(leagues.invitationPreview?.leagueName == "Sunday Legends")
        #expect(leagues.leagues.isEmpty)
        let created = await leagues.create(name: "Sunday Legends", competitionID: "1", game: harness.game, apiBaseURL: harness.base)
        #expect(created?.competitionId == "1")
        let body = try #require(harness.log.createBody)
        #expect(Set(body.keys) == Set(["name", "competitionId", "showAI"]))
        #expect(harness.log.paths.filter { $0.contains("redeem") }.isEmpty)
    }

    @Test func authenticationChangeClearsAnAlreadyDisplayedPrivateTable() async throws {
        let harness = try MiniLeagueHarness()
        defer { harness.finish() }
        await harness.game.gameScreenDidAppear(apiBaseURL: harness.base)
        let leagues = PredictionMiniLeagueStore()
        await leagues.load(game: harness.game, apiBaseURL: harness.base)
        #expect(!leagues.leagues.isEmpty)
        harness.center.currentTeamPlayerID = nil
        harness.center.changes.send(())
        for _ in 0..<20 where !leagues.leagues.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        #expect(leagues.leagues.isEmpty)
    }

    @Test func invalidLeagueIdentifierNeverBecomesARequestPath() async throws {
        let harness = try MiniLeagueHarness()
        defer { harness.finish() }
        await harness.game.gameScreenDidAppear(apiBaseURL: harness.base)
        let leagues = PredictionMiniLeagueStore()
        await leagues.loadDetail(leagueID: "../players", game: harness.game, apiBaseURL: harness.base)
        #expect(leagues.detail == nil)
        #expect(leagues.errorMessage != nil)
        #expect(harness.log.privateCredentials.isEmpty)
    }
}

@MainActor
final class MiniLeagueHarness {
    let base = "https://example.test/top-scores/api/v1"
    let suite = "PredictionMiniLeagueTests." + UUID().uuidString
    let defaults: UserDefaults
    let session: URLSession
    let credentials: MiniLeagueCredentials
    let center = MiniLeagueCenter()
    let log = MiniLeagueRequestLog()
    let game: PredictionGameStore

    init(verified: Bool = true) throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MiniLeagueURLProtocol.self]
        session = URLSession(configuration: configuration)
        credentials = MiniLeagueCredentials([base: "guest-credential"])
        game = PredictionGameStore(userDefaults: defaults, apiSession: session,
            credentialStorage: credentials, gameCenterFactory: { [center] in center })
        let log = log
        MiniLeagueURLProtocol.handler = { request in
            log.record(request)
            let path = request.url?.lastPathComponent ?? ""
            switch path {
            case "game-center":
                let proof = verified ? #", "credential":"verified-credential", "privateSessionExpiresAt":"2099-09-11T12:00:00Z", "restoredExisting":false"# : ""
                return (200, Data((#"{"player":{"id":"player","displayName":"You","gameCenterLinked":true}"# + proof + "}").utf8))
            case "fixtures": return (200, Data(#"{"fixtures":[],"serverTime":"2026-09-10T12:00:00Z"}"#.utf8))
            case "123":
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer guest-credential" {
                    return (401, Data(#"{"error":"Verify Game Center","code":"game_center_required"}"#.utf8))
                }
                return (200, Data((#"{"fixture":"# + Self.fixtureJSON + #","serverTime":"2026-09-10T12:00:00Z"}"#).utf8))
            case "submissions": return (200, Data(#"{"leaderboards":[],"achievements":[]}"#.utf8))
            case "my-leagues": return (200, Data((#"{"leagues":["# + Self.leagueJSON + #"],"serverTime":"2026-09-10T12:00:00Z"}"#).utf8))
            case "mini-leagues": return (200, Data((#"{"league":"# + Self.leagueJSON + #","serverTime":"2026-09-10T12:00:00Z"}"#).utf8))
            case "preview": return (200, Data(#"{"invitation":{"leagueId":"league-1","leagueName":"Sunday Legends","competitionName":"Premier League","memberCount":2,"expiresAt":"2099-09-11T12:00:00Z","alreadyMember":false,"startsFrom":"Round 5"},"serverTime":"2026-09-10T12:00:00Z"}"#.utf8))
            default: throw URLError(.badURL)
            }
        }
    }
    func finish() {
        game.gameScreenDidDisappear()
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suite)
        MiniLeagueURLProtocol.handler = nil
        MiniLeagueURLProtocol.privateDelay = 0
    }
    nonisolated private static let fixtureJSON = #"{"id":"123","homeTeam":"Arsenal","awayTeam":"Chelsea","seasonId":"2026","seasonLabel":"2026/27","kickoffAt":"2099-09-12T14:00:00Z","status":"notstarted","locked":false,"settled":false,"void":false,"challengeId":null,"ai":{"homeScore":1,"awayScore":1,"modelVersion":"v2","sourceRevision":"revision-1","frozenAt":"2026-09-10T12:00:00Z"},"prediction":{"homeScore":2,"awayScore":1,"savedAt":"2026-09-10T12:00:00Z","youPoints":null,"aiPoints":null,"outcome":null},"result":null}"#
    nonisolated private static let leagueJSON = #"{"id":"league-1","name":"Sunday Legends","competitionId":"1","competitionName":"Premier League","ownerMemberId":"member-1","myMemberId":"member-1","isOwner":true,"showAI":true,"status":"active","memberCount":2,"position":1,"points":12,"gapToLeader":0,"currentRound":null,"startsFrom":"Round 5","createdAt":"2026-09-10T12:00:00Z"}"#
}

final class MiniLeagueURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var privateDelay: TimeInterval = 0
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler, let url = request.url else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            let delay = url.lastPathComponent == "my-leagues" ? Self.privateDelay : 0
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.lock.withLock({ self.stopped }) else { return }
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { lock.withLock { stopped = true } }
}
final class MiniLeagueRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var paths: [String] { lock.withLock { requests.compactMap { $0.url?.path } } }
    var privateCredentials: [String] { lock.withLock { requests.filter { $0.url?.lastPathComponent == "my-leagues" }.compactMap { $0.value(forHTTPHeaderField: "Authorization") } } }
    var createBody: [String: Any]? {
        lock.withLock {
            guard let request = requests.first(where: { $0.url?.lastPathComponent == "mini-leagues" }), let data = request.httpBody else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }
    func record(_ request: URLRequest) {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            captured.httpBody = data
        }
        let snapshot = captured
        lock.withLock { requests.append(snapshot) }
    }
}
final class MiniLeagueCredentials: PredictionGameCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    init(_ values: [String: String]) { self.values = values }
    func load(server: String) -> String? { lock.withLock { values[server] } }
    func save(_ credential: String, server: String) { lock.withLock { values[server] = credential } }
    func preserveGuest(_ credential: String, server: String) { save(credential, server: server + "#guest") }
}
@MainActor
final class MiniLeagueCenter: PredictionGameCenterServing {
    var isPresentingAuthentication = false
    var currentTeamPlayerID: String?
    var isMultiplayerGamingRestricted = false
    let changes = PassthroughSubject<Void, Never>()
    var authenticationChanges: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }
    var failure: Error?
    func isAuthenticated(expectedTeamPlayerID: String) -> Bool { currentTeamPlayerID == expectedTeamPlayerID }
    func authenticate() async throws -> PredictionGameCenterIdentity {
        if let failure { throw failure }
        currentTeamPlayerID = "team"
        return PredictionGameCenterIdentity(gamePlayerId: "game", teamPlayerId: "team", publicKeyUrl: "https://static.gc.apple.com/public-key/test.cer", signature: "signature", salt: "salt", timestamp: 1, displayName: "You")
    }
    func cancelAuthentication() {}
    func showLeaderboards(expectedTeamPlayerID: String, leaderboardID: String?) throws {}
    func showAchievements(expectedTeamPlayerID: String) throws {}
    func submit(_ submissions: PredictionGameCenterSubmissions, expectedTeamPlayerID: String) async throws {}
}
