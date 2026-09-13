import Foundation
import Testing
@testable import Top_Scores

struct FantasyPreviousTeamTests {
    @Test func pickerTitleOmitsUnavailableScore() {
        #expect(fantasyPreviousTeamPickerTitle(finalScore: nil) == "Previous team")
    }

    @Test func pickerTitleIncludesFinalScore() {
        #expect(fantasyPreviousTeamPickerTitle(finalScore: 51) == "Previous team (51)")
    }

    @Test func reauthenticationIndicatorRequiresPriorSuccessfulSignIn() {
        #expect(!fantasyShouldShowReauthenticationIndicator(
            hasAuthenticatedBefore: false,
            requiresAuthentication: true
        ))
        #expect(!fantasyShouldShowReauthenticationIndicator(
            hasAuthenticatedBefore: true,
            requiresAuthentication: false
        ))
        #expect(fantasyShouldShowReauthenticationIndicator(
            hasAuthenticatedBefore: true,
            requiresAuthentication: true
        ))
    }

    @Test func entryHistoryDecodesHistoricalTeamValue() throws {
        let data = Data(
            #"{"event":4,"points":51,"total_points":189,"rank":123,"overall_rank":456,"event_transfers_cost":0,"points_on_bench":8,"value":1013}"#.utf8
        )

        let history = try JSONDecoder().decode(FantasyEntryHistory.self, from: data)

        #expect(history.teamValue == 1013)
        #expect(history.totalPoints == 189)
    }

    @Test func seasonTotalAddsLivePointsWhenFPLHasNotUpdatedCurrentGameweek() {
        #expect(fantasySeasonTotalPoints(
            reportedSeasonPoints: 189,
            reportedCurrentGameweekPoints: 0,
            resolvedCurrentGameweekPoints: 53
        ) == 242)
    }

    @Test func seasonTotalDoesNotDoubleCountWhenFPLHasUpdatedCurrentGameweek() {
        #expect(fantasySeasonTotalPoints(
            reportedSeasonPoints: 242,
            reportedCurrentGameweekPoints: 53,
            resolvedCurrentGameweekPoints: 53
        ) == 242)
    }

    @Test func seasonTotalReplacesReportedGameweekPointsWithResolvedScore() {
        #expect(fantasySeasonTotalPoints(
            reportedSeasonPoints: 240,
            reportedCurrentGameweekPoints: 51,
            resolvedCurrentGameweekPoints: 53
        ) == 242)
    }

    @Test func reconciledSeasonTotalUsesNewerProfileGameweekWhenPicksAndLiveAreStale() {
        #expect(fantasyReconciledSeasonTotalPoints(
            squadSeasonPoints: 242,
            reportedCurrentGameweekPoints: 53,
            resolvedCurrentGameweekPoints: 53,
            gameweekID: 4,
            profileCurrentGameweekID: 4,
            profileCurrentGameweekPoints: 82,
            profileSeasonPoints: 271
        ) == 271)
    }

    @Test func reconciledSeasonTotalUsesLiveScoreWhenItHasAdvancedBeyondPicks() {
        #expect(fantasyReconciledSeasonTotalPoints(
            squadSeasonPoints: 242,
            reportedCurrentGameweekPoints: 0,
            resolvedCurrentGameweekPoints: 53,
            gameweekID: 3,
            profileCurrentGameweekID: 3,
            profileCurrentGameweekPoints: 0,
            profileSeasonPoints: 189
        ) == 242)
    }

    @Test func reconciledSeasonTotalIgnoresProfileThatIsBehindPicks() {
        #expect(fantasyReconciledSeasonTotalPoints(
            squadSeasonPoints: 242,
            reportedCurrentGameweekPoints: 53,
            resolvedCurrentGameweekPoints: 53,
            gameweekID: 3,
            profileCurrentGameweekID: 3,
            profileCurrentGameweekPoints: 0,
            profileSeasonPoints: 189
        ) == 242)
    }

    @Test func liveProfileDoesNotRegressWhenFPLReturnsAnOlderSnapshot() {
        let newer = profile(overallPoints: 271, eventPoints: 82)
        let older = profile(overallPoints: 242, eventPoints: 53)

        #expect(fantasyStableEntryProfile(
            existing: newer,
            candidate: older,
            gameweekDataChecked: false
        ) == newer)
    }

    @Test func liveProfileAdvancesWhenFPLReturnsANewerSnapshot() {
        let older = profile(overallPoints: 242, eventPoints: 53)
        let newer = profile(overallPoints: 271, eventPoints: 82)

        #expect(fantasyStableEntryProfile(
            existing: older,
            candidate: newer,
            gameweekDataChecked: false
        ) == newer)
    }

    @Test func checkedGameweekAcceptsFinalDownwardCorrection() {
        let provisional = profile(overallPoints: 271, eventPoints: 82)
        let final = profile(overallPoints: 270, eventPoints: 81)

        #expect(fantasyStableEntryProfile(
            existing: provisional,
            candidate: final,
            gameweekDataChecked: true
        ) == final)
    }

    private func profile(overallPoints: Int, eventPoints: Int) -> FantasyEntryProfile {
        FantasyEntryProfile(
            id: 658_621,
            name: "Magic Muck",
            playerFirstName: "Mike",
            playerLastName: "Wagstaff",
            summaryOverallPoints: overallPoints,
            clubBadgeSrc: nil,
            currentEvent: 4,
            summaryEventPoints: eventPoints,
            leagues: nil
        )
    }
}
