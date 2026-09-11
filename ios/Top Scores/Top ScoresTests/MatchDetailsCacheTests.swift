import Foundation
import Testing
@testable import Top_Scores

struct MatchDetailsCacheTests {
    @Test func readsExistingCacheKeysAndIgnoresCorruptData() async throws {
        let suite = "MatchDetailsCacheTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = MatchDetailsCache(suiteName: suite)
        defaults.set(Data(#"{"id":"legacy","home_score":2,"updated_at":"2026-09-10T18:00:00Z"}"#.utf8),
                     forKey: "match.details.cache.legacy")
        defaults.set(Data("broken JSON".utf8), forKey: "match.details.cache.corrupt")

        let legacy = await cache.load(for: "legacy")
        #expect(legacy?.homeScore == 2)
        #expect(legacy?.updatedAt == "2026-09-10T18:00:00Z")
        #expect(await cache.load(for: "corrupt") == nil)
        #expect(await cache.load(for: "missing") == nil)
    }

    @Test func preservesEventsDuringBackfillAndAcceptsFreshPopulatedDetails() async throws {
        let suite = "MatchDetailsCacheTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = MatchDetailsCache(suiteName: suite)
        let initial = try payload(#"{"id":"match","home_score":1,"home_goal_scorers":[{"player":"Scorer","goal_times":["12'"]}]}"#)
        let empty = try payload(#"{"id":"match","home_score":0}"#)
        let updated = try payload(#"{"id":"match","home_score":2,"home_goal_scorers":[{"player":"Scorer","goal_times":["12'","81'"]}]}"#)

        await cache.save(initial, for: "match")
        await cache.save(empty, for: "match")
        #expect(await cache.load(for: "match") == initial)
        await cache.save(updated, for: "match")
        #expect(await cache.load(for: "match") == updated)
    }

    private func payload(_ json: String) throws -> MatchDetailsPayload {
        try JSONDecoder().decode(MatchDetailsPayload.self, from: Data(json.utf8))
    }
}
