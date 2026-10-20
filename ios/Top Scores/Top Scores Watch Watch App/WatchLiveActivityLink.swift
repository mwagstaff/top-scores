import Foundation

enum WatchLiveActivityLink {
    static func competition(for selected: WatchMatch, matches: [WatchMatch]) -> WatchCompetition {
        var candidates = matches.filter {
            $0.date == selected.date && $0.league.localizedCaseInsensitiveCompare(selected.league) == .orderedSame
        }
        if !candidates.contains(where: { $0.matchDetailsIDValue == selected.matchDetailsIDValue }) {
            candidates.append(selected)
        }
        return WatchCompetition(
            id: selected.league.lowercased(), name: selected.league,
            weight: selected.competitionWeight ?? 0,
            matches: WatchMatchGrouping.sortedMatches(candidates)
        )
    }

    static func match(from url: URL) -> WatchMatch? {
        guard url.scheme == "topscores", url.host == "match",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard let id = value("id"), !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let date = value("date"), let time = value("time"),
              let home = value("home"), !home.isEmpty,
              let away = value("away"), !away.isEmpty,
              let league = value("league") else { return nil }

        return WatchMatch(
            date: date, time: time, homeTeam: home, awayTeam: away,
            homeShortName: nil, awayShortName: nil,
            league: league, leagueSubcategory: nil, competitionWeight: nil,
            watchabilityIndex: nil, matchDetailsIDValue: id, tvChannels: [],
            homeScore: value("homeScore").flatMap(Int.init),
            awayScore: value("awayScore").flatMap(Int.init),
            scoreStatus: value("status"),
            homeGoalScorers: [], awayGoalScorers: [], homeAssists: [], awayAssists: [],
            homeYellowCards: [], awayYellowCards: [], homeRedCards: [], awayRedCards: [],
            homeVarEvents: [], awayVarEvents: [], teamLineups: nil,
            penaltyResult: nil, homeTeamId: nil, awayTeamId: nil
        )
    }
}
