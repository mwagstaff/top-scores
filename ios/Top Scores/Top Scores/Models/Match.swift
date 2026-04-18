import Foundation

struct MatchGoalScorer: Codable, Hashable, Sendable {
    let player: String
    let goalTimes: [String]
    let ownGoalTimes: [String]
    let disallowedGoalTimes: [String]

    init(player: String, goalTimes: [String], ownGoalTimes: [String] = [], disallowedGoalTimes: [String] = []) {
        self.player = player
        self.goalTimes = goalTimes
        self.ownGoalTimes = ownGoalTimes
        self.disallowedGoalTimes = disallowedGoalTimes
    }

    enum CodingKeys: String, CodingKey {
        case player
        case goalTimes = "goal_times"
        case ownGoalTimes = "own_goal_times"
        case disallowedGoalTimes = "disallowed_goal_times"
    }

    private enum AlternateCodingKeys: String, CodingKey {
        case playerName = "player_name"
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decodedPlayer = try container.decodeIfPresent(String.self, forKey: .player) {
            player = decodedPlayer
        } else {
            let alternate = try decoder.container(keyedBy: AlternateCodingKeys.self)
            player = try alternate.decodeIfPresent(String.self, forKey: .playerName) ?? ""
        }
        goalTimes = try container.decodeIfPresent([String].self, forKey: .goalTimes) ?? []
        ownGoalTimes = try container.decodeIfPresent([String].self, forKey: .ownGoalTimes) ?? []
        disallowedGoalTimes = try container.decodeIfPresent([String].self, forKey: .disallowedGoalTimes) ?? []
    }

    nonisolated static func == (lhs: MatchGoalScorer, rhs: MatchGoalScorer) -> Bool {
        lhs.player == rhs.player &&
        lhs.goalTimes == rhs.goalTimes &&
        lhs.ownGoalTimes == rhs.ownGoalTimes &&
        lhs.disallowedGoalTimes == rhs.disallowedGoalTimes
    }
}

struct MatchAssistProvider: Codable, Hashable, Sendable {
    let player: String
    let assistTimes: [String]

    init(player: String, assistTimes: [String]) {
        self.player = player
        self.assistTimes = assistTimes
    }

    enum CodingKeys: String, CodingKey {
        case player
        case assistTimes = "assist_times"
    }

    private enum AlternateCodingKeys: String, CodingKey {
        case playerName = "player_name"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decodedPlayer = try container.decodeIfPresent(String.self, forKey: .player) {
            player = decodedPlayer
        } else {
            let alternate = try decoder.container(keyedBy: AlternateCodingKeys.self)
            player = try alternate.decodeIfPresent(String.self, forKey: .playerName) ?? ""
        }
        assistTimes = try container.decodeIfPresent([String].self, forKey: .assistTimes) ?? []
    }

    nonisolated static func == (lhs: MatchAssistProvider, rhs: MatchAssistProvider) -> Bool {
        lhs.player == rhs.player &&
        lhs.assistTimes == rhs.assistTimes
    }
}

struct MatchRedCardEvent: Codable, Hashable, Sendable {
    let player: String
    let redCardTimes: [String]

    init(player: String, redCardTimes: [String]) {
        self.player = player
        self.redCardTimes = redCardTimes
    }

    enum CodingKeys: String, CodingKey {
        case player
        case redCardTimes = "red_card_times"
    }

    private enum AlternateCodingKeys: String, CodingKey {
        case playerName = "player_name"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decodedPlayer = try container.decodeIfPresent(String.self, forKey: .player) {
            player = decodedPlayer
        } else {
            let alternate = try decoder.container(keyedBy: AlternateCodingKeys.self)
            player = try alternate.decodeIfPresent(String.self, forKey: .playerName) ?? ""
        }
        redCardTimes = try container.decodeIfPresent([String].self, forKey: .redCardTimes) ?? []
    }

    nonisolated static func == (lhs: MatchRedCardEvent, rhs: MatchRedCardEvent) -> Bool {
        lhs.player == rhs.player &&
        lhs.redCardTimes == rhs.redCardTimes
    }
}

struct MatchYellowCardEvent: Codable, Hashable, Sendable {
    let player: String
    let yellowCardTimes: [String]

    init(player: String, yellowCardTimes: [String]) {
        self.player = player
        self.yellowCardTimes = yellowCardTimes
    }

    enum CodingKeys: String, CodingKey {
        case player
        case yellowCardTimes = "yellow_card_times"
    }

    private enum AlternateCodingKeys: String, CodingKey {
        case playerName = "player_name"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decodedPlayer = try container.decodeIfPresent(String.self, forKey: .player) {
            player = decodedPlayer
        } else {
            let alternate = try decoder.container(keyedBy: AlternateCodingKeys.self)
            player = try alternate.decodeIfPresent(String.self, forKey: .playerName) ?? ""
        }
        yellowCardTimes = try container.decodeIfPresent([String].self, forKey: .yellowCardTimes) ?? []
    }

    nonisolated static func == (lhs: MatchYellowCardEvent, rhs: MatchYellowCardEvent) -> Bool {
        lhs.player == rhs.player &&
        lhs.yellowCardTimes == rhs.yellowCardTimes
    }
}

struct MatchLineupPlayer: Codable, Hashable, Identifiable, Sendable {
    let number: Int
    let name: String
    let positionCategory: String?
    let formationRowIndex: Int?
    let formationSlotIndex: Int?
    let formationRowSize: Int?

    var id: String {
        "\(number)|\(normalizedNameKey)"
    }

    var normalizedNameKey: String {
        Self.normalizeName(name)
    }

    enum CodingKeys: String, CodingKey {
        case number
        case name
        case positionCategory = "position_category"
        case formationRowIndex = "formation_row_index"
        case formationSlotIndex = "formation_slot_index"
        case formationRowSize = "formation_row_size"
    }

    private static func normalizeName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "(c)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .joined(separator: " ")
    }

    nonisolated static func == (lhs: MatchLineupPlayer, rhs: MatchLineupPlayer) -> Bool {
        lhs.number == rhs.number &&
        lhs.name == rhs.name &&
        lhs.positionCategory == rhs.positionCategory &&
        lhs.formationRowIndex == rhs.formationRowIndex &&
        lhs.formationSlotIndex == rhs.formationSlotIndex &&
        lhs.formationRowSize == rhs.formationRowSize
    }
}

struct MatchLineupSubstitution: Codable, Hashable, Identifiable, Sendable {
    let minute: String
    let playerOff: MatchLineupPlayer
    let playerOn: MatchLineupPlayer

    var id: String {
        "\(playerOff.id)|\(playerOn.id)|\(minute)"
    }

    enum CodingKeys: String, CodingKey {
        case minute
        case playerOff = "player_off"
        case playerOn = "player_on"
    }

    nonisolated static func == (lhs: MatchLineupSubstitution, rhs: MatchLineupSubstitution) -> Bool {
        lhs.minute == rhs.minute &&
        lhs.playerOff == rhs.playerOff &&
        lhs.playerOn == rhs.playerOn
    }
}

struct MatchTeamLineup: Codable, Hashable, Sendable {
    let team: String?
    let manager: String?
    let formation: String?
    let startingLineup: [MatchLineupPlayer]
    let substitutes: [MatchLineupPlayer]
    let substitutions: [MatchLineupSubstitution]

    enum CodingKeys: String, CodingKey {
        case team
        case manager
        case formation
        case startingLineup = "starting_lineup"
        case substitutes
        case substitutions
    }

    nonisolated static func == (lhs: MatchTeamLineup, rhs: MatchTeamLineup) -> Bool {
        lhs.team == rhs.team &&
        lhs.manager == rhs.manager &&
        lhs.formation == rhs.formation &&
        lhs.startingLineup == rhs.startingLineup &&
        lhs.substitutes == rhs.substitutes &&
        lhs.substitutions == rhs.substitutions
    }
}

struct MatchTeamLineups: Codable, Hashable, Sendable {
    let home: MatchTeamLineup?
    let away: MatchTeamLineup?

    nonisolated static func == (lhs: MatchTeamLineups, rhs: MatchTeamLineups) -> Bool {
        lhs.home == rhs.home &&
        lhs.away == rhs.away
    }
}

struct MatchDetailsPayload: Codable, Hashable, Sendable {
    let id: String
    let detailsURL: String?
    let date: String?
    let time: String?
    let league: String?
    let homeTeam: String?
    let awayTeam: String?
    let homeShortName: String?
    let awayShortName: String?
    let homeScore: Int?
    let awayScore: Int?
    let aggregateHomeScore: Int?
    let aggregateAwayScore: Int?
    let firstLegHomeScore: Int?
    let firstLegAwayScore: Int?
    let scoreStatus: String?
    let homeGoalScorers: [MatchGoalScorer]
    let awayGoalScorers: [MatchGoalScorer]
    let homeAssists: [MatchAssistProvider]
    let awayAssists: [MatchAssistProvider]
    let homeYellowCards: [MatchYellowCardEvent]
    let awayYellowCards: [MatchYellowCardEvent]
    let homeRedCards: [MatchRedCardEvent]
    let awayRedCards: [MatchRedCardEvent]
    let teamLineups: MatchTeamLineups?
    let penaltyResult: String?
    let inProgress: Bool?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case detailsURL = "details_url"
        case date
        case time
        case league
        case homeTeam = "home_team"
        case awayTeam = "away_team"
        case homeShortName = "home_short_name"
        case awayShortName = "away_short_name"
        case homeScore = "home_score"
        case awayScore = "away_score"
        case aggregateHomeScore = "aggregate_home_score"
        case aggregateAwayScore = "aggregate_away_score"
        case firstLegHomeScore = "first_leg_home_score"
        case firstLegAwayScore = "first_leg_away_score"
        case scoreStatus = "score_status"
        case homeGoalScorers = "home_goal_scorers"
        case awayGoalScorers = "away_goal_scorers"
        case homeAssists = "home_assists"
        case awayAssists = "away_assists"
        case homeYellowCards = "home_yellow_cards"
        case awayYellowCards = "away_yellow_cards"
        case homeRedCards = "home_red_cards"
        case awayRedCards = "away_red_cards"
        case teamLineups = "team_lineups"
        case penaltyResult = "penalty_result"
        case inProgress = "in_progress"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        detailsURL = try container.decodeIfPresent(String.self, forKey: .detailsURL)
        date = try container.decodeIfPresent(String.self, forKey: .date)
        time = try container.decodeIfPresent(String.self, forKey: .time)
        league = try container.decodeIfPresent(String.self, forKey: .league)
        homeTeam = try container.decodeIfPresent(String.self, forKey: .homeTeam)
        awayTeam = try container.decodeIfPresent(String.self, forKey: .awayTeam)
        homeShortName = try container.decodeIfPresent(String.self, forKey: .homeShortName)
        awayShortName = try container.decodeIfPresent(String.self, forKey: .awayShortName)
        homeScore = try container.decodeIfPresent(Int.self, forKey: .homeScore)
        awayScore = try container.decodeIfPresent(Int.self, forKey: .awayScore)
        aggregateHomeScore = try container.decodeIfPresent(Int.self, forKey: .aggregateHomeScore)
        aggregateAwayScore = try container.decodeIfPresent(Int.self, forKey: .aggregateAwayScore)
        firstLegHomeScore = try container.decodeIfPresent(Int.self, forKey: .firstLegHomeScore)
        firstLegAwayScore = try container.decodeIfPresent(Int.self, forKey: .firstLegAwayScore)
        scoreStatus = try container.decodeIfPresent(String.self, forKey: .scoreStatus)
        homeGoalScorers = try container.decodeIfPresent([MatchGoalScorer].self, forKey: .homeGoalScorers) ?? []
        awayGoalScorers = try container.decodeIfPresent([MatchGoalScorer].self, forKey: .awayGoalScorers) ?? []
        homeAssists = try container.decodeIfPresent([MatchAssistProvider].self, forKey: .homeAssists) ?? []
        awayAssists = try container.decodeIfPresent([MatchAssistProvider].self, forKey: .awayAssists) ?? []
        homeYellowCards = try container.decodeIfPresent([MatchYellowCardEvent].self, forKey: .homeYellowCards) ?? []
        awayYellowCards = try container.decodeIfPresent([MatchYellowCardEvent].self, forKey: .awayYellowCards) ?? []
        homeRedCards = try container.decodeIfPresent([MatchRedCardEvent].self, forKey: .homeRedCards) ?? []
        awayRedCards = try container.decodeIfPresent([MatchRedCardEvent].self, forKey: .awayRedCards) ?? []
        teamLineups = try container.decodeIfPresent(MatchTeamLineups.self, forKey: .teamLineups)
        penaltyResult = try container.decodeIfPresent(String.self, forKey: .penaltyResult)
        inProgress = try container.decodeIfPresent(Bool.self, forKey: .inProgress)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

struct Match: Identifiable, Codable, Hashable, Sendable {
    let date: String
    let time: String
    let homeTeam: String
    let awayTeam: String
    let homeShortName: String?
    let awayShortName: String?
    let league: String
    let leagueSubcategory: String?
    let detailsURL: String?
    let matchDetailsIDValue: String?
    let hasBbcSourceValue: Bool?
    let tvChannels: [String]
    let homeScore: Int?
    let awayScore: Int?
    let aggregateHomeScore: Int?
    let aggregateAwayScore: Int?
    let firstLegHomeScore: Int?
    let firstLegAwayScore: Int?
    let scoreStatus: String?
    let homeGoalScorers: [MatchGoalScorer]
    let awayGoalScorers: [MatchGoalScorer]
    let homeAssists: [MatchAssistProvider]
    let awayAssists: [MatchAssistProvider]
    let homeYellowCards: [MatchYellowCardEvent]
    let awayYellowCards: [MatchYellowCardEvent]
    let homeRedCards: [MatchRedCardEvent]
    let awayRedCards: [MatchRedCardEvent]
    let teamLineups: MatchTeamLineups?
    let penaltyResult: String?
    let isTestMatch: Bool?

    nonisolated init(
        date: String,
        time: String,
        homeTeam: String,
        awayTeam: String,
        homeShortName: String? = nil,
        awayShortName: String? = nil,
        league: String,
        leagueSubcategory: String? = nil,
        detailsURL: String? = nil,
        matchDetailsID: String? = nil,
        hasBbcSource: Bool? = nil,
        tvChannels: [String],
        homeScore: Int? = nil,
        awayScore: Int? = nil,
        aggregateHomeScore: Int? = nil,
        aggregateAwayScore: Int? = nil,
        firstLegHomeScore: Int? = nil,
        firstLegAwayScore: Int? = nil,
        scoreStatus: String? = nil,
        homeGoalScorers: [MatchGoalScorer] = [],
        awayGoalScorers: [MatchGoalScorer] = [],
        homeAssists: [MatchAssistProvider] = [],
        awayAssists: [MatchAssistProvider] = [],
        homeYellowCards: [MatchYellowCardEvent] = [],
        awayYellowCards: [MatchYellowCardEvent] = [],
        homeRedCards: [MatchRedCardEvent] = [],
        awayRedCards: [MatchRedCardEvent] = [],
        teamLineups: MatchTeamLineups? = nil,
        penaltyResult: String? = nil,
        isTestMatch: Bool? = nil
    ) {
        self.date = date
        self.time = time
        self.homeTeam = homeTeam
        self.awayTeam = awayTeam
        self.homeShortName = homeShortName
        self.awayShortName = awayShortName
        self.league = league
        self.leagueSubcategory = leagueSubcategory
        self.detailsURL = detailsURL
        self.matchDetailsIDValue = Self.normalizedMatchDetailsID(matchDetailsID)
        self.hasBbcSourceValue = hasBbcSource
        self.tvChannels = tvChannels
        self.homeScore = homeScore
        self.awayScore = awayScore
        self.aggregateHomeScore = aggregateHomeScore
        self.aggregateAwayScore = aggregateAwayScore
        self.firstLegHomeScore = firstLegHomeScore
        self.firstLegAwayScore = firstLegAwayScore
        self.scoreStatus = scoreStatus
        self.homeGoalScorers = homeGoalScorers
        self.awayGoalScorers = awayGoalScorers
        self.homeAssists = homeAssists
        self.awayAssists = awayAssists
        self.homeYellowCards = homeYellowCards
        self.awayYellowCards = awayYellowCards
        self.homeRedCards = homeRedCards
        self.awayRedCards = awayRedCards
        self.teamLineups = teamLineups
        self.penaltyResult = penaltyResult
        self.isTestMatch = isTestMatch
    }

    nonisolated var id: String {
        "\(date)|\(time)|\(league)|\(homeTeam)|\(awayTeam)"
    }

    nonisolated var displayHomeTeam: String {
        let trimmed = homeShortName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? homeTeam : trimmed
    }

    nonisolated var displayAwayTeam: String {
        let trimmed = awayShortName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? awayTeam : trimmed
    }

    nonisolated var dateTime: Date? {
        MatchDateParser.parse(date: date, time: time)
    }

    nonisolated var matchDetailsID: String? {
        if let explicit = Self.normalizedMatchDetailsID(matchDetailsIDValue) {
            return explicit
        }
        return Self.matchDetailsID(from: detailsURL)
    }

    nonisolated var hasBbcMatchEntry: Bool {
        hasBbcSourceValue == true ||
            matchDetailsID != nil ||
            tvChannels.contains { $0.caseInsensitiveCompare("BBC Sport Website") == .orderedSame }
    }

    nonisolated var dateOnly: Date? {
        MatchDateParser.parse(date: date, time: "00:00")
    }

    nonisolated var hasScore: Bool {
        homeScore != nil && awayScore != nil
    }

    var scoreLine: String? {
        guard let homeScore, let awayScore else { return nil }
        return "\(homeScore) - \(awayScore)"
    }

    var hasAggregateScore: Bool {
        resolvedAggregateScore != nil
    }

    nonisolated var hasKnownAggregateScore: Bool {
        resolvedAggregateScore != nil
    }

    nonisolated var hasDisplayableAggregateScore: Bool {
        hasKnownAggregateScore
    }

    var shouldShowAggregateBracketScoresInline: Bool {
        isUpcomingScorelessFixture && hasDisplayableAggregateScore
    }

    var resolvedAggregateHomeScore: Int? {
        resolvedAggregateScore?.home
    }

    var resolvedAggregateAwayScore: Int? {
        resolvedAggregateScore?.away
    }

    var aggregateSummaryText: String? {
        guard let aggregate = resolvedAggregateScore else { return nil }
        let aggregateHomeScore = aggregate.home
        let aggregateAwayScore = aggregate.away
        return "Agg: \(aggregateHomeScore)-\(aggregateAwayScore)"
    }

    var winnerSummaryText: String? {
        if let penaltyWinnerSummary = penaltyWinnerSummaryText {
            return penaltyWinnerSummary
        }

        if let aggregateWinnerSummary = aggregateWinnerSummaryText {
            return aggregateWinnerSummary
        }

        guard stabilizedScoreStatus() == "AET",
              let homeScore,
              let awayScore,
              homeScore != awayScore
        else {
            return nil
        }

        let winner = homeScore > awayScore ? homeTeam : awayTeam
        return "\(winner) win \(homeScore) - \(awayScore) after extra time"
    }

    var displayScoreStatus: String? {
        if let penaltyDisplayScoreText {
            return penaltyDisplayScoreText
        }
        guard let scoreStatus = stabilizedScoreStatus() else { return nil }
        return MatchStatusFormatter.displayValue(for: scoreStatus)
    }

    nonisolated var isInProgress: Bool {
        guard let scoreStatus = stabilizedScoreStatus() else { return false }
        return MatchStatusFormatter.isInProgress(scoreStatus)
    }

    nonisolated var isFinished: Bool {
        guard let scoreStatus = stabilizedScoreStatus() else { return false }
        return MatchStatusFormatter.isFinished(scoreStatus)
    }

    nonisolated var isPostponed: Bool {
        MatchStatusFormatter.isPostponed(scoreStatus)
    }

    nonisolated var isUpcomingScorelessFixture: Bool {
        if isPostponed {
            return false
        }
        return Self.isUpcomingScorelessFixture(
            date: date,
            time: time,
            homeScore: homeScore,
            awayScore: awayScore,
            scoreStatus: scoreStatus,
            inProgress: nil
        )
    }

    nonisolated var displayLeague: String {
        let baseLeague = CompetitionWeightConfig.displayBaseCompetitionName(league)
        if let subcategory = leagueSubcategory, !subcategory.isEmpty {
            return "\(baseLeague): \(subcategory)"
        }
        return baseLeague
    }

    func withScore(
        home: Int,
        away: Int,
        status: String?,
        aggregateHome: Int? = nil,
        aggregateAway: Int? = nil
    ) -> Match {
        let nextAggregateHome = aggregateHome ?? adjustedAggregate(
            base: resolvedAggregateHomeScore,
            previousScore: homeScore,
            nextScore: home
        )
        let nextAggregateAway = aggregateAway ?? adjustedAggregate(
            base: resolvedAggregateAwayScore,
            previousScore: awayScore,
            nextScore: away
        )

        return Match(
            date: date,
            time: time,
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            homeShortName: homeShortName,
            awayShortName: awayShortName,
            league: league,
            leagueSubcategory: leagueSubcategory,
            detailsURL: detailsURL,
            matchDetailsID: matchDetailsIDValue,
            hasBbcSource: hasBbcSourceValue,
            tvChannels: tvChannels,
            homeScore: home,
            awayScore: away,
            aggregateHomeScore: nextAggregateHome,
            aggregateAwayScore: nextAggregateAway,
            firstLegHomeScore: firstLegHomeScore,
            firstLegAwayScore: firstLegAwayScore,
            scoreStatus: status,
            homeGoalScorers: homeGoalScorers,
            awayGoalScorers: awayGoalScorers,
            homeAssists: homeAssists,
            awayAssists: awayAssists,
            homeYellowCards: homeYellowCards,
            awayYellowCards: awayYellowCards,
            homeRedCards: homeRedCards,
            awayRedCards: awayRedCards,
            teamLineups: teamLineups,
            penaltyResult: penaltyResult,
            isTestMatch: isTestMatch
        )
    }

    func withTvChannels(_ channels: [String]) -> Match {
        Match(
            date: date,
            time: time,
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            homeShortName: homeShortName,
            awayShortName: awayShortName,
            league: league,
            leagueSubcategory: leagueSubcategory,
            detailsURL: detailsURL,
            matchDetailsID: matchDetailsIDValue,
            hasBbcSource: hasBbcSourceValue,
            tvChannels: channels,
            homeScore: homeScore,
            awayScore: awayScore,
            aggregateHomeScore: aggregateHomeScore,
            aggregateAwayScore: aggregateAwayScore,
            firstLegHomeScore: firstLegHomeScore,
            firstLegAwayScore: firstLegAwayScore,
            scoreStatus: scoreStatus,
            homeGoalScorers: homeGoalScorers,
            awayGoalScorers: awayGoalScorers,
            homeAssists: homeAssists,
            awayAssists: awayAssists,
            homeYellowCards: homeYellowCards,
            awayYellowCards: awayYellowCards,
            homeRedCards: homeRedCards,
            awayRedCards: awayRedCards,
            teamLineups: teamLineups,
            penaltyResult: penaltyResult,
            isTestMatch: isTestMatch
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        time = try container.decode(String.self, forKey: .time)
        homeTeam = try container.decode(String.self, forKey: .homeTeam)
        awayTeam = try container.decode(String.self, forKey: .awayTeam)
        homeShortName = try container.decodeIfPresent(String.self, forKey: .homeShortName)
        awayShortName = try container.decodeIfPresent(String.self, forKey: .awayShortName)
        league = try container.decode(String.self, forKey: .league)
        leagueSubcategory = try container.decodeIfPresent(String.self, forKey: .leagueSubcategory)
        detailsURL = try container.decodeIfPresent(String.self, forKey: .detailsURL)
        matchDetailsIDValue = Self.normalizedMatchDetailsID(
            try container.decodeIfPresent(String.self, forKey: .matchDetailsIDValue)
        )
        hasBbcSourceValue = try container.decodeIfPresent(Bool.self, forKey: .hasBbcSourceValue)
        tvChannels = try container.decodeIfPresent([String].self, forKey: .tvChannels) ?? []
        homeScore = try container.decodeIfPresent(Int.self, forKey: .homeScore)
        awayScore = try container.decodeIfPresent(Int.self, forKey: .awayScore)
        aggregateHomeScore = try container.decodeIfPresent(Int.self, forKey: .aggregateHomeScore)
        aggregateAwayScore = try container.decodeIfPresent(Int.self, forKey: .aggregateAwayScore)
        firstLegHomeScore = try container.decodeIfPresent(Int.self, forKey: .firstLegHomeScore)
        firstLegAwayScore = try container.decodeIfPresent(Int.self, forKey: .firstLegAwayScore)
        scoreStatus = try container.decodeIfPresent(String.self, forKey: .scoreStatus)
        homeGoalScorers = try container.decodeIfPresent([MatchGoalScorer].self, forKey: .homeGoalScorers) ?? []
        awayGoalScorers = try container.decodeIfPresent([MatchGoalScorer].self, forKey: .awayGoalScorers) ?? []
        homeAssists = try container.decodeIfPresent([MatchAssistProvider].self, forKey: .homeAssists) ?? []
        awayAssists = try container.decodeIfPresent([MatchAssistProvider].self, forKey: .awayAssists) ?? []
        homeYellowCards = try container.decodeIfPresent([MatchYellowCardEvent].self, forKey: .homeYellowCards) ?? []
        awayYellowCards = try container.decodeIfPresent([MatchYellowCardEvent].self, forKey: .awayYellowCards) ?? []
        homeRedCards = try container.decodeIfPresent([MatchRedCardEvent].self, forKey: .homeRedCards) ?? []
        awayRedCards = try container.decodeIfPresent([MatchRedCardEvent].self, forKey: .awayRedCards) ?? []
        teamLineups = try container.decodeIfPresent(MatchTeamLineups.self, forKey: .teamLineups)
        penaltyResult = try container.decodeIfPresent(String.self, forKey: .penaltyResult)
        isTestMatch = try container.decodeIfPresent(Bool.self, forKey: .isTestMatch)

    }

    enum CodingKeys: String, CodingKey {
        case date
        case time
        case homeTeam = "home_team"
        case awayTeam = "away_team"
        case homeShortName = "home_short_name"
        case awayShortName = "away_short_name"
        case league
        case leagueSubcategory = "league_subcategory"
        case detailsURL = "details_url"
        case matchDetailsIDValue = "match_details_id"
        case hasBbcSourceValue = "has_bbc_source"
        case tvChannels = "tv_channels"
        case homeScore = "home_score"
        case awayScore = "away_score"
        case aggregateHomeScore = "aggregate_home_score"
        case aggregateAwayScore = "aggregate_away_score"
        case firstLegHomeScore = "first_leg_home_score"
        case firstLegAwayScore = "first_leg_away_score"
        case scoreStatus = "score_status"
        case homeGoalScorers = "home_goal_scorers"
        case awayGoalScorers = "away_goal_scorers"
        case homeAssists = "home_assists"
        case awayAssists = "away_assists"
        case homeYellowCards = "home_yellow_cards"
        case awayYellowCards = "away_yellow_cards"
        case homeRedCards = "home_red_cards"
        case awayRedCards = "away_red_cards"
        case teamLineups = "team_lineups"
        case penaltyResult = "penalty_result"
        case isTestMatch = "is_test_match"
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(time, forKey: .time)
        try container.encode(homeTeam, forKey: .homeTeam)
        try container.encode(awayTeam, forKey: .awayTeam)
        try container.encodeIfPresent(homeShortName, forKey: .homeShortName)
        try container.encodeIfPresent(awayShortName, forKey: .awayShortName)
        try container.encode(league, forKey: .league)
        try container.encodeIfPresent(leagueSubcategory, forKey: .leagueSubcategory)
        try container.encodeIfPresent(detailsURL, forKey: .detailsURL)
        try container.encodeIfPresent(matchDetailsIDValue, forKey: .matchDetailsIDValue)
        try container.encodeIfPresent(hasBbcSourceValue, forKey: .hasBbcSourceValue)
        try container.encode(tvChannels, forKey: .tvChannels)
        try container.encodeIfPresent(homeScore, forKey: .homeScore)
        try container.encodeIfPresent(awayScore, forKey: .awayScore)
        try container.encodeIfPresent(aggregateHomeScore, forKey: .aggregateHomeScore)
        try container.encodeIfPresent(aggregateAwayScore, forKey: .aggregateAwayScore)
        try container.encodeIfPresent(firstLegHomeScore, forKey: .firstLegHomeScore)
        try container.encodeIfPresent(firstLegAwayScore, forKey: .firstLegAwayScore)
        try container.encodeIfPresent(scoreStatus, forKey: .scoreStatus)
        try container.encode(homeGoalScorers, forKey: .homeGoalScorers)
        try container.encode(awayGoalScorers, forKey: .awayGoalScorers)
        try container.encode(homeAssists, forKey: .homeAssists)
        try container.encode(awayAssists, forKey: .awayAssists)
        try container.encode(homeYellowCards, forKey: .homeYellowCards)
        try container.encode(awayYellowCards, forKey: .awayYellowCards)
        try container.encode(homeRedCards, forKey: .homeRedCards)
        try container.encode(awayRedCards, forKey: .awayRedCards)
        try container.encodeIfPresent(teamLineups, forKey: .teamLineups)
        try container.encodeIfPresent(penaltyResult, forKey: .penaltyResult)
        try container.encodeIfPresent(isTestMatch, forKey: .isTestMatch)
    }

    nonisolated static func == (lhs: Match, rhs: Match) -> Bool {
        lhs.date == rhs.date &&
        lhs.time == rhs.time &&
        lhs.homeTeam == rhs.homeTeam &&
        lhs.awayTeam == rhs.awayTeam &&
        lhs.homeShortName == rhs.homeShortName &&
        lhs.awayShortName == rhs.awayShortName &&
        lhs.league == rhs.league &&
        lhs.leagueSubcategory == rhs.leagueSubcategory &&
        lhs.detailsURL == rhs.detailsURL &&
        lhs.matchDetailsIDValue == rhs.matchDetailsIDValue &&
        lhs.hasBbcSourceValue == rhs.hasBbcSourceValue &&
        lhs.tvChannels == rhs.tvChannels &&
        lhs.homeScore == rhs.homeScore &&
        lhs.awayScore == rhs.awayScore &&
        lhs.aggregateHomeScore == rhs.aggregateHomeScore &&
        lhs.aggregateAwayScore == rhs.aggregateAwayScore &&
        lhs.firstLegHomeScore == rhs.firstLegHomeScore &&
        lhs.firstLegAwayScore == rhs.firstLegAwayScore &&
        lhs.scoreStatus == rhs.scoreStatus &&
        lhs.homeGoalScorers == rhs.homeGoalScorers &&
        lhs.awayGoalScorers == rhs.awayGoalScorers &&
        lhs.homeAssists == rhs.homeAssists &&
        lhs.awayAssists == rhs.awayAssists &&
        lhs.homeYellowCards == rhs.homeYellowCards &&
        lhs.awayYellowCards == rhs.awayYellowCards &&
        lhs.homeRedCards == rhs.homeRedCards &&
        lhs.awayRedCards == rhs.awayRedCards &&
        lhs.teamLineups == rhs.teamLineups &&
        lhs.penaltyResult == rhs.penaltyResult &&
        lhs.isTestMatch == rhs.isTestMatch
    }

    func withDetails(_ details: MatchDetailsPayload) -> Match {
        guard isCompatible(with: details) else {
            return self
        }

        let nextDate = details.date ?? date
        let nextTime = details.time ?? time
        let isPostponedStatus = MatchStatusFormatter.isPostponed(details.scoreStatus)
        let shouldClearScores = Self.isUpcomingScorelessFixture(
            date: nextDate,
            time: nextTime,
            homeScore: details.homeScore,
            awayScore: details.awayScore,
            scoreStatus: details.scoreStatus,
            inProgress: details.inProgress
        ) || isPostponedStatus
        let mergedScoreStatus = MatchStatusFormatter.preferredStatus(
            current: scoreStatus,
            incoming: details.scoreStatus
        )

        return Match(
            date: details.date ?? date,
            time: details.time ?? time,
            homeTeam: details.homeTeam ?? homeTeam,
            awayTeam: details.awayTeam ?? awayTeam,
            homeShortName: details.homeShortName ?? homeShortName,
            awayShortName: details.awayShortName ?? awayShortName,
            league: details.league ?? league,
            leagueSubcategory: leagueSubcategory,
            detailsURL: details.detailsURL ?? detailsURL,
            matchDetailsID: details.id,
            hasBbcSource: hasBbcSourceValue,
            tvChannels: tvChannels,
            homeScore: shouldClearScores ? nil : (details.homeScore ?? homeScore),
            awayScore: shouldClearScores ? nil : (details.awayScore ?? awayScore),
            aggregateHomeScore: details.aggregateHomeScore ?? aggregateHomeScore,
            aggregateAwayScore: details.aggregateAwayScore ?? aggregateAwayScore,
            firstLegHomeScore: details.firstLegHomeScore ?? firstLegHomeScore,
            firstLegAwayScore: details.firstLegAwayScore ?? firstLegAwayScore,
            scoreStatus: isPostponedStatus ? mergedScoreStatus : (shouldClearScores ? nil : mergedScoreStatus),
            homeGoalScorers: details.homeGoalScorers,
            awayGoalScorers: details.awayGoalScorers,
            homeAssists: details.homeAssists,
            awayAssists: details.awayAssists,
            homeYellowCards: details.homeYellowCards,
            awayYellowCards: details.awayYellowCards,
            homeRedCards: details.homeRedCards,
            awayRedCards: details.awayRedCards,
            teamLineups: details.teamLineups ?? teamLineups,
            penaltyResult: details.penaltyResult ?? penaltyResult,
            isTestMatch: isTestMatch
        )
    }

    func isCompatible(with details: MatchDetailsPayload) -> Bool {
        let detailsHome = details.homeTeam?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let detailsAway = details.awayTeam?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !detailsHome.isEmpty, !detailsAway.isEmpty else {
            return false
        }

        guard TeamIdentityStore.shared.matches(homeTeam, detailsHome),
              TeamIdentityStore.shared.matches(awayTeam, detailsAway)
        else {
            return false
        }

        if let detailsDate = Self.normalizedLookupDate(details.date), detailsDate != date {
            return false
        }

        if let detailsTime = Self.normalizedLookupTime(details.time),
           !lookupTimesAreComparable(detailsTime, Self.normalizedLookupTime(time) ?? "00:00") {
            return false
        }

        return true
    }

    nonisolated func stabilizedScoreStatus(now: Date = Date()) -> String? {
        MatchStatusFormatter.stabilizedStatus(
            scoreStatus,
            kickoff: dateTime,
            hasScore: hasScore,
            now: now
        )
    }

    private nonisolated static func matchDetailsID(from detailsURL: String?) -> String? {
        guard let detailsURL else { return nil }
        guard let parsed = URL(string: detailsURL) else { return nil }
        let path = parsed.path.lowercased()
        guard path.contains("/football/") else { return nil }
        guard let last = path.split(separator: "/").last else { return nil }
        let id = String(last)
        guard !id.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics
        guard id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return id.lowercased()
    }

    private nonisolated static func normalizedMatchDetailsID(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics
        guard normalized.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return normalized
    }

    private nonisolated static func normalizedLookupDate(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return Self.dateOnlyPattern.firstMatch(in: normalized, options: [], range: NSRange(location: 0, length: normalized.utf16.count)) != nil
            ? normalized
            : nil
    }

    private nonisolated static func normalizedLookupTime(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return Self.timeOnlyPattern.firstMatch(in: normalized, options: [], range: NSRange(location: 0, length: normalized.utf16.count)) != nil
            ? normalized
            : nil
    }

    private nonisolated static func lookupTimeMinutes(_ value: String) -> Int? {
        let components = value.split(separator: ":")
        guard components.count == 2,
              let hours = Int(components[0]),
              let minutes = Int(components[1]),
              (0 ... 23).contains(hours),
              (0 ... 59).contains(minutes)
        else {
            return nil
        }

        return (hours * 60) + minutes
    }

    private nonisolated static let dateOnlyPattern = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)
    private nonisolated static let timeOnlyPattern = try! NSRegularExpression(pattern: #"^\d{2}:\d{2}$"#)

    private func adjustedAggregate(base: Int?, previousScore: Int?, nextScore: Int) -> Int? {
        guard let base else { return nil }
        return base + (nextScore - (previousScore ?? 0))
    }

    private nonisolated var resolvedAggregateScore: (home: Int, away: Int)? {
        let explicitAggregate: (home: Int, away: Int)? = {
            guard let aggregateHomeScore, let aggregateAwayScore else { return nil }
            guard !shouldSuppressPreKickoffPlaceholderAggregate(
                home: aggregateHomeScore,
                away: aggregateAwayScore
            ) else {
                return nil
            }
            return (aggregateHomeScore, aggregateAwayScore)
        }()

        if let firstLegHomeScore, let firstLegAwayScore {
            if homeScore != nil || awayScore != nil {
                return (
                    firstLegHomeScore + (homeScore ?? 0),
                    firstLegAwayScore + (awayScore ?? 0)
                )
            }

            return (firstLegHomeScore, firstLegAwayScore)
        }

        return explicitAggregate
    }

    private nonisolated func shouldSuppressPreKickoffPlaceholderAggregate(home: Int, away: Int) -> Bool {
        isUpcomingScorelessFixture &&
        home == 0 &&
        away == 0 &&
        firstLegHomeScore == nil &&
        firstLegAwayScore == nil
    }

    private var penaltyWinnerSummaryText: String? {
        let trimmedPenaltyResult = penaltyResult?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedPenaltyResult, !trimmedPenaltyResult.isEmpty else {
            return nil
        }

        guard let scorePair = Self.firstScorePair(in: trimmedPenaltyResult) else {
            return trimmedPenaltyResult
        }

        let homeMentioned = Self.containsTeamName(homeTeam, in: trimmedPenaltyResult)
        let awayMentioned = Self.containsTeamName(awayTeam, in: trimmedPenaltyResult)
        let winner: String
        if homeMentioned != awayMentioned {
            winner = homeMentioned ? homeTeam : awayTeam
        } else if scorePair.0 == scorePair.1 {
            return trimmedPenaltyResult
        } else {
            winner = scorePair.0 > scorePair.1 ? homeTeam : awayTeam
        }

        return "\(winner) win \(scorePair.0) - \(scorePair.1) on penalties"
    }

    private var penaltyDisplayScoreText: String? {
        let trimmedPenaltyResult = penaltyResult?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedPenaltyResult, !trimmedPenaltyResult.isEmpty else {
            return nil
        }

        guard let scorePair = Self.firstScorePair(in: trimmedPenaltyResult) else {
            return nil
        }

        let homeMentioned = Self.containsTeamName(homeTeam, in: trimmedPenaltyResult)
        let awayMentioned = Self.containsTeamName(awayTeam, in: trimmedPenaltyResult)
        guard homeMentioned != awayMentioned else {
            return nil
        }

        let homePenaltyScore = homeMentioned ? scorePair.0 : scorePair.1
        let awayPenaltyScore = homeMentioned ? scorePair.1 : scorePair.0
        return "P \(homePenaltyScore)-\(awayPenaltyScore)"
    }

    private var aggregateWinnerSummaryText: String? {
        guard isFinished,
              let aggregate = resolvedAggregateScore,
              aggregate.home != aggregate.away
        else {
            return nil
        }

        let aggregateHomeScore = aggregate.home
        let aggregateAwayScore = aggregate.away
        let homeWins = aggregateHomeScore > aggregateAwayScore
        let winner = homeWins ? homeTeam : awayTeam
        let winnerScore = homeWins ? aggregateHomeScore : aggregateAwayScore
        let loserScore = homeWins ? aggregateAwayScore : aggregateHomeScore
        return "\(winner) win \(winnerScore) - \(loserScore) on aggregate"
    }

    private nonisolated static func isUpcomingScorelessFixture(
        date: String,
        time: String,
        homeScore: Int?,
        awayScore: Int?,
        scoreStatus: String?,
        inProgress: Bool?,
        now: Date = Date()
    ) -> Bool {
        guard homeScore == nil, awayScore == nil else { return false }
        guard inProgress != true else { return false }

        let normalizedStatus = scoreStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if let normalizedStatus, !normalizedStatus.isEmpty {
            if MatchStatusFormatter.isInProgress(normalizedStatus) ||
                MatchStatusFormatter.isFinished(normalizedStatus) {
                return false
            }
        }

        guard let kickoff = MatchDateParser.parse(date: date, time: time) else {
            return normalizedStatus == nil || normalizedStatus?.isEmpty == true
        }
        return kickoff.timeIntervalSince(now) > -(15 * 60)
    }

    private nonisolated static func containsTeamName(_ teamName: String, in text: String) -> Bool {
        let normalizedTeam = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTeam.isEmpty else { return false }
        return text.range(of: normalizedTeam, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private nonisolated static func firstScorePair(in text: String) -> (Int, Int)? {
        guard let range = text.range(
            of: #"(\d+)\s*[-–]\s*(\d+)"#,
            options: .regularExpression
        ) else {
            return nil
        }

        let matched = String(text[range])
        let numbers = matched
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }

        guard numbers.count >= 2 else { return nil }
        return (numbers[0], numbers[1])
    }
}

enum MatchStatusFormatter {
    private nonisolated static let inProgressTokens: Set<String> = ["HT", "ET", "LIVE", "PENS", "PEN", "PEN."]
    private nonisolated static let completeTokens: Set<String> = ["FT", "AET"]
    private nonisolated static let postponedTokens: Set<String> = ["POSTPONED", "MATCH POSTPONED"]
    private nonisolated static let minutePattern = #"^\d{1,3}(?:\+\d{1,2})?'?$"#
    private nonisolated static let penaltyProgressPattern = #"^P\s+(\d+)\s*-\s*(\d+)$"#
    private nonisolated static let maximumLiveWindow: TimeInterval = 3.5 * 60 * 60

    nonisolated static func displayValue(for rawStatus: String) -> String {
        let status = canonicalStatus(rawStatus) ?? normalized(rawStatus)
        guard !status.isEmpty else { return rawStatus }
        if isMinuteStatus(status) {
            let minuteValue = status.replacingOccurrences(of: "'", with: "")
            return "\(minuteValue)'"
        }
        if status == "POSTPONED" {
            return "Match postponed"
        }
        return status
    }

    nonisolated static func isInProgress(_ rawStatus: String) -> Bool {
        let status = canonicalStatus(rawStatus) ?? normalized(rawStatus)
        guard !status.isEmpty else { return false }
        if isMinuteStatus(status) { return true }
        if isPenaltyShootoutStatus(status) { return true }

        let token = status.uppercased()
        if completeTokens.contains(token) { return false }
        return inProgressTokens.contains(token)
    }

    nonisolated static func isFinished(_ rawStatus: String) -> Bool {
        let status = canonicalStatus(rawStatus) ?? normalized(rawStatus)
        guard !status.isEmpty else { return false }
        let token = status.uppercased()
        return completeTokens.contains(token)
    }

    nonisolated static func isPostponed(_ rawStatus: String?) -> Bool {
        canonicalStatus(rawStatus) == "POSTPONED"
    }

    nonisolated static func preferredStatus(current: String?, incoming: String?) -> String? {
        let currentStatus = normalizedStatus(current)
        let incomingStatus = normalizedStatus(incoming)

        guard let currentStatus else { return incomingStatus }
        guard let incomingStatus else { return currentStatus }

        let currentState = statusState(for: currentStatus)
        let incomingState = statusState(for: incomingStatus)

        switch (currentState, incomingState) {
        case (.postponed, .unknown):
            return currentStatus
        case (.unknown, .postponed):
            return incomingStatus
        case (.postponed, .postponed):
            return incomingStatus
        case (.postponed, _):
            return incomingStatus
        case (_, .postponed):
            return currentStatus
        case (.finished, .finished):
            if currentStatus == "AET" && incomingStatus == "FT" {
                return currentStatus
            }
            if incomingStatus == "AET" && currentStatus == "FT" {
                return incomingStatus
            }
            return incomingStatus
        case (.finished, _):
            return currentStatus
        case (_, .finished):
            return incomingStatus
        default:
            break
        }

        let currentPenalty = isPenaltyShootoutStatus(currentStatus)
        let incomingPenalty = isPenaltyShootoutStatus(incomingStatus)
        if currentPenalty, !incomingPenalty {
            return currentStatus
        }
        if incomingPenalty, !currentPenalty {
            return incomingStatus
        }
        if currentPenalty, incomingPenalty {
            return incomingStatus
        }

        let currentMinute = parseMatchTimeMinutes(currentStatus)
        let incomingMinute = parseMatchTimeMinutes(incomingStatus)
        if let currentMinute, let incomingMinute {
            return incomingMinute >= currentMinute ? incomingStatus : currentStatus
        }
        if currentMinute != nil || incomingMinute != nil {
            if let incomingMinute {
                if currentStatus == "LIVE" {
                    return incomingStatus
                }
                if currentStatus == "HT", isFirstHalfMinuteStatus(incomingStatus) {
                    return currentStatus
                }
                if currentStatus == "ET", incomingMinute <= 90 {
                    return currentStatus
                }
                return incomingStatus
            }

            if incomingStatus == "LIVE" {
                return currentStatus
            }
            if incomingStatus == "HT", !isFirstHalfMinuteStatus(currentStatus) {
                return currentStatus
            }
            if incomingStatus == "ET" || isPenaltyShootoutStatus(incomingStatus) {
                return incomingStatus
            }
            return incomingStatus
        }

        return incomingStatus
    }

    nonisolated static func prefersIncomingStatus(current: String?, incoming: String?) -> Bool {
        guard let incomingStatus = normalizedStatus(incoming) else { return false }
        return preferredStatus(current: current, incoming: incoming) == incomingStatus
    }

    nonisolated static func stabilizedStatus(
        _ rawStatus: String?,
        kickoff: Date?,
        hasScore: Bool,
        now: Date = Date()
    ) -> String? {
        guard let trimmed = canonicalStatus(rawStatus) else { return nil }

        guard hasScore, isInProgress(trimmed), let kickoff else {
            return trimmed
        }

        let elapsed = now.timeIntervalSince(kickoff)
        guard elapsed >= maximumLiveWindow else {
            return trimmed
        }

        return "FT"
    }

    nonisolated static func parseMatchTimeMinutes(_ matchTime: String?) -> Int? {
        guard let matchTime = matchTime?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }

        if let match = matchTime.range(of: #"^(\d+)(?:\+(\d+))?[']?$"#, options: .regularExpression) {
            let components = matchTime[match].split(separator: "+")
            let base = Int(components[0].trimmingCharacters(in: CharacterSet(charactersIn: "'"))) ?? 0
            let added = components.count > 1 ? Int(components[1].trimmingCharacters(in: CharacterSet(charactersIn: "'"))) ?? 0 : 0
            return base + added
        }
        if matchTime.range(of: penaltyProgressPattern, options: .regularExpression) != nil {
            return 120
        }

        let upper = matchTime.uppercased()
        if upper.contains("HT") || upper.contains("HALF") { return 45 }
        if upper.contains("FT") || upper.contains("FULL") { return 90 }
        if upper == "AET" { return 120 }
        if upper == "PENS" || upper == "PEN" || upper == "PEN." { return 120 }

        return nil
    }

    private nonisolated static func normalized(_ rawStatus: String) -> String {
        rawStatus.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func isMinuteStatus(_ status: String) -> Bool {
        status.range(of: minutePattern, options: .regularExpression) != nil
    }

    nonisolated static func normalizedStatus(_ value: String?) -> String? {
        canonicalStatus(value)
    }

    private nonisolated static func isFirstHalfMinuteStatus(_ status: String) -> Bool {
        guard let minute = parseMatchTimeMinutes(status) else { return false }
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isMinuteStatus(trimmed) else { return false }
        return minute <= 45
    }

    private nonisolated static func isPenaltyShootoutStatus(_ status: String) -> Bool {
        status == "PENS" ||
        status == "PEN" ||
        status == "PEN." ||
        status.range(of: penaltyProgressPattern, options: .regularExpression) != nil
    }

    private nonisolated static func trimmedStatus(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private nonisolated static func canonicalStatus(_ value: String?) -> String? {
        guard let value = trimmedStatus(value) else {
            return nil
        }
        if let match = value.range(of: penaltyProgressPattern, options: .regularExpression) {
            let parts = value[match]
                .split(whereSeparator: { !$0.isNumber })
                .map(String.init)
            if parts.count >= 2 {
                return "P \(parts[0])-\(parts[1])"
            }
        }
        let uppercased = value.uppercased()
        if postponedTokens.contains(uppercased) {
            return "POSTPONED"
        }
        return uppercased
    }

    private nonisolated static func statusState(for status: String) -> StatusState {
        if status == "POSTPONED" {
            return .postponed
        }
        if completeTokens.contains(status) {
            return .finished
        }
        if parseMatchTimeMinutes(status) != nil || inProgressTokens.contains(status) {
            return .inProgress
        }
        return .unknown
    }

    private enum StatusState: Sendable {
        case postponed
        case finished
        case inProgress
        case unknown
    }
}

enum MatchDateParser {
    private nonisolated static let parseCacheLock = NSLock()
    private nonisolated static let displayFormatterLock = NSLock()
    private nonisolated(unsafe) static var parsedDatesByKey: [String: Date] = [:]
    private nonisolated(unsafe) static var invalidParseKeys: Set<String> = []
    private nonisolated static let displayDateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone.current
        dateFormatter.dateFormat = "EEE, MMM d, yyyy"
        return dateFormatter
    }()

    nonisolated static func parse(date: String, time: String) -> Date? {
        let cacheKey = "\(date)|\(time)"
        parseCacheLock.lock()
        if let cached = parsedDatesByKey[cacheKey] {
            parseCacheLock.unlock()
            return cached
        }
        if invalidParseKeys.contains(cacheKey) {
            parseCacheLock.unlock()
            return nil
        }
        parseCacheLock.unlock()

        guard let (year, month, day) = parseDateComponents(date),
              let (hour, minute) = parseTimeComponents(time) else {
            parseCacheLock.lock()
            invalidParseKeys.insert(cacheKey)
            parseCacheLock.unlock()
            return nil
        }

        var components = DateComponents()
        components.calendar = Calendar.current
        components.timeZone = TimeZone.current
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        guard let resolved = components.date else {
            parseCacheLock.lock()
            invalidParseKeys.insert(cacheKey)
            parseCacheLock.unlock()
            return nil
        }

        parseCacheLock.lock()
        parsedDatesByKey[cacheKey] = resolved
        parseCacheLock.unlock()
        return resolved
    }

    nonisolated static func displayDate(_ date: Date) -> String {
        displayFormatterLock.lock()
        defer { displayFormatterLock.unlock() }
        return displayDateFormatter.string(from: date)
    }

    nonisolated static func displayDateWithRelative(_ date: Date) -> String {
        let base = displayDate(date)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "\(base) (Today)"
        }
        if calendar.isDateInTomorrow(date) {
            return "\(base) (Tomorrow)"
        }
        return base
    }

    private nonisolated static func parseDateComponents(_ value: String) -> (Int, Int, Int)? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }
        return (year, month, day)
    }

    private nonisolated static func parseTimeComponents(_ value: String) -> (Int, Int)? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else {
            return nil
        }
        return (hour, minute)
    }
}

private func lookupTimesAreComparable(_ lhs: String, _ rhs: String) -> Bool {
    if lhs == rhs || lhs == "00:00" || rhs == "00:00" {
        return true
    }

    guard let leftMinutes = lookupTimeMinutes(lhs), let rightMinutes = lookupTimeMinutes(rhs) else {
        return false
    }

    let minuteDelta = leftMinutes >= rightMinutes
        ? leftMinutes - rightMinutes
        : rightMinutes - leftMinutes
    return minuteDelta <= 120
}

private func lookupTimeMinutes(_ value: String) -> Int? {
    let components = value.split(separator: ":")
    guard components.count == 2,
          let hours = Int(components[0]),
          let minutes = Int(components[1]),
          (0 ... 23).contains(hours),
          (0 ... 59).contains(minutes)
    else {
        return nil
    }

    return (hours * 60) + minutes
}
