import Foundation

nonisolated struct WatchFantasyLeagueTransfer: Codable, Sendable {
    let id: Int
    let name: String
    let entries: [WatchFantasyStandingTransfer]
}

nonisolated struct WatchFantasyStandingTransfer: Codable, Sendable {
    let entry: Int
    let rank: Int
    let lastRank: Int?
    let entryName: String
    let playerName: String
    let total: Int?
    let clubBadgeSrc: String?
}

enum WatchFantasyTablesStore {
    private nonisolated static let key = "fantasy.watchTables"

    private nonisolated struct Payload: Codable {
        let managerEntryID: Int
        let leagues: [WatchFantasyLeagueTransfer]
    }

    nonisolated static func load(managerEntryID: Int?) -> [WatchFantasyLeagueTransfer]? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.managerEntryID == managerEntryID else { return nil }
        return payload.leagues
    }

    static func persist(managerEntryID: String, model: FantasyViewModel) {
        guard let entryID = Int(managerEntryID), let squad = model.data,
              let profile = model.myProfile, profile.id == entryID else { return }

        let myTotal = fantasyReconciledSeasonTotalPoints(
            squadSeasonPoints: squad.seasonTotalPoints,
            reportedCurrentGameweekPoints: squad.totalPoints,
            resolvedCurrentGameweekPoints: squad.resolvedCurrentScore,
            gameweekID: squad.gameweekID,
            profileCurrentGameweekID: profile.currentEvent,
            profileCurrentGameweekPoints: profile.summaryEventPoints,
            profileSeasonPoints: profile.summaryOverallPoints
        )
        var rivals = [WatchFantasyStandingTransfer(
            entry: entryID, rank: 0, lastRank: nil, entryName: profile.name,
            playerName: "\(profile.playerFirstName) \(profile.playerLastName)",
            total: myTotal, clubBadgeSrc: profile.clubBadgeSrc
        )]
        rivals += model.rivalSquads.map {
            WatchFantasyStandingTransfer(
                entry: $0.entryID, rank: 0, lastRank: nil, entryName: $0.teamName,
                playerName: $0.managerName, total: $0.squad.seasonTotalPoints ?? $0.allGameweeksPoints,
                clubBadgeSrc: $0.clubBadgeSrc
            )
        }
        var previousTotals: [Int: Int] = [:]
        if let myTotal { previousTotals[entryID] = myTotal - squad.resolvedCurrentScore }
        for rival in model.rivalSquads where rival.squad.gameweekID == squad.gameweekID {
            if let total = rival.squad.seasonTotalPoints ?? rival.allGameweeksPoints {
                previousTotals[rival.entryID] = total - rival.currentScore
            }
        }
        rivals.sort {
            if $0.total != $1.total { return ($0.total ?? Int.min) > ($1.total ?? Int.min) }
            return $0.entryName.localizedCaseInsensitiveCompare($1.entryName) == .orderedAscending
        }
        let rankedRivals = rivals.map { row in
            let rank = 1 + rivals.filter { ($0.total ?? Int.min) > (row.total ?? Int.min) }.count
            let lastRank = previousTotals.count == rivals.count ? previousTotals[row.entry].map { total in
                1 + previousTotals.values.filter { $0 > total }.count
            } : nil
            return WatchFantasyStandingTransfer(
                entry: row.entry, rank: rank, lastRank: lastRank, entryName: row.entryName,
                playerName: row.playerName, total: row.total, clubBadgeSrc: row.clubBadgeSrc
            )
        }
        var leagues = [WatchFantasyLeagueTransfer(id: 0, name: "Rivals", entries: rankedRivals)]
        let tracked = Dictionary(uniqueKeysWithValues: model.trackedLeagueStandings.map { ($0.leagueID, $0) })
        leagues += (profile.leagues?.classic ?? []).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }.map { league in
            WatchFantasyLeagueTransfer(id: league.id, name: league.name, entries: (tracked[league.id]?.standings ?? []).map {
                WatchFantasyStandingTransfer(
                    entry: $0.entry, rank: $0.rank, lastRank: $0.lastRank, entryName: $0.entryName,
                    playerName: $0.playerName, total: $0.total, clubBadgeSrc: $0.clubBadgeSrc
                )
            })
        }
        guard let data = try? JSONEncoder().encode(Payload(managerEntryID: entryID, leagues: leagues)) else { return }
        UserDefaults.standard.set(data, forKey: key)
        SharedMatchesBridge.refreshWatchFantasyState()
    }
}
