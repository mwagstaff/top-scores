import Foundation
import Testing
@testable import Top_Scores

@MainActor
struct MatchCommentaryTests {
    private func sample(refresh: String = "null") throws -> MatchCommentaryPayload {
        let json = """
        {
          "event_id":123,"status":"finished","has_play_by_play":true,
          "updated_at":"2026-10-20T17:00:00Z","stale":false,"refresh_after_seconds":\(refresh),
          "commentary":[
            {"id":"first","period":1,"minute":1,"added_time":null,"second":null,
             "type":"future_bsd_type","team":null,"player":null,"related_player":null,
             "score":{"home":null,"away":null},"text":"Kick-off.","important":false},
            {"id":"goal","period":2,"minute":90,"added_time":3,"second":12,
             "type":"goal","team":"home","player":{"id":42,"name":"Scorer"},
             "related_player":{"id":null,"name":null},"score":{"home":1,"away":0},
             "text":"Goal! Home lead 1-0.","important":true},
            {"id":"fulltime","period":2,"minute":90,"added_time":null,"second":null,
             "type":"period_end","team":null,"player":null,"related_player":null,
             "score":{"home":1,"away":0},"text":"Full-time.","important":true}
          ]
        }
        """
        return try JSONDecoder().decode(MatchCommentaryPayload.self, from: Data(json.utf8))
    }

    @Test func decodesUnknownTypesNullablePlayersAndAddedTime() throws {
        let payload = try sample()
        #expect(payload.eventID == 123)
        #expect(payload.commentary[0].type == "future_bsd_type")
        #expect(payload.commentary[0].score?.home == nil)
        #expect(payload.commentary[1].relatedPlayer?.id == nil)
        #expect(payload.commentary[1].minuteText == "90+3′")
        #expect(payload.commentary[1].accessibilityText == "90 minutes plus 3. Key moment. Goal! Home lead 1-0.")
        #expect(payload.refreshAfterSeconds == nil)
    }

    @Test func preservesProviderOrderWhenFullTimeHasAnEarlierDisplayMinute() throws {
        let payload = try sample()
        #expect(payload.entries(importantOnly: false).map(\.id) == ["fulltime", "goal", "first"])
        #expect(payload.entries(importantOnly: true).map(\.id) == ["fulltime", "goal"])
    }

    @Test func settledResponseStopsPollingAndReopeningRefreshes() async throws {
        let value = try sample()
        var calls = 0
        let store = MatchCommentaryStore { _, _ in calls += 1; return value }
        let url = try #require(URL(string: "https://example.com"))
        await store.follow(matchID: "123", baseURL: url)
        #expect(calls == 1)
        #expect(store.payload?.commentary.count == 3)
        await store.follow(matchID: "123", baseURL: url)
        #expect(calls == 2)
    }

    @Test func failedRefreshKeepsPreviousFeedAndCancellationStopsRetry() async throws {
        let value = try sample()
        var shouldFail = false
        let store = MatchCommentaryStore { _, _ in
            if shouldFail { throw URLError(.notConnectedToInternet) }
            return value
        }
        let url = try #require(URL(string: "https://example.com"))
        await store.follow(matchID: "123", baseURL: url)
        shouldFail = true
        let task = Task { await store.follow(matchID: "123", baseURL: url) }
        for _ in 0..<100 where !store.hasError { await Task.yield() }
        #expect(store.hasError)
        #expect(store.payload?.commentary.count == 3)
        task.cancel()
        await task.value
    }

    @Test func cancelledFetchDoesNotPublishOrShowAnError() async throws {
        let value = try sample()
        var started = false
        let store = MatchCommentaryStore { _, _ in
            started = true
            try await Task.sleep(for: .seconds(60))
            return value
        }
        let url = try #require(URL(string: "https://example.com"))
        let task = Task { await store.follow(matchID: "123", baseURL: url) }
        for _ in 0..<100 where !started { await Task.yield() }
        #expect(started)
        task.cancel()
        await task.value
        #expect(store.payload == nil)
        #expect(!store.hasError)
    }
}
