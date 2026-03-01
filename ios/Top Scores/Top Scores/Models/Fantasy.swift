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

    enum CodingKeys: String, CodingKey {
        case totalPoints = "total_points"
    }
}

struct FantasyFixture: Codable, Hashable {
    let id: Int
    let event: Int?
    let teamH: Int
    let teamA: Int
    let started: Bool?
    let finished: Bool?
    let finishedProvisional: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case event
        case teamH = "team_h"
        case teamA = "team_a"
        case started
        case finished
        case finishedProvisional = "finished_provisional"
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
    let upcomingOpponentDisplay: String?

    var id: Int {
        elementID
    }

    var isStarter: Bool {
        pickPosition <= 11
    }
}

struct FantasySquadDisplayData: Hashable {
    let gameweekID: Int
    let gameweekTitle: String
    let totalPoints: Int
    let hasActiveFixtures: Bool
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
}

enum FantasySquadBuilder {
    static func build(
        gameweek: FantasyGameweek,
        picksResponse: FantasyPicksResponse,
        liveResponse: FantasyEventLiveResponse,
        fixtures: [FantasyFixture],
        bootstrap: FantasyBootstrapLookup
    ) -> FantasySquadDisplayData {
        let livePointsByElementID = Dictionary(
            uniqueKeysWithValues: liveResponse.elements.map { ($0.id, $0.stats.totalPoints) }
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
                upcomingOpponentDisplay: upcomingOpponentDisplay
            )
        }
        .sorted { $0.pickPosition < $1.pickPosition }

        let starters = players.filter { $0.isStarter }
        let bench = players
            .filter { !$0.isStarter }
            .sorted { $0.pickPosition < $1.pickPosition }

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
