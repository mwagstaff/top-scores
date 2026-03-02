import Foundation

struct FantasyGameweek: Codable, Hashable {
    let id: Int
    let name: String?
    let isCurrent: Bool?
    let isNext: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case isCurrent = "is_current"
        case isNext = "is_next"
    }
}

struct FantasyBootstrapLookup: Codable, Hashable {
    let updatedAt: String?
    let elements: [FantasyBootstrapElement]
    let teams: [FantasyBootstrapTeam]
    let elementTypes: [FantasyBootstrapElementType]
    let events: [FantasyGameweek]

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case elements
        case teams
        case elementTypes = "element_types"
        case events
    }
}

struct FantasyBootstrapElement: Codable, Hashable {
    let id: Int
    let webName: String
    let firstName: String
    let secondName: String
    let team: Int
    let elementType: Int
    let photo: String?
    let status: String?
    let news: String?

    enum CodingKeys: String, CodingKey {
        case id
        case webName = "web_name"
        case firstName = "first_name"
        case secondName = "second_name"
        case team
        case elementType = "element_type"
        case photo
        case status
        case news
    }
}

struct FantasyBootstrapTeam: Codable, Hashable {
    let id: Int
    let name: String
    let shortName: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case shortName = "short_name"
    }
}

struct FantasyBootstrapElementType: Codable, Hashable {
    let id: Int
    let singularName: String
    let singularNameShort: String

    enum CodingKeys: String, CodingKey {
        case id
        case singularName = "singular_name"
        case singularNameShort = "singular_name_short"
    }
}

struct FantasyPicksResponse: Codable, Hashable {
    let picks: [FantasyPick]
    let entryHistory: FantasyEntryHistory

    enum CodingKeys: String, CodingKey {
        case picks
        case entryHistory = "entry_history"
    }
}

struct FantasyPick: Codable, Hashable {
    let element: Int
    let position: Int
    let multiplier: Int
    let isCaptain: Bool
    let isViceCaptain: Bool
    let elementType: Int?

    enum CodingKeys: String, CodingKey {
        case element
        case position
        case multiplier
        case isCaptain = "is_captain"
        case isViceCaptain = "is_vice_captain"
        case elementType = "element_type"
    }
}

struct FantasyEntryHistory: Codable, Hashable {
    let event: Int
    let points: Int
    let rank: Int?
    let overallRank: Int?
    let eventTransfersCost: Int?
    let pointsOnBench: Int?

    enum CodingKeys: String, CodingKey {
        case event
        case points
        case rank
        case overallRank = "overall_rank"
        case eventTransfersCost = "event_transfers_cost"
        case pointsOnBench = "points_on_bench"
    }
}

struct FantasyEventLiveResponse: Codable, Hashable {
    let elements: [FantasyLiveElement]
}

struct FantasyLiveElement: Codable, Hashable {
    let id: Int
    let stats: FantasyLiveStats
}

struct FantasyLiveStats: Codable, Hashable {
    let totalPoints: Int
    let minutes: Int?
    let goalsScored: Int?
    let assists: Int?
    let yellowCards: Int?
    let redCards: Int?

    enum CodingKeys: String, CodingKey {
        case totalPoints = "total_points"
        case minutes
        case goalsScored = "goals_scored"
        case assists
        case yellowCards = "yellow_cards"
        case redCards = "red_cards"
    }
}

struct FantasyFixture: Codable, Hashable {
    let id: Int
    let event: Int?
    let teamH: Int
    let teamA: Int
    let kickoffTime: String?
    let started: Bool?
    let finished: Bool?
    let finishedProvisional: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case event
        case teamH = "team_h"
        case teamA = "team_a"
        case kickoffTime = "kickoff_time"
        case started
        case finished
        case finishedProvisional = "finished_provisional"
    }
}

struct FantasyEntryProfile: Codable, Hashable {
    let id: Int
    let name: String
    let playerFirstName: String
    let playerLastName: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case playerFirstName = "player_first_name"
        case playerLastName = "player_last_name"
    }
}

struct FantasyRivalManager: Codable, Hashable, Identifiable {
    let entryID: Int
    let teamName: String
    let managerFirstName: String
    let managerLastName: String

    var id: Int {
        entryID
    }

    var managerDisplayName: String {
        let combined = [managerFirstName, managerLastName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return combined.isEmpty ? "Manager \(entryID)" : combined
    }
}

struct FantasyRivalSquad: Identifiable, Hashable {
    let entryID: Int
    let teamName: String
    let managerName: String
    let squad: FantasySquadDisplayData

    var id: Int {
        entryID
    }

    var currentScore: Int {
        squad.resolvedCurrentScore
    }
}

enum FantasyPositionType: Int, CaseIterable, Hashable {
    case goalkeeper = 1
    case defender = 2
    case midfielder = 3
    case forward = 4

    var shortLabel: String {
        switch self {
        case .goalkeeper:
            return "GKP"
        case .defender:
            return "DEF"
        case .midfielder:
            return "MID"
        case .forward:
            return "FWD"
        }
    }
}

struct FantasyDisplayPlayer: Identifiable, Hashable {
    let elementID: Int
    let pickPosition: Int
    let positionType: FantasyPositionType
    let displayName: String
    let teamName: String
    let rawPoints: Int
    let appliedPoints: Int
    let displayPoints: Int
    let multiplier: Int
    let isCaptain: Bool
    let isViceCaptain: Bool
    let isPlayingNow: Bool
    let isUnavailable: Bool
    let minutesPlayed: Int
    let upcomingOpponentDisplay: String?
    let goalsScored: Int
    let assists: Int
    let yellowCards: Int
    let redCards: Int

    var id: Int {
        elementID
    }

    var isStarter: Bool {
        pickPosition <= 11
    }

    var didNotPlay: Bool {
        minutesPlayed == 0
    }
}

struct FantasySquadDisplayData: Hashable {
    let gameweekID: Int
    let gameweekTitle: String
    let totalPoints: Int
    let hasActiveFixtures: Bool
    let hasFixturesPlayedToday: Bool
    let isEstimatedScore: Bool
    let estimatedCurrentScore: Int
    let scoreCalculationRulesApplied: [String]
    let rank: Int?
    let overallRank: Int?
    let transfersCost: Int?
    let pointsOnBench: Int?
    let goalkeepers: [FantasyDisplayPlayer]
    let defenders: [FantasyDisplayPlayer]
    let midfielders: [FantasyDisplayPlayer]
    let forwards: [FantasyDisplayPlayer]
    let bench: [FantasyDisplayPlayer]

    var starters: [FantasyDisplayPlayer] {
        (goalkeepers + defenders + midfielders + forwards)
            .sorted { $0.pickPosition < $1.pickPosition }
    }

    var computedAppliedPointsTotal: Int {
        starters.reduce(0) { $0 + $1.appliedPoints }
    }

    var allPlayers: [FantasyDisplayPlayer] {
        (starters + bench).sorted { $0.pickPosition < $1.pickPosition }
    }

    var resolvedCurrentScore: Int {
        isEstimatedScore
            ? estimatedCurrentScore
            : totalPoints
    }
}

enum FantasySquadBuilder {
    static func build(
        gameweek: FantasyGameweek,
        picksResponse: FantasyPicksResponse,
        liveResponse: FantasyEventLiveResponse,
        fixtures: [FantasyFixture],
        bootstrap: FantasyBootstrapLookup,
        now: Date = Date()
    ) -> FantasySquadDisplayData {
        let livePointsByElementID = Dictionary(
            uniqueKeysWithValues: liveResponse.elements.map { ($0.id, $0.stats.totalPoints) }
        )
        let liveStatsByElementID = Dictionary(
            uniqueKeysWithValues: liveResponse.elements.map { ($0.id, $0.stats) }
        )

        let elementByID = Dictionary(
            uniqueKeysWithValues: bootstrap.elements.map { ($0.id, $0) }
        )

        let teamNameByID = Dictionary(
            uniqueKeysWithValues: bootstrap.teams.map { ($0.id, $0.name) }
        )
        let teamShortNameByID = Dictionary(
            uniqueKeysWithValues: bootstrap.teams.map { ($0.id, $0.shortName) }
        )

        let activeTeamIDs = Set(
            fixtures.flatMap { fixture -> [Int] in
                let hasStarted = fixture.started == true
                let isFinished = fixture.finished == true || fixture.finishedProvisional == true
                guard hasStarted, !isFinished else { return [] }
                return [fixture.teamH, fixture.teamA]
            }
        )
        let hasActiveFixtures = !activeTeamIDs.isEmpty
        let hasFixturesPlayedToday = {
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: now)
            guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) else {
                return false
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fallbackFormatter = ISO8601DateFormatter()
            fallbackFormatter.formatOptions = [.withInternetDateTime]

            for fixture in fixtures {
                guard fixture.started == true else { continue }
                guard let kickoffRaw = fixture.kickoffTime?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !kickoffRaw.isEmpty else {
                    continue
                }
                let kickoffDate = formatter.date(from: kickoffRaw) ?? fallbackFormatter.date(from: kickoffRaw)
                guard let kickoffDate else { continue }
                if kickoffDate >= startOfToday && kickoffDate < startOfTomorrow {
                    return true
                }
            }
            return false
        }()

        func teamDisplayCode(teamID: Int) -> String {
            let shortName = (teamShortNameByID[teamID] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !shortName.isEmpty {
                return shortName.uppercased()
            }

            let fallbackName = (teamNameByID[teamID] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if fallbackName.isEmpty {
                return "TBD"
            }

            let lettersOnly = fallbackName
                .uppercased()
                .filter { $0.isLetter }
            if lettersOnly.count >= 3 {
                return String(lettersOnly.prefix(3))
            }
            return lettersOnly.isEmpty ? "TBD" : lettersOnly
        }

        var upcomingOpponentByTeamID: [Int: String] = [:]
        fixtures
            .sorted { $0.id < $1.id }
            .forEach { fixture in
                let hasStarted = fixture.started == true
                let isFinished = fixture.finished == true || fixture.finishedProvisional == true
                guard !hasStarted, !isFinished else { return }

                if upcomingOpponentByTeamID[fixture.teamH] == nil {
                    upcomingOpponentByTeamID[fixture.teamH] = "\(teamDisplayCode(teamID: fixture.teamA)) (H)"
                }
                if upcomingOpponentByTeamID[fixture.teamA] == nil {
                    upcomingOpponentByTeamID[fixture.teamA] = "\(teamDisplayCode(teamID: fixture.teamH)) (A)"
                }
            }

        let fallbackGameweekTitle = "Gameweek \(picksResponse.entryHistory.event)"
        let resolvedGameweekTitle = {
            let trimmed = gameweek.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                return fallbackGameweekTitle
            }
            if trimmed.localizedCaseInsensitiveContains("gameweek") {
                return trimmed
            }
            return "Gameweek \(gameweek.id)"
        }()

        let players = picksResponse.picks.compactMap { pick -> FantasyDisplayPlayer? in
            let element = elementByID[pick.element]
            let teamName = teamNameByID[element?.team ?? -1] ?? "Unknown Team"
            let displayName = {
                let fromWebName = element?.webName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !fromWebName.isEmpty { return fromWebName }

                let first = element?.firstName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let second = element?.secondName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let combined = [first, second].filter { !$0.isEmpty }.joined(separator: " ")
                if !combined.isEmpty { return combined }

                return "Player #\(pick.element)"
            }()

            let resolvedPositionTypeRaw = pick.elementType ?? element?.elementType ?? 0
            let positionType = FantasyPositionType(rawValue: resolvedPositionTypeRaw) ?? .midfielder

            let rawPoints = livePointsByElementID[pick.element] ?? 0
            let appliedPoints = rawPoints * pick.multiplier
            let displayPoints = pick.position <= 11 ? appliedPoints : rawPoints
            let liveStats = liveStatsByElementID[pick.element]
            let minutesPlayed = liveStats?.minutes ?? 0
            let goalsScored = liveStats?.goalsScored ?? 0
            let assists = liveStats?.assists ?? 0
            let yellowCards = liveStats?.yellowCards ?? 0
            let redCards = liveStats?.redCards ?? 0
            let isPlayingNow = {
                guard let teamID = element?.team else { return false }
                return activeTeamIDs.contains(teamID)
            }()
            let isUnavailable = {
                let status = (element?.status ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                return status == "i" || status == "d" || status == "s" || status == "u"
            }()
            let upcomingOpponentDisplay: String? = {
                guard rawPoints == 0 else { return nil }
                guard let teamID = element?.team else { return nil }
                return upcomingOpponentByTeamID[teamID]
            }()

            return FantasyDisplayPlayer(
                elementID: pick.element,
                pickPosition: pick.position,
                positionType: positionType,
                displayName: displayName,
                teamName: teamName,
                rawPoints: rawPoints,
                appliedPoints: appliedPoints,
                displayPoints: displayPoints,
                multiplier: pick.multiplier,
                isCaptain: pick.isCaptain,
                isViceCaptain: pick.isViceCaptain,
                isPlayingNow: isPlayingNow,
                isUnavailable: isUnavailable,
                minutesPlayed: minutesPlayed,
                upcomingOpponentDisplay: upcomingOpponentDisplay,
                goalsScored: goalsScored,
                assists: assists,
                yellowCards: yellowCards,
                redCards: redCards
            )
        }
        .sorted { $0.pickPosition < $1.pickPosition }

        let starters = players.filter { $0.isStarter }
        let bench = players
            .filter { !$0.isStarter }
            .sorted { $0.pickPosition < $1.pickPosition }

        let isEstimatedScore = hasActiveFixtures || hasFixturesPlayedToday
        let computedAppliedPointsTotal = starters.reduce(0) { $0 + $1.appliedPoints }
        var estimatedCurrentScore = picksResponse.entryHistory.points
        var scoreCalculationRulesApplied: [String] = []

        if isEstimatedScore {
            var runningEstimatedTotal = computedAppliedPointsTotal

            if let unavailableStartingGoalkeeper = starters.first(where: { player in
                player.positionType == .goalkeeper && player.didNotPlay
            }),
               let benchGoalkeeper = bench.first(where: { $0.positionType == .goalkeeper && !$0.didNotPlay }) {
                runningEstimatedTotal -= unavailableStartingGoalkeeper.appliedPoints
                runningEstimatedTotal += benchGoalkeeper.rawPoints
                scoreCalculationRulesApplied.append(
                    "Goalkeeper auto-sub applied: \(unavailableStartingGoalkeeper.displayName) did not play, so \(benchGoalkeeper.displayName) contributed \(benchGoalkeeper.rawPoints) pts."
                )
            }

            let minimumFormation: [FantasyPositionType: Int] = [
                .defender: 3,
                .midfielder: 2,
                .forward: 1
            ]
            var activeOutfieldCounts: [FantasyPositionType: Int] = [.defender: 0, .midfielder: 0, .forward: 0]
            for player in starters where player.positionType != .goalkeeper {
                activeOutfieldCounts[player.positionType, default: 0] += 1
            }

            var nonPlayingOutfieldStarters = starters
                .filter { $0.positionType != .goalkeeper && $0.didNotPlay }
                .sorted { $0.pickPosition < $1.pickPosition }
            let playedOutfieldBench = bench
                .filter { $0.positionType != .goalkeeper && !$0.didNotPlay }
                .sorted { $0.pickPosition < $1.pickPosition }
            var outfieldReplacementNotes: [String] = []

            for benchPlayer in playedOutfieldBench {
                guard !nonPlayingOutfieldStarters.isEmpty else { break }

                let replacementIndex = nonPlayingOutfieldStarters.firstIndex { starter in
                    var simulatedCounts = activeOutfieldCounts
                    simulatedCounts[starter.positionType, default: 0] -= 1
                    simulatedCounts[benchPlayer.positionType, default: 0] += 1
                    let defendersOK = (simulatedCounts[.defender] ?? 0) >= (minimumFormation[.defender] ?? 0)
                    let midfieldersOK = (simulatedCounts[.midfielder] ?? 0) >= (minimumFormation[.midfielder] ?? 0)
                    let forwardsOK = (simulatedCounts[.forward] ?? 0) >= (minimumFormation[.forward] ?? 0)
                    return defendersOK && midfieldersOK && forwardsOK
                }

                guard let replacementIndex else { continue }
                let replacedStarter = nonPlayingOutfieldStarters.remove(at: replacementIndex)

                activeOutfieldCounts[replacedStarter.positionType, default: 0] -= 1
                activeOutfieldCounts[benchPlayer.positionType, default: 0] += 1

                runningEstimatedTotal -= replacedStarter.appliedPoints
                runningEstimatedTotal += benchPlayer.rawPoints
                outfieldReplacementNotes.append(
                    "\(benchPlayer.displayName) (\(benchPlayer.rawPoints)) for \(replacedStarter.displayName)"
                )
            }

            if !outfieldReplacementNotes.isEmpty {
                scoreCalculationRulesApplied.append(
                    "Outfield auto-subs applied: \(outfieldReplacementNotes.joined(separator: ", "))."
                )
            }

            if let captain = starters.first(where: { $0.isCaptain && $0.didNotPlay }),
               let viceCaptain = players.first(where: { $0.isViceCaptain && !$0.didNotPlay }) {
                runningEstimatedTotal += viceCaptain.rawPoints
                scoreCalculationRulesApplied.append(
                    "Vice-captain boost applied: \(captain.displayName) did not play, so \(viceCaptain.displayName) was doubled (+\(viceCaptain.rawPoints) pts)."
                )
            }

            estimatedCurrentScore = runningEstimatedTotal
        }

        var goalkeepers: [FantasyDisplayPlayer] = []
        var defenders: [FantasyDisplayPlayer] = []
        var midfielders: [FantasyDisplayPlayer] = []
        var forwards: [FantasyDisplayPlayer] = []

        for starter in starters {
            switch starter.positionType {
            case .goalkeeper:
                goalkeepers.append(starter)
            case .defender:
                defenders.append(starter)
            case .midfielder:
                midfielders.append(starter)
            case .forward:
                forwards.append(starter)
            }
        }

        goalkeepers.sort { $0.pickPosition < $1.pickPosition }
        defenders.sort { $0.pickPosition < $1.pickPosition }
        midfielders.sort { $0.pickPosition < $1.pickPosition }
        forwards.sort { $0.pickPosition < $1.pickPosition }

        return FantasySquadDisplayData(
            gameweekID: gameweek.id,
            gameweekTitle: resolvedGameweekTitle,
            totalPoints: picksResponse.entryHistory.points,
            hasActiveFixtures: hasActiveFixtures,
            hasFixturesPlayedToday: hasFixturesPlayedToday,
            isEstimatedScore: isEstimatedScore,
            estimatedCurrentScore: estimatedCurrentScore,
            scoreCalculationRulesApplied: scoreCalculationRulesApplied,
            rank: picksResponse.entryHistory.rank,
            overallRank: picksResponse.entryHistory.overallRank,
            transfersCost: picksResponse.entryHistory.eventTransfersCost,
            pointsOnBench: picksResponse.entryHistory.pointsOnBench,
            goalkeepers: goalkeepers,
            defenders: defenders,
            midfielders: midfielders,
            forwards: forwards,
            bench: bench
        )
    }
}
