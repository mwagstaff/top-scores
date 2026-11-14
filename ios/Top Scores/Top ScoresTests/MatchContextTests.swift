import Foundation
import Testing
@testable import Top_Scores

struct MatchContextTests {
    private func payload(status: String = "predicted", lineups: String = "null") throws -> MatchDetailsPayload {
        try JSONDecoder().decode(MatchDetailsPayload.self, from: Data("""
        {"id":"42","home_team":"A","away_team":"B","team_lineups":\(lineups),"match_context":{
          "kickoff_at":"2026-11-14T15:00:00Z","is_upcoming":true,"lineup_status":"\(status)",
          "head_to_head":{"total_matches":1,"home_wins":0,"draws":1,"away_wins":0,
            "recent_matches":[{"event_id":"21","match_id":null,"date":"2026-10-01T15:00:00Z",
              "home_team":"B","away_team":"A","home_score":null,"away_score":null}]},
          "match_preview":{"text":"Preview","generated_at":null},"fun_facts":["A fact"],"refresh_after_seconds":30}}
        """.utf8))
    }

    @Test func cachedContentExpiresAtKickoffAndSupportsRescheduling() throws {
        let context = try #require(payload().matchContext)
        #expect(context.isPrematch(at: try #require(MatchContext.parseDate("2026-11-14T14:59:59Z")) ))
        #expect(!context.isPrematch(at: try #require(MatchContext.parseDate("2026-11-14T15:00:00Z")) ))
        #expect(context.funFacts == ["A fact"])
        #expect(MatchContext.parseDate("2026-11-14T15:00:00.000Z") == context.kickoffDate)
    }

    @Test func absentHistoryScoresAndUnresolvedMatchesStayUnavailable() throws {
        let meeting = try #require(payload().matchContext?.headToHead?.recentMatches.first)
        #expect(meeting.scoreText == "–")
        #expect(meeting.match == nil)
    }

    @Test func unavailableDetailsClearPreviouslyCachedPredictedLineups() throws {
        let lineup = MatchTeamLineup(team: "A", manager: nil, formation: "4-3-3", startingLineup: [], substitutes: [], substitutions: [])
        let match = Match(date: "2026-11-14", time: "15:00", homeTeam: "A", awayTeam: "B", league: "League", tvChannels: [],
                          teamLineups: MatchTeamLineups(home: lineup, away: nil))
        #expect(match.withDetails(try payload(status: "unavailable")).teamLineups == nil)
        let legacy = try JSONDecoder().decode(MatchDetailsPayload.self, from: Data("{\"id\":\"42\",\"home_team\":\"A\",\"away_team\":\"B\"}".utf8))
        #expect(match.withDetails(legacy).teamLineups != nil)
    }
}
