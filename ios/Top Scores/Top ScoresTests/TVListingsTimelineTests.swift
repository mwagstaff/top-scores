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

    @Test func matchesUseStrictDateAllCompetitionsAndRequestedRegion() {
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
                date: "2026-08-30",
                time: "00:30",
                home: "Tomorrow FC",
                league: "Championship",
                channels: [TvChannel(name: "Sky Sports", countryCode: "GB")]
            ),
        ]

        let listings = TVListingsTimeline.matches(
            for: "2026-08-29",
            from: matches,
            regionCode: "GB"
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
            from: matches,
            regionCode: "GB"
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
        channels: [TvChannel] = [TvChannel(name: "Sky Sports", countryCode: "GB")]
    ) -> Match {
        Match(
            date: date,
            time: time,
            homeTeam: home,
            awayTeam: "Away",
            league: league,
            tvChannels: channels
        )
    }
}
