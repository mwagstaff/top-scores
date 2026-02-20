import Foundation

struct WatchGoalScorer: Codable, Hashable {
    let player: String
    let goalTimes: [String]
    let ownGoalTimes: [String]

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

struct WatchPreferencesSnapshot: Codable, Equatable {
    let selectedLeagues: [String]
    let selectedChannels: [String]
    let englishPremierLeagueTeamsOnly: Bool
    let apiBaseURL: String
    let refreshIntervalMinutes: Int
}

struct WatchMatch: Identifiable, Codable, Hashable {
    let date: String
    let time: String
    let homeTeam: String
    let awayTeam: String
    let league: String
    let leagueSubcategory: String?
    let matchDetailsIDValue: String?
    let tvChannels: [String]
    let homeScore: Int?
    let awayScore: Int?
    let scoreStatus: String?
    let homeGoalScorers: [WatchGoalScorer]
    let awayGoalScorers: [WatchGoalScorer]
    let homeAssists: [WatchAssistProvider]
    let awayAssists: [WatchAssistProvider]
    let homeRedCards: [WatchRedCardEvent]
    let awayRedCards: [WatchRedCardEvent]
    let penaltyResult: String?

    var id: String {
        "\(date)|\(time)|\(league)|\(homeTeam)|\(awayTeam)"
    }

    var dateTime: Date? {
        WatchMatchDateParser.shared.parse(date: date, time: time)
    }

    var scoreLine: String? {
        guard let homeScore, let awayScore else { return nil }
        return "\(homeScore)-\(awayScore)"
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
            return "\(league) -> \(subcategory)"
        }
        return league
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        time = try container.decode(String.self, forKey: .time)
        homeTeam = try container.decode(String.self, forKey: .homeTeam)
        awayTeam = try container.decode(String.self, forKey: .awayTeam)
        league = try container.decode(String.self, forKey: .league)
        leagueSubcategory = try container.decodeIfPresent(String.self, forKey: .leagueSubcategory)
        matchDetailsIDValue = try container.decodeIfPresent(String.self, forKey: .matchDetailsIDValue)
        tvChannels = try container.decodeIfPresent([String].self, forKey: .tvChannels) ?? []
        homeScore = try container.decodeIfPresent(Int.self, forKey: .homeScore)
        awayScore = try container.decodeIfPresent(Int.self, forKey: .awayScore)
        scoreStatus = try container.decodeIfPresent(String.self, forKey: .scoreStatus)
        homeGoalScorers = try container.decodeIfPresent([WatchGoalScorer].self, forKey: .homeGoalScorers) ?? []
        awayGoalScorers = try container.decodeIfPresent([WatchGoalScorer].self, forKey: .awayGoalScorers) ?? []
        homeAssists = try container.decodeIfPresent([WatchAssistProvider].self, forKey: .homeAssists) ?? []
        awayAssists = try container.decodeIfPresent([WatchAssistProvider].self, forKey: .awayAssists) ?? []
        homeRedCards = try container.decodeIfPresent([WatchRedCardEvent].self, forKey: .homeRedCards) ?? []
        awayRedCards = try container.decodeIfPresent([WatchRedCardEvent].self, forKey: .awayRedCards) ?? []
        penaltyResult = try container.decodeIfPresent(String.self, forKey: .penaltyResult)
    }

    enum CodingKeys: String, CodingKey {
        case date
        case time
        case homeTeam = "home_team"
        case awayTeam = "away_team"
        case league
        case leagueSubcategory = "league_subcategory"
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
    }
}

private enum WatchMatchStatusFormatter {
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

    private static func normalized(_ rawStatus: String) -> String {
        rawStatus.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isMinuteStatus(_ status: String) -> Bool {
        status.range(of: minutePattern, options: .regularExpression) != nil
    }
}

struct WatchSharedMatchesPayload: Codable {
    let snapshot: WatchPreferencesSnapshot
    let matches: [WatchMatch]
    let unfilteredMatches: [WatchMatch]
    let lastUpdated: Date?
    let generatedAt: Date
}

struct WatchMatchDay: Identifiable, Hashable {
    let id: String
    let displayDate: String
    let matches: [WatchMatch]
}

enum WatchMatchGrouping {
    static func sortedMatches(_ matches: [WatchMatch]) -> [WatchMatch] {
        matches.sorted {
            let leftDate = $0.dateTime ?? WatchMatchDateParser.shared.parse(date: $0.date, time: "00:00") ?? .distantFuture
            let rightDate = $1.dateTime ?? WatchMatchDateParser.shared.parse(date: $1.date, time: "00:00") ?? .distantFuture
            if leftDate != rightDate {
                return leftDate < rightDate
            }

            let leagueCompare = $0.league.localizedCaseInsensitiveCompare($1.league)
            if leagueCompare != .orderedSame {
                return leagueCompare == .orderedAscending
            }

            let homeCompare = $0.homeTeam.localizedCaseInsensitiveCompare($1.homeTeam)
            if homeCompare != .orderedSame {
                return homeCompare == .orderedAscending
            }

            return $0.awayTeam.localizedCaseInsensitiveCompare($1.awayTeam) == .orderedAscending
        }
    }

    static func groupedDays(_ matches: [WatchMatch]) -> [WatchMatchDay] {
        let byDate = Dictionary(grouping: matches) { $0.date }
        let dateKeys = byDate.keys.sorted()

        let dateDays: [WatchMatchDay] = dateKeys.compactMap { dateKey -> WatchMatchDay? in
            guard let dateMatches = byDate[dateKey] else { return nil }
            let displayDate: String
            if let parsed = WatchMatchDateParser.shared.parse(date: dateKey, time: "00:00") {
                displayDate = WatchMatchDateParser.shared.displayDateWithRelative(parsed)
            } else {
                displayDate = dateKey
            }
            return WatchMatchDay(id: dateKey, displayDate: displayDate, matches: dateMatches)
        }
        return dateDays
    }

    static func todaysMatchCount(_ matches: [WatchMatch]) -> Int {
        let calendar = Calendar.current
        return matches.reduce(into: 0) { count, match in
            guard let matchDate = WatchMatchDateParser.shared.parse(date: match.date, time: "00:00") else { return }
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
