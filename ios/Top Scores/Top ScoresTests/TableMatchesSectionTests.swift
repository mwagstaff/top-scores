import Foundation
import Testing
@testable import Top_Scores

struct TableMatchesSectionTests {
    @Test func liveMatchesTakePriorityOverResultsAndFixtures() {
        let section = TableMatchesSection.resolve(from: [
            match(date: "2020-08-20", home: "A", away: "B", round: 1, status: "FT"),
            match(date: "2026-08-29", home: "C", away: "D", round: 2, status: "45"),
            match(date: "2099-08-30", home: "E", away: "F", round: 3),
        ])

        #expect(section?.kind == .inProgress)
        #expect(section?.matches.map(\.homeTeam) == ["C"])
    }

    @Test func latestResultsContainOnlyTheLatestCompletedRound() {
        let section = TableMatchesSection.resolve(from: [
            match(date: "2020-08-20", home: "A", away: "B", round: 1, status: "FT"),
            match(date: "2020-08-27", home: "A", away: "C", round: 2, status: "FT"),
            match(date: "2020-08-28", home: "B", away: "D", round: 2, status: "FT"),
            match(date: "2099-09-03", home: "A", away: "D", round: 3),
        ])

        #expect(section?.kind == .latestResults)
        #expect(section?.matches.map(\.roundNumber) == [2, 2])
    }

    @Test func futureFixturesUseTheNextRoundWhenNoResultsExist() {
        let section = TableMatchesSection.resolve(from: [
            match(date: "2099-08-30", home: "A", away: "B", round: 1),
            match(date: "2099-08-31", home: "C", away: "D", round: 1),
            match(date: "2099-09-06", home: "A", away: "C", round: 2),
        ])

        #expect(section?.kind == .futureFixtures)
        #expect(section?.matches.map(\.roundNumber) == [1, 1])
    }

    @Test func repeatedTeamsInferRoundBoundariesForOlderPayloads() {
        let section = TableMatchesSection.resolve(from: [
            match(date: "2020-08-20", home: "A", away: "B", round: nil, status: "FT"),
            match(date: "2020-08-20", home: "C", away: "D", round: nil, status: "FT"),
            match(date: "2020-08-27", home: "A", away: "C", round: nil, status: "FT"),
            match(date: "2020-08-27", home: "B", away: "D", round: nil, status: "FT"),
        ])

        #expect(section?.kind == .latestResults)
        #expect(section?.matches.map(\.homeTeam) == ["A", "B"])
    }

    private func match(
        date: String,
        home: String,
        away: String,
        round: Int?,
        status: String? = nil
    ) -> Match {
        Match(
            date: date,
            time: "15:00",
            homeTeam: home,
            awayTeam: away,
            league: "Test League",
            leagueId: "test-league",
            seasonID: 1,
            roundNumber: round,
            tvChannels: [],
            homeScore: status == "FT" ? 1 : nil,
            awayScore: status == "FT" ? 0 : nil,
            scoreStatus: status
        )
    }
}

@MainActor
struct TableLiveScoreTests {
    @Test func scoresUseEachTeamsPerspective() {
        let scores = TableLiveScore.scoresByTeam(from: [match(status: "45", home: 2, away: 1)])
        let city = scores[TableLiveScore.teamKey("Manchester City")]
        let ipswich = scores[TableLiveScore.teamKey("Ipswich Town")]
        #expect(city?.text == "2-1")
        #expect(city?.result == "Winning")
        #expect(ipswich?.text == "1-2")
        #expect(ipswich?.result == "Losing")
    }

    @Test func halfTimeDrawIsLive() {
        let scores = TableLiveScore.scoresByTeam(from: [match(status: "HT", home: 0, away: 0)])
        #expect(scores.count == 2)
        #expect(scores.values.allSatisfy { $0.text == "0-0" && $0.result == "Drawing" })
    }

    @Test func finishedUpcomingAndUnknownScoresHaveNoPills() {
        for match in [
            match(status: "FT", home: 2, away: 1),
            match(status: nil, home: nil, away: nil),
            match(status: "45", home: 2, away: nil)
        ] {
            #expect(TableLiveScore.scoresByTeam(from: [match]).isEmpty)
        }
    }

    @Test func todaysResultRetainsMatchDestinationWithoutLiveHighlight() throws {
        let finished = match(status: "FT", home: 2, away: 1, date: "2026-10-18", time: "15:00")
        let now = try #require(finished.dateTime)
        let scores = TableLiveScore.scoresByTeam(from: [finished], now: now)
        let city = try #require(scores[TableLiveScore.teamKey("Manchester City")])
        #expect(city.match == finished)
        #expect(city.text == "2-1")
        #expect(city.result == "Won")
        #expect(!city.isLive)
        #expect(scores[TableLiveScore.teamKey("Ipswich Town")]?.result == "Lost")
        #expect(TableLiveScore.scoresByTeam(from: [finished], now: now.addingTimeInterval(86400)).isEmpty)
    }

    @Test func liveMatchTakesPriorityOverTodaysEarlierResult() throws {
        let finished = match(status: "FT", home: 2, away: 1, date: "2026-10-18", time: "15:00")
        let live = match(status: "HT", home: 0, away: 0)
        let now = try #require(finished.dateTime)
        for matches in [[live, finished], [finished, live]] {
            let scores = TableLiveScore.scoresByTeam(from: matches, now: now)
            #expect(scores[TableLiveScore.teamKey("Manchester City")]?.match == live)
        }
    }

    @Test func completedScoresUseLocalCalendarDay() throws {
        let finished = match(status: "FT", home: 1, away: 1, date: "2026-10-18", time: "23:30")
        let kickoff = try #require(finished.dateTime)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let nextDay = try #require(calendar.date(byAdding: .day, value: 1, to: kickoff))
        let midnight = calendar.startOfDay(for: nextDay)
        #expect(!TableLiveScore.scoresByTeam(from: [finished], now: midnight.addingTimeInterval(-1), calendar: calendar).isEmpty)
        #expect(TableLiveScore.scoresByTeam(from: [finished], now: midnight, calendar: calendar).isEmpty)
    }

    private func match(status: String?, home: Int?, away: Int?, date: String = "", time: String = "") -> Match {
        Match(
            date: date, time: time,
            homeTeam: "Manchester City", awayTeam: "Ipswich Town",
            league: "Premier League", tvChannels: [],
            homeScore: home, awayScore: away, scoreStatus: status
        )
    }
}
