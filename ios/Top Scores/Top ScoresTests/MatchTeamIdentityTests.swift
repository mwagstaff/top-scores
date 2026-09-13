import Foundation
import Testing
@testable import Top_Scores

@Suite(.serialized)
struct MatchTeamIdentityTests {
    @Test func matchDetailsRejectConflictingBSDTeamIDsDespiteMatchingNames() throws {
        let match = Match(
            date: "2026-09-08",
            time: "20:00",
            homeTeam: "Real Madrid",
            awayTeam: "Inter Milan",
            homeTeamId: "57",
            awayTeamId: "77",
            league: "UEFA Champions League",
            matchDetailsID: "601024",
            tvChannels: [],
            homeScore: 2,
            awayScore: 1,
            scoreStatus: "FT"
        )
        let details = try detailsPayload(homeID: "57", awayID: "398", awayName: "Inter Milan")

        #expect(!match.isCompatible(with: details))
        #expect(match.withDetails(details) == match)
    }

    @Test func matchDetailsAcceptMatchingBSDTeamIDsDespiteAmbiguousNames() throws {
        let match = Match(
            date: "2026-09-08",
            time: "20:00",
            homeTeam: "Real Madrid",
            awayTeam: "Inter",
            homeTeamId: "57",
            awayTeamId: "77",
            league: "UEFA Champions League",
            matchDetailsID: "601024",
            tvChannels: []
        )
        let details = try detailsPayload(homeID: "57", awayID: "77", awayName: "Inter Milan")

        #expect(match.isCompatible(with: details))
        #expect(match.withDetails(details).awayTeam == "Inter Milan")
    }

    @Test func matchDetailsDoNotNameMatchWhenOnlyTheMatchHasBSDTeamIDs() throws {
        let match = Match(
            date: "2026-09-08",
            time: "20:00",
            homeTeam: "Real Madrid",
            awayTeam: "Inter Milan",
            homeTeamId: "57",
            awayTeamId: "77",
            league: "UEFA Champions League",
            matchDetailsID: "601024",
            tvChannels: []
        )
        let json = """
        {
          "id": "601024",
          "date": "2026-09-08",
          "time": "20:00",
          "league": "UEFA Champions League",
          "home_team": "Real Madrid",
          "away_team": "Inter Milan",
          "home_score": 2,
          "away_score": 1,
          "score_status": "FT"
        }
        """
        let details = try JSONDecoder().decode(MatchDetailsPayload.self, from: Data(json.utf8))

        #expect(!match.isCompatible(with: details))
        #expect(match.withDetails(details) == match)
    }

    private func detailsPayload(homeID: String, awayID: String, awayName: String) throws -> MatchDetailsPayload {
        let json = """
        {
          "id": "601024",
          "date": "2026-09-08",
          "time": "20:00",
          "league": "UEFA Champions League",
          "home_team": "Real Madrid",
          "away_team": "\(awayName)",
          "home_team_id": "\(homeID)",
          "away_team_id": "\(awayID)",
          "home_score": 2,
          "away_score": 1,
          "score_status": "FT"
        }
        """
        return try JSONDecoder().decode(MatchDetailsPayload.self, from: Data(json.utf8))
    }
}
