import Foundation

struct MatchGoalScorer: Codable, Hashable {
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

    init(from decoder: Decoder) throws {
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
}

struct MatchAssistProvider: Codable, Hashable {
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
}

struct MatchRedCardEvent: Codable, Hashable {
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
}

struct MatchYellowCardEvent: Codable, Hashable {
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
}

struct MatchLineupPlayer: Codable, Hashable, Identifiable {
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
}

struct MatchLineupSubstitution: Codable, Hashable, Identifiable {
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
}

struct MatchTeamLineup: Codable, Hashable {
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
}

struct MatchTeamLineups: Codable, Hashable {
    let home: MatchTeamLineup?
    let away: MatchTeamLineup?
}

struct MatchDetailsPayload: Codable, Hashable {
    let id: String
    let detailsURL: String?
    let date: String?
    let time: String?
    let league: String?
    let homeTeam: String?
    let awayTeam: String?
    let homeScore: Int?
    let awayScore: Int?
    let aggregateHomeScore: Int?
    let aggregateAwayScore: Int?
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
        case homeScore = "home_score"
        case awayScore = "away_score"
        case aggregateHomeScore = "aggregate_home_score"
        case aggregateAwayScore = "aggregate_away_score"
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
        homeScore = try container.decodeIfPresent(Int.self, forKey: .homeScore)
        awayScore = try container.decodeIfPresent(Int.self, forKey: .awayScore)
        aggregateHomeScore = try container.decodeIfPresent(Int.self, forKey: .aggregateHomeScore)
        aggregateAwayScore = try container.decodeIfPresent(Int.self, forKey: .aggregateAwayScore)
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

struct Match: Identifiable, Codable, Hashable {
    let date: String
    let time: String
    let homeTeam: String
    let awayTeam: String
    let league: String
    let leagueSubcategory: String?
    let detailsURL: String?
    let matchDetailsIDValue: String?
    let tvChannels: [String]
    let homeScore: Int?
    let awayScore: Int?
    let aggregateHomeScore: Int?
    let aggregateAwayScore: Int?
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

    init(
        date: String,
        time: String,
        homeTeam: String,
        awayTeam: String,
        league: String,
        leagueSubcategory: String? = nil,
        detailsURL: String? = nil,
        matchDetailsID: String? = nil,
        tvChannels: [String],
        homeScore: Int? = nil,
        awayScore: Int? = nil,
        aggregateHomeScore: Int? = nil,
        aggregateAwayScore: Int? = nil,
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
        self.league = league
        self.leagueSubcategory = leagueSubcategory
        self.detailsURL = detailsURL
        self.matchDetailsIDValue = Self.normalizedMatchDetailsID(matchDetailsID)
        self.tvChannels = tvChannels
        self.homeScore = homeScore
        self.awayScore = awayScore
        self.aggregateHomeScore = aggregateHomeScore
        self.aggregateAwayScore = aggregateAwayScore
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

    var id: String {
        "\(date)|\(time)|\(league)|\(homeTeam)|\(awayTeam)"
    }

    var dateTime: Date? {
        MatchDateParser.shared.parse(date: date, time: time)
    }

    var matchDetailsID: String? {
        if let explicit = Self.normalizedMatchDetailsID(matchDetailsIDValue) {
            return explicit
        }
        return Self.matchDetailsID(from: detailsURL)
    }

    var dateOnly: Date? {
        MatchDateParser.shared.parse(date: date, time: "00:00")
    }

    var hasScore: Bool {
        homeScore != nil && awayScore != nil
    }

    var scoreLine: String? {
        guard let homeScore, let awayScore else { return nil }
        return "\(homeScore) - \(awayScore)"
    }

    var hasAggregateScore: Bool {
        aggregateHomeScore != nil && aggregateAwayScore != nil
    }

    var aggregateSummaryText: String? {
        guard let aggregateHomeScore, let aggregateAwayScore else { return nil }
        // BBC uses 0-0 as a "not yet populated" placeholder — suppress until real data arrives
        guard aggregateHomeScore != 0 || aggregateAwayScore != 0 else { return nil }
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
        guard let scoreStatus = stabilizedScoreStatus() else { return nil }
        return MatchStatusFormatter.displayValue(for: scoreStatus)
    }

    var isInProgress: Bool {
        guard let scoreStatus = stabilizedScoreStatus() else { return false }
        return MatchStatusFormatter.isInProgress(scoreStatus)
    }

    var isFinished: Bool {
        guard let scoreStatus = stabilizedScoreStatus() else { return false }
        return MatchStatusFormatter.isFinished(scoreStatus)
    }

    var isUpcomingScorelessFixture: Bool {
        Self.isUpcomingScorelessFixture(
            date: date,
            time: time,
            homeScore: homeScore,
            awayScore: awayScore,
            scoreStatus: scoreStatus,
            inProgress: nil
        )
    }

    var displayLeague: String {
        if let subcategory = leagueSubcategory, !subcategory.isEmpty {
            return "\(league): \(subcategory)"
        }
        return league
    }

    func withScore(
        home: Int,
        away: Int,
        status: String?,
        aggregateHome: Int? = nil,
        aggregateAway: Int? = nil
    ) -> Match {
        let nextAggregateHome = aggregateHome ?? adjustedAggregate(base: aggregateHomeScore, previousScore: homeScore, nextScore: home)
        let nextAggregateAway = aggregateAway ?? adjustedAggregate(base: aggregateAwayScore, previousScore: awayScore, nextScore: away)

        return Match(
            date: date,
            time: time,
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            league: league,
            leagueSubcategory: leagueSubcategory,
            detailsURL: detailsURL,
            matchDetailsID: matchDetailsIDValue,
            tvChannels: tvChannels,
            homeScore: home,
            awayScore: away,
            aggregateHomeScore: nextAggregateHome,
            aggregateAwayScore: nextAggregateAway,
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
            league: league,
            leagueSubcategory: leagueSubcategory,
            detailsURL: detailsURL,
            matchDetailsID: matchDetailsIDValue,
            tvChannels: channels,
            homeScore: homeScore,
            awayScore: awayScore,
            aggregateHomeScore: aggregateHomeScore,
            aggregateAwayScore: aggregateAwayScore,
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
        league = try container.decode(String.self, forKey: .league)
        leagueSubcategory = try container.decodeIfPresent(String.self, forKey: .leagueSubcategory)
        detailsURL = try container.decodeIfPresent(String.self, forKey: .detailsURL)
        matchDetailsIDValue = Self.normalizedMatchDetailsID(
            try container.decodeIfPresent(String.self, forKey: .matchDetailsIDValue)
        )
        tvChannels = try container.decodeIfPresent([String].self, forKey: .tvChannels) ?? []
        homeScore = try container.decodeIfPresent(Int.self, forKey: .homeScore)
        awayScore = try container.decodeIfPresent(Int.self, forKey: .awayScore)
        aggregateHomeScore = try container.decodeIfPresent(Int.self, forKey: .aggregateHomeScore)
        aggregateAwayScore = try container.decodeIfPresent(Int.self, forKey: .aggregateAwayScore)
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

        // Debug log for Pens/AET status
        if let status = scoreStatus, (status.uppercased() == "PENS" || status.uppercased() == "PEN" || status.uppercased() == "PEN." || status.uppercased() == "AET") {
            NSLog("[DEBUG Match decode] Decoded match with status=%@ for %@ vs %@ (league=%@)", status, homeTeam, awayTeam, league)
        }
    }

    enum CodingKeys: String, CodingKey {
        case date
        case time
        case homeTeam = "home_team"
        case awayTeam = "away_team"
        case league
        case leagueSubcategory = "league_subcategory"
        case detailsURL = "details_url"
        case matchDetailsIDValue = "match_details_id"
        case tvChannels = "tv_channels"
        case homeScore = "home_score"
        case awayScore = "away_score"
        case aggregateHomeScore = "aggregate_home_score"
        case aggregateAwayScore = "aggregate_away_score"
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

    func withDetails(_ details: MatchDetailsPayload) -> Match {
        let nextDate = details.date ?? date
        let nextTime = details.time ?? time
        let shouldClearScores = Self.isUpcomingScorelessFixture(
            date: nextDate,
            time: nextTime,
            homeScore: details.homeScore,
            awayScore: details.awayScore,
            scoreStatus: details.scoreStatus,
            inProgress: details.inProgress
        )
        let mergedScoreStatus = MatchStatusFormatter.preferredStatus(
            current: scoreStatus,
            incoming: details.scoreStatus
        )

        return Match(
            date: details.date ?? date,
            time: details.time ?? time,
            homeTeam: details.homeTeam ?? homeTeam,
            awayTeam: details.awayTeam ?? awayTeam,
            league: details.league ?? league,
            leagueSubcategory: leagueSubcategory,
            detailsURL: details.detailsURL ?? detailsURL,
            matchDetailsID: details.id,
            tvChannels: tvChannels,
            homeScore: shouldClearScores ? nil : (details.homeScore ?? homeScore),
            awayScore: shouldClearScores ? nil : (details.awayScore ?? awayScore),
            aggregateHomeScore: shouldClearScores ? nil : (details.aggregateHomeScore ?? aggregateHomeScore),
            aggregateAwayScore: shouldClearScores ? nil : (details.aggregateAwayScore ?? aggregateAwayScore),
            scoreStatus: shouldClearScores ? nil : mergedScoreStatus,
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

    func stabilizedScoreStatus(now: Date = Date()) -> String? {
        MatchStatusFormatter.stabilizedStatus(
            scoreStatus,
            kickoff: dateTime,
            hasScore: hasScore,
            now: now
        )
    }

    private static func matchDetailsID(from detailsURL: String?) -> String? {
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

    private static func normalizedMatchDetailsID(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics
        guard normalized.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return normalized
    }

    private func adjustedAggregate(base: Int?, previousScore: Int?, nextScore: Int) -> Int? {
        guard let base else { return nil }
        guard let previousScore else { return base }
        return base + (nextScore - previousScore)
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

    private var aggregateWinnerSummaryText: String? {
        guard isFinished,
              let aggregateHomeScore,
              let aggregateAwayScore,
              (aggregateHomeScore != 0 || aggregateAwayScore != 0),
              aggregateHomeScore != aggregateAwayScore
        else {
            return nil
        }

        let homeWins = aggregateHomeScore > aggregateAwayScore
        let winner = homeWins ? homeTeam : awayTeam
        let winnerScore = homeWins ? aggregateHomeScore : aggregateAwayScore
        let loserScore = homeWins ? aggregateAwayScore : aggregateHomeScore
        return "\(winner) win \(winnerScore) - \(loserScore) on aggregate"
    }

    private static func isUpcomingScorelessFixture(
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

        guard let kickoff = MatchDateParser.shared.parse(date: date, time: time) else {
            return normalizedStatus == nil || normalizedStatus?.isEmpty == true
        }
        return kickoff.timeIntervalSince(now) > -(15 * 60)
    }

    private static func containsTeamName(_ teamName: String, in text: String) -> Bool {
        let normalizedTeam = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTeam.isEmpty else { return false }
        return text.range(of: normalizedTeam, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func firstScorePair(in text: String) -> (Int, Int)? {
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
    private static let inProgressTokens: Set<String> = ["HT", "ET", "LIVE", "PENS", "PEN", "PEN."]
    private static let completeTokens: Set<String> = ["FT", "AET"]
    private static let minutePattern = #"^\d{1,3}(?:\+\d{1,2})?'?$"#
    private static let maximumLiveWindow: TimeInterval = 3.5 * 60 * 60

    static func displayValue(for rawStatus: String) -> String {
        let status = normalized(rawStatus)
        guard !status.isEmpty else { return rawStatus }
        if isMinuteStatus(status) {
            let minuteValue = status.replacingOccurrences(of: "'", with: "")
            return "\(minuteValue)'"
        }
        return status
    }

    static func isInProgress(_ rawStatus: String) -> Bool {
        let status = normalized(rawStatus)
        guard !status.isEmpty else { return false }
        if isMinuteStatus(status) { return true }

        let token = status.uppercased()
        if completeTokens.contains(token) { return false }
        return inProgressTokens.contains(token)
    }

    static func isFinished(_ rawStatus: String) -> Bool {
        let status = normalized(rawStatus)
        guard !status.isEmpty else { return false }
        let token = status.uppercased()
        return completeTokens.contains(token)
    }

    static func preferredStatus(current: String?, incoming: String?) -> String? {
        let currentStatus = normalizedStatus(current)
        let incomingStatus = normalizedStatus(incoming)

        guard let currentStatus else { return incomingStatus }
        guard let incomingStatus else { return currentStatus }

        let currentState = statusState(for: currentStatus)
        let incomingState = statusState(for: incomingStatus)

        if currentState == .finished && incomingState != .finished {
            return currentStatus
        }
        if incomingState == .finished && currentState != .finished {
            return incomingStatus
        }
        if currentState == .finished && incomingState == .finished {
            if currentStatus == "AET" && incomingStatus == "FT" {
                return currentStatus
            }
            if incomingStatus == "AET" && currentStatus == "FT" {
                return incomingStatus
            }
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

    static func prefersIncomingStatus(current: String?, incoming: String?) -> Bool {
        guard let incomingStatus = normalizedStatus(incoming) else { return false }
        return preferredStatus(current: current, incoming: incoming) == incomingStatus
    }

    static func stabilizedStatus(
        _ rawStatus: String?,
        kickoff: Date?,
        hasScore: Bool,
        now: Date = Date()
    ) -> String? {
        guard let trimmed = trimmedStatus(rawStatus) else { return nil }

        guard hasScore, isInProgress(trimmed), let kickoff else {
            return trimmed
        }

        let elapsed = now.timeIntervalSince(kickoff)
        guard elapsed >= maximumLiveWindow else {
            return trimmed
        }

        return "FT"
    }

    static func parseMatchTimeMinutes(_ matchTime: String?) -> Int? {
        guard let matchTime = matchTime?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }

        if let match = matchTime.range(of: #"^(\d+)(?:\+(\d+))?[']?$"#, options: .regularExpression) {
            let components = matchTime[match].split(separator: "+")
            let base = Int(components[0].trimmingCharacters(in: CharacterSet(charactersIn: "'"))) ?? 0
            let added = components.count > 1 ? Int(components[1].trimmingCharacters(in: CharacterSet(charactersIn: "'"))) ?? 0 : 0
            return base + added
        }

        let upper = matchTime.uppercased()
        if upper.contains("HT") || upper.contains("HALF") { return 45 }
        if upper.contains("FT") || upper.contains("FULL") { return 90 }
        if upper == "AET" { return 120 }
        if upper == "PENS" || upper == "PEN" || upper == "PEN." { return 120 }

        return nil
    }

    private static func normalized(_ rawStatus: String) -> String {
        rawStatus.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isMinuteStatus(_ status: String) -> Bool {
        status.range(of: minutePattern, options: .regularExpression) != nil
    }

    static func normalizedStatus(_ value: String?) -> String? {
        guard let value = trimmedStatus(value) else {
            return nil
        }
        return value.uppercased()
    }

    private static func isFirstHalfMinuteStatus(_ status: String) -> Bool {
        guard let minute = parseMatchTimeMinutes(status) else { return false }
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isMinuteStatus(trimmed) else { return false }
        return minute <= 45
    }

    private static func isPenaltyShootoutStatus(_ status: String) -> Bool {
        status == "PENS" || status == "PEN" || status == "PEN."
    }

    private static func trimmedStatus(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func statusState(for status: String) -> StatusState {
        if completeTokens.contains(status) {
            return .finished
        }
        if parseMatchTimeMinutes(status) != nil || inProgressTokens.contains(status) {
            return .inProgress
        }
        return .unknown
    }

    private enum StatusState {
        case finished
        case inProgress
        case unknown
    }
}

final class MatchDateParser {
    static let shared = MatchDateParser()

    private let dateTimeFormatter: DateFormatter
    private let dateFormatter: DateFormatter

    private init() {
        let dateTimeFormatter = DateFormatter()
        dateTimeFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateTimeFormatter.timeZone = TimeZone.current
        dateTimeFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        self.dateTimeFormatter = dateTimeFormatter

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone.current
        dateFormatter.dateFormat = "EEE, MMM d, yyyy"
        self.dateFormatter = dateFormatter
    }

    func parse(date: String, time: String) -> Date? {
        dateTimeFormatter.date(from: "\(date) \(time)")
    }

    func displayDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    func displayDateWithRelative(_ date: Date) -> String {
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
}
