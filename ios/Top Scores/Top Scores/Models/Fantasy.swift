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
    let nowCost: Int?
    let form: String?
    let pointsPerGame: String?
    let eventPoints: Int?
    let totalPoints: Int?
    let bonus: Int?
    let ictIndex: String?
    let selectedByPercent: String?
    let chanceOfPlayingThisRound: Int?
    let chanceOfPlayingNextRound: Int?

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
        case nowCost = "now_cost"
        case form
        case pointsPerGame = "points_per_game"
        case eventPoints = "event_points"
        case totalPoints = "total_points"
        case bonus
        case ictIndex = "ict_index"
        case selectedByPercent = "selected_by_percent"
        case chanceOfPlayingThisRound = "chance_of_playing_this_round"
        case chanceOfPlayingNextRound = "chance_of_playing_next_round"
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

struct FantasyElementSummaryResponse: Codable, Hashable {
    let fixtures: [FantasyElementSummaryFixture]
    let history: [FantasyElementSummaryHistory]

    enum CodingKeys: String, CodingKey {
        case fixtures
        case history
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fixtures = (try? container.decode([FantasyElementSummaryFixture].self, forKey: .fixtures)) ?? []
        history = (try? container.decode([FantasyElementSummaryHistory].self, forKey: .history)) ?? []
    }
}

struct FantasyElementSummaryFixture: Codable, Hashable {
    let event: Int?
    let opponentTeam: Int?
    let teamH: Int?
    let teamA: Int?
    let isHome: Bool?
    let difficulty: Int?
    let kickoffTime: String?
    let finished: Bool?

    enum CodingKeys: String, CodingKey {
        case event
        case opponentTeam = "opponent_team"
        case teamH = "team_h"
        case teamA = "team_a"
        case isHome = "is_home"
        case difficulty
        case kickoffTime = "kickoff_time"
        case finished
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        event = Self.decodeFlexibleInt(container: container, key: .event)
        opponentTeam = Self.decodeFlexibleInt(container: container, key: .opponentTeam)
        teamH = Self.decodeFlexibleInt(container: container, key: .teamH)
        teamA = Self.decodeFlexibleInt(container: container, key: .teamA)
        difficulty = Self.decodeFlexibleInt(container: container, key: .difficulty)
        kickoffTime = try? container.decode(String.self, forKey: .kickoffTime)
        finished = try? container.decode(Bool.self, forKey: .finished)

        if let value = try? container.decode(Bool.self, forKey: .isHome) {
            isHome = value
        } else if let value = Self.decodeFlexibleInt(container: container, key: .isHome) {
            isHome = value != 0
        } else {
            isHome = nil
        }
    }

    private static func decodeFlexibleInt(
        container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let intValue = Int(trimmed) {
                return intValue
            }
            if let doubleValue = Double(trimmed) {
                return Int(doubleValue)
            }
            return nil
        }
        if let value = try? container.decode(Double.self, forKey: key) {
            return Int(value)
        }
        return nil
    }
}

struct FantasyElementSummaryHistory: Codable, Hashable {
    let round: Int
    let opponentTeam: Int
    let wasHome: Bool
    let totalPoints: Int
    let starts: Int
    let minutes: Int
    let goalsScored: Int
    let assists: Int
    let expectedGoals: String?
    let kickoffTime: String?

    enum CodingKeys: String, CodingKey {
        case round
        case opponentTeam = "opponent_team"
        case wasHome = "was_home"
        case totalPoints = "total_points"
        case starts
        case minutes
        case goalsScored = "goals_scored"
        case assists
        case expectedGoals = "expected_goals"
        case kickoffTime = "kickoff_time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        round = Self.decodeFlexibleInt(container: container, key: .round) ?? 0
        opponentTeam = Self.decodeFlexibleInt(container: container, key: .opponentTeam) ?? 0
        totalPoints = Self.decodeFlexibleInt(container: container, key: .totalPoints) ?? 0
        starts = Self.decodeFlexibleInt(container: container, key: .starts) ?? 0
        minutes = Self.decodeFlexibleInt(container: container, key: .minutes) ?? 0
        goalsScored = Self.decodeFlexibleInt(container: container, key: .goalsScored) ?? 0
        assists = Self.decodeFlexibleInt(container: container, key: .assists) ?? 0
        kickoffTime = try? container.decode(String.self, forKey: .kickoffTime)

        if let value = try? container.decode(Bool.self, forKey: .wasHome) {
            wasHome = value
        } else if let value = Self.decodeFlexibleInt(container: container, key: .wasHome) {
            wasHome = value != 0
        } else {
            wasHome = false
        }

        if let value = try? container.decode(String.self, forKey: .expectedGoals) {
            expectedGoals = value
        } else if let value = try? container.decode(Double.self, forKey: .expectedGoals) {
            expectedGoals = String(format: "%.2f", value)
        } else if let value = try? container.decode(Int.self, forKey: .expectedGoals) {
            expectedGoals = String(format: "%.2f", Double(value))
        } else {
            expectedGoals = nil
        }
    }

    private static func decodeFlexibleInt(
        container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let intValue = Int(trimmed) {
                return intValue
            }
            if let doubleValue = Double(trimmed) {
                return Int(doubleValue)
            }
            return nil
        }
        if let value = try? container.decode(Double.self, forKey: key) {
            return Int(value)
        }
        return nil
    }
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

struct FantasyPlayerDetailsData: Hashable {
    enum StatusSeverity: String, Hashable {
        case warning
        case info
    }

    struct StatusUpdate: Hashable, Identifiable {
        let message: String
        let severity: StatusSeverity

        var id: String {
            "\(severity.rawValue)-\(message)"
        }
    }

    struct Metric: Hashable {
        let title: String
        let value: String
    }

    struct FormItem: Hashable, Identifiable {
        let gameweek: Int
        let opponentTeamID: Int?
        let opponentTeamName: String
        let wasHome: Bool?
        let points: Int?
        let isBlank: Bool

        var id: String {
            "\(gameweek)-\(opponentTeamID ?? -1)-\(wasHome ?? false)-\(points ?? -1)-\(isBlank)"
        }
    }

    struct UpcomingFixture: Hashable, Identifiable {
        let gameweek: Int
        let opponentTeamID: Int?
        let opponentTeamName: String
        let isHome: Bool?
        let difficulty: Int?
        let isBlank: Bool

        var id: String {
            "\(gameweek)-\(opponentTeamID ?? -1)-\(isHome ?? false)-\(difficulty ?? -1)-\(isBlank)"
        }
    }

    struct HistoryRow: Hashable, Identifiable {
        let gameweek: Int
        let opponentTeamID: Int
        let opponentTeamName: String
        let wasHome: Bool
        let points: Int
        let starts: Int
        let minutes: Int
        let goalsScored: Int
        let assists: Int
        let expectedGoals: String

        var id: String {
            "\(gameweek)-\(opponentTeamID)-\(wasHome)-\(points)-\(minutes)"
        }
    }

    let elementID: Int
    let playerName: String
    let teamName: String
    let teamID: Int
    let position: String
    let statusUpdates: [StatusUpdate]
    let metrics: [Metric]
    let formItems: [FormItem]
    let upcomingFixtures: [UpcomingFixture]
    let historyRows: [HistoryRow]
}

enum FantasyPlayerDetailsBuilder {
    static func build(
        elementID: Int,
        gameweekID: Int,
        bootstrap: FantasyBootstrapLookup,
        summary: FantasyElementSummaryResponse
    ) throws -> FantasyPlayerDetailsData {
        guard let element = bootstrap.elements.first(where: { $0.id == elementID }) else {
            throw FantasyPublicAPIError.decodeFailed(
                operation: "fpl_element_summary",
                underlying: NSError(domain: "Fantasy", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing bootstrap element for player \(elementID)."])
            )
        }

        let teamsByID = Dictionary(uniqueKeysWithValues: bootstrap.teams.map { ($0.id, $0) })
        let positionByID = Dictionary(uniqueKeysWithValues: bootstrap.elementTypes.map { ($0.id, $0.singularName) })
        let team = teamsByID[element.team]
        let teamName = team?.name ?? "Unknown Team"
        let position = positionByID[element.elementType] ?? "Player"

        let sortedHistory = summary.history.sorted { lhs, rhs in
            if lhs.round != rhs.round {
                return lhs.round > rhs.round
            }
            return (lhs.kickoffTime ?? "") > (rhs.kickoffTime ?? "")
        }

        let latestGameweekPoints = sortedHistory
            .filter { $0.round == gameweekID }
            .reduce(0) { $0 + $1.totalPoints }
        let resolvedLatestPoints = latestGameweekPoints > 0 ? latestGameweekPoints : (element.eventPoints ?? 0)

        var statusUpdates: [FantasyPlayerDetailsData.StatusUpdate] = []
        var seenStatusMessages = Set<String>()

        func appendStatus(
            _ message: String,
            severity: FantasyPlayerDetailsData.StatusSeverity
        ) {
            let normalized = message
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !normalized.isEmpty else { return }
            guard !seenStatusMessages.contains(normalized) else { return }
            seenStatusMessages.insert(normalized)
            statusUpdates.append(
                FantasyPlayerDetailsData.StatusUpdate(
                    message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                    severity: severity
                )
            )
        }

        if let chance = element.chanceOfPlayingNextRound, chance < 100 {
            if chance == 0 {
                appendStatus("Unavailable - 0% chance of playing", severity: .warning)
            } else {
                appendStatus("Knock - \(chance)% chance of playing", severity: .warning)
            }
        }
        let news = (element.news ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !news.isEmpty {
            appendStatus(news, severity: .warning)
        }

        let fixtureEventIDs = Set(summary.fixtures.compactMap(\.event))
        let upcomingGameweekRange = (gameweekID + 1)...(gameweekID + 5)
        if let firstBlankGameweek = upcomingGameweekRange.first(where: { !fixtureEventIDs.contains($0) }) {
            appendStatus(
                "This player currently has no Premier League fixture in Gameweek \(firstBlankGameweek).",
                severity: .info
            )
        }

        let upcomingCandidates: [FantasyElementSummaryFixture] = summary.fixtures
            .filter { fixture in
                guard let event = fixture.event else { return false }
                if event <= gameweekID { return false }
                if fixture.finished == true { return false }
                return true
            }
            .sorted { lhs, rhs in
                let leftEvent = lhs.event ?? Int.max
                let rightEvent = rhs.event ?? Int.max
                if leftEvent != rightEvent {
                    return leftEvent < rightEvent
                }
                return (lhs.kickoffTime ?? "") < (rhs.kickoffTime ?? "")
            }

        let upcomingByGameweek: [Int: FantasyElementSummaryFixture] = Dictionary(
            upcomingCandidates.compactMap { fixture in
                guard let event = fixture.event else { return nil }
                return (event, fixture)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let upcoming: [FantasyPlayerDetailsData.UpcomingFixture] = upcomingGameweekRange.map { gw in
            guard
                let fixture = upcomingByGameweek[gw],
                let resolvedOpponentTeam = resolveOpponentTeamID(
                    fixture: fixture,
                    playerTeamID: element.team
                )
            else {
                return FantasyPlayerDetailsData.UpcomingFixture(
                    gameweek: gw,
                    opponentTeamID: nil,
                    opponentTeamName: "No game",
                    isHome: nil,
                    difficulty: nil,
                    isBlank: true
                )
            }

            return FantasyPlayerDetailsData.UpcomingFixture(
                gameweek: gw,
                opponentTeamID: resolvedOpponentTeam,
                opponentTeamName: teamsByID[resolvedOpponentTeam]?.name ?? "Unknown",
                isHome: fixture.isHome ?? true,
                difficulty: fixture.difficulty ?? 3,
                isBlank: false
            )
        }

        let metrics: [FantasyPlayerDetailsData.Metric] = [
            .init(title: "Price", value: formatPrice(element.nowCost)),
            .init(title: "Form", value: formatDecimalString(element.form)),
            .init(title: "Pts / Match", value: formatDecimalString(element.pointsPerGame)),
            .init(title: "Latest GW Pts", value: "\(resolvedLatestPoints)"),
            .init(title: "Total Pts", value: formatInt(element.totalPoints)),
            .init(title: "Total Bonus", value: formatInt(element.bonus)),
            .init(title: "ICT Index", value: formatDecimalString(element.ictIndex)),
            .init(title: "TSB %", value: formatPercent(element.selectedByPercent))
        ]

        let sortedHistoryForLookup = sortedHistory.sorted { lhs, rhs in
            if lhs.round != rhs.round {
                return lhs.round > rhs.round
            }
            return (lhs.kickoffTime ?? "") > (rhs.kickoffTime ?? "")
        }
        let recentGameweeks = stride(from: gameweekID, through: max(1, gameweekID - 2), by: -1)
        let formItems = recentGameweeks.map { gw in
            guard let row = sortedHistoryForLookup.first(where: { $0.round == gw }) else {
                return FantasyPlayerDetailsData.FormItem(
                    gameweek: gw,
                    opponentTeamID: nil,
                    opponentTeamName: "No game",
                    wasHome: nil,
                    points: nil,
                    isBlank: true
                )
            }

            return FantasyPlayerDetailsData.FormItem(
                gameweek: row.round,
                opponentTeamID: row.opponentTeam,
                opponentTeamName: teamsByID[row.opponentTeam]?.name ?? "Unknown",
                wasHome: row.wasHome,
                points: row.totalPoints,
                isBlank: false
            )
        }

        let historyRows = Array(sortedHistory.prefix(10)).map { row in
            FantasyPlayerDetailsData.HistoryRow(
                gameweek: row.round,
                opponentTeamID: row.opponentTeam,
                opponentTeamName: teamsByID[row.opponentTeam]?.name ?? "Unknown",
                wasHome: row.wasHome,
                points: row.totalPoints,
                starts: row.starts,
                minutes: row.minutes,
                goalsScored: row.goalsScored,
                assists: row.assists,
                expectedGoals: formatDecimalString(row.expectedGoals)
            )
        }

        let fullName = "\(element.firstName) \(element.secondName)".trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPlayerName = fullName.isEmpty ? element.webName : fullName

        return FantasyPlayerDetailsData(
            elementID: elementID,
            playerName: resolvedPlayerName,
            teamName: teamName,
            teamID: element.team,
            position: position,
            statusUpdates: statusUpdates,
            metrics: metrics,
            formItems: formItems,
            upcomingFixtures: Array(upcoming),
            historyRows: historyRows
        )
    }

    private static func formatPrice(_ raw: Int?) -> String {
        guard let raw else { return "-" }
        return String(format: "£%.1fm", Double(raw) / 10.0)
    }

    private static func formatInt(_ value: Int?) -> String {
        guard let value else { return "-" }
        return "\(value)"
    }

    private static func formatDecimalString(_ value: String?) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "-" : trimmed
    }

    private static func formatPercent(_ value: String?) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "-" }
        return "\(trimmed)%"
    }

    private static func resolveOpponentTeamID(
        fixture: FantasyElementSummaryFixture,
        playerTeamID: Int
    ) -> Int? {
        if let opponentTeam = fixture.opponentTeam {
            return opponentTeam
        }
        if let isHome = fixture.isHome {
            if isHome {
                return fixture.teamA
            }
            return fixture.teamH
        }
        if let teamH = fixture.teamH, let teamA = fixture.teamA {
            return teamH == playerTeamID ? teamA : (teamA == playerTeamID ? teamH : nil)
        }
        return nil
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
