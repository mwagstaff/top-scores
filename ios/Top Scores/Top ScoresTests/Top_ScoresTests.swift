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

    @Test @MainActor func preferencesStore_usesRequestedDefaultsForNewInstalls() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        let store = PreferencesStore(userDefaults: defaults)

        #expect(store.englishPremierLeagueTeamsOnly)
        #expect(!store.competitionFilterEnabled)
        #expect(store.notificationsEnabled)
        #expect(store.notificationDelayMinutes == 2)
        #expect(store.notificationEventTypes == PreferencesStore.defaultNotificationEventTypes)
        #expect(store.notificationUseViewingFilter)
        #expect(store.matchGroupSortOrder == .kickoffThenTeamScore)
        #expect(!store.showTodayUnfinishedFixturesBadge)
        #expect(store.showFantasyMatchPills)
        #expect(!store.channelFilterEnabled)
    }

    @Test func appIconBadgeManager_countsOnlyTodayUnfinishedFixtures() async throws {
        let today = formattedDate(offsetDays: 0)
        let yesterday = formattedDate(offsetDays: -1)
        let tomorrow = formattedDate(offsetDays: 1)

        let matches = [
            makeMatch(date: today, time: "12:30", homeScore: nil, awayScore: nil, aggregateHomeScore: nil, aggregateAwayScore: nil, scoreStatus: nil),
            makeMatch(date: today, time: "15:00", homeScore: 1, awayScore: 0, aggregateHomeScore: nil, aggregateAwayScore: nil, scoreStatus: "33"),
            makeMatch(date: today, time: "17:30", homeScore: 2, awayScore: 1, aggregateHomeScore: nil, aggregateAwayScore: nil, scoreStatus: "FT"),
            makeMatch(date: yesterday, time: "19:45", homeScore: 1, awayScore: 1, aggregateHomeScore: nil, aggregateAwayScore: nil, scoreStatus: "FT"),
            makeMatch(date: tomorrow, time: "20:00", homeScore: nil, awayScore: nil, aggregateHomeScore: nil, aggregateAwayScore: nil, scoreStatus: nil)
        ]

        #expect(AppIconBadgeManager.unfinishedFixtureCount(for: matches) == 2)
    }

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

    @Test func withDetails_upgradesFirstHalfStoppageTimeToHalfTime() async throws {
        let match = makeMatch(
            homeScore: 0,
            awayScore: 1,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            scoreStatus: "45+5"
        )

        let updated = match.withDetails(
            makeDetailsPayload(scoreStatus: "HT")
        )

        #expect(updated.scoreStatus == "HT")
    }

    @Test func matchStatusFormatter_prefersHalfTimeOverFirstHalfStoppageTime() async throws {
        #expect(MatchStatusFormatter.preferredStatus(current: "45+5", incoming: "HT") == "HT")
        #expect(MatchStatusFormatter.preferredStatus(current: "HT", incoming: "45+5") == "HT")
        #expect(MatchStatusFormatter.preferredStatus(current: "47", incoming: "HT") == "47")
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

    @Test func winnerSummaryText_formatsPenaltyShootoutWinners() async throws {
        let match = Match(
            date: "2026-03-01",
            time: "19:45",
            homeTeam: "West Ham United",
            awayTeam: "Brentford",
            league: "FA Cup",
            tvChannels: [],
            homeScore: 1,
            awayScore: 1,
            scoreStatus: "AET",
            penaltyResult: "West Ham United win 5-3 on penalties"
        )

        #expect(match.winnerSummaryText == "West Ham United win 5 - 3 on penalties")
    }

    @Test func winnerSummaryText_formatsAggregateWinners() async throws {
        let match = Match(
            date: "2026-02-25",
            time: "20:00",
            homeTeam: "Paris Saint-Germain",
            awayTeam: "Monaco",
            league: "UEFA Champions League",
            leagueSubcategory: "Knockout Round Play-offs",
            tvChannels: [],
            homeScore: 2,
            awayScore: 2,
            aggregateHomeScore: 5,
            aggregateAwayScore: 4,
            scoreStatus: "FT"
        )

        #expect(match.winnerSummaryText == "Paris Saint-Germain win 5 - 4 on aggregate")
    }

    @Test func winnerSummaryText_formatsExtraTimeWinners() async throws {
        let match = Match(
            date: "2026-03-01",
            time: "20:00",
            homeTeam: "Chelsea",
            awayTeam: "Liverpool",
            league: "FA Cup",
            tvChannels: [],
            homeScore: 2,
            awayScore: 1,
            scoreStatus: "AET"
        )

        #expect(match.winnerSummaryText == "Chelsea win 2 - 1 after extra time")
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

    @Test func matchScoreResolver_applyScores_acceptsHalfTimeAfterFirstHalfStoppageTime() async throws {
        let match = Match(
            date: formattedDate(offsetDays: 0),
            time: "17:30",
            homeTeam: "Chelsea",
            awayTeam: "Newcastle United",
            league: "Premier League",
            tvChannels: [],
            homeScore: 0,
            awayScore: 1,
            scoreStatus: "45+5"
        )

        let updated = MatchScoreResolver.applyScores(
            to: [match],
            using: [makeBbcMatch(
                homeTeam: "Chelsea",
                awayTeam: "Newcastle United",
                homeScore: 0,
                awayScore: 1,
                matchTime: "HT"
            )]
        )

        #expect(updated.count == 1)
        #expect(updated[0].scoreStatus == "HT")
    }

    @Test func fantasySquadDisplayData_matchSquadSection_splitsStartersAndBenchByTeam() async throws {
        let squad = FantasySquadDisplayData(
            gameweekID: 29,
            gameweekTitle: "GW29",
            deadlineGameweekID: nil,
            deadlineTime: nil,
            totalPoints: 0,
            hasActiveFixtures: false,
            hasStartedFixturesInGameweek: false,
            hasFixturesPlayedToday: false,
            isEstimatedScore: false,
            estimatedCurrentScore: 0,
            scoreCalculationRulesApplied: [],
            rank: nil,
            overallRank: nil,
            transfersCost: nil,
            pointsOnBench: nil,
            activeChips: [],
            goalkeepers: [
                makeFantasyPlayer(
                    elementID: 1,
                    pickPosition: 1,
                    positionType: .goalkeeper,
                    displayName: "Trafford",
                    fullName: "James Trafford",
                    teamName: "Burnley"
                )
            ],
            defenders: [],
            midfielders: [
                makeFantasyPlayer(
                    elementID: 2,
                    pickPosition: 6,
                    positionType: .midfielder,
                    displayName: "Brownhill",
                    fullName: "Josh Brownhill",
                    teamName: "Burnley"
                ),
                makeFantasyPlayer(
                    elementID: 3,
                    pickPosition: 7,
                    positionType: .midfielder,
                    displayName: "Saka",
                    fullName: "Bukayo Saka",
                    teamName: "Arsenal"
                )
            ],
            forwards: [],
            bench: [
                makeFantasyPlayer(
                    elementID: 4,
                    pickPosition: 12,
                    positionType: .goalkeeper,
                    displayName: "Foster",
                    fullName: "Mark Flekken Foster",
                    teamName: "Burnley"
                ),
                makeFantasyPlayer(
                    elementID: 5,
                    pickPosition: 13,
                    positionType: .defender,
                    displayName: "Mykolenko",
                    fullName: "Vitalii Mykolenko",
                    teamName: "Everton"
                )
            ]
        )

        let section = squad.matchSquadSection(forTeamName: "Burnley")

        #expect(section?.teamName == "Burnley")
        #expect(section?.starters.map(\.displayName) == ["Trafford", "Brownhill"])
        #expect(section?.bench.map(\.displayName) == ["Foster"])
    }

    @Test func fantasySquadBuilder_countsBenchBoostBenchPointsInCurrentScore() async throws {
        let gameweek = FantasyGameweek(
            id: 30,
            name: "Gameweek 30",
            isCurrent: true,
            isNext: false,
            finished: false,
            deadlineTime: "2026-03-14T11:00:00Z"
        )
        let bootstrap = FantasyBootstrapLookup(
            updatedAt: nil,
            elements: [
                makeFantasyBootstrapElement(id: 1, team: 1, elementType: 1, webName: "Keeper A"),
                makeFantasyBootstrapElement(id: 2, team: 1, elementType: 2, webName: "Def A"),
                makeFantasyBootstrapElement(id: 3, team: 1, elementType: 2, webName: "Def B"),
                makeFantasyBootstrapElement(id: 4, team: 1, elementType: 2, webName: "Def C"),
                makeFantasyBootstrapElement(id: 5, team: 1, elementType: 3, webName: "Mid A"),
                makeFantasyBootstrapElement(id: 6, team: 1, elementType: 3, webName: "Mid B"),
                makeFantasyBootstrapElement(id: 7, team: 1, elementType: 3, webName: "Mid C"),
                makeFantasyBootstrapElement(id: 8, team: 1, elementType: 4, webName: "Fwd A"),
                makeFantasyBootstrapElement(id: 9, team: 1, elementType: 4, webName: "Fwd B"),
                makeFantasyBootstrapElement(id: 10, team: 1, elementType: 3, webName: "Mid D"),
                makeFantasyBootstrapElement(id: 11, team: 1, elementType: 2, webName: "Def D"),
                makeFantasyBootstrapElement(id: 12, team: 2, elementType: 1, webName: "Keeper B"),
                makeFantasyBootstrapElement(id: 13, team: 2, elementType: 2, webName: "Bench Def"),
                makeFantasyBootstrapElement(id: 14, team: 2, elementType: 3, webName: "Bench Mid"),
                makeFantasyBootstrapElement(id: 15, team: 2, elementType: 4, webName: "Bench Fwd")
            ],
            teams: [
                FantasyBootstrapTeam(id: 1, name: "Arsenal", shortName: "ARS"),
                FantasyBootstrapTeam(id: 2, name: "Everton", shortName: "EVE")
            ],
            elementTypes: [
                FantasyBootstrapElementType(id: 1, singularName: "Goalkeeper", singularNameShort: "GKP"),
                FantasyBootstrapElementType(id: 2, singularName: "Defender", singularNameShort: "DEF"),
                FantasyBootstrapElementType(id: 3, singularName: "Midfielder", singularNameShort: "MID"),
                FantasyBootstrapElementType(id: 4, singularName: "Forward", singularNameShort: "FWD")
            ],
            events: [gameweek]
        )
        let picks = FantasyPicksResponse(
            picks: [
                makeFantasyPick(element: 1, position: 1, elementType: 1),
                makeFantasyPick(element: 2, position: 2, elementType: 2),
                makeFantasyPick(element: 3, position: 3, elementType: 2),
                makeFantasyPick(element: 4, position: 4, elementType: 2),
                makeFantasyPick(element: 5, position: 5, elementType: 3),
                makeFantasyPick(element: 6, position: 6, elementType: 3),
                makeFantasyPick(element: 7, position: 7, elementType: 3),
                makeFantasyPick(element: 8, position: 8, elementType: 4),
                makeFantasyPick(element: 9, position: 9, elementType: 4),
                makeFantasyPick(element: 10, position: 10, elementType: 3),
                makeFantasyPick(element: 11, position: 11, elementType: 2),
                makeFantasyPick(element: 12, position: 12, elementType: 1),
                makeFantasyPick(element: 13, position: 13, elementType: 2),
                makeFantasyPick(element: 14, position: 14, elementType: 3),
                makeFantasyPick(element: 15, position: 15, elementType: 4)
            ],
            entryHistory: FantasyEntryHistory(
                event: 30,
                points: 7,
                rank: nil,
                overallRank: nil,
                eventTransfersCost: nil,
                pointsOnBench: 11
            ),
            activeChipCodes: ["bboost"]
        )
        let liveResponse = FantasyEventLiveResponse(
            elements: [
                makeLiveElement(id: 1, points: 0),
                makeLiveElement(id: 2, points: 0),
                makeLiveElement(id: 3, points: 0),
                makeLiveElement(id: 4, points: 0),
                makeLiveElement(id: 5, points: 2),
                makeLiveElement(id: 6, points: 3),
                makeLiveElement(id: 7, points: 2),
                makeLiveElement(id: 8, points: 0),
                makeLiveElement(id: 9, points: 0),
                makeLiveElement(id: 10, points: 0),
                makeLiveElement(id: 11, points: 0),
                makeLiveElement(id: 12, points: 0),
                makeLiveElement(id: 13, points: 8),
                makeLiveElement(id: 14, points: 3),
                makeLiveElement(id: 15, points: 0)
            ]
        )
        let fixtures = [
            FantasyFixture(
                id: 101,
                event: 30,
                teamH: 1,
                teamA: 2,
                kickoffTime: "2026-03-14T15:00:00Z",
                started: true,
                finished: false,
                finishedProvisional: false
            )
        ]

        let squad = FantasySquadBuilder.build(
            gameweek: gameweek,
            picksResponse: picks,
            liveResponse: liveResponse,
            fixtures: fixtures,
            seasonFixtures: fixtures,
            bootstrap: bootstrap,
            now: Date(timeIntervalSince1970: 1_773_571_200)
        )

        #expect(squad.hasBenchBoostActive)
        #expect(squad.resolvedCurrentScore == 18)
        #expect(squad.resolvedCurrentScoreDisplay == "18*")
        #expect(squad.activeChipSummaryText == "Active chip: Bench Boost")
        #expect(
            squad.effectivePlayerContributions.contains {
                $0.elementID == 13 && $0.points == 8
            }
        )
        #expect(
            squad.effectivePlayerContributions.contains {
                $0.elementID == 14 && $0.points == 3
            }
        )
    }

    @Test func fantasySquadDisplayData_marksNonScoringChipsWithAsterisk() async throws {
        let squad = FantasySquadDisplayData(
            gameweekID: 30,
            gameweekTitle: "GW30",
            deadlineGameweekID: nil,
            deadlineTime: nil,
            totalPoints: 52,
            hasActiveFixtures: false,
            hasStartedFixturesInGameweek: true,
            hasFixturesPlayedToday: false,
            isEstimatedScore: false,
            estimatedCurrentScore: 52,
            scoreCalculationRulesApplied: [],
            rank: nil,
            overallRank: nil,
            transfersCost: nil,
            pointsOnBench: nil,
            activeChips: [FantasyChip(code: "freehit")],
            goalkeepers: [],
            defenders: [],
            midfielders: [],
            forwards: [],
            bench: []
        )

        #expect(squad.hasActiveChip)
        #expect(squad.resolvedCurrentScore == 52)
        #expect(squad.resolvedCurrentScoreDisplay == "52*")
        #expect(squad.activeChipSummaryText == "Active chip: Free Hit")
    }

    @Test func fantasySquadGameweekResolver_usesNextGameweekWhenCurrentIsFinished() async throws {
        let current = FantasyGameweek(
            id: 29,
            name: "Gameweek 29",
            isCurrent: true,
            isNext: false,
            finished: true,
            deadlineTime: "2026-03-01T11:00:00Z"
        )
        let next = FantasyGameweek(
            id: 30,
            name: "Gameweek 30",
            isCurrent: false,
            isNext: true,
            finished: false,
            deadlineTime: "2026-03-08T11:00:00Z"
        )

        let resolved = FantasySquadGameweekResolver.resolve(
            currentGameweek: current,
            nextGameweek: next
        )

        #expect(resolved.id == 30)
    }

    @Test func fantasySquadGameweekResolver_keepsCurrentGameweekWhenCurrentIsStillLive() async throws {
        let current = FantasyGameweek(
            id: 29,
            name: "Gameweek 29",
            isCurrent: true,
            isNext: false,
            finished: false,
            deadlineTime: "2026-03-01T11:00:00Z"
        )
        let next = FantasyGameweek(
            id: 30,
            name: "Gameweek 30",
            isCurrent: false,
            isNext: true,
            finished: false,
            deadlineTime: "2026-03-08T11:00:00Z"
        )

        let resolved = FantasySquadGameweekResolver.resolve(
            currentGameweek: current,
            nextGameweek: next
        )

        #expect(resolved.id == 29)
    }

    @Test func lineupPlayerInitials_handlesParticlesAndHyphenatedSurnames() async throws {
        #expect(lineupPlayerInitials("Virgil van Dijk") == "VvD")
        #expect(lineupPlayerInitials("Declan Rice") == "DR")
        #expect(lineupPlayerInitials("Micky van de Ven") == "MvdV")
        #expect(lineupPlayerInitials("Trent Alexander-Arnold") == "TAA")
    }

    @Test func lineupPlayerMarkerLabel_prefersFantasyPointsWhenAvailable() async throws {
        #expect(lineupPlayerMarkerLabel(name: "Virgil van Dijk", fantasyPoints: 12) == "12")
        #expect(lineupPlayerMarkerLabel(name: "Virgil van Dijk", fantasyPoints: nil) == "VvD")
    }

    @Test func fantasyDisplayPlayerGameweekScoreState_prefersRemainingFixtureOverMinutesPlayed() async throws {
        let player = makeFantasyPlayer(
            elementID: 1,
            pickPosition: 5,
            positionType: .midfielder,
            displayName: "Mid A",
            fullName: "Midfielder A",
            teamName: "Arsenal",
            hasAnyFixtureThisGameweek: true,
            hasUpcomingFixtureThisGameweek: true,
            hasActiveFixtureThisGameweek: false,
            minutesPlayed: 90
        )

        #expect(player.gameweekScoreState == .upcoming)
        #expect(player.hasRemainingFixtureThisGameweek)
        #expect(!player.hasFinishedScoringForGameweek)
    }

    @Test func fantasyDisplayPlayerGameweekScoreState_distinguishesCompletedAndBlankGameweeks() async throws {
        let completed = makeFantasyPlayer(
            elementID: 2,
            pickPosition: 6,
            positionType: .midfielder,
            displayName: "Mid B",
            fullName: "Midfielder B",
            teamName: "Chelsea",
            hasAnyFixtureThisGameweek: true,
            hasUpcomingFixtureThisGameweek: false,
            hasActiveFixtureThisGameweek: false,
            minutesPlayed: 12
        )
        let blank = makeFantasyPlayer(
            elementID: 3,
            pickPosition: 7,
            positionType: .forward,
            displayName: "Fwd A",
            fullName: "Forward A",
            teamName: "Liverpool",
            hasAnyFixtureThisGameweek: false,
            hasUpcomingFixtureThisGameweek: false,
            hasActiveFixtureThisGameweek: false,
            minutesPlayed: 0
        )

        #expect(completed.gameweekScoreState == .completed)
        #expect(blank.gameweekScoreState == .noFixture)
        #expect(completed.hasFinishedScoringForGameweek)
        #expect(blank.hasFinishedScoringForGameweek)
    }

    @Test func fantasyExpectedPointsSection_sumsStartersForSelectedTeamXP() async throws {
        let section = FantasyAssistantManagerResponse.ExpectedPointsSection(
            starters: [
                makeExpectedPointsPlayer(elementID: 1, pickPosition: 1, expectedPointsNextGameweek: 5.4),
                makeExpectedPointsPlayer(elementID: 2, pickPosition: 2, expectedPointsNextGameweek: 6.1)
            ],
            bench: [
                makeExpectedPointsPlayer(elementID: 12, pickPosition: 12, expectedPointsNextGameweek: 3.8)
            ]
        )

        #expect(abs(section.selectedTeamExpectedPointsNextGameweek - 11.5) < 0.001)
    }

    @Test func fantasySquadProjectedGameweekPoints_addsCurrentScoreToRemainingExpectedPoints() async throws {
        let playedStarter = makeFantasyPlayer(
            elementID: 1,
            pickPosition: 1,
            positionType: .goalkeeper,
            displayName: "Keeper",
            fullName: "Keeper",
            teamName: "Everton",
            hasAnyFixtureThisGameweek: true,
            hasUpcomingFixtureThisGameweek: false,
            hasActiveFixtureThisGameweek: false,
            minutesPlayed: 90,
            rawPoints: 6,
            appliedPoints: 6,
            displayPoints: 6
        )
        let upcomingCaptain = makeFantasyPlayer(
            elementID: 2,
            pickPosition: 2,
            positionType: .forward,
            displayName: "Captain",
            fullName: "Captain",
            teamName: "Liverpool",
            hasAnyFixtureThisGameweek: true,
            hasUpcomingFixtureThisGameweek: true,
            hasActiveFixtureThisGameweek: false,
            minutesPlayed: 0,
            multiplier: 2,
            isCaptain: true
        )
        let squad = FantasySquadDisplayData(
            gameweekID: 30,
            gameweekTitle: "GW30",
            deadlineGameweekID: nil,
            deadlineTime: nil,
            totalPoints: 26,
            hasActiveFixtures: false,
            hasStartedFixturesInGameweek: true,
            hasFixturesPlayedToday: true,
            isEstimatedScore: false,
            estimatedCurrentScore: 26,
            scoreCalculationRulesApplied: [],
            rank: nil,
            overallRank: nil,
            transfersCost: nil,
            pointsOnBench: nil,
            activeChips: [],
            goalkeepers: [playedStarter],
            defenders: [],
            midfielders: [],
            forwards: [upcomingCaptain],
            bench: []
        )
        let section = FantasyAssistantManagerResponse.ExpectedPointsSection(
            starters: [
                makeExpectedPointsPlayer(elementID: 1, pickPosition: 1, expectedPointsNextGameweek: 2.5),
                makeExpectedPointsPlayer(elementID: 2, pickPosition: 2, expectedPointsNextGameweek: 5.0)
            ],
            bench: []
        )

        #expect(abs(squad.remainingExpectedPoints(using: section) - 10.0) < 0.001)
        #expect(abs(squad.projectedGameweekPoints(using: section) - 36.0) < 0.001)
    }

    @Test func fantasyTeamLookupKeys_handleClubPrefixesAndSuffixes() async throws {
        seedTeamIdentityStore()
        #expect(fantasyTeamLookupKeys("AFC Bournemouth").contains("bournemouth"))
        #expect(fantasyTeamLookupKeys("Bournemouth FC").contains("bournemouth"))
    }

    @Test func fantasyTeamLookupKeys_handleFantasyShortTeamAliases() async throws {
        seedTeamIdentityStore()
        #expect(fantasyTeamLookupKeys("Man City").contains("manchester city"))
        #expect(fantasyTeamLookupKeys("Manchester City").contains("man city"))
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

    private func formattedDate(offsetDays: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        let date = Calendar.current.date(byAdding: .day, value: offsetDays, to: Date())!
        return formatter.string(from: date)
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

    private func makeBbcMatch(
        homeTeam: String,
        awayTeam: String,
        homeScore: Int,
        awayScore: Int,
        matchTime: String
    ) -> BbcMatch {
        let payload: [String: Any?] = [
            "home_team": homeTeam,
            "away_team": awayTeam,
            "home_score": homeScore,
            "away_score": awayScore,
            "aggregate_home_score": nil,
            "aggregate_away_score": nil,
            "match_time": matchTime,
            "details_url": nil,
            "home_goal_scorers": [],
            "away_goal_scorers": [],
            "home_assists": [],
            "away_assists": [],
            "home_red_cards": [],
            "away_red_cards": [],
        ]

        let data = try! JSONSerialization.data(withJSONObject: payload.compactMapValues { $0 })
        return try! JSONDecoder().decode(BbcMatch.self, from: data)
    }

    private func makeFantasyPlayer(
        elementID: Int,
        pickPosition: Int,
        positionType: FantasyPositionType,
        displayName: String,
        fullName: String,
        teamName: String,
        hasAnyFixtureThisGameweek: Bool = true,
        hasUpcomingFixtureThisGameweek: Bool = true,
        hasActiveFixtureThisGameweek: Bool = false,
        minutesPlayed: Int = 0,
        rawPoints: Int = 0,
        appliedPoints: Int = 0,
        displayPoints: Int = 0,
        multiplier: Int = 1,
        isCaptain: Bool = false
    ) -> FantasyDisplayPlayer {
        FantasyDisplayPlayer(
            elementID: elementID,
            pickPosition: pickPosition,
            positionType: positionType,
            displayName: displayName,
            fullName: fullName,
            teamName: teamName,
            nowCostMillions: 5.0,
            rawPoints: rawPoints,
            appliedPoints: appliedPoints,
            displayPoints: displayPoints,
            multiplier: multiplier,
            isCaptain: isCaptain,
            isViceCaptain: false,
            isPlayingNow: false,
            isUnavailable: false,
            isDefinitelyUnavailable: false,
            hasAnyFixtureThisGameweek: hasAnyFixtureThisGameweek,
            hasUpcomingFixtureThisGameweek: hasUpcomingFixtureThisGameweek,
            hasActiveFixtureThisGameweek: hasActiveFixtureThisGameweek,
            hasFutureAvailabilityIssue: false,
            futureAvailabilityIssueGameweek: nil,
            minutesPlayed: minutesPlayed,
            upcomingOpponentDisplay: nil,
            goalsScored: 0,
            assists: 0,
            yellowCards: 0,
            redCards: 0
        )
    }

    private func makeExpectedPointsPlayer(
        elementID: Int,
        pickPosition: Int,
        expectedPointsNextGameweek: Double
    ) -> FantasyAssistantManagerResponse.ExpectedPointsPlayer {
        FantasyAssistantManagerResponse.ExpectedPointsPlayer(
            elementID: elementID,
            pickPosition: pickPosition,
            isStarter: pickPosition <= 11,
            playerName: "Player \(elementID)",
            teamName: "Arsenal",
            teamShortName: "ARS",
            opponentTeamName: "Chelsea",
            opponentLabel: "CHE (H)",
            difficulty: 3,
            expectedPointsNextGameweek: expectedPointsNextGameweek,
            isBlank: false
        )
    }

    private func makeFantasyBootstrapElement(
        id: Int,
        team: Int,
        elementType: Int,
        webName: String
    ) -> FantasyBootstrapElement {
        FantasyBootstrapElement(
            id: id,
            webName: webName,
            firstName: webName,
            secondName: "Test",
            team: team,
            elementType: elementType,
            photo: nil,
            status: "a",
            news: nil,
            nowCost: 50,
            form: "0.0",
            pointsPerGame: "0.0",
            eventPoints: 0,
            totalPoints: 0,
            bonus: 0,
            ictIndex: "0.0",
            selectedByPercent: "0.0",
            chanceOfPlayingThisRound: 100,
            chanceOfPlayingNextRound: 100
        )
    }

    private func makeFantasyPick(element: Int, position: Int, elementType: Int) -> FantasyPick {
        FantasyPick(
            element: element,
            position: position,
            multiplier: 1,
            isCaptain: false,
            isViceCaptain: false,
            elementType: elementType
        )
    }

    private func makeLiveElement(id: Int, points: Int) -> FantasyLiveElement {
        FantasyLiveElement(
            id: id,
            stats: FantasyLiveStats(
                totalPoints: points,
                minutes: points > 0 ? 90 : 0,
                goalsScored: 0,
                assists: 0,
                yellowCards: 0,
                redCards: 0
            )
        )
    }

    private func seedTeamIdentityStore() {
        TeamIdentityStore.shared.update(
            from: TeamColorsCatalogResponse(
                updatedAt: "2026-03-14T00:00:00Z",
                defaultStyle: TeamColorStyleResponse(
                    primary: "#111111",
                    secondary: "#FFFFFF",
                    scheme: "default-dark"
                ),
                teams: [
                    TeamColorRecordResponse(
                        name: "Bournemouth",
                        aliases: ["AFC Bournemouth", "BOU"],
                        primary: "#DA291C",
                        secondary: "#000000",
                        scheme: "red-black"
                    ),
                    TeamColorRecordResponse(
                        name: "Manchester City",
                        aliases: ["Man City", "MCI"],
                        primary: "#6CABDD",
                        secondary: "#FFFFFF",
                        scheme: "sky-white"
                    )
                ],
                identityGroups: [
                    TeamIdentityGroupResponse(name: "Bournemouth", aliases: ["AFC Bournemouth", "BOU"]),
                    TeamIdentityGroupResponse(name: "Manchester City", aliases: ["Man City", "MCI"])
                ]
            )
        )
    }

}
