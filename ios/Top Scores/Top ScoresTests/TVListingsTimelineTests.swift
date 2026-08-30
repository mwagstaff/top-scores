import Foundation
import Testing
@testable import Top_Scores

struct TVListingsTimelineTests {
    @Test func availabilityIncludesTodayAndFutureButNotPast() throws {
        let calendar = testCalendar
        let now = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 29, hour: 20)
        ))

        #expect(TVListingsTimeline.isAvailable(
            for: "2026-08-29",
            now: now,
            calendar: calendar
        ))
        #expect(TVListingsTimeline.isAvailable(
            for: "2026-08-30",
            now: now,
            calendar: calendar
        ))
        #expect(!TVListingsTimeline.isAvailable(
            for: "2026-08-28",
            now: now,
            calendar: calendar
        ))
        #expect(!TVListingsTimeline.isAvailable(
            for: nil,
            now: now,
            calendar: calendar
        ))
    }

    @Test func matchesUseStrictDateAllCompetitionsAndUKChannels() {
        let matches = [
            makeMatch(
                date: "2026-08-29",
                time: "21:00",
                home: "Chelsea",
                league: "Premier League",
                channels: [
                    TvChannel(name: "Sky Sports", countryCode: "GB"),
                    TvChannel(name: "NBC", countryCode: "US"),
                ]
            ),
            makeMatch(
                date: "2026-08-29",
                time: "20:00",
                home: "Barcelona",
                league: "La Liga",
                channels: [TvChannel(name: "LaLiga TV", countryCode: "GB")]
            ),
            makeMatch(
                date: "2026-08-29",
                time: "19:00",
                home: "Miami",
                league: "MLS",
                channels: [TvChannel(name: "Apple TV", countryCode: "US")]
            ),
            makeMatch(
                date: "2026-08-29",
                time: "18:00",
                home: "Legacy BBC",
                league: "FA Cup",
                channels: [TvChannel(name: "BBC One")]
            ),
            makeMatch(
                date: "2026-08-30",
                time: "00:30",
                home: "Tomorrow FC",
                league: "Championship",
                channels: [TvChannel(name: "Sky Sports", countryCode: "GB")]
            ),
        ]

        let listings = TVListingsTimeline.matches(
            for: "2026-08-29",
            from: matches
        )

        #expect(listings.map(\.homeTeam) == ["Barcelona", "Chelsea"])
        #expect(Set(listings.map(\.league)) == ["Premier League", "La Liga"])
        #expect(listings.last?.tvChannels.map(\.name) == ["Sky Sports"])
    }

    @Test func matchesSortEqualKickoffsDeterministically() {
        let matches = [
            makeMatch(
                date: "2026-08-29",
                time: "20:00",
                home: "Zulu",
                league: "Premier League"
            ),
            makeMatch(
                date: "2026-08-29",
                time: "20:00",
                home: "Alpha",
                league: "Championship"
            ),
        ]

        let listings = TVListingsTimeline.matches(
            for: "2026-08-29",
            from: matches
        )

        #expect(listings.map(\.league) == ["Championship", "Premier League"])
    }

    @Test func currentTimeMarkerFallsBeforeNextKickoff() throws {
        let matches = [
            makeMatch(date: "2026-08-29", time: "19:00", home: "First"),
            makeMatch(date: "2026-08-29", time: "21:00", home: "Second"),
            makeMatch(date: "2026-08-29", time: "22:30", home: "Third"),
        ]
        let firstKickoff = try #require(matches[0].dateTime)
        let betweenFirstAndSecond = firstKickoff.addingTimeInterval(60 * 60)

        #expect(TVListingsTimeline.currentTimeInsertionIndex(
            in: matches,
            now: firstKickoff.addingTimeInterval(-60)
        ) == 0)
        #expect(TVListingsTimeline.currentTimeInsertionIndex(
            in: matches,
            now: betweenFirstAndSecond
        ) == 1)
        #expect(TVListingsTimeline.currentTimeInsertionIndex(
            in: matches,
            now: firstKickoff.addingTimeInterval(5 * 60 * 60)
        ) == matches.endIndex)
    }

    @Test func currentTimeMarkerFallsBeforeFirstLiveMatch() throws {
        let matches = [
            makeMatch(date: "2026-08-29", time: "12:00", home: "Finished", scoreStatus: "FT"),
            makeMatch(date: "2026-08-29", time: "14:00", home: "First live", scoreStatus: "39"),
            makeMatch(date: "2026-08-29", time: "14:00", home: "Second live", scoreStatus: "39"),
            makeMatch(date: "2026-08-29", time: "16:00", home: "Later"),
        ]
        let liveKickoff = try #require(matches[1].dateTime)

        #expect(TVListingsTimeline.currentTimeInsertionIndex(
            in: matches,
            now: liveKickoff.addingTimeInterval(39 * 60)
        ) == 1)
    }

    @Test func currentTimeStatusShowsNextMatchWhenNothingIsLive() throws {
        let matches = [
            makeMatch(date: "2026-08-29", time: "09:00", home: "Finished"),
            makeMatch(date: "2026-08-29", time: "12:00", home: "Next"),
            makeMatch(date: "2026-08-29", time: "14:00", home: "Later"),
        ]
        let nextKickoff = try #require(matches[1].dateTime)
        let now = nextKickoff.addingTimeInterval(-60 * 60)

        #expect(TVListingsTimeline.currentTimeStatus(in: matches, now: now) == .nextMatch(
            at: nextKickoff
        ))
    }

    @Test func currentTimeStatusPrefersLiveMatchOverNextKickoff() throws {
        let matches = [
            makeMatch(
                date: "2026-08-29",
                time: "10:00",
                home: "Live",
                scoreStatus: "38"
            ),
            makeMatch(date: "2026-08-29", time: "12:00", home: "Next"),
        ]
        let liveKickoff = try #require(matches[0].dateTime)
        let now = liveKickoff.addingTimeInterval(38 * 60)

        #expect(TVListingsTimeline.currentTimeStatus(in: matches, now: now) == .onNow)
    }

    @Test func currentTimeStatusHandlesEndOfDay() throws {
        let matches = [
            makeMatch(date: "2026-08-29", time: "20:00", home: "Last"),
        ]
        let kickoff = try #require(matches[0].dateTime)

        #expect(TVListingsTimeline.currentTimeStatus(
            in: matches,
            now: kickoff.addingTimeInterval(3 * 60 * 60)
        ) == .noMoreMatches)
    }

    @Test func matchDecodesWatchabilityIndexBreakdown() throws {
        let json = """
        {
          "date": "2026-08-29",
          "time": "20:00",
          "league": "Premier League",
          "home_team": "Arsenal",
          "away_team": "Liverpool",
          "tv_channels": [],
          "watchability_index": {
            "score": 91,
            "tier": "must_watch",
            "stars": 5,
            "confidence": 0.94,
            "model_version": "v1",
            "components": [
              {
                "key": "competition",
                "label": "Competition",
                "score": 100,
                "weight": 50,
                "contribution": 50,
                "detail": "Premier League carries a 100/100 competition weighting."
              }
            ]
          }
        }
        """

        let match = try JSONDecoder().decode(Match.self, from: Data(json.utf8))

        #expect(match.watchabilityIndex?.score == 91)
        #expect(match.watchabilityIndex?.tier == "must_watch")
        #expect(match.watchabilityIndex?.components.first?.key == "competition")
    }

    private var testCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeMatch(
        date: String,
        time: String,
        home: String,
        league: String = "Premier League",
        scoreStatus: String? = nil,
        channels: [TvChannel] = [TvChannel(name: "Sky Sports", countryCode: "GB")]
    ) -> Match {
        Match(
            date: date,
            time: time,
            homeTeam: home,
            awayTeam: "Away",
            league: league,
            tvChannels: channels,
            scoreStatus: scoreStatus
        )
    }
}
