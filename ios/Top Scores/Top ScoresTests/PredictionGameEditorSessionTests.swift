import Foundation
import Testing
@testable import Top_Scores

@Suite(.serialized)
struct PredictionGameEditorSessionTests {
    @MainActor
    @Test func currentMatchBecomesEditableWhileNextSetIsStillLoading() async throws {
        let server = EditorSessionTestServer(setResponseDelay: 0.2)
        let environment = try EditorSessionTestEnvironment(server: server)
        defer { environment.close() }
        let editor = PredictionGameEditorSession(fixtureID: "1")
        let work = Task { await editor.load(game: environment.game, apiBaseURL: environment.baseURL) }
        for _ in 0..<100 where server.setRequestCount == 0 { try await Task.sleep(for: .milliseconds(5)) }

        #expect(server.setRequestCount == 1)
        #expect(editor.isPrepared)
        #expect(!editor.isLoading)
        #expect(!editor.isWorking)
        #expect(editor.predictionSet == nil)
        editor.homeScore = 4
        editor.awayScore = 3
        await work.value

        #expect(editor.predictionSet != nil)
        #expect(editor.homeScore == 4 && editor.awayScore == 3)
    }

    @MainActor
    @Test func savingWhileOptionalSetLoadsPreservesAcceptedEntryAndDraft() async throws {
        let server = EditorSessionTestServer(setResponseDelay: 0.2)
        let environment = try EditorSessionTestEnvironment(server: server)
        defer { environment.close() }
        let editor = PredictionGameEditorSession(fixtureID: "1")
        let work = Task { await editor.load(game: environment.game, apiBaseURL: environment.baseURL) }
        for _ in 0..<100 where server.setRequestCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(editor.isPrepared)
        editor.homeScore = 4
        editor.awayScore = 3

        let dismiss = await editor.save(game: environment.game, apiBaseURL: environment.baseURL, advance: false)
        await work.value

        #expect(dismiss)
        #expect(environment.game.fixture(for: "1")?.prediction != nil)
        #expect(environment.game.fixture(for: "1")?.ai?.frozenAt != nil)
        #expect(editor.homeScore == 4 && editor.awayScore == 3)
        #expect(editor.predictionSet == nil)
        #expect(editor.saveError == nil)
    }

    @MainActor
    @Test func optionalSetFailureDoesNotHideMatchOrReplaceDraft() async throws {
        let server = EditorSessionTestServer(failInitialSet: true, setResponseDelay: 0.2)
        let environment = try EditorSessionTestEnvironment(server: server)
        defer { environment.close() }
        let editor = PredictionGameEditorSession(fixtureID: "1")
        let work = Task { await editor.load(game: environment.game, apiBaseURL: environment.baseURL) }
        for _ in 0..<100 where server.setRequestCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(editor.isPrepared)
        #expect(!editor.isLoading && !editor.isWorking)
        editor.homeScore = 4
        editor.awayScore = 3
        await work.value

        #expect(editor.isPrepared)
        #expect(editor.homeScore == 4 && editor.awayScore == 3)
        #expect(editor.saveError?.contains("still save this pick") == true)
        #expect(await editor.save(game: environment.game, apiBaseURL: environment.baseURL, advance: false))
    }

    @MainActor
    @Test func lateOptionalSetFailureDoesNotReplaceSaveFailure() async throws {
        let server = EditorSessionTestServer(saveFailure: .server, failInitialSet: true, setResponseDelay: 0.2)
        let environment = try EditorSessionTestEnvironment(server: server)
        defer { environment.close() }
        let editor = PredictionGameEditorSession(fixtureID: "1")
        let work = Task { await editor.load(game: environment.game, apiBaseURL: environment.baseURL) }
        for _ in 0..<100 where server.setRequestCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let dismiss = await editor.save(game: environment.game, apiBaseURL: environment.baseURL, advance: false)
        let saveError = editor.saveError
        await work.value

        #expect(!dismiss)
        #expect(saveError?.contains("not saved") == true)
        #expect(editor.saveError == saveError)
        #expect(environment.game.errorMessage == saveError)
        #expect(editor.isPrepared && !editor.isWorking)
    }

    @MainActor
    @Test func freshlySuppliedSetAvoidsBothDuplicateRequests() async throws {
        let server = EditorSessionTestServer(existingPredictionIDs: ["2"])
        let environment = try EditorSessionTestEnvironment(server: server)
        defer { environment.close() }
        let supplied = try #require(await environment.game.loadPredictionSet(apiBaseURL: environment.baseURL))
        let editor = PredictionGameEditorSession(fixtureID: "2", predictionSet: supplied)

        await editor.load(game: environment.game, apiBaseURL: environment.baseURL)

        #expect(editor.isPrepared)
        #expect(!editor.isLoading && !editor.isWorking)
        #expect(editor.homeScore == 2 && editor.awayScore == 1)
        #expect(server.setRequestCount == 1)
        #expect(!server.hasRead("2"))
    }

    @MainActor
    @Test func suppliedSetIsNotReusedForAnotherServer() async throws {
        let server = EditorSessionTestServer()
        let environment = try EditorSessionTestEnvironment(server: server)
        defer { environment.close() }
        let supplied = try #require(await environment.game.loadPredictionSet(apiBaseURL: environment.baseURL))
        let editor = PredictionGameEditorSession(fixtureID: "1", predictionSet: supplied)

        await editor.load(game: environment.game, apiBaseURL: "https://other-editor.test/api/v1")

        #expect(editor.isPrepared)
        #expect(server.hasRead("1"))
        #expect(server.setRequestCount == 2)
    }

    @MainActor
    @Test func suppliedSetStillUsesServerClockForDeadline() async throws {
        let server = EditorSessionTestServer(clockOffset: 7_200)
        let environment = try EditorSessionTestEnvironment(server: server)
        defer { environment.close() }
        let supplied = try #require(await environment.game.loadPredictionSet(apiBaseURL: environment.baseURL))
        let editor = PredictionGameEditorSession(fixtureID: "1", predictionSet: supplied)
        await editor.load(game: environment.game, apiBaseURL: environment.baseURL)

        let dismiss = await editor.save(game: environment.game, apiBaseURL: environment.baseURL, advance: false)

        #expect(!dismiss)
        #expect(server.setRequestCount == 1)
        #expect(!server.hasRead("1"))
        #expect(server.savedIDs.isEmpty)
        #expect(editor.saveError?.contains("locked") == true)
    }

    @MainActor
    @Test func failedSaveStaysOnCurrentMatchAndPreservesDraft() async throws {
        let server = EditorSessionTestServer(saveFailure: .server)
        let environment = try EditorSessionTestEnvironment(server: server)
        defer { environment.close() }
        let editor = PredictionGameEditorSession(fixtureID: "bsd:1")
        await editor.load(game: environment.game, apiBaseURL: environment.baseURL)
        editor.homeScore = 4
        editor.awayScore = 3

        let dismiss = await editor.save(game: environment.game, apiBaseURL: environment.baseURL, advance: true)

        #expect(!dismiss)
        #expect(editor.fixtureID == "1")
        #expect(editor.homeScore == 4 && editor.awayScore == 3)
        #expect(editor.saveError?.contains("not saved") == true)
        #expect(!editor.isWorking)
        #expect(!server.hasRead("2"))
    }

    @MainActor
    @Test func changedAIRequiresReviewWithoutAdvancingOrResettingDraft() async throws {
        let server = EditorSessionTestServer(saveFailure: .aiChanged)
        let environment = try EditorSessionTestEnvironment(server: server)
        defer { environment.close() }
        let editor = PredictionGameEditorSession(fixtureID: "1")
        await editor.load(game: environment.game, apiBaseURL: environment.baseURL)
        editor.homeScore = 4
        editor.awayScore = 3

        let dismiss = await editor.save(game: environment.game, apiBaseURL: environment.baseURL, advance: true)

        #expect(!dismiss)
        #expect(editor.fixtureID == "1")
        #expect(editor.homeScore == 4 && editor.awayScore == 3)
        #expect(editor.saveError?.contains("AI prediction changed") == true)
        #expect(!server.hasRead("2"))
    }

    @MainActor
    @Test func advancesThroughUnenteredThenExistingPicksWithoutRevisiting() async throws {
        let server = EditorSessionTestServer(existingPredictionIDs: ["2"])
        let environment = try EditorSessionTestEnvironment(server: server)
        defer { environment.close() }
        let editor = PredictionGameEditorSession(fixtureID: "1")
        await editor.load(game: environment.game, apiBaseURL: environment.baseURL)
        #expect(editor.nextFixture(game: environment.game, at: Date())?.id == "3")

        let firstDismiss = await editor.save(game: environment.game, apiBaseURL: environment.baseURL, advance: true)
        #expect(!firstDismiss)
        #expect(editor.fixtureID == "3")
        #expect(editor.homeScore == 0 && editor.awayScore == 0)
        #expect(editor.nextFixture(game: environment.game, at: Date())?.id == "2")

        let secondDismiss = await editor.save(game: environment.game, apiBaseURL: environment.baseURL, advance: true)
        #expect(!secondDismiss)
        #expect(editor.fixtureID == "2")
        #expect(editor.homeScore == 2 && editor.awayScore == 1)
        #expect(editor.nextFixture(game: environment.game, at: Date()) == nil)

        let finished = await editor.save(game: environment.game, apiBaseURL: environment.baseURL, advance: true)
        #expect(finished)
        #expect(server.savedIDs == ["1", "3", "2"])
        #expect(editor.saveError == nil)
    }

    @MainActor
    @Test func successfulSaveDoesNotAdvanceIntoAnotherGameweek() async throws {
        let server = EditorSessionTestServer(refreshedGameweekID: "week-2")
        let environment = try EditorSessionTestEnvironment(server: server)
        defer { environment.close() }
        let editor = PredictionGameEditorSession(fixtureID: "1")
        await editor.load(game: environment.game, apiBaseURL: environment.baseURL)

        let dismiss = await editor.save(game: environment.game, apiBaseURL: environment.baseURL, advance: true)

        #expect(!dismiss)
        #expect(editor.fixtureID == "1")
        #expect(editor.saveError?.contains("was saved") == true)
        #expect(editor.saveError?.contains("gameweek changed") == true)
        #expect(!server.hasRead("2"))
    }

    @MainActor
    @Test func shootoutChoiceClearsForDecisiveScoresAndDoesNotCarryIntoNextFixture() async throws {
        let server = EditorSessionTestServer()
        let environment = try EditorSessionTestEnvironment(server: server)
        defer { environment.close() }
        let editor = PredictionGameEditorSession(fixtureID: "1")
        await editor.load(game: environment.game, apiBaseURL: environment.baseURL)
        editor.homeScore = 1
        editor.awayScore = 1
        editor.penaltyWinner = "away"
        editor.homeScore = 2
        #expect(editor.penaltyWinner == nil)
        editor.homeScore = 1
        editor.penaltyWinner = "home"

        #expect(await editor.save(game: environment.game, apiBaseURL: environment.baseURL, advance: true) == false)
        #expect(editor.fixtureID == "2")
        #expect(editor.penaltyWinner == nil)
    }

    @MainActor
    @Test func fixtureContextKeepsOtherCompetitionSeparateFromHomeSelection() async throws {
        let server = EditorSessionTestServer(competitionID: "2")
        let environment = try EditorSessionTestEnvironment(server: server)
        defer { environment.close() }
        let editor = PredictionGameEditorSession(fixtureID: "1")
        await editor.load(game: environment.game, apiBaseURL: environment.baseURL)

        #expect(environment.game.selectedCompetitionID == "1")
        #expect(editor.predictionSet?.resolvedCompetitionID == "2")
        #expect(editor.nextFixture(game: environment.game, at: Date())?.resolvedCompetitionID == "2")
        #expect(await editor.save(game: environment.game, apiBaseURL: environment.baseURL, advance: true) == false)
        #expect(editor.fixtureID == "2")
        #expect(server.contextRequestsHaveNoCompetitionOverride)
    }

    @MainActor
    @Test func successfulSaveCannotAdvanceIntoAnotherCompetitionWithSameGameweekID() async throws {
        let server = EditorSessionTestServer(refreshedCompetitionID: "2")
        let environment = try EditorSessionTestEnvironment(server: server)
        defer { environment.close() }
        let editor = PredictionGameEditorSession(fixtureID: "1")
        await editor.load(game: environment.game, apiBaseURL: environment.baseURL)

        #expect(await editor.save(game: environment.game, apiBaseURL: environment.baseURL, advance: true) == false)
        #expect(editor.fixtureID == "1")
        #expect(server.savedIDs == ["1"])
        #expect(editor.predictionSet == nil)
        #expect(!server.hasRead("2"))
    }

    @MainActor
    @Test func nextSetFailureClearlyReportsThatCurrentPickWasSaved() async throws {
        let server = EditorSessionTestServer(failSetAfterSave: true)
        let environment = try EditorSessionTestEnvironment(server: server)
        defer { environment.close() }
        let editor = PredictionGameEditorSession(fixtureID: "1")
        await editor.load(game: environment.game, apiBaseURL: environment.baseURL)
        editor.homeScore = 2
        editor.awayScore = 1

        let dismiss = await editor.save(game: environment.game, apiBaseURL: environment.baseURL, advance: true)

        #expect(!dismiss)
        #expect(editor.fixtureID == "1")
        #expect(editor.homeScore == 2 && editor.awayScore == 1)
        #expect(environment.game.fixture(for: "1")?.prediction != nil)
        #expect(editor.saveError?.contains("was saved, but") == true)
        #expect(!editor.isWorking)
    }

    @MainActor
    @Test func rechecksKickoffWhenLoadingNextCandidate() async throws {
        let server = EditorSessionTestServer(expiredReadIDs: ["2"])
        let environment = try EditorSessionTestEnvironment(server: server)
        defer { environment.close() }
        let editor = PredictionGameEditorSession(fixtureID: "1")
        await editor.load(game: environment.game, apiBaseURL: environment.baseURL)
        #expect(editor.nextFixture(game: environment.game, at: Date())?.id == "2")

        let dismiss = await editor.save(game: environment.game, apiBaseURL: environment.baseURL, advance: true)

        #expect(!dismiss)
        #expect(server.hasRead("2"))
        #expect(editor.fixtureID == "3")
        #expect(editor.saveError == nil)
    }

    @MainActor
    @Test func saveRechecksCurrentDeadlineWithoutSendingExpiredPick() async throws {
        let server = EditorSessionTestServer(clockOffset: 7_200)
        let environment = try EditorSessionTestEnvironment(server: server)
        defer { environment.close() }
        let editor = PredictionGameEditorSession(fixtureID: "1")
        await editor.load(game: environment.game, apiBaseURL: environment.baseURL)

        let dismiss = await editor.save(game: environment.game, apiBaseURL: environment.baseURL, advance: false)

        #expect(!dismiss)
        #expect(server.savedIDs.isEmpty)
        #expect(editor.saveError?.contains("locked") == true)
    }

    @MainActor
    @Test func cancellationDuringCandidateLoadCannotNavigateOrReplaceDraft() async throws {
        let server = EditorSessionTestServer(delayedReadIDs: ["2"])
        let environment = try EditorSessionTestEnvironment(server: server)
        defer { environment.close() }
        let editor = PredictionGameEditorSession(fixtureID: "1")
        await editor.load(game: environment.game, apiBaseURL: environment.baseURL)
        editor.homeScore = 4
        editor.awayScore = 3
        let work = Task {
            await editor.save(game: environment.game, apiBaseURL: environment.baseURL, advance: true)
        }
        for _ in 0..<100 where !server.hasRead("2") { try await Task.sleep(for: .milliseconds(5)) }
        #expect(server.hasRead("2"))
        editor.cancel()
        let dismiss = await work.value

        #expect(!dismiss)
        #expect(editor.fixtureID == "1")
        #expect(editor.homeScore == 4 && editor.awayScore == 3)
        #expect(!editor.isWorking)
        #expect(editor.saveError == nil)
    }

    @MainActor
    @Test func cancelledInitialLoadCannotPrepareEditor() async throws {
        let server = EditorSessionTestServer(delayedReadIDs: ["1"])
        let environment = try EditorSessionTestEnvironment(server: server)
        defer { environment.close() }
        let editor = PredictionGameEditorSession(fixtureID: "1")
        let work = Task { await editor.load(game: environment.game, apiBaseURL: environment.baseURL) }
        for _ in 0..<100 where !server.hasRead("1") { try await Task.sleep(for: .milliseconds(5)) }
        #expect(server.hasRead("1"))
        editor.cancel()
        work.cancel()
        await work.value

        #expect(!editor.isPrepared)
        #expect(!editor.isLoading)
        #expect(!editor.isWorking)
        #expect(editor.saveError == nil)
    }
}

@MainActor
private final class EditorSessionTestEnvironment {
    let baseURL = "https://editor-\(UUID().uuidString).test/api/v1"
    let game: PredictionGameStore
    private let suiteName = "PredictionGameEditorSessionTests.\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let session: URLSession

    init(server: EditorSessionTestServer) throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: PredictionGameStore.enabledPreferenceKey)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EditorSessionTestURLProtocol.self]
        session = URLSession(configuration: configuration)
        EditorSessionTestURLProtocol.responseHandler = { try server.response(for: $0) }
        game = PredictionGameStore(
            userDefaults: defaults, apiSession: session, credentialStorage: EditorSessionTestCredentials()
        )
    }

    func close() {
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suiteName)
        EditorSessionTestURLProtocol.responseHandler = nil
    }
}

private final class EditorSessionTestServer: @unchecked Sendable {
    enum SaveFailure { case server, aiChanged }
    private let lock = NSLock()
    private let kickoff = Date().addingTimeInterval(3_600)
    private let saveFailure: SaveFailure?
    private let existingPredictionIDs: Set<String>
    private let refreshedGameweekID: String
    private let failSetAfterSave: Bool
    private let failInitialSet: Bool
    private let setResponseDelay: TimeInterval
    private let expiredReadIDs: Set<String>
    private let delayedReadIDs: Set<String>
    private let clockOffset: TimeInterval
    private let competitionID: String
    private let refreshedCompetitionID: String?
    private var hasContextCompetitionOverride = false
    private var reads: [String] = []
    private var acceptedIDs: [String] = []
    private var setRequests = 0

    init(
        saveFailure: SaveFailure? = nil,
        existingPredictionIDs: Set<String> = [],
        refreshedGameweekID: String = "week-1",
        failSetAfterSave: Bool = false,
        failInitialSet: Bool = false,
        setResponseDelay: TimeInterval = 0,
        expiredReadIDs: Set<String> = [],
        delayedReadIDs: Set<String> = [],
        clockOffset: TimeInterval = 0,
        competitionID: String = "1",
        refreshedCompetitionID: String? = nil
    ) {
        self.saveFailure = saveFailure
        self.existingPredictionIDs = existingPredictionIDs
        self.refreshedGameweekID = refreshedGameweekID
        self.failSetAfterSave = failSetAfterSave
        self.failInitialSet = failInitialSet
        self.setResponseDelay = setResponseDelay
        self.expiredReadIDs = expiredReadIDs
        self.delayedReadIDs = delayedReadIDs
        self.clockOffset = clockOffset
        self.competitionID = competitionID
        self.refreshedCompetitionID = refreshedCompetitionID
    }

    var contextRequestsHaveNoCompetitionOverride: Bool { lock.withLock { !hasContextCompetitionOverride } }
    var savedIDs: [String] { lock.withLock { acceptedIDs } }
    var setRequestCount: Int { lock.withLock { setRequests } }
    func hasRead(_ id: String) -> Bool { lock.withLock { reads.contains(id) } }

    func response(for request: URLRequest) throws -> (Int, Data, TimeInterval) {
        try lock.withLock {
            let url = try #require(request.url)
            let now = Date().addingTimeInterval(clockOffset)
            let serverTime = ISO8601DateFormatter().string(from: now)
            if request.httpMethod == "PUT" {
                if let saveFailure {
                    let aiChanged = saveFailure == .aiChanged
                    return (aiChanged ? 409 : 503, try JSONSerialization.data(withJSONObject: [
                        "code": aiChanged ? "ai_changed" : "unavailable",
                        "error": aiChanged ? "Review the new AI prediction." : "Your prediction was not saved. Please try again."
                    ]), 0)
                }
                let id = url.lastPathComponent
                acceptedIDs.append(id)
                return (200, try JSONSerialization.data(withJSONObject: [
                    "fixture": fixture(id), "serverTime": serverTime
                ]), 0)
            }
            if url.lastPathComponent == "fixtures" {
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let id = try #require(components?.queryItems?.first(where: { $0.name == "ids" })?.value)
                reads.append(id)
                return (200, try JSONSerialization.data(withJSONObject: [
                    "fixtures": [fixture(id, expired: expiredReadIDs.contains(id))], "serverTime": serverTime
                ]), delayedReadIDs.contains(id) ? 0.15 : 0)
            }
            #expect(url.lastPathComponent == "next-predictions")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.contains(where: { $0.name == "fixtureId" }), query.contains(where: { $0.name == "competitionId" }) {
                hasContextCompetitionOverride = true
            }
            setRequests += 1
            if (failSetAfterSave && !acceptedIDs.isEmpty) || (failInitialSet && acceptedIDs.isEmpty) {
                return (503, Data(#"{"error":"Next matches could not be loaded.","code":"unavailable"}"#.utf8), setResponseDelay)
            }
            return (200, try JSONSerialization.data(withJSONObject: [
                "serverTime": serverTime,
                "gameweekId": acceptedIDs.isEmpty ? "week-1" : refreshedGameweekID,
                "competitionId": acceptedIDs.isEmpty ? competitionID : refreshedCompetitionID ?? competitionID,
                "competitionName": competitionID == "1" ? "Premier League" : "Champions League",
                "gameweekLabel": "Gameweek 1", "fixtures": ["1", "2", "3"].map { fixture($0) }
            ]), setResponseDelay)
        }
    }

    private func fixture(_ id: String, expired: Bool = false) -> [String: Any] {
        let entered = existingPredictionIDs.contains(id) || acceptedIDs.contains(id)
        let savedAt = ISO8601DateFormatter().string(from: kickoff.addingTimeInterval(-3_600))
        return [
            "id": id, "homeTeam": "Home \(id)", "awayTeam": "Away \(id)",
            "competitionId": competitionID, "competitionName": competitionID == "1" ? "Premier League" : "Champions League",
            "seasonId": "2026", "seasonLabel": "2026/27",
            "kickoffAt": ISO8601DateFormatter().string(from: expired ? Date().addingTimeInterval(-1) : kickoff),
            "status": "notstarted", "locked": false, "settled": false, "void": false,
            "challengeId": "challenge-1",
            "ai": ["homeScore": 1, "awayScore": 0, "modelVersion": "v1", "sourceRevision": "revision-1",
                   "frozenAt": entered ? savedAt as Any : NSNull()],
            "prediction": entered ? ["homeScore": 2, "awayScore": 1, "savedAt": savedAt,
                                     "youPoints": NSNull(), "aiPoints": NSNull(), "outcome": NSNull()] : NSNull(),
            "result": NSNull()
        ]
    }
}

private final class EditorSessionTestURLProtocol: URLProtocol, @unchecked Sendable {
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
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { lock.withLock { stopped = true } }
}

private struct EditorSessionTestCredentials: PredictionGameCredentialStorage {
    func load(server: String) -> String? { "editor-test-credential" }
    func save(_ credential: String, server: String) {}
    func preserveGuest(_ credential: String, server: String) {}
}
