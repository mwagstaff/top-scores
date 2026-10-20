import Foundation
import Testing
@testable import Top_Scores_Watch_Watch_App

@MainActor
struct WatchCompetitionRefreshTests {
    private let baseURL = URL(string: "https://example.com")!

    @Test func refreshReplacesOldScoreAndClockWithFinalResult() async throws {
        let live = try match(score: 2, status: "74")
        let final = try match(score: 3, status: "FT")
        var calls = 0
        let store = WatchCompetitionRefreshStore { _, _ in
            calls += 1
            return [calls == 1 ? live : final]
        }
        await store.refresh(date: live.date, baseURL: baseURL)
        #expect(store.matches?.first?.scoreStatus == "74")
        await store.refresh(date: live.date, baseURL: baseURL)
        #expect(store.matches?.first?.scoreStatus == "FT")
        #expect(store.matches?.first?.awayScore == 3)
        #expect(store.matches?.first?.isInProgress == false)
    }

    @Test func failedRefreshRetainsLastResultAndAllowsRecovery() async throws {
        let result = try match(score: 3, status: "FT")
        var calls = 0
        let store = WatchCompetitionRefreshStore { _, _ in
            calls += 1
            if calls == 2 { throw URLError(.notConnectedToInternet) }
            return [result]
        }
        await store.refresh(date: result.date, baseURL: baseURL)
        await store.refresh(date: result.date, baseURL: baseURL)
        #expect(store.matches?.first?.awayScore == 3)
        #expect(store.loadError != nil)
        await store.refresh(date: result.date, baseURL: baseURL)
        #expect(store.loadError == nil)
        #expect(!store.isLoading)
    }

    @Test func cancelledPollingDoesNotFetch() async {
        var calls = 0
        let store = WatchCompetitionRefreshStore { _, _ in
            calls += 1
            return []
        }
        let task = Task { await store.run(date: "2026-10-17", baseURL: baseURL) }
        task.cancel()
        await task.value
        #expect(calls == 0)
    }

    private func match(score: Int, status: String) throws -> WatchMatch {
        let json = """
        {"date":"2026-10-17","time":"15:00","league":"Premier League",
         "home_team":"Brentford","away_team":"Liverpool","match_details_id":"8324",
         "home_score":1,"away_score":\(score),"score_status":"\(status)"}
        """
        return try JSONDecoder().decode(WatchMatch.self, from: Data(json.utf8))
    }
}
