import Foundation
import Testing
@testable import Top_Scores

struct FantasyAutoSubstitutionTests {
    private func player(_ id: Int, _ position: FantasyPositionType, points: Int = 0,
                        minutes: Int = 90, upcoming: Bool = false, active: Bool = false,
                        yellow: Int = 0, red: Int = 0) -> FantasyDisplayPlayer {
        makeFantasyPlayer(elementID: id, pickPosition: id, positionType: position,
            displayName: "Player \(id)", fullName: "Player \(id)", teamName: "Team",
            hasStartedFixtureThisGameweek: true,
            hasUpcomingFixtureThisGameweek: upcoming, hasActiveFixtureThisGameweek: active,
            minutesPlayed: minutes, rawPoints: points, appliedPoints: id <= 11 ? points : 0,
            displayPoints: points, multiplier: id <= 11 ? 1 : 0,
            yellowCards: yellow, redCards: red)
    }

    private var starters: [FantasyDisplayPlayer] {
        [player(1, .goalkeeper, points: 7),
         player(2, .defender, points: 10), player(3, .defender, points: 1), player(4, .defender, points: 1),
         player(5, .midfielder), player(6, .midfielder, points: 1), player(7, .midfielder, points: 2),
         player(8, .midfielder, minutes: 0), player(9, .forward, points: 2),
         player(10, .forward, points: 16), player(11, .forward, minutes: 0)]
    }
    private var bench: [FantasyDisplayPlayer] {
        [player(12, .goalkeeper, points: 9), player(13, .midfielder, points: 1),
         player(14, .defender, points: 6), player(15, .defender, points: 1)]
    }
    private func resolve(_ starters: [FantasyDisplayPlayer], _ bench: [FantasyDisplayPlayer]) -> [FantasyBenchContribution] {
        FantasyAutoSubResolver.resolve(starters: starters, bench: bench, benchBoost: false)
    }

    @Test func screenshotExampleCountsFirstTwoOutfieldPlayers() {
        let result = resolve(starters, bench)
        #expect(result.map(\.id) == [13, 14])
        #expect(result.compactMap { $0.outgoing?.elementID } == [8, 11])
        #expect(starters.reduce(0) { $0 + $1.appliedPoints } + result.reduce(0) { $0 + $1.points } == 47)
        #expect(result.allSatisfy { !$0.confirmed })
    }

    @Test func formationSkipsMidfielderWhenOnlyDefenderIsAbsent() {
        var team = starters
        team[1] = player(2, .defender, minutes: 0)
        team[7] = player(8, .midfielder)
        team[10] = player(11, .forward)
        let result = resolve(team, bench)
        #expect(result.map(\.id) == [14])
        #expect(result.first?.outgoing?.elementID == 2)
    }

    @Test func remainingFixturesAndOneMinuteAppearancePreventSubstitution() {
        var team = starters
        team[7] = player(8, .midfielder, minutes: 0, upcoming: true)
        team[10] = player(11, .forward, minutes: 0, active: true)
        #expect(resolve(team, bench).isEmpty)
        team[7] = player(8, .midfielder, minutes: 1)
        team[10] = player(11, .forward, minutes: 1)
        #expect(resolve(team, bench).isEmpty)
    }

    @Test func cardsCountAsParticipationAndNegativeBenchPointsCount() {
        var team = starters
        team[7] = player(8, .midfielder, minutes: 0, yellow: 1)
        team[10] = player(11, .forward, minutes: 0, red: 1)
        #expect(resolve(team, bench).isEmpty)
        let negativeBench = [player(13, .midfielder, points: -1, minutes: 0, yellow: 1)]
        #expect(resolve(starters, negativeBench).first?.points == -1)
    }

    @Test func goalkeeperOnlyReplacesGoalkeeperAndZeroPointsStillCount() {
        var team = starters
        team[0] = player(1, .goalkeeper, minutes: 0)
        let result = resolve(team, [player(12, .goalkeeper, points: 0)])
        #expect(result.count == 1)
        #expect(result.first?.outgoing?.elementID == 1)
        #expect(result.first?.points == 0)
    }

    @Test func benchBoostIncludesAllFourWithoutOutgoingPlayers() {
        let result = FantasyAutoSubResolver.resolve(starters: starters, bench: bench, benchBoost: true, isFinal: true)
        #expect(result.map(\.id) == [12, 13, 14, 15])
        #expect(result.allSatisfy { $0.outgoing == nil && $0.confirmed })
        #expect(result.reduce(0) { $0 + $1.points } == 17)
    }

    @Test func officialRecordsOverrideInferenceAndSurviveProjectionCopies() {
        let records = [FantasyAutomaticSubstitution(elementIn: 14, elementOut: 11)]
        var squad = FantasySquadDisplayData(
            gameweekID: 8, gameweekTitle: "GW8", deadlineGameweekID: nil, deadlineTime: nil,
            totalPoints: 46, gameweekAverageScore: nil, hasActiveFixtures: false,
            hasStartedFixturesInGameweek: true, hasFixturesPlayedToday: false,
            isEstimatedScore: false, estimatedCurrentScore: 46, scoreCalculationRulesApplied: [],
            rank: nil, overallRank: nil, transfersCost: nil, pointsOnBench: nil, activeChips: [],
            goalkeepers: starters.filter { $0.positionType == .goalkeeper },
            defenders: starters.filter { $0.positionType == .defender },
            midfielders: starters.filter { $0.positionType == .midfielder },
            forwards: starters.filter { $0.positionType == .forward }, bench: bench,
            officialAutomaticSubs: records)
        #expect(squad.benchContributions.map(\.id) == [14])
        #expect(squad.benchContributions.allSatisfy { $0.confirmed })
        #expect(squad.effectivePlayerMultipliersByElementID[14] == 1)
        #expect(squad.effectivePlayerMultipliersByElementID[13] == 0)
        #expect(squad.applyingExpectedPoints([:]).officialAutomaticSubs == records)
        squad.officialAutomaticSubs = []
        #expect(squad.benchContributions.isEmpty)
    }

    @Test func missingParticipationDataDoesNotInventAnAbsence() {
        var team = starters
        team[7].hasParticipationData = false
        team[10].hasParticipationData = false
        #expect(resolve(team, bench).isEmpty)
    }

    @Test func officialAPIPayloadDecodesAndOldPayloadStillWorks() throws {
        let json = #"{"picks":[],"entry_history":{"event":8,"points":47},"automatic_subs":[{"element_in":13,"element_out":8,"entry":123,"event":8}]}"#
        let response = try JSONDecoder().decode(FantasyPicksResponse.self, from: Data(json.utf8))
        #expect(response.automaticSubs == [FantasyAutomaticSubstitution(elementIn: 13, elementOut: 8)])
        let old = #"{"picks":[],"entry_history":{"event":8,"points":47}}"#
        #expect(try JSONDecoder().decode(FantasyPicksResponse.self, from: Data(old.utf8)).automaticSubs == nil)
    }

    @Test func confirmedPicksRestoreOriginalBenchSlots() throws {
        // Shape verified against a processed official FPL picks response.
        let json = #"{"picks":[{"element":31,"position":5,"multiplier":1,"is_captain":false,"is_vice_captain":false,"element_type":2},{"element":368,"position":13,"multiplier":0,"is_captain":false,"is_vice_captain":false,"element_type":3}],"entry_history":{"event":6,"points":47},"automatic_subs":[{"element_in":31,"element_out":368}]}"#
        let response = try JSONDecoder().decode(FantasyPicksResponse.self, from: Data(json.utf8))
        let original = response.picksBeforeAutomaticSubstitutions
        #expect(original.first?.element == 368)
        #expect(original.first?.position == 5)
        #expect(original.last?.element == 31)
        #expect(original.last?.position == 13)
        let alreadyOriginal = FantasyPicksResponse(picks: original, entryHistory: response.entryHistory,
                                                  automaticSubs: response.automaticSubs)
        #expect(alreadyOriginal.picksBeforeAutomaticSubstitutions == original)
    }

    private func makeFantasyPlayer(
        elementID: Int,
        pickPosition: Int,
        positionType: FantasyPositionType,
        displayName: String,
        fullName: String,
        teamName: String,
        hasAnyFixtureThisGameweek: Bool = true,
        hasStartedFixtureThisGameweek: Bool = false,
        hasUpcomingFixtureThisGameweek: Bool = true,
        hasActiveFixtureThisGameweek: Bool = false,
        minutesPlayed: Int = 0,
        rawPoints: Int = 0,
        appliedPoints: Int = 0,
        displayPoints: Int = 0,
        multiplier: Int = 1,
        isCaptain: Bool = false,
        isViceCaptain: Bool = false,
        isDefinitelyUnavailable: Bool = false,
        expectedPointsThisGameweek: Double? = nil,
        officialExpectedPointsNextGameweek: Double? = nil,
        yellowCards: Int = 0,
        redCards: Int = 0
    ) -> FantasyDisplayPlayer {
        FantasyDisplayPlayer(
            elementID: elementID,
            pickPosition: pickPosition,
            positionType: positionType,
            displayName: displayName,
            fullName: fullName,
            teamName: teamName,
            profileImageURL: nil,
            nowCostMillions: 5.0,
            hasStartedCurrentSeason: true,
            ownershipPercent: nil,
            ownershipCount: nil,
            form: nil,
            pointsPerMatch: nil,
            totalPoints: nil,
            averageMinutes: nil,
            rawPoints: rawPoints,
            appliedPoints: appliedPoints,
            displayPoints: displayPoints,
            multiplier: multiplier,
            isCaptain: isCaptain,
            isViceCaptain: isViceCaptain,
            isPlayingNow: false,
            isUnavailable: false,
            isDefinitelyUnavailable: isDefinitelyUnavailable,
            hasAnyFixtureThisGameweek: hasAnyFixtureThisGameweek,
            hasStartedFixtureThisGameweek: hasStartedFixtureThisGameweek,
            hasUpcomingFixtureThisGameweek: hasUpcomingFixtureThisGameweek,
            hasActiveFixtureThisGameweek: hasActiveFixtureThisGameweek,
            hasFutureAvailabilityIssue: false,
            futureAvailabilityIssueGameweek: nil,
            minutesPlayed: minutesPlayed,
            upcomingOpponentDisplay: nil,
            fixtureDifficulty: nil,
            nextFiveFixtureDifficulties: [],
            expectedPointsThisGameweek: expectedPointsThisGameweek,
            officialExpectedPointsNextGameweek: officialExpectedPointsNextGameweek,
            goalsScored: 0,
            assists: 0,
            yellowCards: yellowCards,
            redCards: redCards
        )
    }

}
