import Foundation

struct WatchGoalScorer: Codable, Hashable {
    let player: String
    let goalTimes: [String]
    let ownGoalTimes: [String]
    let disallowedGoalTimes: [String]

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

struct WatchAssistProvider: Codable, Hashable {
    let player: String
    let assistTimes: [String]

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

struct WatchRedCardEvent: Codable, Hashable {
    let player: String
    let redCardTimes: [String]

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

struct WatchYellowCardEvent: Codable, Hashable {
    let player: String
    let yellowCardTimes: [String]

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

struct WatchVarEvent: Codable, Hashable {
    let player: String?
    let minute: String?
    let detail: String

    enum CodingKeys: String, CodingKey {
        case player
        case minute
        case detail
    }
}

struct WatchLineupPlayer: Codable, Hashable, Identifiable {
    let number: Int
    let name: String
    let positionShort: String?
    let position: String?

    var id: String {
        "\(number)|\(name)"
    }

    enum CodingKeys: String, CodingKey {
        case number
        case name
        case positionShort = "position_short"
        case position
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decodeIfPresent(Int.self, forKey: .number) ?? 0
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        positionShort = try container.decodeIfPresent(String.self, forKey: .positionShort)
        position = try container.decodeIfPresent(String.self, forKey: .position)
    }
}

struct WatchLineupSubstitution: Codable, Hashable, Identifiable {
    let minute: String
    let playerOff: WatchLineupPlayer
    let playerOn: WatchLineupPlayer

    var id: String {
        "\(minute)|\(playerOff.id)|\(playerOn.id)"
    }

    enum CodingKeys: String, CodingKey {
        case minute
        case playerOff = "player_off"
        case playerOn = "player_on"
    }
}

struct WatchTeamLineup: Codable, Hashable {
    let team: String?
    let formation: String?
    let startingLineup: [WatchLineupPlayer]
    let substitutions: [WatchLineupSubstitution]

    enum CodingKeys: String, CodingKey {
        case team
        case formation
        case startingLineup = "starting_lineup"
        case substitutions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        team = try container.decodeIfPresent(String.self, forKey: .team)
        formation = try container.decodeIfPresent(String.self, forKey: .formation)
        startingLineup = try container.decodeIfPresent([WatchLineupPlayer].self, forKey: .startingLineup) ?? []
        substitutions = try container.decodeIfPresent([WatchLineupSubstitution].self, forKey: .substitutions) ?? []
    }
}

struct WatchTeamLineups: Codable, Hashable {
    let home: WatchTeamLineup?
    let away: WatchTeamLineup?
}

struct WatchMatchWatchabilityComponent: Codable, Hashable {
    let key: String
    let score: Int
}

struct WatchMatchWatchabilityIndex: Codable, Hashable {
    let score: Int
    let components: [WatchMatchWatchabilityComponent]

    var teamQualityScore: Int? {
        components.first { $0.key == "team_quality" }?.score
    }

    enum CodingKeys: String, CodingKey {
        case score
        case components
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        score = try container.decodeIfPresent(Int.self, forKey: .score) ?? 0
        components = try container.decodeIfPresent(
            [WatchMatchWatchabilityComponent].self,
            forKey: .components
        ) ?? []
    }
}

struct WatchFantasyPlayer: Codable, Hashable, Identifiable {
    let elementID: Int
    let displayName: String
    let teamName: String
    let points: Int
    let isCaptain: Bool
    let isViceCaptain: Bool
    let isStarter: Bool
    var profileImageURL: String? = nil
    var opponent: String? = nil
    var expectedPoints: Double? = nil
    var surname: String? = nil

    var id: Int { elementID }
}

struct WatchFantasySnapshot: Codable, Hashable {
    let gameweekTitle: String
    let players: [WatchFantasyPlayer]
    var deadlineTime: String? = nil
    var deadlineGameweekID: Int? = nil
    var scorePhase: String? = nil
    var totalPoints: Int? = nil
    var expectedPoints: Double? = nil
    var syncedAt: String? = nil
    var leagues: [WatchFantasyLeague]? = nil
}

struct WatchPreferencesSnapshot: Codable, Equatable {
    let selectedLeagues: [String]
    let selectedChannels: [String]
    let competitionFilterEnabled: Bool
    let channelFilterEnabled: Bool
    let englishPremierLeagueTeamsOnly: Bool
    let apiBaseURL: String
    let refreshIntervalMinutes: Int
    let showAllMatches: Bool

    enum CodingKeys: String, CodingKey {
        case selectedLeagues
        case selectedChannels
        case competitionFilterEnabled
        case channelFilterEnabled
        case englishPremierLeagueTeamsOnly
        case apiBaseURL
        case refreshIntervalMinutes
        case showAllMatches
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedLeagues = try container.decodeIfPresent([String].self, forKey: .selectedLeagues) ?? []
        selectedChannels = try container.decodeIfPresent([String].self, forKey: .selectedChannels) ?? []
        competitionFilterEnabled = try container.decodeIfPresent(Bool.self, forKey: .competitionFilterEnabled) ?? true
        channelFilterEnabled = try container.decodeIfPresent(Bool.self, forKey: .channelFilterEnabled) ?? true
        englishPremierLeagueTeamsOnly = try container.decodeIfPresent(Bool.self, forKey: .englishPremierLeagueTeamsOnly) ?? false
        apiBaseURL = try container.decodeIfPresent(String.self, forKey: .apiBaseURL) ?? ""
        refreshIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes) ?? 10
        showAllMatches = try container.decodeIfPresent(Bool.self, forKey: .showAllMatches) ?? false
    }
}

private struct WatchTVChannelSummary: Decodable {
    let name: String
}

struct WatchMatch: Identifiable, Codable, Hashable {
    let id: String
    let dateTime: Date?
    let date: String
    let time: String
    let homeTeam: String
    let awayTeam: String
    let homeShortName: String?
    let awayShortName: String?
    let league: String
    let leagueSubcategory: String?
    let competitionWeight: Double?
    let watchabilityIndex: WatchMatchWatchabilityIndex?
    let matchDetailsIDValue: String?
    let tvChannels: [String]
    let homeScore: Int?
    let awayScore: Int?
    let scoreStatus: String?
    let homeGoalScorers: [WatchGoalScorer]
    let awayGoalScorers: [WatchGoalScorer]
    let homeAssists: [WatchAssistProvider]
    let awayAssists: [WatchAssistProvider]
    let homeYellowCards: [WatchYellowCardEvent]
    let awayYellowCards: [WatchYellowCardEvent]
    let homeRedCards: [WatchRedCardEvent]
    let awayRedCards: [WatchRedCardEvent]
    let homeVarEvents: [WatchVarEvent]
    let awayVarEvents: [WatchVarEvent]
    let teamLineups: WatchTeamLineups?
    let penaltyResult: String?
    let homeTeamId: String?
    let awayTeamId: String?

    var scoreLine: String? {
        guard let homeScore, let awayScore else { return nil }
        return "\(homeScore)-\(awayScore)"
    }

    var displayHomeTeam: String {
        WatchTeamNameResolver.shared.displayName(
            for: homeTeam,
            providerShortName: homeShortName
        )
    }

    var displayAwayTeam: String {
        WatchTeamNameResolver.shared.displayName(
            for: awayTeam,
            providerShortName: awayShortName
        )
    }

    var hasScore: Bool {
        homeScore != nil && awayScore != nil
    }

    var displayScoreStatus: String? {
        guard let scoreStatus else { return nil }
        return WatchMatchStatusFormatter.displayValue(for: scoreStatus)
    }

    var isInProgress: Bool {
        guard let scoreStatus else { return false }
        return WatchMatchStatusFormatter.isInProgress(scoreStatus)
    }

    var displayLeague: String {
        if let subcategory = leagueSubcategory, !subcategory.isEmpty {
            return "\(league): \(subcategory)"
        }
        return league
    }

    init(
        date: String,
        time: String,
        homeTeam: String,
        awayTeam: String,
        homeShortName: String?,
        awayShortName: String?,
        league: String,
        leagueSubcategory: String?,
        competitionWeight: Double?,
        watchabilityIndex: WatchMatchWatchabilityIndex?,
        matchDetailsIDValue: String?,
        tvChannels: [String],
        homeScore: Int?,
        awayScore: Int?,
        scoreStatus: String?,
        homeGoalScorers: [WatchGoalScorer],
        awayGoalScorers: [WatchGoalScorer],
        homeAssists: [WatchAssistProvider],
        awayAssists: [WatchAssistProvider],
        homeYellowCards: [WatchYellowCardEvent],
        awayYellowCards: [WatchYellowCardEvent],
        homeRedCards: [WatchRedCardEvent],
        awayRedCards: [WatchRedCardEvent],
        homeVarEvents: [WatchVarEvent],
        awayVarEvents: [WatchVarEvent],
        teamLineups: WatchTeamLineups?,
        penaltyResult: String?,
        homeTeamId: String?,
        awayTeamId: String?
    ) {
        self.id = Self.makeID(date: date, time: time, league: league, homeTeam: homeTeam, awayTeam: awayTeam)
        self.dateTime = WatchMatchDateParser.shared.parse(date: date, time: time)
        self.date = date
        self.time = time
        self.homeTeam = homeTeam
        self.awayTeam = awayTeam
        self.homeShortName = homeShortName
        self.awayShortName = awayShortName
        self.league = league
        self.leagueSubcategory = leagueSubcategory
        self.competitionWeight = competitionWeight
        self.watchabilityIndex = watchabilityIndex
        self.matchDetailsIDValue = matchDetailsIDValue
        self.tvChannels = tvChannels
        self.homeScore = homeScore
        self.awayScore = awayScore
        self.scoreStatus = scoreStatus
        self.homeGoalScorers = homeGoalScorers
        self.awayGoalScorers = awayGoalScorers
        self.homeAssists = homeAssists
        self.awayAssists = awayAssists
        self.homeYellowCards = homeYellowCards
        self.awayYellowCards = awayYellowCards
        self.homeRedCards = homeRedCards
        self.awayRedCards = awayRedCards
        self.homeVarEvents = homeVarEvents
        self.awayVarEvents = awayVarEvents
        self.teamLineups = teamLineups
        self.penaltyResult = penaltyResult
        self.homeTeamId = homeTeamId
        self.awayTeamId = awayTeamId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedDate = try container.decode(String.self, forKey: .date)
        let decodedTime = try container.decode(String.self, forKey: .time)
        let decodedHomeTeam = try container.decode(String.self, forKey: .homeTeam)
        let decodedAwayTeam = try container.decode(String.self, forKey: .awayTeam)
        let decodedLeague = try container.decode(String.self, forKey: .league)
        date = decodedDate
        time = decodedTime
        homeTeam = decodedHomeTeam
        awayTeam = decodedAwayTeam
        homeShortName = try container.decodeIfPresent(String.self, forKey: .homeShortName)
        awayShortName = try container.decodeIfPresent(String.self, forKey: .awayShortName)
        league = decodedLeague
        leagueSubcategory = try container.decodeIfPresent(String.self, forKey: .leagueSubcategory)
        competitionWeight = try container.decodeIfPresent(Double.self, forKey: .competitionWeight)
        watchabilityIndex = try container.decodeIfPresent(WatchMatchWatchabilityIndex.self, forKey: .watchabilityIndex)
        matchDetailsIDValue = try container.decodeIfPresent(String.self, forKey: .matchDetailsIDValue)
        if let names = try? container.decode([String].self, forKey: .tvChannels) {
            tvChannels = names
        } else {
            tvChannels = (try? container.decode([WatchTVChannelSummary].self, forKey: .tvChannels))?
                .map(\.name) ?? []
        }
        homeScore = try container.decodeIfPresent(Int.self, forKey: .homeScore)
        awayScore = try container.decodeIfPresent(Int.self, forKey: .awayScore)
        scoreStatus = try container.decodeIfPresent(String.self, forKey: .scoreStatus)
        homeGoalScorers = try container.decodeIfPresent([WatchGoalScorer].self, forKey: .homeGoalScorers) ?? []
        awayGoalScorers = try container.decodeIfPresent([WatchGoalScorer].self, forKey: .awayGoalScorers) ?? []
        homeAssists = try container.decodeIfPresent([WatchAssistProvider].self, forKey: .homeAssists) ?? []
        awayAssists = try container.decodeIfPresent([WatchAssistProvider].self, forKey: .awayAssists) ?? []
        homeYellowCards = try container.decodeIfPresent([WatchYellowCardEvent].self, forKey: .homeYellowCards) ?? []
        awayYellowCards = try container.decodeIfPresent([WatchYellowCardEvent].self, forKey: .awayYellowCards) ?? []
        homeRedCards = try container.decodeIfPresent([WatchRedCardEvent].self, forKey: .homeRedCards) ?? []
        awayRedCards = try container.decodeIfPresent([WatchRedCardEvent].self, forKey: .awayRedCards) ?? []
        homeVarEvents = try container.decodeIfPresent([WatchVarEvent].self, forKey: .homeVarEvents) ?? []
        awayVarEvents = try container.decodeIfPresent([WatchVarEvent].self, forKey: .awayVarEvents) ?? []
        teamLineups = try container.decodeIfPresent(WatchTeamLineups.self, forKey: .teamLineups)
        penaltyResult = try container.decodeIfPresent(String.self, forKey: .penaltyResult)
        homeTeamId = try container.decodeIfPresent(String.self, forKey: .homeTeamId)
        awayTeamId = try container.decodeIfPresent(String.self, forKey: .awayTeamId)
        id = Self.makeID(
            date: decodedDate,
            time: decodedTime,
            league: decodedLeague,
            homeTeam: decodedHomeTeam,
            awayTeam: decodedAwayTeam
        )
        dateTime = WatchMatchDateParser.shared.parse(date: decodedDate, time: decodedTime)
    }

    private static func makeID(
        date: String,
        time: String,
        league: String,
        homeTeam: String,
        awayTeam: String
    ) -> String {
        "\(date)|\(time)|\(league)|\(homeTeam)|\(awayTeam)"
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
        case competitionWeight = "competition_weight"
        case watchabilityIndex = "watchability_index"
        case matchDetailsIDValue = "match_details_id"
        case tvChannels = "tv_channels"
        case homeScore = "home_score"
        case awayScore = "away_score"
        case scoreStatus = "score_status"
        case homeGoalScorers = "home_goal_scorers"
        case awayGoalScorers = "away_goal_scorers"
        case homeAssists = "home_assists"
        case awayAssists = "away_assists"
        case homeYellowCards = "home_yellow_cards"
        case awayYellowCards = "away_yellow_cards"
        case homeRedCards = "home_red_cards"
        case awayRedCards = "away_red_cards"
        case homeVarEvents = "home_var_events"
        case awayVarEvents = "away_var_events"
        case teamLineups = "team_lineups"
        case penaltyResult = "penalty_result"
        case homeTeamId = "home_team_id"
        case awayTeamId = "away_team_id"
    }
}

private enum WatchMatchStatusFormatter {
    private static let inProgressTokens: Set<String> = ["HT", "ET", "LIVE", "PENS", "PEN", "PEN."]
    private static let completeTokens: Set<String> = ["FT", "AET"]

    static func displayValue(for rawStatus: String) -> String {
        let status = normalized(rawStatus)
        guard !status.isEmpty else { return rawStatus }
        if isMinuteStatus(status) {
            let minuteValue = status.replacingOccurrences(of: "'", with: "")
            return "\(minuteValue)'"
        }
        if isExtraTimeMinuteStatus(status) {
            let minuteValue = String(status.dropFirst(2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "'", with: "")
            return "ET \(minuteValue)'"
        }
        return status
    }

    static func isInProgress(_ rawStatus: String) -> Bool {
        let status = normalized(rawStatus)
        guard !status.isEmpty else { return false }
        if isMinuteStatus(status) || isExtraTimeMinuteStatus(status) { return true }

        let token = status.uppercased()
        if completeTokens.contains(token) { return false }
        return inProgressTokens.contains(token)
    }

    private static func normalized(_ rawStatus: String) -> String {
        rawStatus.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isMinuteStatus(_ status: String) -> Bool {
        var value = status[...]
        if value.last == "'" {
            value = value.dropLast()
        }
        let components = value.split(separator: "+", omittingEmptySubsequences: false)
        guard (1...2).contains(components.count),
              isASCIIInteger(components[0], maximumDigits: 3) else {
            return false
        }
        return components.count == 1 || isASCIIInteger(components[1], maximumDigits: 2)
    }

    private static func isExtraTimeMinuteStatus(_ status: String) -> Bool {
        guard status.count > 3,
              status.prefix(3).uppercased() == "ET " else {
            return false
        }
        return isMinuteStatus(String(status.dropFirst(3)))
    }

    private static func isASCIIInteger(_ value: Substring, maximumDigits: Int) -> Bool {
        guard !value.isEmpty, value.count <= maximumDigits else { return false }
        return value.utf8.allSatisfy { byte in
            byte >= 48 && byte <= 57
        }
    }
}

struct WatchSharedMatchesPayload: Codable {
    let snapshot: WatchPreferencesSnapshot
    let matches: [WatchMatch]
    let unfilteredMatches: [WatchMatch]
    let fantasy: WatchFantasySnapshot?
    let lastUpdated: Date?
    let generatedAt: Date

    enum CodingKeys: String, CodingKey {
        case snapshot
        case matches
        case unfilteredMatches
        case fantasy
        case lastUpdated
        case generatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = try container.decode(WatchPreferencesSnapshot.self, forKey: .snapshot)
        matches = try container.decodeIfPresent([WatchMatch].self, forKey: .matches) ?? []
        unfilteredMatches = try container.decodeIfPresent([WatchMatch].self, forKey: .unfilteredMatches) ?? []
        fantasy = try container.decodeIfPresent(WatchFantasySnapshot.self, forKey: .fantasy)
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
    }
}

enum WatchFeaturedMatchSelector {
    static func select(from matches: [WatchMatch], at date: Date) -> WatchMatch? {
        guard !matches.isEmpty else { return nil }

        let live = matches.filter(\.isInProgress)
        if !live.isEmpty {
            return ranked(live).first
        }

        let upcoming = matches.filter { match in
            guard let kickoff = match.dateTime else { return false }
            return kickoff > date && !WatchMatchStatusRules.isFinished(match)
        }
        if !upcoming.isEmpty {
            return ranked(upcoming).first
        }

        return ranked(matches).first
    }

    private static func ranked(_ matches: [WatchMatch]) -> [WatchMatch] {
        matches.sorted { lhs, rhs in
            let leftTeamQuality = lhs.watchabilityIndex?.teamQualityScore ?? Int.min
            let rightTeamQuality = rhs.watchabilityIndex?.teamQualityScore ?? Int.min
            if leftTeamQuality != rightTeamQuality {
                return leftTeamQuality > rightTeamQuality
            }

            let leftWatchability = lhs.watchabilityIndex?.score ?? Int.min
            let rightWatchability = rhs.watchabilityIndex?.score ?? Int.min
            if leftWatchability != rightWatchability {
                return leftWatchability > rightWatchability
            }

            let leftWeight = lhs.competitionWeight ?? 0
            let rightWeight = rhs.competitionWeight ?? 0
            if leftWeight != rightWeight {
                return leftWeight > rightWeight
            }

            let leftKickoff = lhs.dateTime ?? .distantPast
            let rightKickoff = rhs.dateTime ?? .distantPast
            if leftKickoff != rightKickoff {
                return leftKickoff > rightKickoff
            }

            return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
        }
    }
}

struct WatchMatchDay: Identifiable, Hashable {
    let id: String
    let displayDate: String
    let matches: [WatchMatch]
}

enum WatchMatchGrouping {
    static func sortedMatches(_ matches: [WatchMatch]) -> [WatchMatch] {
        matches.sorted { lhs, rhs in
            let leftDate = matchSortDate(for: lhs)
            let rightDate = matchSortDate(for: rhs)
            if leftDate != rightDate {
                return leftDate < rightDate
            }

            let leftWeight = competitionWeight(for: lhs)
            let rightWeight = competitionWeight(for: rhs)
            if leftWeight != rightWeight {
                return leftWeight > rightWeight
            }

            let leagueCompare = lhs.displayLeague.localizedCaseInsensitiveCompare(rhs.displayLeague)
            if leagueCompare != .orderedSame {
                return leagueCompare == .orderedAscending
            }

            let homeCompare = lhs.homeTeam.localizedCaseInsensitiveCompare(rhs.homeTeam)
            if homeCompare != .orderedSame {
                return homeCompare == .orderedAscending
            }

            return lhs.awayTeam.localizedCaseInsensitiveCompare(rhs.awayTeam) == .orderedAscending
        }
    }

    static func groupedDays(_ matches: [WatchMatch]) -> [WatchMatchDay] {
        let byDate = Dictionary(grouping: matches) { $0.date }
        let dateKeys = byDate.keys.sorted()

        let dateDays: [WatchMatchDay] = dateKeys.compactMap { dateKey -> WatchMatchDay? in
            guard let dateMatches = byDate[dateKey] else { return nil }
            let sortedDateMatches = sortedMatches(dateMatches)
            let displayDate: String
            if let parsed = WatchMatchDateParser.shared.parse(date: dateKey, time: "00:00") {
                displayDate = WatchMatchDateParser.shared.displayDateWithRelative(parsed)
            } else {
                displayDate = dateKey
            }

            let groupedByLeague = Dictionary(grouping: sortedDateMatches) { $0.displayLeague }
            let orderedMatches = groupedByLeague.compactMap { entry -> (league: String, matches: [WatchMatch], firstKickoff: Date, weight: Double)? in
                let (league, leagueMatches) = entry
                let sortedLeagueMatches = sortedMatches(leagueMatches)
                guard let firstMatch = sortedLeagueMatches.first else { return nil }
                return (
                    league: league,
                    matches: sortedLeagueMatches,
                    firstKickoff: matchSortDate(for: firstMatch),
                    weight: leagueMatches.map { competitionWeight(for: $0) }.max() ?? 0
                )
            }
            .sorted { lhs, rhs in
                if lhs.firstKickoff != rhs.firstKickoff {
                    return lhs.firstKickoff < rhs.firstKickoff
                }

                if lhs.weight != rhs.weight {
                    return lhs.weight > rhs.weight
                }

                return lhs.league.localizedCaseInsensitiveCompare(rhs.league) == .orderedAscending
            }
            .flatMap(\.matches)

            return WatchMatchDay(id: dateKey, displayDate: displayDate, matches: orderedMatches)
        }
        return dateDays
    }

    private static func matchSortDate(for match: WatchMatch) -> Date {
        match.dateTime ?? WatchMatchDateParser.shared.parse(date: match.date, time: "00:00") ?? .distantFuture
    }

    private static func competitionWeight(for match: WatchMatch) -> Double {
        match.competitionWeight ?? 0
    }

    static func todaysMatchCount(_ matches: [WatchMatch]) -> Int {
        let calendar = Calendar.current
        return matches.reduce(into: 0) { count, match in
            guard let matchDate = match.dateTime else { return }
            if calendar.isDateInToday(matchDate) {
                count += 1
            }
        }
    }
}

final class WatchMatchDateParser {
    static let shared = WatchMatchDateParser()

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
        dateFormatter.dateFormat = "EEE, MMM d"
        self.dateFormatter = dateFormatter
    }

    func parse(date: String, time: String) -> Date? {
        dateTimeFormatter.date(from: "\(date) \(time)")
    }

    func displayDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    func displayDateWithRelative(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInTomorrow(date) {
            return "Tomorrow"
        }
        return displayDate(date)
    }
}
