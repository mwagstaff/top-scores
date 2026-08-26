import Foundation
import Testing
@testable import Top_Scores

struct SharedMatchesBridgeTests {
    @Test func widgetPayload_capsShowAllFixturesAndOmitsDuplicateCollection() throws {
        let now = Date()
        let futureDate = dayString(offset: 1, from: now)
        let pastDate = dayString(offset: -1, from: now)
        let showAllMatches = (0..<(SharedMatchesBridge.widgetFixtureLimit + 20)).map { index in
            Match(
                date: futureDate,
                time: "15:00",
                homeTeam: "Home \(index)",
                awayTeam: "Away \(index)",
                league: "League",
                tvChannels: [TvChannel(name: "Sky Sports")]
            )
        }
        let pastMatch = Match(
            date: pastDate,
            time: "15:00",
            homeTeam: "Past Home",
            awayTeam: "Past Away",
            league: "League",
            tvChannels: []
        )
        let finishedMatch = Match(
            date: futureDate,
            time: "12:00",
            homeTeam: "Finished Home",
            awayTeam: "Finished Away",
            league: "League",
            tvChannels: [],
            homeScore: 1,
            awayScore: 0,
            scoreStatus: "FT"
        )

        let payload = SharedMatchesBridge.makeWidgetPayload(
            matches: [],
            unfilteredMatches: showAllMatches + [pastMatch, finishedMatch],
            lastUpdated: now,
            snapshot: makeSnapshot(showAllMatches: true),
            generatedAt: now
        )

        #expect(payload.matches.count == SharedMatchesBridge.widgetFixtureLimit)
        #expect(!payload.matches.contains { $0.homeTeam == pastMatch.homeTeam })
        #expect(!payload.matches.contains { $0.homeTeam == finishedMatch.homeTeam })

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedMatches = try #require(object["matches"] as? [[String: Any]])
        let firstMatch = try #require(encodedMatches.first)

        #expect(object["unfilteredMatches"] == nil)
        #expect(firstMatch["tv_channels"] as? [String] == ["Sky Sports"])
        #expect(firstMatch["home_goal_scorers"] == nil)
        #expect(firstMatch["team_lineups"] == nil)
    }

    @Test func widgetPayload_usesVisibleMatchesWhenShowAllIsDisabled() {
        let now = Date()
        let futureDate = dayString(offset: 1, from: now)
        let visibleMatch = Match(
            date: futureDate,
            time: "15:00",
            homeTeam: "Visible Home",
            awayTeam: "Visible Away",
            league: "Selected League",
            matchDetailsID: "12345",
            tvChannels: []
        )
        let unfilteredMatch = Match(
            date: futureDate,
            time: "16:00",
            homeTeam: "Unfiltered Home",
            awayTeam: "Unfiltered Away",
            league: "Other League",
            tvChannels: []
        )

        let payload = SharedMatchesBridge.makeWidgetPayload(
            matches: [visibleMatch],
            unfilteredMatches: [visibleMatch, unfilteredMatch],
            lastUpdated: now,
            snapshot: makeSnapshot(showAllMatches: false),
            generatedAt: now
        )

        #expect(payload.matches.map(\.homeTeam) == [visibleMatch.homeTeam])
        #expect(payload.matches.first?.matchDetailsIDValue == "12345")
    }

    private func makeSnapshot(showAllMatches: Bool) -> PreferencesSnapshot {
        PreferencesSnapshot(
            selectedLeagues: [],
            selectedChannels: [],
            englishPremierLeagueTeamsOnly: false,
            apiBaseURL: PreferencesStore.defaultApiBaseURL,
            refreshIntervalMinutes: PreferencesStore.defaultRefreshIntervalMinutes,
            showAllMatches: showAllMatches
        )
    }

    private func dayString(offset: Int, from date: Date) -> String {
        let calendar = Calendar.current
        let shifted = calendar.date(byAdding: .day, value: offset, to: date) ?? date
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: shifted)
    }
}
