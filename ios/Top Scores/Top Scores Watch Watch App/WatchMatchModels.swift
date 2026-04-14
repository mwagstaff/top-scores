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

struct WatchMatch: Identifiable, Codable, Hashable {
    let date: String
    let time: String
    let homeTeam: String
    let awayTeam: String
    let homeShortName: String?
    let awayShortName: String?
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

    var displayHomeTeam: String {
        let trimmed = homeShortName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? homeTeam : trimmed
    }

    var displayAwayTeam: String {
        let trimmed = awayShortName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? awayTeam : trimmed
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
        case homeShortName = "home_short_name"
        case awayShortName = "away_short_name"
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
                    weight: competitionWeight(forCompetitionName: league)
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
        if let displayWeight = WatchCompetitionWeightConfig.weight(for: match.displayLeague) {
            return displayWeight
        }
        return WatchCompetitionWeightConfig.weight(for: match.league) ?? 0
    }

    private static func competitionWeight(forCompetitionName competitionName: String) -> Double {
        WatchCompetitionWeightConfig.weight(for: competitionName) ?? 0
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

private enum WatchCompetitionWeightConfig {
    private static let bootstrapWeightsByName: [String: Double] = [
        "premier league": 100,
        "uefa champions league": 90,
        "fifa world cup 2026": 85,
        "uefa europa league": 80,
        "uefa conference league": 70,
        "uefa nations league": 69,
        "uefa super cup": 68,
        "fa cup": 65,
        "english league cup": 60,
        "copa del rey": 58,
        "la liga": 50,
        "bundesliga": 48,
        "serie a": 48,
        "championship": 40,
        "scottish premiership": 30,
        "scottish championship": 25,
        "scottish league one": 20,
        "scottish league two": 15,
        "league one": 14,
        "league two": 12,
        "international friendly": 10,
    ]
    private static let stagePatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"\s*[-:–]\s*Round\s+\w+$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+\w+\s+Round$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Round\s+\w+$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Round\s+\d+$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Round\s+of\s+\d+$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Last\s+\d+$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Group\s+Stage$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Group\s+[A-Z]$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Quarter[- ]Finals?$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Semi[- ]Finals?$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Finals?$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Third[- ]Place\s+Play-?Off$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Play-?Offs?$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Qualifying$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Qualification$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Preliminary\s+Round$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+First\s+Leg$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Second\s+Leg$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+1st\s+Leg$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+2nd\s+Leg$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Leg\s+\d+$"#, options: [.caseInsensitive]),
    ]
    private static let trailingStageSeparatorPattern = try! NSRegularExpression(
        pattern: #"[-:–]\s*$"#,
        options: [.caseInsensitive]
    )
    private static let aliases: [String: String] = [
        "efl cup": "english league cup",
        "carabao cup": "english league cup",
        "uefa europa conference league": "uefa conference league",
    ]

    static func weight(for competitionName: String) -> Double? {
        let canonical = canonicalCompetitionName(competitionName)
        guard !canonical.isEmpty else { return nil }
        return loadWeights()[canonical]
    }

    private static func normalizeCompetitionName(_ competitionName: String) -> String {
        competitionName
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func canonicalCompetitionName(_ competitionName: String) -> String {
        let normalized = normalizeCompetitionName(competitionName)
        guard !normalized.isEmpty else { return "" }
        let stripped = stripStageDescriptors(from: normalized)
        let canonical = stripped.isEmpty ? normalized : stripped
        return aliases[canonical] ?? canonical
    }

    private static func loadWeights() -> [String: Double] {
        guard let defaults = UserDefaults(suiteName: WatchAppGroupConfig.identifier),
              let data = defaults.data(forKey: WatchAppGroupConfig.competitionCatalogWeightsDataKey),
              let weights = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return bootstrapWeightsByName
        }
        return weights.isEmpty ? bootstrapWeightsByName : weights
    }

    private static func stripStageDescriptors(from competitionName: String) -> String {
        var normalized = competitionName
        var changed = true

        while changed {
            changed = false
            for pattern in stagePatterns {
                let range = NSRange(location: 0, length: normalized.utf16.count)
                guard pattern.firstMatch(in: normalized, options: [], range: range) != nil else {
                    continue
                }

                normalized = pattern
                    .stringByReplacingMatches(in: normalized, options: [], range: range, withTemplate: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let separatorRange = NSRange(location: 0, length: normalized.utf16.count)
                normalized = trailingStageSeparatorPattern
                    .stringByReplacingMatches(in: normalized, options: [], range: separatorRange, withTemplate: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }

        return normalized
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
