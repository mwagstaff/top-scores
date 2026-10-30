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

    @Test func ratingThresholdsOverrideInconsistentCachedStarsAndLabels() {
        let cases = [(0, 1), (29, 1), (30, 2), (54, 2), (55, 3), (69, 3), (70, 4), (84, 4), (85, 5), (100, 5)]
        let labels = ["For the diehards", "Moderate", "Good watch", "Highly watchable", "Must watch"]
        for (score, stars) in cases {
            let index = MatchWatchabilityIndex(score: score, tier: "moderate", stars: 0, confidence: 0.64, modelVersion: "v4", components: [])
            #expect(index.ratingStars == stars)
            #expect(index.ratingTitle == labels[stars - 1])
        }
    }

    @Test func minimumRatingFiltersBeforeTimelineAndKeepsUnratedOnlyInAllMatches() {
        let rated = [54, 55, 70, 85].map { score in
            Match(date: "2026-10-27", time: "20:00", homeTeam: "Team \(score)", awayTeam: "Away", league: "Premier League",
                  watchabilityIndex: MatchWatchabilityIndex(score: score, tier: "moderate", stars: 0, confidence: 0.64, modelVersion: "v4", components: []),
                  tvChannels: [TvChannel(name: "Sky Sports", countryCode: "GB")])
        }
        let matches = rated + [makeMatch(date: "2026-10-27", time: "19:00", home: "Unrated")]
        #expect(TVListingsTimeline.matches(for: "2026-10-27", from: matches).count == 5)
        #expect(TVListingsTimeline.matches(for: "2026-10-27", from: matches, minimumStars: 1).count == 4)
        #expect(TVListingsTimeline.matches(for: "2026-10-27", from: matches, minimumStars: 3).map(\.homeTeam) == ["Team 55", "Team 70", "Team 85"])
        #expect(TVListingsTimeline.matches(for: "2026-10-27", from: matches, minimumStars: 5).map(\.homeTeam) == ["Team 85"])
        #expect(TVListingsTimeline.matches(for: "2026-10-28", from: matches, minimumStars: 5).isEmpty)
    }

    @Test func emptyRatingSuggestionChoosesHighestAvailableRatingAndExactCount() {
        let rated = [30, 54, 29].map { score in
            Match(date: "2026-10-27", time: "20:00", homeTeam: "Team \(score)", awayTeam: "Away", league: "Premier League",
                  watchabilityIndex: MatchWatchabilityIndex(score: score, tier: "moderate", stars: 0, confidence: 0.64, modelVersion: "v4", components: []),
                  tvChannels: [TvChannel(name: "Sky Sports", countryCode: "GB")])
        }
        let suggestion = TVListingsTimeline.lowerRatingSuggestion(in: rated, minimumStars: 3)
        #expect(suggestion == .init(minimumStars: 2, matchCount: 2))
        #expect(suggestion?.actionTitle == "Tap here to lower the rating and see 2 matches rated ‘Moderate’.")
        #expect(TVListingsTimeline.lowerRatingSuggestion(in: rated, minimumStars: 5) == suggestion)
        #expect(TVListingsTimeline.lowerRatingSuggestion(in: rated, minimumStars: 2) == nil)
        #expect(TVListingsTimeline.matches(for: "2026-10-27", from: rated, minimumStars: suggestion!.minimumStars).count == suggestion?.matchCount)
    }

    @Test func emptyRatingSuggestionDistinguishesNoListingsFromUnratedListings() {
        #expect(TVListingsTimeline.lowerRatingSuggestion(in: [], minimumStars: 3) == nil)
        let unrated = [makeMatch(date: "2026-10-27", time: "19:00", home: "Unrated")]
        let suggestion = TVListingsTimeline.lowerRatingSuggestion(in: unrated, minimumStars: 3)
        #expect(suggestion == .init(minimumStars: 0, matchCount: 1))
        #expect(suggestion?.actionTitle == "Tap here to show all matches and see 1 unrated match.")
        #expect(TVListingsTimeline.lowerRatingSuggestion(in: unrated, minimumStars: 0) == nil)
        let otherDate = TVListingsTimeline.matches(for: "2026-10-28", from: unrated)
        #expect(TVListingsTimeline.lowerRatingSuggestion(in: otherDate, minimumStars: 3) == nil)
    }

    @Test func carouselDisablesOnlyPreparedDatesWithoutMatchingRatings() {
        let unrated = makeMatch(date: "2026-10-27", time: "19:00", home: "Unrated")
        let rated = Match(date: "2026-10-28", time: "20:00", homeTeam: "Rated", awayTeam: "Away", league: "Premier League",
                          watchabilityIndex: MatchWatchabilityIndex(score: 70, tier: "high", stars: 4, confidence: 1, modelVersion: "v5", components: []),
                          tvChannels: [TvChannel(name: "Sky Sports", countryCode: "GB")])
        let pages = ["2026-10-27": [unrated], "2026-10-28": [rated], "2026-10-29": []]
        #expect(TVListingsTimeline.disabledDateKeys(in: pages, minimumStars: 0) == ["2026-10-29"])
        #expect(TVListingsTimeline.disabledDateKeys(in: pages, minimumStars: 3) == ["2026-10-27", "2026-10-29"])
        #expect(TVListingsTimeline.disabledDateKeys(in: pages, minimumStars: 5) == Set(pages.keys))
        #expect(!TVListingsTimeline.disabledDateKeys(in: pages, minimumStars: 5).contains("2026-10-30"))
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
