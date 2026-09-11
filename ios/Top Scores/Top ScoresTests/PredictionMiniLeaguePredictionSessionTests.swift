import Combine
import Foundation
import Testing
@testable import Top_Scores

extension PredictionMiniLeagueClientTests {
    @Test func privateRoundBoardReusesCanonicalPicksAndNeverSubmitsSharedAIRevision() async throws {
        let harness = try MiniLeagueHarness()
        defer { harness.finish() }
        let server = MiniLeagueBoardServer(existingIDs: ["124"])
        server.install()
        await harness.game.gameScreenDidAppear(apiBaseURL: harness.base)
        let board = PredictionMiniLeaguePredictionSession()
        await board.load(leagueID: "league-1", roundID: "round-1", game: harness.game, apiBaseURL: harness.base)
        #expect(board.fixtures.count == 2)
        #expect(board.draft(for: "123").home == nil)
        #expect(board.draft(for: "124").home == 2)
        #expect(board.changedCount == 0)
        #expect(board.sharedAI["123"]?.displayText == "0–3")
        #expect(harness.game.fixture(for: "123")?.ai?.displayText == "2–1")
        await board.save(game: harness.game, apiBaseURL: harness.base)
        #expect(server.attemptedIDs.isEmpty)
        board.setHome(0, id: "123")
        board.setAway(0, id: "123")
        await board.save(game: harness.game, apiBaseURL: harness.base)
        #expect(server.attemptedIDs == ["123"])
        #expect(server.revisions == ["personal-revision"])
        #expect(harness.game.fixture(for: "123")?.prediction?.displayText == "0–0")
        #expect(board.sharedAI["123"]?.displayText == "0–3")
        #expect(board.changedCount == 0)
    }

    @Test func privateBoardKeepsPartialDraftsAndRetriesOnlyFailedPicks() async throws {
        let harness = try MiniLeagueHarness()
        defer { harness.finish() }
        let server = MiniLeagueBoardServer(failOnce: ["124"])
        server.install()
        await harness.game.gameScreenDidAppear(apiBaseURL: harness.base)
        let board = PredictionMiniLeaguePredictionSession()
        await board.load(leagueID: "league-1", roundID: "round-1", game: harness.game, apiBaseURL: harness.base)
        board.setHome(3, id: "123")
        await board.save(game: harness.game, apiBaseURL: harness.base)
        #expect(server.attemptedIDs.isEmpty)
        #expect(board.rowErrors["123"]?.contains("both scores") == true)
        board.setAway(1, id: "123")
        board.setHome(1, id: "124")
        board.setAway(0, id: "124")
        await board.save(game: harness.game, apiBaseURL: harness.base)
        #expect(server.attemptedIDs == ["123", "124"])
        #expect(!board.draft(for: "123").changed)
        #expect(board.draft(for: "124").changed)
        await board.save(game: harness.game, apiBaseURL: harness.base)
        #expect(server.attemptedIDs == ["123", "124", "124"])
        #expect(board.changedCount == 0)
    }

    @Test func privateBoardRechecksDeadlinesBetweenSaves() async throws {
        let harness = try MiniLeagueHarness()
        defer { harness.finish() }
        let server = MiniLeagueBoardServer(clockJumpAfterSave: 8_000)
        server.install()
        await harness.game.gameScreenDidAppear(apiBaseURL: harness.base)
        let board = PredictionMiniLeaguePredictionSession()
        await board.load(leagueID: "league-1", roundID: "round-1", game: harness.game, apiBaseURL: harness.base)
        for id in ["123", "124"] { board.setHome(1, id: id); board.setAway(0, id: id) }
        await board.save(game: harness.game, apiBaseURL: harness.base)
        #expect(server.attemptedIDs == ["123"])
        #expect(board.rowErrors["124"]?.contains("locked") == true)
        #expect(board.draft(for: "124").changed)
    }

    @Test func privateBoardDropsDraftsAndFixturesWhenGameCenterAccountChanges() async throws {
        let harness = try MiniLeagueHarness()
        defer { harness.finish() }
        MiniLeagueBoardServer().install()
        await harness.game.gameScreenDidAppear(apiBaseURL: harness.base)
        let board = PredictionMiniLeaguePredictionSession()
        await board.load(leagueID: "league-1", roundID: "round-1", game: harness.game, apiBaseURL: harness.base)
        board.setHome(4, id: "123")
        board.setAway(0, id: "123")
        #expect(board.changedCount == 1)
        harness.center.currentTeamPlayerID = nil
        harness.center.changes.send(())
        for _ in 0..<20 where !board.fixtures.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        #expect(board.fixtures.isEmpty)
        #expect(board.drafts.isEmpty)
        #expect(board.sharedAI.isEmpty)
        #expect(!board.isCurrent(game: harness.game, apiBaseURL: harness.base))
    }
}

private final class MiniLeagueBoardServer: @unchecked Sendable {
    private let lock = NSLock()
    private let now = Date()
    private let existingIDs: Set<String>
    private let failOnce: Set<String>
    private let clockJumpAfterSave: TimeInterval
    private var attempts: [String] = []
    private var aiRevisions: [String] = []
    private var saved: [String: [String: Int]] = [:]
    init(existingIDs: Set<String> = [], failOnce: Set<String> = [], clockJumpAfterSave: TimeInterval = 0) {
        self.existingIDs = existingIDs; self.failOnce = failOnce; self.clockJumpAfterSave = clockJumpAfterSave
    }
    var attemptedIDs: [String] { lock.withLock { attempts } }
    var revisions: [String] { lock.withLock { aiRevisions } }
    func install() {
        let previous = MiniLeagueURLProtocol.handler
        MiniLeagueURLProtocol.handler = { [self] request in
            if let response = try self.response(request) { return response }
            guard let previous else { throw URLError(.badURL) }
            return try previous(request)
        }
    }
    private func response(_ request: URLRequest) throws -> (Int, Data)? {
        try lock.withLock {
            guard let url = request.url else { return nil }
            let last = url.lastPathComponent
            if request.httpMethod == "PUT", ["123", "124"].contains(last) {
                let body = try JSONSerialization.jsonObject(with: bodyData(request)) as? [String: Any] ?? [:]
                let first = !attempts.contains(last)
                attempts.append(last)
                aiRevisions.append(body["expectedAIRevision"] as? String ?? "")
                if failOnce.contains(last), first { return (503, Data(#"{"error":"Try this pick again","code":"unavailable"}"#.utf8)) }
                saved[last] = ["homeScore": body["homeScore"] as? Int ?? -1, "awayScore": body["awayScore"] as? Int ?? -1]
                return (200, try encode(["fixture": fixture(last), "serverTime": serverTime]))
            }
            guard last == "fixtures" else { return nil }
            if url.path.contains("/mini-leagues/") {
                return (200, try encode([
                    "fixtures": [fixture("123"), fixture("124")],
                    "sharedAI": ["123", "124"].map { ["fixtureId": $0, "ai": ["homeScore": 0, "awayScore": 3, "modelVersion": "v2", "sourceRevision": "league-revision"]] },
                    "round": NSNull(), "serverTime": serverTime
                ]))
            }
            let ids = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "ids" })?.value?.split(separator: ",").map(String.init) ?? []
            return (200, try encode(["fixtures": ids.map(fixture), "serverTime": serverTime]))
        }
    }
    private var serverTime: String { ISO8601DateFormatter().string(from: Date().addingTimeInterval(saved.isEmpty ? 0 : clockJumpAfterSave)) }
    private func fixture(_ id: String) -> [String: Any] {
        let score = saved[id] ?? (existingIDs.contains(id) ? ["homeScore": 2, "awayScore": 1] : nil)
        let prediction: Any = score.map { ["homeScore": $0["homeScore"]!, "awayScore": $0["awayScore"]!, "savedAt": serverTime] as [String: Any] } as Any? ?? NSNull()
        return [
            "id": id, "homeTeam": "Arsenal", "awayTeam": "Chelsea", "competitionId": "1", "competitionName": "Premier League",
            "seasonId": "2026", "seasonLabel": "2026/27", "kickoffAt": ISO8601DateFormatter().string(from: now.addingTimeInterval(id == "123" ? 3_600 : 7_200)),
            "status": "notstarted", "locked": false, "settled": false, "void": false,
            "ai": ["homeScore": 2, "awayScore": 1, "modelVersion": "v2", "sourceRevision": "personal-revision"],
            "prediction": prediction, "result": NSNull()
        ]
    }
    private func encode(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
