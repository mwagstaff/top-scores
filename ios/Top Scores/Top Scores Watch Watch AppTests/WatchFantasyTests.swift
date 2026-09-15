import Foundation
import Testing
@testable import Top_Scores_Watch_Watch_App

struct WatchFantasyTests {
    @Test func olderPhoneSnapshotsStillDecode() throws {
        let data = Data(#"{"gameweekTitle":"Gameweek 5","players":[{"elementID":1,"displayName":"Salah","teamName":"Liverpool","points":12,"isCaptain":true,"isViceCaptain":false,"isStarter":true}]}"#.utf8)
        let snapshot = try JSONDecoder().decode(WatchFantasySnapshot.self, from: data)
        #expect(snapshot.players.count == 1)
        #expect(snapshot.players[0].profileImageURL == nil)
        #expect(snapshot.leagues == nil)
        #expect(snapshot.scoreDisplay == "— pts")
    }

    @Test func expectedProvisionalAndFinalScoresAreDistinct() {
        var snapshot = WatchFantasySnapshot(gameweekTitle: "Gameweek 5", players: [], scorePhase: "expected", totalPoints: 0, expectedPoints: 69.3)
        #expect(snapshot.scoreDisplay == "69.3 xP")
        snapshot.expectedPoints = nil
        #expect(snapshot.scoreDisplay == "— xP")
        snapshot.scorePhase = "provisional"
        snapshot.totalPoints = 42
        #expect(snapshot.scoreDisplay == "42 pts")
        #expect(snapshot.scoreDescription == "Live · provisional")
        snapshot.scorePhase = "final"
        #expect(snapshot.scoreDescription == "Confirmed points")
    }

    @Test func deadlineUsesCalendarDaysAndHandlesExpiredOrMissingDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        let now = try #require(WatchFantasyPresentation.parseDate("2026-09-16T22:30:00Z"))
        #expect(WatchFantasyPresentation.deadline("2026-09-18T17:30:00Z", now: now, calendar: calendar) == "Friday 18th (2 days)")
        #expect(WatchFantasyPresentation.deadline("2026-09-17T17:30:00Z", now: now, calendar: calendar) == "Thursday 17th (1 day)")
        #expect(WatchFantasyPresentation.deadline("2026-09-16T22:45:00Z", now: now, calendar: calendar) == "Wednesday 16th (today)")
        #expect(WatchFantasyPresentation.deadline("2026-09-11T17:30:00Z", now: now, calendar: calendar) == "Friday 11th (passed)")
        #expect(WatchFantasyPresentation.deadline(nil) == "Deadline unavailable")
    }

    @Test func namesAndDoubleGameweekOpponentsStayReadable() {
        #expect(WatchFantasyPresentation.surname("B. Fernandes") == "Fernandes")
        #expect(WatchFantasyPresentation.surname("B.Fernandes") == "Fernandes")
        #expect(WatchFantasyPresentation.surname("van Dijk") == "van Dijk")
        #expect(WatchFantasyPresentation.opponent("BHA (H), ARS (A)") == "BHA, ARS")
        #expect(WatchFantasyPresentation.opponent(nil) == "—")
    }

    @Test func standingsDecodeFromPhoneAndPublicAPIAndShowRankMovement() throws {
        let phone = Data(#"{"entry":123,"rank":2,"lastRank":5,"entryName":"My Team","playerName":"A Manager","total":320}"#.utf8)
        let row = try JSONDecoder().decode(WatchFantasyStanding.self, from: phone)
        #expect(row.trend == "arrow.up")
        #expect(row.trendDescription == "Up 3 places")
        let api = Data(#"{"entry":123,"rank":5,"last_rank":2,"entry_name":"My Team","player_name":"A Manager","total":320,"club_badge_src":null}"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let apiRow = try decoder.decode(WatchFantasyStanding.self, from: api)
        #expect(apiRow.trend == "arrow.down")
        #expect(apiRow.entryName == "My Team")
        let newEntry = WatchFantasyStanding(entry: 5, rank: 1, lastRank: 0, entryName: "New", playerName: "Manager", total: nil, clubBadgeSrc: nil)
        #expect(newEntry.trendDescription == "Trend unavailable")
    }
}
