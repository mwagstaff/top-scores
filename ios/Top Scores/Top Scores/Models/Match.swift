import Foundation

struct MatchGoalScorer: Codable, Hashable {
    let player: String
    let goalTimes: [String]
    let ownGoalTimes: [String]

    init(player: String, goalTimes: [String], ownGoalTimes: [String] = []) {
        self.player = player
        self.goalTimes = goalTimes
        self.ownGoalTimes = ownGoalTimes
    }

    enum CodingKeys: String, CodingKey {
        case player
        case goalTimes = "goal_times"
        case ownGoalTimes = "own_goal_times"
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
    let scoreStatus: String?
    let homeGoalScorers: [MatchGoalScorer]
    let awayGoalScorers: [MatchGoalScorer]
    let homeAssists: [MatchAssistProvider]
    let awayAssists: [MatchAssistProvider]
    let homeRedCards: [MatchRedCardEvent]
    let awayRedCards: [MatchRedCardEvent]
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
        case scoreStatus = "score_status"
        case homeGoalScorers = "home_goal_scorers"
        case awayGoalScorers = "away_goal_scorers"
        case homeAssists = "home_assists"
        case awayAssists = "away_assists"
        case homeRedCards = "home_red_cards"
        case awayRedCards = "away_red_cards"
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
        scoreStatus = try container.decodeIfPresent(String.self, forKey: .scoreStatus)
        homeGoalScorers = try container.decodeIfPresent([MatchGoalScorer].self, forKey: .homeGoalScorers) ?? []
        awayGoalScorers = try container.decodeIfPresent([MatchGoalScorer].self, forKey: .awayGoalScorers) ?? []
        homeAssists = try container.decodeIfPresent([MatchAssistProvider].self, forKey: .homeAssists) ?? []
        awayAssists = try container.decodeIfPresent([MatchAssistProvider].self, forKey: .awayAssists) ?? []
        homeRedCards = try container.decodeIfPresent([MatchRedCardEvent].self, forKey: .homeRedCards) ?? []
        awayRedCards = try container.decodeIfPresent([MatchRedCardEvent].self, forKey: .awayRedCards) ?? []
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
    let scoreStatus: String?
    let homeGoalScorers: [MatchGoalScorer]
    let awayGoalScorers: [MatchGoalScorer]
    let homeAssists: [MatchAssistProvider]
    let awayAssists: [MatchAssistProvider]
    let homeRedCards: [MatchRedCardEvent]
    let awayRedCards: [MatchRedCardEvent]
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
        scoreStatus: String? = nil,
        homeGoalScorers: [MatchGoalScorer] = [],
        awayGoalScorers: [MatchGoalScorer] = [],
        homeAssists: [MatchAssistProvider] = [],
        awayAssists: [MatchAssistProvider] = [],
        homeRedCards: [MatchRedCardEvent] = [],
        awayRedCards: [MatchRedCardEvent] = [],
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
        self.scoreStatus = scoreStatus
        self.homeGoalScorers = homeGoalScorers
        self.awayGoalScorers = awayGoalScorers
        self.homeAssists = homeAssists
        self.awayAssists = awayAssists
        self.homeRedCards = homeRedCards
        self.awayRedCards = awayRedCards
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

    var displayScoreStatus: String? {
        guard let scoreStatus else { return nil }
        return MatchStatusFormatter.displayValue(for: scoreStatus)
    }

    var isInProgress: Bool {
        guard let scoreStatus else { return false }
        return MatchStatusFormatter.isInProgress(scoreStatus)
    }

    var isFinished: Bool {
        guard let scoreStatus else { return false }
        return MatchStatusFormatter.isFinished(scoreStatus)
    }

    var displayLeague: String {
        if let subcategory = leagueSubcategory, !subcategory.isEmpty {
            return "\(league): \(subcategory)"
        }
        return league
    }

    func withScore(home: Int, away: Int, status: String?) -> Match {
        Match(
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
            scoreStatus: status,
            homeGoalScorers: homeGoalScorers,
            awayGoalScorers: awayGoalScorers,
            homeAssists: homeAssists,
            awayAssists: awayAssists,
            homeRedCards: homeRedCards,
            awayRedCards: awayRedCards,
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
            scoreStatus: scoreStatus,
            homeGoalScorers: homeGoalScorers,
            awayGoalScorers: awayGoalScorers,
            homeAssists: homeAssists,
            awayAssists: awayAssists,
            homeRedCards: homeRedCards,
            awayRedCards: awayRedCards,
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
        scoreStatus = try container.decodeIfPresent(String.self, forKey: .scoreStatus)
        homeGoalScorers = try container.decodeIfPresent([MatchGoalScorer].self, forKey: .homeGoalScorers) ?? []
        awayGoalScorers = try container.decodeIfPresent([MatchGoalScorer].self, forKey: .awayGoalScorers) ?? []
        homeAssists = try container.decodeIfPresent([MatchAssistProvider].self, forKey: .homeAssists) ?? []
        awayAssists = try container.decodeIfPresent([MatchAssistProvider].self, forKey: .awayAssists) ?? []
        homeRedCards = try container.decodeIfPresent([MatchRedCardEvent].self, forKey: .homeRedCards) ?? []
        awayRedCards = try container.decodeIfPresent([MatchRedCardEvent].self, forKey: .awayRedCards) ?? []
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
        case scoreStatus = "score_status"
        case homeGoalScorers = "home_goal_scorers"
        case awayGoalScorers = "away_goal_scorers"
        case homeAssists = "home_assists"
        case awayAssists = "away_assists"
        case homeRedCards = "home_red_cards"
        case awayRedCards = "away_red_cards"
        case penaltyResult = "penalty_result"
        case isTestMatch = "is_test_match"
    }

    func withDetails(_ details: MatchDetailsPayload) -> Match {
        // Prefer AET over Pens when merging - if base match has AET and details have Pens, keep AET
        // This handles the case where the main matches list has been updated but cached details are stale
        let mergedScoreStatus: String?
        if let baseStatus = scoreStatus?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
           let detailStatus = details.scoreStatus?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
           baseStatus == "AET" && (detailStatus == "PENS" || detailStatus == "PEN" || detailStatus == "PEN.") {
            NSLog("[DEBUG withDetails] Keeping AET from base match (base=%@ details=%@) for %@ vs %@", scoreStatus ?? "nil", details.scoreStatus ?? "nil", homeTeam, awayTeam)
            mergedScoreStatus = scoreStatus
        } else {
            mergedScoreStatus = details.scoreStatus ?? scoreStatus
            if (scoreStatus?.uppercased() == "PENS" || scoreStatus?.uppercased() == "PEN" || scoreStatus?.uppercased() == "PEN." || details.scoreStatus?.uppercased() == "PENS" || details.scoreStatus?.uppercased() == "PEN" || details.scoreStatus?.uppercased() == "PEN.") {
                NSLog("[DEBUG withDetails] Status merge: base=%@ details=%@ merged=%@ for %@ vs %@", scoreStatus ?? "nil", details.scoreStatus ?? "nil", mergedScoreStatus ?? "nil", homeTeam, awayTeam)
            }
        }

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
            homeScore: details.homeScore ?? homeScore,
            awayScore: details.awayScore ?? awayScore,
            scoreStatus: mergedScoreStatus,
            homeGoalScorers: details.homeGoalScorers,
            awayGoalScorers: details.awayGoalScorers,
            homeAssists: details.homeAssists,
            awayAssists: details.awayAssists,
            homeRedCards: details.homeRedCards,
            awayRedCards: details.awayRedCards,
            penaltyResult: details.penaltyResult ?? penaltyResult,
            isTestMatch: isTestMatch
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
}

private enum MatchStatusFormatter {
    private static let inProgressTokens: Set<String> = ["HT", "ET", "LIVE", "PENS", "PEN", "PEN."]
    private static let completeTokens: Set<String> = ["FT", "AET"]
    private static let minutePattern = #"^\d{1,3}(?:\+\d{1,2})?'?$"#

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

    private static func normalized(_ rawStatus: String) -> String {
        rawStatus.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isMinuteStatus(_ status: String) -> Bool {
        status.range(of: minutePattern, options: .regularExpression) != nil
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
