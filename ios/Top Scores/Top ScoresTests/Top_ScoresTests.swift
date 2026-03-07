//
//  Top_ScoresTests.swift
//  Top ScoresTests
//
//  Created by Mike Wagstaff on 11/02/2026.
//

import Foundation
import Testing
@testable import Top_Scores

struct Top_ScoresTests {

    @Test func withScore_adjustsAggregateByScoreDelta() async throws {
        let match = makeMatch(
            homeScore: 0,
            awayScore: 0,
            aggregateHomeScore: 3,
            aggregateAwayScore: 3
        )

        let updated = match.withScore(home: 1, away: 0, status: "33")

        #expect(updated.homeScore == 1)
        #expect(updated.awayScore == 0)
        #expect(updated.aggregateHomeScore == 4)
        #expect(updated.aggregateAwayScore == 3)
    }

    @Test func withScore_keepsAggregateWhenBaseScoresMissing() async throws {
        let match = makeMatch(
            homeScore: nil,
            awayScore: nil,
            aggregateHomeScore: 3,
            aggregateAwayScore: 3
        )

        let updated = match.withScore(home: 1, away: 0, status: "33")

        #expect(updated.aggregateHomeScore == 3)
        #expect(updated.aggregateAwayScore == 3)
    }

    @Test func withDetails_preservesFinishedStatusWhenDetailsRegressToLiveMinute() async throws {
        let match = makeMatch(
            homeScore: 2,
            awayScore: 1,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            scoreStatus: "FT"
        )

        let updated = match.withDetails(
            makeDetailsPayload(scoreStatus: "90+7")
        )

        #expect(updated.scoreStatus == "FT")
    }

    @Test func stabilizedScoreStatus_clampsOverdueLiveMatchesToFullTime() async throws {
        let kickoff = Date(timeIntervalSince1970: 1_772_626_800) // 2026-03-07 15:00 UTC
        let now = kickoff.addingTimeInterval((3.5 * 60 * 60) + 60)

        let match = makeMatch(
            date: "2026-03-07",
            time: "15:00",
            homeScore: 1,
            awayScore: 0,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            scoreStatus: "90+7"
        )

        #expect(match.stabilizedScoreStatus(now: now) == "FT")
    }

    @Test @MainActor func mergeRefreshedMatches_preservesTerminalStateAcrossResetRefresh() async throws {
        let existing = makeMatch(
            date: "2026-03-07",
            time: "15:00",
            homeScore: 2,
            awayScore: 1,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            scoreStatus: "FT"
        )
        let incoming = makeMatch(
            date: "2026-03-07",
            time: "15:00",
            homeScore: 2,
            awayScore: 1,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            scoreStatus: "90+7"
        )

        let merged = MatchesStore.mergeRefreshedMatches(existing: [existing], incoming: [incoming])

        #expect(merged.count == 1)
        #expect(merged[0].scoreStatus == "FT")
    }

    private func makeMatch(
        date: String = "2026-02-24",
        time: String = "17:45",
        homeScore: Int?,
        awayScore: Int?,
        aggregateHomeScore: Int?,
        aggregateAwayScore: Int?,
        scoreStatus: String = "30"
    ) -> Match {
        Match(
            date: date,
            time: time,
            homeTeam: "Atletico Madrid",
            awayTeam: "Club Brugge",
            league: "UEFA Champions League",
            tvChannels: ["TNT Sports 3"],
            homeScore: homeScore,
            awayScore: awayScore,
            aggregateHomeScore: aggregateHomeScore,
            aggregateAwayScore: aggregateAwayScore,
            scoreStatus: scoreStatus
        )
    }

    private func makeDetailsPayload(scoreStatus: String) -> MatchDetailsPayload {
        let payload: [String: Any?] = [
            "id": "abc123",
            "details_url": nil,
            "date": "2026-02-24",
            "time": "17:45",
            "league": "UEFA Champions League",
            "home_team": "Atletico Madrid",
            "away_team": "Club Brugge",
            "home_score": 2,
            "away_score": 1,
            "aggregate_home_score": nil,
            "aggregate_away_score": nil,
            "score_status": scoreStatus,
            "home_goal_scorers": [],
            "away_goal_scorers": [],
            "home_assists": [],
            "away_assists": [],
            "home_red_cards": [],
            "away_red_cards": [],
            "penalty_result": nil,
            "in_progress": true,
            "updated_at": "2026-02-24T20:10:00Z",
        ]

        let data = try! JSONSerialization.data(withJSONObject: payload.compactMapValues { $0 })
        return try! JSONDecoder().decode(MatchDetailsPayload.self, from: data)
    }

}
