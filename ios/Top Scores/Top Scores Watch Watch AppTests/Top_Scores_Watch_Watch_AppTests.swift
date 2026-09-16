//
//  Top_Scores_Watch_Watch_AppTests.swift
//  Top Scores Watch Watch AppTests
//
//  Created by Mike Wagstaff on 12/02/2026.
//

import Foundation
import Testing
import UIKit
@testable import Top_Scores_Watch_Watch_App

struct Top_Scores_Watch_Watch_AppTests {
    @Test func competitionsAreGroupedAndSortedByHighestWeight() throws {
        let now = try #require(WatchMatchDateParser.shared.parse(date: "2026-09-14", time: "21:00"))
        let matches = try [
            makeMatch(id: "serie-a-1", league: "Serie A", weight: 45, time: "17:30"),
            makeMatch(id: "premier-league-1", league: "Premier League", weight: 100, time: "20:00"),
            makeMatch(id: "serie-a-2", league: "Serie A", weight: 45, time: "19:45"),
            makeMatch(id: "la-liga-1", league: "La Liga", weight: 50, time: "20:00")
        ]

        let competitions = WatchMatchCollections.todayCompetitions(from: matches, now: now)

        #expect(competitions.map(\.name) == ["Premier League", "La Liga", "Serie A"])
        #expect(competitions.map(\.matches.count) == [1, 1, 2])
    }

    @Test func fixtureDatesContainUpcomingMatchesInChronologicalOrder() throws {
        let now = try #require(WatchMatchDateParser.shared.parse(date: "2026-09-14", time: "12:00"))
        let matches = try [
            makeMatch(id: "today", league: "Premier League", weight: 100, date: "2026-09-14", time: "20:00"),
            makeMatch(id: "tomorrow-late", league: "Serie A", weight: 45, date: "2026-09-15", time: "20:00"),
            makeMatch(id: "tomorrow-early", league: "Premier League", weight: 100, date: "2026-09-15", time: "18:00"),
            makeMatch(id: "later", league: "La Liga", weight: 50, date: "2026-09-18", time: "19:00"),
            makeMatch(id: "completed-future", league: "Serie A", weight: 45, date: "2026-09-16", time: "19:00", scoreStatus: "FT")
        ]

        let days = WatchMatchCollections.fixtureDays(from: matches, now: now)

        #expect(days.map(\.id) == ["2026-09-15", "2026-09-18"])
        #expect(days.map(\.matches.count) == [2, 1])
        #expect(days.first?.matches.map(\.matchDetailsIDValue) == ["tomorrow-early", "tomorrow-late"])
    }

    @Test func resultDatesContainFinishedMatchesInReverseChronologicalOrder() throws {
        let now = try #require(WatchMatchDateParser.shared.parse(date: "2026-09-14", time: "23:00"))
        let matches = try [
            makeMatch(id: "today-result", league: "Premier League", weight: 100, date: "2026-09-14", time: "20:00", scoreStatus: "FT"),
            makeMatch(id: "older-result", league: "Serie A", weight: 45, date: "2026-09-11", time: "19:00", scoreStatus: "FT"),
            makeMatch(id: "not-a-result", league: "La Liga", weight: 50, date: "2026-09-13", time: "19:00"),
            makeMatch(id: "future-result", league: "Serie A", weight: 45, date: "2026-09-15", time: "19:00", scoreStatus: "FT")
        ]

        let days = WatchMatchCollections.resultDays(from: matches, now: now)

        #expect(days.map(\.id) == ["2026-09-14", "2026-09-11"])
        #expect(days.map(\.matches.count) == [1, 1])
    }

    @Test func selectedDateCompetitionsUseHomeScreenRanking() throws {
        let matches = try [
            makeMatch(id: "serie-a", league: "Serie A", weight: 45, date: "2026-09-16", time: "17:30"),
            makeMatch(id: "premier-league", league: "Premier League", weight: 100, date: "2026-09-16", time: "20:00"),
            makeMatch(id: "la-liga", league: "La Liga", weight: 50, date: "2026-09-16", time: "19:00")
        ]

        let competitions = WatchMatchCollections.competitions(from: matches)

        #expect(competitions.map(\.name) == ["Premier League", "La Liga", "Serie A"])
    }

    @Test func dateLabelsAndNavigationAreChronological() throws {
        let now = try #require(WatchMatchDateParser.shared.parse(date: "2026-09-15", time: "12:00"))
        let days = [
            WatchMatchDay(id: "2026-09-16", displayDate: "fallback", matches: []),
            WatchMatchDay(id: "2026-09-15", displayDate: "fallback", matches: []),
            WatchMatchDay(id: "2026-09-14", displayDate: "fallback", matches: []),
            WatchMatchDay(id: "2026-09-12", displayDate: "fallback", matches: [])
        ]

        #expect(WatchMatchDayLabel.text(for: days[0], now: now) == "Tomorrow")
        #expect(WatchMatchDayLabel.text(for: days[1], now: now) == "Today")
        #expect(WatchMatchDayLabel.text(for: days[2], now: now) == "Yesterday")
        #expect(WatchMatchDayLabel.text(for: days[3], now: now) == "Sat 12 Sep")
        #expect(WatchMatchDayNavigation.previousDay(to: days[1], in: days)?.id == "2026-09-14")
        #expect(WatchMatchDayNavigation.nextDay(to: days[1], in: days)?.id == "2026-09-16")
    }

    @Test func latestSummaryMovesStaleUpcomingMatchIntoPlayedToday() throws {
        let now = try #require(WatchMatchDateParser.shared.parse(date: "2026-09-14", time: "21:00"))
        let stale = try makeMatch(
            id: "209570",
            league: "Premier League",
            weight: 100,
            time: "20:00"
        )
        let latest = try makeMatch(
            id: "209570",
            league: "Premier League",
            weight: 100,
            time: "20:00",
            homeScore: 4,
            awayScore: 1,
            scoreStatus: "FT"
        )

        let refreshed = WatchMatchSummaryMerger.merging(source: [stale], latest: [latest])
        let sections = WatchMatchCollections.todaySections(from: refreshed, now: now)

        #expect(refreshed.first?.scoreLine == "4-1")
        #expect(sections.map(\.title) == ["Played Today"])
    }

    @Test func todaySectionsKeepMatchesWithAnUnresolvedStatusAfterKickoff() throws {
        let now = try #require(WatchMatchDateParser.shared.parse(date: "2026-09-14", time: "21:00"))
        let match = try makeMatch(
            id: "championship",
            league: "Championship",
            weight: 60,
            time: "20:00"
        )

        let sections = WatchMatchCollections.todaySections(from: [match], now: now)

        #expect(sections.map(\.title) == ["Today"])
        #expect(sections.first?.matches.map(\.matchDetailsIDValue) == ["championship"])
    }

    @Test func liveRefreshPreservesPhoneResolvedTeamShortNames() throws {
        let synced = try makeMatch(
            id: "man-utd-synced",
            league: "Premier League",
            weight: 100,
            time: "20:00",
            homeTeam: "Manchester United",
            homeShortName: "Man Utd"
        )
        let latest = try makeMatch(
            id: "man-utd-synced",
            league: "Premier League",
            weight: 100,
            time: "20:00",
            homeTeam: "Manchester United",
            homeShortName: "Manchester United",
            homeScore: 1,
            awayScore: 0,
            scoreStatus: "32'"
        )

        let refreshed = synced.mergingLatestSummary(latest)

        #expect(refreshed.displayHomeTeam == "Man Utd")
    }

    @Test func bundledPhoneCatalogResolvesShortNamesFromExistingWatchPayloads() throws {
        let match = try makeMatch(
            id: "efl-cup",
            league: "EFL Cup",
            weight: 80,
            time: "20:00",
            homeTeam: "Manchester United",
            awayTeam: "Brighton & Hove Albion",
            homeShortName: "Manchester United",
            awayShortName: "Brighton & Hove Albion"
        )

        #expect(match.displayHomeTeam == "Man Utd")
        #expect(match.displayAwayTeam == "Brighton")
    }

    @Test func liveMinuteStatusesAreRecognizedWithoutRegularExpressions() throws {
        let regularTime = try makeMatch(
            id: "regular-time",
            league: "Premier League",
            weight: 100,
            time: "20:00",
            scoreStatus: "45+6'"
        )
        let extraTime = try makeMatch(
            id: "extra-time",
            league: "FA Cup",
            weight: 80,
            time: "20:00",
            scoreStatus: "ET 105+1'"
        )
        let finished = try makeMatch(
            id: "finished",
            league: "Premier League",
            weight: 100,
            time: "20:00",
            scoreStatus: "FT"
        )

        #expect(regularTime.isInProgress)
        #expect(extraTime.isInProgress)
        #expect(!finished.isInProgress)
    }

    @Test func directMatchListChannelObjectsDecodeToNames() throws {
        let object: [String: Any] = [
            "date": "2026-09-14",
            "time": "20:00",
            "home_team": "Leeds United",
            "away_team": "Newcastle United",
            "league": "Premier League",
            "match_details_id": "209570",
            "tv_channels": [
                ["name": "Sky Sports Main Event", "country": "United Kingdom"],
                ["name": "Sky Sports Premier League", "country": "United Kingdom"]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: object)
        let match = try JSONDecoder().decode(WatchMatch.self, from: data)

        #expect(match.tvChannels == ["Sky Sports Main Event", "Sky Sports Premier League"])
    }

    @Test func featuredMatchUsesClubEloQualityBeforeKickoffTime() throws {
        let now = try #require(WatchMatchDateParser.shared.parse(date: "2026-09-14", time: "23:22"))
        let matches = try [
            makeMatch(id: "como-parma", league: "Serie A", weight: 45, time: "17:30", homeScore: 2, awayScore: 1, scoreStatus: "FT", teamQuality: 46, watchability: 46),
            makeMatch(id: "inter-udinese", league: "Serie A", weight: 45, time: "19:45", homeScore: 5, awayScore: 3, scoreStatus: "FT", teamQuality: 58, watchability: 45),
            makeMatch(id: "leeds-newcastle", league: "Premier League", weight: 100, time: "20:00", homeScore: 4, awayScore: 1, scoreStatus: "FT", teamQuality: 67, watchability: 76)
        ]

        let featured = WatchFeaturedMatchSelector.select(from: matches, at: now)

        #expect(featured?.matchDetailsIDValue == "leeds-newcastle")
    }

    @Test func matchEventsAreNewestFirstIncludingAddedTime() throws {
        let object: [String: Any] = [
            "date": "2026-09-14",
            "time": "20:00",
            "home_team": "Leeds United",
            "away_team": "Newcastle United",
            "league": "Premier League",
            "home_goal_scorers": [
                ["player": "First Scorer", "goal_times": ["45+6"], "own_goal_times": [], "disallowed_goal_times": []],
                ["player": "Late Scorer", "goal_times": ["90+2"], "own_goal_times": [], "disallowed_goal_times": []]
            ],
            "away_yellow_cards": [
                ["player": "Booked Player", "yellow_card_times": ["67"]]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let match = try JSONDecoder().decode(WatchMatch.self, from: data)

        let events = WatchMatchEventEntry.newestFirstEntries(for: match)

        #expect(events.map(\.sortMinute) == [9002, 6700, 4506])
    }

    @Test func watchPayloadDecodesSyncedFantasyPlayers() throws {
        let json = """
        {
          "snapshot": {
            "selectedLeagues": [], "selectedChannels": [],
            "competitionFilterEnabled": true, "channelFilterEnabled": true,
            "englishPremierLeagueTeamsOnly": false,
            "apiBaseURL": "https://example.test/api/v1",
            "refreshIntervalMinutes": 10, "showAllMatches": true
          },
          "matches": [], "unfilteredMatches": [],
          "fantasy": {
            "gameweekTitle": "Gameweek 4",
            "players": [{
              "elementID": 7, "displayName": "Player",
              "teamName": "Leeds", "points": 8,
              "isCaptain": true, "isViceCaptain": false, "isStarter": true
            }]
          },
          "generatedAt": "2026-09-14T22:22:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let payload = try decoder.decode(WatchSharedMatchesPayload.self, from: Data(json.utf8))

        #expect(payload.fantasy?.gameweekTitle == "Gameweek 4")
        #expect(payload.fantasy?.players.first?.points == 8)
    }

    @Test func fantasyMatchDetailsAreLimitedToPremierLeagueFixtures() throws {
        let premierLeagueMatch = try makeMatch(
            id: "ipswich-arsenal-league",
            league: " Premier League ",
            weight: 100,
            time: "15:00"
        )
        let cupMatch = try makeMatch(
            id: "ipswich-arsenal-cup",
            league: "FA Cup",
            weight: 80,
            time: "15:00"
        )

        #expect(WatchFantasyMatchRules.isEligible(premierLeagueMatch))
        #expect(!WatchFantasyMatchRules.isEligible(cupMatch))
    }

    @Test func primaryBroadcastKeepsApiOrderAndUsesBrandedAsset() throws {
        let primary = try #require(
            WatchTvLogoResolver.shared.primaryResolvedLogo(
                for: ["Sky Sports Main Event", "Sky Sports Premier League"]
            )
        )

        #expect(primary.channel == "Sky Sports Main Event")
    }

    @Test func wideCompetitionLogosUseCompactSquareWatchMarks() throws {
        let scottishPremiership = try #require(
            WatchCompetitionLogoResolver.image(for: "Scottish Premiership")
        )
        let nationalLeague = try #require(
            WatchCompetitionLogoResolver.image(for: "National League")
        )

        #expect(scottishPremiership.size == CGSize(width: 48, height: 48))
        #expect(nationalLeague.size == CGSize(width: 48, height: 48))
    }

    @Test func tottenhamCrestResolvesByBSDIDInsteadOfTheFallback() throws {
        let crest = try #require(
            WatchTeamLogoResolver.shared.image(
                for: "Renamed club",
                teamId: "9",
                alternateNames: ["NEW"]
            )
        )
        let expected = try #require(UIImage(named: "Tottenham"))
        let fallback = try #require(UIImage(named: "_noTeamLogo 1"))

        #expect(crest.pngData() == expected.pngData())
        #expect(crest.pngData() != fallback.pngData())
    }

    @Test func bsdIDTakesPrecedenceOverAConflictingTeamName() throws {
        let crest = try #require(
            WatchTeamLogoResolver.shared.image(
                for: "Manchester City",
                teamId: "17"
            )
        )
        let expected = try #require(UIImage(named: "Man United"))
        let wrongTeam = try #require(UIImage(named: "Man City"))

        #expect(crest.pngData() == expected.pngData())
        #expect(crest.pngData() != wrongTeam.pngData())
    }

    private func makeMatch(
        id: String,
        league: String,
        weight: Double,
        date: String = "2026-09-14",
        time: String,
        homeTeam: String? = nil,
        awayTeam: String? = nil,
        homeShortName: String? = nil,
        awayShortName: String? = nil,
        homeScore: Int? = nil,
        awayScore: Int? = nil,
        scoreStatus: String? = nil,
        teamQuality: Int? = nil,
        watchability: Int? = nil
    ) throws -> WatchMatch {
        var object: [String: Any] = [
            "date": date,
            "time": time,
            "home_team": homeTeam ?? "Home \(id)",
            "away_team": awayTeam ?? "Away \(id)",
            "league": league,
            "competition_weight": weight,
            "match_details_id": id
        ]
        if let homeShortName { object["home_short_name"] = homeShortName }
        if let awayShortName { object["away_short_name"] = awayShortName }
        if let homeScore { object["home_score"] = homeScore }
        if let awayScore { object["away_score"] = awayScore }
        if let scoreStatus { object["score_status"] = scoreStatus }
        if let watchability {
            object["watchability_index"] = [
                "score": watchability,
                "components": teamQuality.map {
                    [["key": "team_quality", "score": $0]]
                } ?? []
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(WatchMatch.self, from: data)
    }
}
