import Foundation
import Testing
@testable import Top_Scores

@Suite(.serialized)
struct PredictionGameWeekSessionTests {
    @MainActor
    @Test func blankAndUnchangedRowsNeverBecomeImplicitZeroZeroPicks() async throws {
        let server = WeekSessionTestServer(existingIDs: ["2"])
        let environment = try WeekSessionTestEnvironment(server: server)
        defer { environment.close() }
        let week = PredictionGameWeekSession()
        await week.load(game: environment.game, apiBaseURL: environment.baseURL)

        #expect(week.fixtures.count == 3)
        #expect(week.draft(for: "1").homeScore == nil)
        #expect(week.draft(for: "1").awayScore == nil)
        #expect(week.draft(for: "2").homeScore == 2)
        #expect(week.changedCount == 0)
        await week.save(game: environment.game, apiBaseURL: environment.baseURL)
        #expect(server.attemptedIDs.isEmpty)
        #expect(server.requestedAllMatches)
    }

    @MainActor
    @Test func validatesPartialAndOutOfRangePairsWhileSavingExplicitZeroZero() async throws {
        let server = WeekSessionTestServer()
        let environment = try WeekSessionTestEnvironment(server: server)
        defer { environment.close() }
        let week = PredictionGameWeekSession()
        await week.load(game: environment.game, apiBaseURL: environment.baseURL)
        week.setHomeScore(1, for: "1")
        week.setHomeScore(0, for: "2")
        week.setAwayScore(0, for: "2")
        week.setHomeScore(21, for: "3")
        week.setAwayScore(1, for: "3")

        await week.save(game: environment.game, apiBaseURL: environment.baseURL)

        #expect(server.attemptedIDs == ["2"])
        #expect(environment.game.fixture(for: "2")?.prediction?.displayText == "0–0")
        #expect(week.rowErrors["1"]?.contains("both scores") == true)
        #expect(week.rowErrors["3"]?.contains("0 to 20") == true)
        #expect(week.draft(for: "1").homeScore == 1)
        #expect(week.draft(for: "1").awayScore == nil)
    }

    @MainActor
    @Test func partialSuccessRetriesOnlyUnconfirmedRows() async throws {
        let server = WeekSessionTestServer(failOnceIDs: ["2"])
        let environment = try WeekSessionTestEnvironment(server: server)
        defer { environment.close() }
        let week = PredictionGameWeekSession()
        await week.load(game: environment.game, apiBaseURL: environment.baseURL)
        for id in ["1", "2"] {
            week.setHomeScore(3, for: id)
            week.setAwayScore(1, for: id)
        }
        await week.save(game: environment.game, apiBaseURL: environment.baseURL)

        #expect(server.attemptedIDs == ["1", "2"])
        #expect(!week.draft(for: "1").isChanged)
        #expect(week.draft(for: "2").isChanged)
        #expect(week.confirmationMessage == "Saved 1 prediction.")
        #expect(week.rowErrors["2"] != nil)
        await week.save(game: environment.game, apiBaseURL: environment.baseURL)

        #expect(server.attemptedIDs == ["1", "2", "2"])
        #expect(week.changedCount == 0)
        #expect(week.rowErrors["2"] == nil)
    }

    @MainActor
    @Test func changedAIRequiresReviewAndKeepsTheTypedScores() async throws {
        let server = WeekSessionTestServer(changeAIOnceIDs: ["1"])
        let environment = try WeekSessionTestEnvironment(server: server)
        defer { environment.close() }
        let week = PredictionGameWeekSession()
        await week.load(game: environment.game, apiBaseURL: environment.baseURL)
        week.setHomeScore(4, for: "1")
        week.setAwayScore(3, for: "1")
        await week.save(game: environment.game, apiBaseURL: environment.baseURL)

        #expect(week.draft(for: "1").homeScore == 4)
        #expect(week.draft(for: "1").awayScore == 3)
        #expect(week.rowErrors["1"]?.contains("AI now predicts 2–0") == true)
        #expect(environment.game.fixture(for: "1")?.prediction == nil)
        await week.save(game: environment.game, apiBaseURL: environment.baseURL)

        #expect(server.submittedRevisions == ["revision-1", "revision-2"])
        #expect(environment.game.fixture(for: "1")?.ai?.sourceRevision == "revision-2")
        #expect(environment.game.fixture(for: "1")?.prediction?.displayText == "4–3")
        #expect(!week.draft(for: "1").isChanged)
    }

    @MainActor
    @Test func rechecksEachFixtureDeadlineAfterEarlierSave() async throws {
        let server = WeekSessionTestServer(clockJumpAfterSave: 8_000)
        let environment = try WeekSessionTestEnvironment(server: server)
        defer { environment.close() }
        let week = PredictionGameWeekSession()
        await week.load(game: environment.game, apiBaseURL: environment.baseURL)
        for id in ["1", "2"] {
            week.setHomeScore(1, for: id)
            week.setAwayScore(0, for: id)
        }
        await week.save(game: environment.game, apiBaseURL: environment.baseURL)

        #expect(server.attemptedIDs == ["1"])
        #expect(week.rowErrors["2"]?.contains("Kick-off has passed") == true)
        #expect(week.draft(for: "2").isChanged)
    }

    @MainActor
    @Test func reloadKeepsCompleteAndPartialDrafts() async throws {
        let server = WeekSessionTestServer()
        let environment = try WeekSessionTestEnvironment(server: server)
        defer { environment.close() }
        let week = PredictionGameWeekSession()
        await week.load(game: environment.game, apiBaseURL: environment.baseURL)
        week.setHomeScore(4, for: "1")
        week.setAwayScore(3, for: "1")
        week.setAwayScore(2, for: "2")
        await week.load(game: environment.game, apiBaseURL: environment.baseURL)

        #expect(week.draft(for: "1").homeScore == 4)
        #expect(week.draft(for: "1").awayScore == 3)
        #expect(week.draft(for: "2").homeScore == nil)
        #expect(week.draft(for: "2").awayScore == 2)
        #expect(week.changedCount == 2)
    }

    @MainActor
    @Test func serverDraftsStayIsolatedAndReturnToTheirOriginalPlayer() async throws {
        let server = WeekSessionTestServer()
        let environment = try WeekSessionTestEnvironment(server: server)
        defer { environment.close() }
        let secondURL = "https://other-week.test/api/v1"
        let week = PredictionGameWeekSession()
        await week.load(game: environment.game, apiBaseURL: environment.baseURL)
        week.setHomeScore(4, for: "1")
        week.setAwayScore(3, for: "1")
        await week.load(game: environment.game, apiBaseURL: secondURL)
        #expect(week.draft(for: "1").homeScore == nil)
        week.setHomeScore(1, for: "1")
        week.setAwayScore(2, for: "1")
        await week.load(game: environment.game, apiBaseURL: environment.baseURL)

        #expect(week.draft(for: "1").homeScore == 4)
        #expect(week.draft(for: "1").awayScore == 3)
        await week.save(game: environment.game, apiBaseURL: secondURL)
        #expect(server.attemptedIDs.isEmpty)
        #expect(week.errorMessage?.contains("session changed") == true)
    }

    @MainActor
    @Test func competitionSwitchLoadsItsOwnWeekAndRestoresEarlierDrafts() async throws {
        let server = WeekSessionTestServer()
        let environment = try WeekSessionTestEnvironment(server: server)
        defer { environment.close() }
        let week = PredictionGameWeekSession()
        await week.load(game: environment.game, apiBaseURL: environment.baseURL)
        week.setHomeScore(4, for: "1")
        week.setAwayScore(3, for: "1")

        await environment.game.selectCompetition("2", apiBaseURL: environment.baseURL)
        await week.save(game: environment.game, apiBaseURL: environment.baseURL)
        #expect(server.attemptedIDs.isEmpty)
        await week.load(game: environment.game, apiBaseURL: environment.baseURL)
        #expect(week.fixtures.map(\.id) == ["11", "12", "13"])
        week.setHomeScore(2, for: "11")
        week.setAwayScore(0, for: "11")
        await environment.game.selectCompetition("1", apiBaseURL: environment.baseURL)
        await week.load(game: environment.game, apiBaseURL: environment.baseURL)

        #expect(week.fixtures.map(\.id) == ["1", "2", "3"])
        #expect(week.draft(for: "1").homeScore == 4)
        #expect(week.draft(for: "1").awayScore == 3)
        #expect(week.changedCount == 1)
        #expect(server.requestedCompetitionIDs == ["1", "2", "1"])
        #expect(server.contextFixtureIDs.allSatisfy { $0 == nil })
    }

    @MainActor
    @Test func shootoutWinnerIsSavedReloadedAndClearedForAnUnequalScore() async throws {
        let server = WeekSessionTestServer()
        let environment = try WeekSessionTestEnvironment(server: server)
        defer { environment.close() }
        let week = PredictionGameWeekSession()
        await week.load(game: environment.game, apiBaseURL: environment.baseURL)
        week.setHomeScore(1, for: "1")
        week.setAwayScore(1, for: "1")
        week.setPenaltyWinner("away", for: "1")
        await week.save(game: environment.game, apiBaseURL: environment.baseURL)

        #expect(server.submittedPenaltyWinners == ["away"])
        #expect(!week.draft(for: "1").isChanged)
        await week.load(game: environment.game, apiBaseURL: environment.baseURL)
        #expect(week.draft(for: "1").penaltyWinner == "away")
        week.setPenaltyWinner("home", for: "1")
        #expect(week.draft(for: "1").isChanged)
        week.setHomeScore(2, for: "1")
        #expect(week.draft(for: "1").penaltyWinner == nil)
        await week.save(game: environment.game, apiBaseURL: environment.baseURL)
        #expect(server.submittedPenaltyWinners == ["away", nil])
        #expect(!week.draft(for: "1").isChanged)
    }

    @MainActor
    @Test func secondLegKeepsAndSavesShootoutWinnerForAnUnequalMatchScore() async throws {
        let server = WeekSessionTestServer(secondLegIDs: ["1"])
        let environment = try WeekSessionTestEnvironment(server: server)
        defer { environment.close() }
        let week = PredictionGameWeekSession()
        await week.load(game: environment.game, apiBaseURL: environment.baseURL)
        week.setHomeScore(1, for: "1")
        week.setAwayScore(1, for: "1")
        week.setPenaltyWinner("away", for: "1")
        week.setHomeScore(2, for: "1")

        #expect(week.draft(for: "1").penaltyWinner == "away")
        await week.save(game: environment.game, apiBaseURL: environment.baseURL)
        #expect(server.submittedPenaltyWinners == ["away"])
        #expect(environment.game.fixture(for: "1")?.prediction?.displayText == "2–1")
        #expect(!week.draft(for: "1").isChanged)
        await week.load(game: environment.game, apiBaseURL: environment.baseURL)
        #expect(week.draft(for: "1").penaltyWinner == "away")
        #expect(week.draft(for: "1").homeScore == 2)
        #expect(week.draft(for: "1").awayScore == 1)
    }

    @MainActor
    @Test func cancellationStopsBatchBeforeTheNextPrediction() async throws {
        let server = WeekSessionTestServer(saveDelay: 0.15)
        let environment = try WeekSessionTestEnvironment(server: server)
        defer { environment.close() }
        let week = PredictionGameWeekSession()
        await week.load(game: environment.game, apiBaseURL: environment.baseURL)
        for id in ["1", "2"] {
            week.setHomeScore(2, for: id)
            week.setAwayScore(0, for: id)
        }
        let work = Task { await week.save(game: environment.game, apiBaseURL: environment.baseURL) }
        for _ in 0..<100 where server.attemptedIDs.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(server.attemptedIDs == ["1"])
        week.cancel()
        work.cancel()
        await work.value

        #expect(server.attemptedIDs == ["1"])
        #expect(week.draft(for: "2").homeScore == 2)
        #expect(week.draft(for: "2").awayScore == 0)
        #expect(!week.isSaving)
    }

    @MainActor
    @Test func freshSuppliedGameweekIncludesLockedMatchesWithoutRefetching() async throws {
        let server = WeekSessionTestServer(lockedIDs: ["3"])
        let environment = try WeekSessionTestEnvironment(server: server)
        defer { environment.close() }
        let supplied = try #require(await environment.game.loadPredictionSet(
            apiBaseURL: environment.baseURL, includeLocked: true
        ))
        let week = PredictionGameWeekSession(predictionSet: supplied)
        await week.load(game: environment.game, apiBaseURL: environment.baseURL)

        #expect(week.fixtures.count == 3)
        #expect(week.fixtures.first(where: { $0.id == "3" })?.locked == true)
        #expect(server.setRequestCount == 1)
    }
}

@MainActor
private final class WeekSessionTestEnvironment {
    let baseURL = "https://week-\(UUID().uuidString).test/api/v1"
    let game: PredictionGameStore
    private let suiteName = "PredictionGameWeekSessionTests.\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let session: URLSession

    init(server: WeekSessionTestServer) throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: PredictionGameStore.enabledPreferenceKey)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WeekSessionTestURLProtocol.self]
        session = URLSession(configuration: configuration)
        WeekSessionTestURLProtocol.responseHandler = { try server.response(for: $0) }
        game = PredictionGameStore(userDefaults: defaults, apiSession: session, credentialStorage: WeekSessionTestCredentials())
    }

    func close() {
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suiteName)
        WeekSessionTestURLProtocol.responseHandler = nil
    }
}

private final class WeekSessionTestServer: @unchecked Sendable {
    private let lock = NSLock()
    private let initialDate = Date()
    private let existingIDs: Set<String>
    private let failOnceIDs: Set<String>
    private let changeAIOnceIDs: Set<String>
    private let lockedIDs: Set<String>
    private let secondLegIDs: Set<String>
    private let clockJumpAfterSave: TimeInterval
    private let saveDelay: TimeInterval
    private var attempts: [String] = []
    private var revisions: [String] = []
    private var changedAI: Set<String> = []
    private var scores: [String: [String: Int]] = [:]
    private var setRequests = 0
    private var includesLocked = false
    private var competitionRequests: [String] = []
    private var contextIDs: [String?] = []
    private var penaltyWinners: [String: String] = [:]
    private var savedPenaltyWinners: [String?] = []

    init(
        existingIDs: Set<String> = [], failOnceIDs: Set<String> = [],
        changeAIOnceIDs: Set<String> = [], lockedIDs: Set<String> = [], secondLegIDs: Set<String> = [],
        clockJumpAfterSave: TimeInterval = 0, saveDelay: TimeInterval = 0
    ) {
        self.existingIDs = existingIDs
        self.failOnceIDs = failOnceIDs
        self.changeAIOnceIDs = changeAIOnceIDs
        self.lockedIDs = lockedIDs
        self.secondLegIDs = secondLegIDs
        self.clockJumpAfterSave = clockJumpAfterSave
        self.saveDelay = saveDelay
    }

    var requestedCompetitionIDs: [String] { lock.withLock { competitionRequests } }
    var contextFixtureIDs: [String?] { lock.withLock { contextIDs } }
    var submittedPenaltyWinners: [String?] { lock.withLock { savedPenaltyWinners } }
    var attemptedIDs: [String] { lock.withLock { attempts } }
    var submittedRevisions: [String] { lock.withLock { revisions } }
    var requestedAllMatches: Bool { lock.withLock { includesLocked } }
    var setRequestCount: Int { lock.withLock { setRequests } }

    func response(for request: URLRequest) throws -> (Int, Data, TimeInterval) {
        try lock.withLock {
            let url = try #require(request.url)
            if request.httpMethod == "PUT" {
                let id = url.lastPathComponent
                let firstAttempt = !attempts.contains(id)
                attempts.append(id)
                let body = try #require(JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
                revisions.append(body["expectedAIRevision"] as? String ?? "")
                if failOnceIDs.contains(id), firstAttempt {
                    return (503, Data(#"{"error":"Please retry this prediction.","code":"unavailable"}"#.utf8), saveDelay)
                }
                if changeAIOnceIDs.contains(id), firstAttempt {
                    changedAI.insert(id)
                    return (409, Data(#"{"error":"The AI changed.","code":"ai_changed"}"#.utf8), saveDelay)
                }
                penaltyWinners[id] = body["penaltyWinner"] as? String
                savedPenaltyWinners.append(body["penaltyWinner"] as? String)
                scores[id] = ["homeScore": body["homeScore"] as? Int ?? -1, "awayScore": body["awayScore"] as? Int ?? -1]
                return (200, try JSONSerialization.data(withJSONObject: ["fixture": fixture(id), "serverTime": serverTime()]), saveDelay)
            }
            if url.lastPathComponent == "fixtures" {
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                let id = try #require(query?.first(where: { $0.name == "ids" })?.value)
                return (200, try JSONSerialization.data(withJSONObject: ["fixtures": [fixture(id)], "serverTime": serverTime()]), 0)
            }
            if url.lastPathComponent == "state" {
                return (503, Data(#"{"error":"Dashboard unavailable in this test."}"#.utf8), 0)
            }
            #expect(url.lastPathComponent == "next-predictions")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            let contextID = query?.first(where: { $0.name == "fixtureId" })?.value
            let competitionID = query?.first(where: { $0.name == "competitionId" })?.value
                ?? ((Int(contextID ?? "0") ?? 0) >= 10 ? "2" : "1")
            competitionRequests.append(competitionID)
            contextIDs.append(contextID)
            includesLocked = query?.contains(where: { $0.name == "includeLocked" && $0.value == "true" }) == true
            setRequests += 1
            return (200, try JSONSerialization.data(withJSONObject: [
                "serverTime": serverTime(), "gameweekId": "week-1", "gameweekLabel": "Gameweek 1",
                "competitionId": competitionID,
                "competitionName": competitionID == "1" ? "Premier League" : "Champions League",
                "fixtures": (competitionID == "1" ? ["1", "2", "3"] : ["11", "12", "13"]).map { fixture($0) }
            ]), 0)
        }
    }

    private func serverTime() -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(scores.isEmpty ? 0 : clockJumpAfterSave))
    }

    private func fixture(_ id: String) -> [String: Any] {
        let score = scores[id] ?? (existingIDs.contains(id) ? ["homeScore": 2, "awayScore": 1] : nil)
        let date = ISO8601DateFormatter().string(from: initialDate)
        return [
            "id": id, "homeTeam": "Home \(id)", "awayTeam": "Away \(id)",
            "competitionId": (Int(id) ?? 0) >= 10 ? "2" : "1",
            "isSecondLeg": secondLegIDs.contains(id),
            "competitionName": (Int(id) ?? 0) >= 10 ? "Champions League" : "Premier League",
            "seasonId": "2026", "seasonLabel": "2026/27",
            "kickoffAt": ISO8601DateFormatter().string(from: initialDate.addingTimeInterval(Double(id)! * 3_600)),
            "status": "notstarted", "locked": lockedIDs.contains(id), "settled": false, "void": false,
            "challengeId": "challenge-1",
            "ai": ["homeScore": changedAI.contains(id) ? 2 : 1, "awayScore": 0,
                   "modelVersion": "v1", "sourceRevision": changedAI.contains(id) ? "revision-2" : "revision-1",
                   "frozenAt": score != nil ? date as Any : NSNull()],
            "prediction": score.map { ["homeScore": $0["homeScore"]!, "awayScore": $0["awayScore"]!,
                                       "savedAt": date, "penaltyWinner": penaltyWinners[id] as Any? ?? NSNull(), "youPoints": NSNull(), "aiPoints": NSNull(), "outcome": NSNull()] as [String: Any] } as Any? ?? NSNull(),
            "result": NSNull()
        ]
    }

    private func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private final class WeekSessionTestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseHandler: (@Sendable (URLRequest) throws -> (Int, Data, TimeInterval))?
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.responseHandler, let url = request.url else { throw URLError(.badServerResponse) }
            let (status, data, delay) = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
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

private struct WeekSessionTestCredentials: PredictionGameCredentialStorage {
    func load(server: String) -> String? { "week-test-credential" }
    func save(_ credential: String, server: String) {}
    func preserveGuest(_ credential: String, server: String) {}
}
