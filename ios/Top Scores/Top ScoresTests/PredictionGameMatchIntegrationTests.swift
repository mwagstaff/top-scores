import Foundation
import Testing
@testable import Top_Scores

struct PredictionGameMatchIntegrationTests {
    @Test func canonicalBSDIdentitySurvivesKickoffChanges() {
        let original = match(date: "2026-09-12", leagueID: "1", detailsID: "8324")
        let rescheduled = match(date: "2026-10-03", leagueID: "1", detailsID: "8324")
        #expect(original.id != rescheduled.id)
        #expect(original.predictionGameFixtureID == "8324")
        #expect(rescheduled.predictionGameFixtureID == original.predictionGameFixtureID)
    }

    @Test func allCompetitionsAcceptBSDIdentifiers() {
        #expect(match(leagueID: "13", detailsID: "8324").predictionGameFixtureID == "8324")
        #expect(match(leagueID: "28", detailsID: "8324").predictionGameFixtureID == "8324")
        #expect(match(leagueID: "1", detailsID: "bbc:abcd").predictionGameFixtureID == nil)
        #expect(match(leagueID: "1", detailsID: nil).predictionGameFixtureID == nil)
    }

    @Test func canonicalCompetitionAliasesAreSupported() {
        #expect(match(leagueID: "premier-league", detailsID: "8324").predictionGameFixtureID == "8324")
        #expect(match(leagueID: nil, detailsID: "8324").predictionGameFixtureID == "8324")
    }

    @Test func predictionInvitationUsesAbsoluteKickoffAndStopsAtTheDeadline() throws {
        let fixture = match(leagueID: "1", detailsID: "8324", kickoffAt: "2026-09-12T14:00:00.000Z")
        let kickoff = try Date("2026-09-12T14:00:00Z", strategy: .iso8601)
        #expect(fixture.predictionGameKickoff == kickoff)
        #expect(fixture.canOfferPredictionGame(at: kickoff.addingTimeInterval(-1)))
        #expect(!fixture.canOfferPredictionGame(at: kickoff))
        #expect(!fixture.canOfferPredictionGame(at: kickoff.addingTimeInterval(1)))
    }

    @Test func predictionInvitationRejectsUncertainAndStartedFixtures() throws {
        let beforeKickoff = try Date("2026-09-12T13:00:00Z", strategy: .iso8601)
        // A live status with a future scheduled kickoff must not become an invitation.
        for status in ["LIVE", "FT", "POSTPONED", "cancelled", "abandoned", "unknown"] {
            #expect(!match(leagueID: "1", detailsID: "8324", scoreStatus: status).canOfferPredictionGame(at: beforeKickoff))
        }
        #expect(!match(date: "TBC", leagueID: "1", detailsID: "8324").canOfferPredictionGame(at: beforeKickoff))
        #expect(match(leagueID: "13", detailsID: "8324").canOfferPredictionGame(at: beforeKickoff))
        #expect(!match(leagueID: "1", detailsID: "8324", homeScore: 0).canOfferPredictionGame(at: beforeKickoff))
    }

    @Test func liveMatchWithoutGameAISnapshotStillShowsLockedAvailability() throws {
        // Fixtures can retain their display prediction even when the game has no
        // pre-kickoff snapshot for a match first imported after play started.
        let fixture = try gameFixture(status: "inprogress", locked: true)
        #expect(fixture.ai == nil)
        #expect(fixture.predictionAvailability(at: fixture.kickoffAt.addingTimeInterval(37 * 60)) == .locked)
    }

    @Test func kickoffClosesPredictionWindowBeforeTheNextServerRefresh() throws {
        let fixture = try gameFixture(status: "notstarted", locked: false)
        #expect(fixture.predictionAvailability(at: fixture.kickoffAt.addingTimeInterval(-1)) == .awaitingAI)
        #expect(fixture.predictionAvailability(at: fixture.kickoffAt) == .locked)
        #expect(fixture.predictionAvailability(at: fixture.kickoffAt.addingTimeInterval(1)) == .locked)
    }

    @Test func voidMatchDoesNotInviteAnotherAttemptAfterKickoff() throws {
        let fixture = try gameFixture(status: "cancelled", locked: true, void: true)
        #expect(fixture.predictionAvailability(at: fixture.kickoffAt.addingTimeInterval(3600)) == .void)
    }

    @Test func completedPredictionHighlightsPreferExactThenHeadToHeadResult() {
        #expect(completedFixture(youPoints: 3, aiPoints: 3).completedPredictionHighlight == .exactScore)
        #expect(completedFixture(youPoints: 1, aiPoints: 0).completedPredictionHighlight == .userWin)
        #expect(completedFixture(youPoints: 0, aiPoints: 1).completedPredictionHighlight == .aiWin)
        #expect(completedFixture(youPoints: 1, aiPoints: 1).completedPredictionHighlight == nil)
    }

    @Test func unfinishedAndUnpredictedMatchesHaveNoCompletedHighlight() {
        #expect(completedFixture(youPoints: 3, aiPoints: 0, settled: false).completedPredictionHighlight == nil)
        #expect(completedFixture(youPoints: nil, aiPoints: nil).completedPredictionHighlight == nil)
    }

    @Test func latestResultUsesNewestCompletedRoundWithScoredMatches() {
        let older = recentRound(id: "gw-2", startsAt: .now.addingTimeInterval(-14 * 86_400), youPoints: 5, aiPoints: 3)
        let newest = recentRound(id: "gw-3", startsAt: .now.addingTimeInterval(-7 * 86_400), youPoints: 2, aiPoints: 4)
        let empty = recentRound(id: "gw-4", startsAt: .now, youPoints: 0, aiPoints: 0, played: 0)
        let inProgress = recentRound(
            id: "gw-5", startsAt: .now.addingTimeInterval(86_400),
            youPoints: 8, aiPoints: 1, completed: false
        )

        #expect(PredictionGameRecentGameweek.latestCompleted(in: [newest, inProgress, older, empty])?.id == "gw-3")
    }

    @Test func recentRoundComparesUserAndAIPoints() {
        #expect(recentRound(id: "win", youPoints: 4, aiPoints: 2).headToHeadOutcome == .userWin)
        #expect(recentRound(id: "draw", youPoints: 3, aiPoints: 3).headToHeadOutcome == .draw)
        #expect(recentRound(id: "loss", youPoints: 1, aiPoints: 5).headToHeadOutcome == .aiWin)
    }

    @Test func latestResultCopyHasConfigurableOptionsForEveryOutcome() {
        for outcome in [PredictionGameRoundOutcome.userWin, .draw, .aiWin] {
            let messages = BeatAILatestResultCopy.messages(for: outcome)
            #expect(messages.count >= 3)
            #expect(Set(messages).count == messages.count)
            #expect(messages.contains(BeatAILatestResultCopy.random(for: outcome)))
        }
    }

    @Test func inPlayRoundComparesProvisionalScoresAndHasConfigurableCopy() {
        let round = PredictionGameInPlayRound(
            id: "round-4", label: "Gameweek 4", youPoints: 6, aiPoints: 4,
            scoredMatches: 3, liveMatches: 2, totalMatches: 10
        )
        #expect(round.headToHeadOutcome == .userWin)
        for outcome in [PredictionGameRoundOutcome.userWin, .draw, .aiWin] {
            let messages = BeatAIInPlayCopy.messages(for: outcome)
            #expect(messages.count >= 3)
            #expect(Set(messages).count == messages.count)
            #expect(messages.contains(BeatAIInPlayCopy.random(for: outcome)))
        }
    }

    private func completedFixture(youPoints: Int?, aiPoints: Int?, settled: Bool = true) -> PredictionGameFixture {
        PredictionGameFixture(
            id: "8324", homeTeam: "Fenerbahçe", awayTeam: "Roma",
            seasonId: "1112", seasonLabel: "2026/27", kickoffAt: .now.addingTimeInterval(-7200),
            status: settled ? "finished" : "inprogress", locked: true, settled: settled, void: false,
            challengeId: nil,
            ai: PredictionGameAI(homeScore: 1, awayScore: 1, modelVersion: "v1", sourceRevision: "v1", frozenAt: .now),
            prediction: youPoints == nil ? nil : PredictionGameEntry(
                homeScore: 2, awayScore: 0, savedAt: .now,
                youPoints: youPoints, aiPoints: aiPoints, outcome: nil
            ),
            result: PredictionGameScore(homeScore: 2, awayScore: 0)
        )
    }

    private func recentRound(
        id: String,
        startsAt: Date = .now,
        youPoints: Int,
        aiPoints: Int,
        played: Int = 10,
        completed: Bool = true
    ) -> PredictionGameRecentGameweek {
        PredictionGameRecentGameweek(
            id: id, label: "Gameweek 3", startsAt: startsAt,
            youPoints: youPoints, aiPoints: aiPoints, played: played,
            predicted: played, totalMatches: 10, completed: completed
        )
    }

    private func gameFixture(status: String, locked: Bool, void: Bool = false) throws -> PredictionGameFixture {
        try PredictionGameAPIClient.decoder().decode(PredictionGameFixture.self, from: Data("""
        {
            "id":"8324", "competitionId":"7", "competitionName":"Champions League",
            "homeTeam":"Fenerbahçe", "awayTeam":"Roma",
            "seasonId":"1112", "seasonLabel":"2026/27", "kickoffAt":"2026-09-10T16:45:00Z",
            "status":"\(status)", "locked":\(locked), "settled":false, "void":\(void),
            "challengeId":null, "ai":null, "prediction":null, "result":null
        }
        """.utf8))
    }

    private func match(
        date: String = "2026-09-12", leagueID: String?, detailsID: String?,
        kickoffAt: String? = nil, scoreStatus: String? = nil, homeScore: Int? = nil
    ) -> Match {
        Match(
            date: date, time: "15:00", homeTeam: "Arsenal", awayTeam: "Liverpool",
            kickoffAt: kickoffAt, league: "Premier League", leagueId: leagueID,
            matchDetailsID: detailsID, tvChannels: [], homeScore: homeScore, scoreStatus: scoreStatus
        )
    }
}
