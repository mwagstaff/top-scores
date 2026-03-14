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
        teamName: String
    ) -> FantasyDisplayPlayer {
        FantasyDisplayPlayer(
            elementID: elementID,
            pickPosition: pickPosition,
            positionType: positionType,
            displayName: displayName,
            fullName: fullName,
            teamName: teamName,
            rawPoints: 0,
            appliedPoints: 0,
            displayPoints: 0,
            multiplier: 1,
            isCaptain: false,
            isViceCaptain: false,
            isPlayingNow: false,
            isUnavailable: false,
            isDefinitelyUnavailable: false,
            hasAnyFixtureThisGameweek: true,
            hasUpcomingFixtureThisGameweek: true,
            hasActiveFixtureThisGameweek: false,
            hasFutureAvailabilityIssue: false,
            futureAvailabilityIssueGameweek: nil,
            minutesPlayed: 0,
            upcomingOpponentDisplay: nil,
            goalsScored: 0,
            assists: 0,
            yellowCards: 0,
            redCards: 0
        )
    }

}
