import Foundation
import Testing
@testable import Top_Scores

@Suite(.serialized)
@MainActor
struct FantasyRivalRefreshTests {
    private let gameweek = FantasyGameweek(
        id: 7, name: "Gameweek 7", isCurrent: true, isNext: false,
        finished: false, deadlineTime: nil
    )

    private func rivals(_ ids: [Int]) -> [FantasyRivalManager] {
        ids.map {
            FantasyRivalManager(entryID: $0, teamName: "Team \($0)", managerFirstName: "Rival",
                                managerLastName: "", overallPoints: nil, clubBadgeSrc: nil)
        }
    }

    private func refresh(_ model: FantasyViewModel, ids: [Int]) async {
        await model.refreshRivalScores(
            rivals: rivals(ids), gameweek: gameweek,
            liveResponse: FantasyEventLiveResponse(elements: []), fixtures: [], seasonFixtures: [],
            bootstrapLookup: FantasyBootstrapLookup(
                updatedAt: nil, totalPlayers: nil, elements: [], teams: [],
                elementTypes: [], events: [gameweek]
            )
        )
    }

    @Test func failedRivalsRetainScoresAndMissingRivalsRecoverOnNextPoll() async throws {
        let suite = "FantasyRivalRefreshTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RivalScoreURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let model = FantasyViewModel(
            fantasyPublicClient: FantasyPublicAPIClient(session: session), rivalScoreDefaults: defaults
        )
        model.prepareRivalScores(accountID: 100, gameweekID: 7, rivals: rivals([1, 2]))
        RivalScoreURLProtocol.failingIDs = [2]
        await refresh(model, ids: [1, 2])
        let saved = try #require(model.rivalScoreSnapshots[1])
        #expect(model.rivalSquads.map(\.entryID) == [1])
        #expect(model.staleRivalEntryIDs == [2])
        #expect(model.loadingRivalEntryIDs.isEmpty)
        #expect(model.automaticScoreRefreshMinimumInterval == 30)

        RivalScoreURLProtocol.failingIDs = [1]
        await refresh(model, ids: [1, 2])
        #expect(Set(model.rivalSquads.map(\.entryID)) == [1, 2])
        #expect(model.rivalScoreSnapshots[1] == saved)
        #expect(model.staleRivalEntryIDs == [1])

        RivalScoreURLProtocol.failingIDs = []
        await refresh(model, ids: [1, 2])
        #expect(model.staleRivalEntryIDs.isEmpty)

        let restored = FantasyViewModel(rivalScoreDefaults: defaults)
        restored.prepareRivalScores(accountID: 100, gameweekID: 7, rivals: rivals([1, 2]))
        #expect(restored.rivalScoreSnapshots == model.rivalScoreSnapshots)
        #expect(restored.staleRivalEntryIDs == [1, 2])
        restored.prepareRivalScores(accountID: 100, gameweekID: 8, rivals: rivals([1, 2]))
        #expect(restored.rivalScoreSnapshots.isEmpty)
        restored.prepareRivalScores(accountID: 200, gameweekID: 7, rivals: rivals([1, 2]))
        #expect(restored.rivalScoreSnapshots.isEmpty)
        restored.prepareRivalScores(accountID: 100, gameweekID: 7, rivals: rivals([2]))
        #expect(Set(restored.rivalScoreSnapshots.keys) == [2])
    }

    @Test func publishesCompletedRivalsBeforeBatchFinishesAndIgnoresCancelledResults() async throws {
        let suite = "FantasyRivalRefreshTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RivalScoreURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let model = FantasyViewModel(
            fantasyPublicClient: FantasyPublicAPIClient(session: session), rivalScoreDefaults: defaults
        )
        model.prepareRivalScores(accountID: 100, gameweekID: 7, rivals: rivals([1, 2]))
        RivalScoreURLProtocol.failingIDs = []
        RivalScoreURLProtocol.heldEntryID = 2
        let task = Task { await refresh(model, ids: [1, 2]) }
        for _ in 0..<200 {
            if model.rivalScoreSnapshots[1] != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.rivalScoreSnapshots[1] != nil)
        #expect(model.rivalScoreSnapshots[2] == nil)
        #expect(model.loadingRivalEntryIDs == [2])

        model.cancelBackgroundRefreshWork()
        #expect(model.staleRivalEntryIDs.contains(2))
        #expect(model.loadingRivalEntryIDs.isEmpty)
        RivalScoreURLProtocol.releaseHeldResponse()
        await task.value
        #expect(model.rivalScoreSnapshots[2] == nil)
        #expect(model.rivalScoreSnapshots[1] != nil)

        await refresh(model, ids: [1, 2])
        #expect(model.rivalScoreSnapshots[2] != nil)
        #expect(model.staleRivalEntryIDs.isEmpty)
    }

    @Test func cacheSeparatesSeasons() {
        #expect(
            FantasyRivalScoreSnapshot.storageKey(accountID: 1, season: "2025", gameweekID: 7) !=
            FantasyRivalScoreSnapshot.storageKey(accountID: 1, season: "2026", gameweekID: 7)
        )
    }
}

private nonisolated final class RivalScoreURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var failingIDs: Set<Int> = []
    nonisolated(unsafe) static var heldEntryID: Int?
    nonisolated(unsafe) private static var heldResponse: RivalScoreURLProtocol?
    private static let lock = NSLock()

    static func releaseHeldResponse() {
        lock.lock()
        heldEntryID = nil
        let response = heldResponse
        heldResponse = nil
        lock.unlock()
        response?.complete()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let entryID = Int(request.url!.pathComponents[3])!
        Self.lock.lock()
        if Self.heldEntryID == entryID {
            Self.heldResponse = self
            Self.lock.unlock()
            return
        }
        Self.lock.unlock()
        complete()
    }

    private func complete() {
        let url = request.url!
        let entryID = Int(url.pathComponents[3])!
        let status = Self.failingIDs.contains(entryID) ? 503 : 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        let data = Data(#"{"picks":[],"entry_history":{"event":7,"points":0,"total_points":100},"active_chip":null}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
