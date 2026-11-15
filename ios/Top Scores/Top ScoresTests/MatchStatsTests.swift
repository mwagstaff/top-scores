import Foundation
import Testing
@testable import Top_Scores

struct MatchStatsTests {
    private func row(_ id: String, home: Double? = 0, away: Double? = nil) -> MatchStats.Row {
        .init(id: id, label: id, group: "Key stats", headline: true, home: home, away: away,
              homeDisplay: home.map { String($0) } ?? "—", awayDisplay: away.map { String($0) } ?? "—", homeEstimated: false, awayEstimated: false)
    }

    @Test func optionalPayloadAndProvenanceDecode() throws {
        let legacy = try JSONDecoder().decode(MatchDetailsPayload.self, from: Data("{\"id\":\"42\"}".utf8))
        #expect(legacy.matchStats == nil)
        let payload = try JSONDecoder().decode(MatchDetailsPayload.self, from: Data("""
        {"id":"42","match_stats":{"status":"available","periods":[{"id":"all","label":"All","rows":[
        {"id":"xg","label":"Expected goals (xG)","group":"Key stats","headline":true,"home":0,"away":null,
         "home_display":"0.00","away_display":"—","home_estimated":true,"away_estimated":false}]}],
        "updated_at":"2026-11-14T16:00:00.000Z","refresh_after_seconds":60}}
        """.utf8))
        let stats = try #require(payload.matchStats)
        #expect(stats.summaryRows[0].display(home: true) == "0.00 est.")
        #expect(stats.summaryRows[0].away == nil)
        #expect(stats.updatedDate != nil)
        let cached = try JSONDecoder().decode(MatchDetailsPayload.self, from: JSONEncoder().encode(payload))
        #expect(cached.matchStats == stats)
    }

    @Test func barsRespectMissingZeroAndNegativeValues() {
        #expect(row("zero", home: 0, away: 0).homeShare == nil)
        #expect(row("missing", home: 3).homeShare == nil)
        #expect(row("negative", home: -1, away: 2).homeShare == nil)
        #expect(row("ratio", home: 3, away: 1).homeShare == 0.75)
    }

    @Test func summaryNeverSubstitutesHalfValuesForWholeMatch() {
        let stats = MatchStats(status: "available", periods: [.init(id: "first_half", label: "1st half", rows: [row("xg")])], updatedAt: nil, refreshAfterSeconds: nil)
        #expect(stats.summaryRows.isEmpty)
        #expect(stats.availablePeriods.count == 1)
        let duplicated = MatchStats(status: "available", periods: [
            .init(id: "all", label: "All", rows: [row("xg"), row("xg"), row("bad", home: .nan)]),
            .init(id: "all", label: "All", rows: [row("shots_on_target")]),
            .init(id: "second_half", label: "2nd half", rows: [])], updatedAt: nil, refreshAfterSeconds: nil)
        #expect(duplicated.availablePeriods.count == 1)
        #expect(duplicated.availablePeriods[0].rows.count == 1)
    }
}
