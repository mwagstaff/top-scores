import SwiftUI
import UIKit
import WidgetKit
import ActivityKit
import ImageIO

private enum WidgetAppGroupConfig {
    static let identifier = "group.dev.skynolimit.topscores"
    static let sharedMatchesFileName = "shared-matches.json"
    static let liveActivityDiagnosticsKey = "live_activity.diagnostics"
    static let liveActivityDiagnosticsFileName = "live-activity-diagnostics.log"
}

private enum WidgetSharedDiagnosticsBridge {
    private static let maxEntries = 80

    static func append(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(trimmed)\n"

        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: WidgetAppGroupConfig.identifier)?
            .appendingPathComponent(WidgetAppGroupConfig.liveActivityDiagnosticsFileName)
        else { return }

        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        lines.append(String(line.dropLast()))
        if lines.count > maxEntries {
            lines.removeFirst(lines.count - maxEntries)
        }
        let output = lines.joined(separator: "\n") + "\n"
        try? output.write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct WidgetPreferencesSnapshot: Codable, Equatable {
    let selectedLeagues: [String]
    let selectedChannels: [String]
    let competitionFilterEnabled: Bool
    let channelFilterEnabled: Bool
    let englishPremierLeagueTeamsOnly: Bool
    let apiBaseURL: String
    let refreshIntervalMinutes: Int
    let showAllMatches: Bool
    let premierLeagueMatchesFirst: Bool

    enum CodingKeys: String, CodingKey {
        case selectedLeagues
        case selectedChannels
        case competitionFilterEnabled
        case channelFilterEnabled
        case englishPremierLeagueTeamsOnly
        case apiBaseURL
        case refreshIntervalMinutes
        case showAllMatches
        case premierLeagueMatchesFirst
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
        premierLeagueMatchesFirst = try container.decodeIfPresent(Bool.self, forKey: .premierLeagueMatchesFirst) ?? true
    }
}

private struct WidgetMatch: Identifiable, Codable, Hashable {
    let date: String
    let time: String
    let homeTeam: String
    let awayTeam: String
    let homeShortName: String?
    let awayShortName: String?
    let league: String
    let leagueSubcategory: String?
    let competitionWeight: Double?
    let tvChannels: [String]
    let homeScore: Int?
    let awayScore: Int?
    let aggregateHomeScore: Int?
    let aggregateAwayScore: Int?
    let firstLegHomeScore: Int?
    let firstLegAwayScore: Int?
    let scoreStatus: String?
    let homeTeamId: String?
    let awayTeamId: String?

    init(
        date: String,
        time: String,
        homeTeam: String,
        awayTeam: String,
        homeShortName: String? = nil,
        awayShortName: String? = nil,
        league: String,
        leagueSubcategory: String?,
        competitionWeight: Double? = nil,
        tvChannels: [String],
        homeScore: Int?,
        awayScore: Int?,
        aggregateHomeScore: Int? = nil,
        aggregateAwayScore: Int? = nil,
        firstLegHomeScore: Int? = nil,
        firstLegAwayScore: Int? = nil,
        scoreStatus: String?,
        homeTeamId: String? = nil,
        awayTeamId: String? = nil
    ) {
        self.date = date
        self.time = time
        self.homeTeam = homeTeam
        self.awayTeam = awayTeam
        self.homeShortName = homeShortName
        self.awayShortName = awayShortName
        self.league = league
        self.leagueSubcategory = leagueSubcategory
        self.competitionWeight = competitionWeight
        self.tvChannels = tvChannels
        self.homeScore = homeScore
        self.awayScore = awayScore
        self.aggregateHomeScore = aggregateHomeScore
        self.aggregateAwayScore = aggregateAwayScore
        self.firstLegHomeScore = firstLegHomeScore
        self.firstLegAwayScore = firstLegAwayScore
        self.scoreStatus = scoreStatus
        self.homeTeamId = homeTeamId
        self.awayTeamId = awayTeamId
    }

    var id: String {
        "\(date)|\(time)|\(league)|\(homeTeam)|\(awayTeam)"
    }

    var dateTime: Date? {
        WidgetMatchDateParser.shared.parse(date: date, time: time)
    }

    var hasScore: Bool {
        rawHasScore && !shouldSuppressScoreDisplay
    }

    var resolvedAggregateHomeScore: Int? {
        resolvedAggregateScore?.home
    }

    var resolvedAggregateAwayScore: Int? {
        resolvedAggregateScore?.away
    }

    var displayHomeTeam: String {
        homeTeam
    }

    var displayAwayTeam: String {
        awayTeam
    }

    var displayLeague: String {
        if let subcategory = leagueSubcategory, !subcategory.isEmpty {
            return "\(league): \(subcategory)"
        }
        return league
    }

    var isInProgress: Bool {
        guard let scoreStatus else { return false }
        let normalized = scoreStatus.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let inProgressTokens: Set<String> = ["HT", "ET", "LIVE", "PENS", "PEN", "PEN."]
        if inProgressTokens.contains(normalized) { return true }
        let minutePattern = #"^\d{1,3}(?:\+\d{1,2})?'?$"#
        return normalized.range(of: minutePattern, options: .regularExpression) != nil
    }

    var isFinished: Bool {
        guard let scoreStatus else { return false }
        let normalized = scoreStatus
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: ".", with: "")
        return normalized.hasPrefix("FT") || normalized.hasPrefix("AET") || normalized == "PENS"
    }

    var displayScoreStatus: String? {
        guard let scoreStatus else { return nil }
        let normalized = scoreStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let minutePattern = #"^\d{1,3}(?:\+\d{1,2})?'?$"#
        if normalized.range(of: minutePattern, options: .regularExpression) != nil {
            let minuteValue = normalized.replacingOccurrences(of: "'", with: "")
            return "\(minuteValue)'"
        }
        return normalized
    }

    private var rawHasScore: Bool {
        homeScore != nil && awayScore != nil
    }

    private var shouldSuppressScoreDisplay: Bool {
        guard rawHasScore else { return false }
        guard !isInProgress, !isFinished else { return false }
        guard let kickoff = dateTime else { return false }

        let secondsSinceKickoff = Date().timeIntervalSince(kickoff)
        if secondsSinceKickoff < 0 {
            return true
        }

        guard homeScore == 0, awayScore == 0 else { return false }
        return secondsSinceKickoff <= 15 * 60
    }

    private var resolvedAggregateScore: (home: Int, away: Int)? {
        if let firstLegHomeScore, let firstLegAwayScore {
            if homeScore != nil || awayScore != nil {
                return (
                    firstLegHomeScore + (homeScore ?? 0),
                    firstLegAwayScore + (awayScore ?? 0)
                )
            }

            return (firstLegHomeScore, firstLegAwayScore)
        }

        guard let aggregateHomeScore, let aggregateAwayScore else { return nil }
        return (aggregateHomeScore, aggregateAwayScore)
    }

    func withTvChannels(_ channels: [String]) -> WidgetMatch {
        WidgetMatch(
            date: date,
            time: time,
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            homeShortName: homeShortName,
            awayShortName: awayShortName,
            league: league,
            leagueSubcategory: leagueSubcategory,
            competitionWeight: competitionWeight,
            tvChannels: channels,
            homeScore: homeScore,
            awayScore: awayScore,
            aggregateHomeScore: aggregateHomeScore,
            aggregateAwayScore: aggregateAwayScore,
            firstLegHomeScore: firstLegHomeScore,
            firstLegAwayScore: firstLegAwayScore,
            scoreStatus: scoreStatus,
            homeTeamId: homeTeamId,
            awayTeamId: awayTeamId
        )
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
        case tvChannels = "tv_channels"
        case homeScore = "home_score"
        case awayScore = "away_score"
        case aggregateHomeScore = "aggregate_home_score"
        case aggregateAwayScore = "aggregate_away_score"
        case firstLegHomeScore = "first_leg_home_score"
        case firstLegAwayScore = "first_leg_away_score"
        case scoreStatus = "score_status"
        case homeTeamId = "home_team_id"
        case awayTeamId = "away_team_id"
    }
}

private struct WidgetSharedMatchesPayload: Codable {
    let snapshot: WidgetPreferencesSnapshot
    let matches: [WidgetMatch]
    let unfilteredMatches: [WidgetMatch]
    let lastUpdated: Date?
    let generatedAt: Date

    enum CodingKeys: String, CodingKey {
        case snapshot
        case matches
        case unfilteredMatches
        case lastUpdated
        case generatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = try container.decode(WidgetPreferencesSnapshot.self, forKey: .snapshot)
        matches = try container.decodeIfPresent([WidgetMatch].self, forKey: .matches) ?? []
        unfilteredMatches = try container.decodeIfPresent([WidgetMatch].self, forKey: .unfilteredMatches) ?? []
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
    }
}

@available(iOSApplicationExtension 16.1, *)
struct TopScoresLiveActivityMatchState: Codable, Hashable {
    let matchId: String
    let date: String
    let time: String
    let league: String
    let leagueSubcategory: String?
    let homeTeam: String
    let awayTeam: String
    let homeShortName: String?
    let awayShortName: String?
    let homeLogoKey: String?
    let awayLogoKey: String?
    let homeScore: Int?
    let awayScore: Int?
    let aggregateHomeScore: Int?
    let aggregateAwayScore: Int?
    let firstLegHomeScore: Int?
    let firstLegAwayScore: Int?
    let matchTime: String?
    let penaltyWinner: String?
    let penaltyResult: String?
    let tvChannels: [String]
    let tvLogoKey: String?

    enum CodingKeys: String, CodingKey {
        case matchId
        case date
        case time
        case league
        case leagueSubcategory
        case homeTeam
        case awayTeam
        case homeShortName
        case awayShortName
        case homeLogoKey
        case awayLogoKey
        case homeScore
        case awayScore
        case aggregateHomeScore
        case aggregateAwayScore
        case firstLegHomeScore
        case firstLegAwayScore
        case matchTime
        case penaltyWinner
        case penaltyResult
        case tvChannels
        case tvLogoKey
    }

    init(
        matchId: String,
        date: String,
        time: String,
        league: String,
        leagueSubcategory: String? = nil,
        homeTeam: String,
        awayTeam: String,
        homeShortName: String? = nil,
        awayShortName: String? = nil,
        homeLogoKey: String? = nil,
        awayLogoKey: String? = nil,
        homeScore: Int? = nil,
        awayScore: Int? = nil,
        aggregateHomeScore: Int? = nil,
        aggregateAwayScore: Int? = nil,
        firstLegHomeScore: Int? = nil,
        firstLegAwayScore: Int? = nil,
        matchTime: String? = nil,
        penaltyWinner: String? = nil,
        penaltyResult: String? = nil,
        tvChannels: [String] = [],
        tvLogoKey: String? = nil
    ) {
        self.matchId = matchId
        self.date = date
        self.time = time
        self.league = league
        self.leagueSubcategory = leagueSubcategory
        self.homeTeam = homeTeam
        self.awayTeam = awayTeam
        self.homeShortName = homeShortName
        self.awayShortName = awayShortName
        self.homeLogoKey = homeLogoKey
        self.awayLogoKey = awayLogoKey
        self.homeScore = homeScore
        self.awayScore = awayScore
        self.aggregateHomeScore = aggregateHomeScore
        self.aggregateAwayScore = aggregateAwayScore
        self.firstLegHomeScore = firstLegHomeScore
        self.firstLegAwayScore = firstLegAwayScore
        self.matchTime = matchTime
        self.penaltyWinner = penaltyWinner
        self.penaltyResult = penaltyResult
        self.tvChannels = tvChannels
        self.tvLogoKey = tvLogoKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        matchId = try container.decode(String.self, forKey: .matchId)
        date = try container.decode(String.self, forKey: .date)
        time = try container.decode(String.self, forKey: .time)
        league = try container.decode(String.self, forKey: .league)
        leagueSubcategory = try container.decodeIfPresent(String.self, forKey: .leagueSubcategory)
        homeTeam = try container.decode(String.self, forKey: .homeTeam)
        awayTeam = try container.decode(String.self, forKey: .awayTeam)
        homeShortName = try container.decodeIfPresent(String.self, forKey: .homeShortName)
        awayShortName = try container.decodeIfPresent(String.self, forKey: .awayShortName)
        homeLogoKey = try container.decodeIfPresent(String.self, forKey: .homeLogoKey)
        awayLogoKey = try container.decodeIfPresent(String.self, forKey: .awayLogoKey)
        homeScore = try container.decodeIfPresent(Int.self, forKey: .homeScore)
        awayScore = try container.decodeIfPresent(Int.self, forKey: .awayScore)
        aggregateHomeScore = try container.decodeIfPresent(Int.self, forKey: .aggregateHomeScore)
        aggregateAwayScore = try container.decodeIfPresent(Int.self, forKey: .aggregateAwayScore)
        firstLegHomeScore = try container.decodeIfPresent(Int.self, forKey: .firstLegHomeScore)
        firstLegAwayScore = try container.decodeIfPresent(Int.self, forKey: .firstLegAwayScore)
        matchTime = try container.decodeIfPresent(String.self, forKey: .matchTime)
        penaltyWinner = try container.decodeIfPresent(String.self, forKey: .penaltyWinner)
        penaltyResult = try container.decodeIfPresent(String.self, forKey: .penaltyResult)
        // Decode tv_channels tolerantly: accepts [String] or [{name,...}] objects
        struct TvChannelRaw: Decodable {
            let name: String?
        }
        if let channels = try? container.decodeIfPresent([TvChannelRaw].self, forKey: .tvChannels) {
            tvChannels = channels.compactMap(\.name).filter { !$0.isEmpty }
        } else if let strings = try? container.decodeIfPresent([String].self, forKey: .tvChannels) {
            tvChannels = strings
        } else {
            tvChannels = []
        }
        tvLogoKey = try container.decodeIfPresent(String.self, forKey: .tvLogoKey)
    }

    var hasScore: Bool {
        rawHasScore && !shouldSuppressScoreDisplay
    }

    var displayHomeTeam: String {
        let trimmed = homeShortName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? homeTeam : trimmed
    }

    var displayAwayTeam: String {
        let trimmed = awayShortName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? awayTeam : trimmed
    }

    var isInProgress: Bool {
        guard let matchTime else { return false }
        let normalized = matchTime.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let inProgressTokens: Set<String> = ["HT", "ET", "LIVE", "PENS", "PEN", "PEN."]
        if inProgressTokens.contains(normalized) { return true }
        let minutePattern = #"^\d{1,3}(?:\+\d{1,2})?'?$"#
        return normalized.range(of: minutePattern, options: .regularExpression) != nil
    }

    var isFinished: Bool {
        guard let matchTime else { return false }
        let normalized = matchTime
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: ".", with: "")
        return normalized.hasPrefix("FT") || normalized.hasPrefix("AET") || normalized == "PENS"
    }

    var hasDisplayableAggregateScore: Bool {
        resolvedAggregateScore != nil
    }

    var resolvedAggregateHomeScore: Int? {
        resolvedAggregateScore?.home
    }

    var resolvedAggregateAwayScore: Int? {
        resolvedAggregateScore?.away
    }

    var homeWonOnPenalties: Bool {
        penaltyWinner?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "home"
    }

    var awayWonOnPenalties: Bool {
        penaltyWinner?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "away"
    }

    var penaltyShootoutScoreText: String? {
        let trimmed = penaltyResult?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        if trimmed.range(of: #"^P\s+\d+\s*-\s*\d+$"#, options: .regularExpression) != nil {
            return trimmed.replacingOccurrences(of: #"\s*-\s*"#, with: "-", options: .regularExpression)
        }
        guard let match = trimmed.range(of: #"(\d+)\s*-\s*(\d+)"#, options: .regularExpression) else {
            return nil
        }
        let score = String(trimmed[match])
            .replacingOccurrences(of: #"\s*-\s*"#, with: "-", options: .regularExpression)
        return "P \(score)"
    }

    var shouldShowAggregateBracketScoresInline: Bool {
        !hasScore && !isInProgress && !isFinished && hasDisplayableAggregateScore
    }

    var suppressedScoreSummary: String? {
        guard rawHasScore, shouldSuppressScoreDisplay else { return nil }
        return "\(homeScore ?? 0)-\(awayScore ?? 0)"
    }

    private var rawHasScore: Bool {
        homeScore != nil && awayScore != nil
    }

    private var shouldSuppressScoreDisplay: Bool {
        guard rawHasScore else { return false }
        guard !isFinished else { return false }

        let normalizedStatus = matchTime?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if let normalizedStatus, !normalizedStatus.isEmpty {
            let inProgressTokens: Set<String> = ["HT", "ET", "LIVE", "PENS", "PEN", "PEN."]
            let minutePattern = #"^\d{1,3}(?:\+\d{1,2})?'?$"#
            if inProgressTokens.contains(normalizedStatus) ||
                normalizedStatus.range(of: minutePattern, options: .regularExpression) != nil {
                return false
            }
        }

        guard let kickoff = WidgetMatchDateParser.shared.parse(date: date, time: time) else {
            return false
        }

        let secondsSinceKickoff = Date().timeIntervalSince(kickoff)
        if secondsSinceKickoff < 0 {
            return true
        }

        guard homeScore == 0, awayScore == 0 else { return false }
        return secondsSinceKickoff <= 15 * 60
    }

    private var resolvedAggregateScore: (home: Int, away: Int)? {
        if let firstLegHomeScore, let firstLegAwayScore {
            if homeScore != nil || awayScore != nil {
                return (
                    firstLegHomeScore + (homeScore ?? 0),
                    firstLegAwayScore + (awayScore ?? 0)
                )
            }

            return (firstLegHomeScore, firstLegAwayScore)
        }

        guard let aggregateHomeScore, let aggregateAwayScore else { return nil }
        return (aggregateHomeScore, aggregateAwayScore)
    }
}

@available(iOSApplicationExtension 16.1, *)
struct TopScoresLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let mode: String
        let generatedAtEpochSeconds: Int
        let delayMinutes: Int
        let fantasyCurrentScore: Int?
        let matches: [TopScoresLiveActivityMatchState]
    }

    let appScope: String
}

@available(iOSApplicationExtension 16.1, *)
private enum LiveActivityMatchDisplayFilter {
    private static let postponedTokens: Set<String> = ["POSTPONED", "MATCH POSTPONED", "MATCH POSTPONED."]

    private static func isPostponed(_ match: TopScoresLiveActivityMatchState) -> Bool {
        guard let matchTime = match.matchTime?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(),
            !matchTime.isEmpty else {
            return false
        }
        return postponedTokens.contains(matchTime)
    }

    static func deduplicatedMatches(
        from matches: [TopScoresLiveActivityMatchState]
    ) -> [TopScoresLiveActivityMatchState] {
        var seenMatchIds = Set<String>()
        var seenTeamPairs = Set<String>()
        return matches.reversed().filter { match in
            guard !isPostponed(match) else {
                return false
            }
            if !match.matchId.isEmpty {
                return seenMatchIds.insert(match.matchId).inserted
            }
            let key = "\(match.date)|\(match.homeTeam.lowercased())|\(match.awayTeam.lowercased())"
            return seenTeamPairs.insert(key).inserted
        }.reversed()
    }

    static func displayMatches(
        for state: TopScoresLiveActivityAttributes.ContentState
    ) -> [TopScoresLiveActivityMatchState] {
        let deduplicated = deduplicatedMatches(from: state.matches)
        guard state.mode == "multi_live" || state.mode == "multi_upcoming" || state.mode == "multi_finished" else {
            return deduplicated
        }
        return deduplicated
    }

    static func trailingDisplayMatches(
        for state: TopScoresLiveActivityAttributes.ContentState
    ) -> [TopScoresLiveActivityMatchState] {
        Array(deduplicatedMatches(from: state.matches).dropFirst())
    }
}

private struct WidgetMatchDay: Identifiable, Hashable {
    let id: String
    let dateKey: String
    let heading: String
    let matches: [WidgetMatch]
}

private enum WidgetChannelSelection {
    private static let specialKeywords: [String: String] = [
        "Amazon (all)": "amazon",
        "BBC (all)": "bbc",
        "DAZN (all)": "dazn",
        "Disney+ (all)": "disneyplus",
        "HBO Max (all)": "hbomax",
        "ITV (all)": "itv",
        "LaLiga TV (all)": "laligatv",
        "Premier Sports (all)": "premiersports",
        "Sky (all)": "sky",
        "TNT (all)": "tnt"
    ]

    static func normalizedSelectedOptions(_ selections: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []

        for selection in selections {
            let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let canonical = canonicalSpecialOption(for: trimmed) ?? trimmed
            let dedupeKey = normalized(canonical)
            if !seen.contains(dedupeKey) {
                seen.insert(dedupeKey)
                output.append(canonical)
            }
        }

        return output.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func filterChannels(_ channels: [String], selectedOptions: [String]) -> [String] {
        let normalizedSelections = normalizedSelectedOptions(selectedOptions)
        guard !normalizedSelections.isEmpty else { return channels }

        return channels.filter { channel in
            normalizedSelections.contains { selection in
                channelMatchesSelection(channelName: channel, selection: selection)
            }
        }
    }

    private static func channelMatchesSelection(channelName: String, selection: String) -> Bool {
        if let special = canonicalSpecialOption(for: selection),
           let keyword = specialKeywords[special] {
            let tokens = normalizedTokens(channelName)
            return tokens.contains { token in token.hasPrefix(keyword) }
        }

        return normalized(channelName) == normalized(selection)
    }

    nonisolated private static func normalizedTokens(_ value: String) -> [String] {
        normalized(value)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    nonisolated private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func canonicalSpecialOption(for selection: String) -> String? {
        let normalizedSelection = normalized(selection)
        return specialKeywords.keys.first { option in
            let canonical = normalized(option)
            let base = normalized(baseName(for: option))
            return normalizedSelection == canonical || normalizedSelection == base
        }
    }

    private static func baseName(for option: String) -> String {
        option.replacingOccurrences(of: "(all)", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum WidgetMatchDataLoader {
    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Basic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func loadPayload() -> WidgetSharedMatchesPayload? {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: WidgetAppGroupConfig.identifier)
        else {
            NSLog("[Widget] app group container URL missing")
            return nil
        }

        let url = containerURL.appendingPathComponent(WidgetAppGroupConfig.sharedMatchesFileName)
        guard let data = try? Data(contentsOf: url) else {
            NSLog("[Widget] shared payload missing at %@", url.path)
            return nil
        }

        NSLog("[Widget] loaded shared payload bytes=\(data.count) path=\(url.path)")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = Self.iso8601WithFractional.date(from: value) ?? Self.iso8601Basic.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 date: \(value)"
            )
        }
        do {
            return try decoder.decode(WidgetSharedMatchesPayload.self, from: data)
        } catch {
            NSLog("[Widget] payload decode failed: %@", error.localizedDescription)
            return nil
        }
    }
}

private enum WidgetMatchPipeline {
    private static let premierLeagueTeamNames: Set<String> = [
        "arsenal", "aston villa", "bournemouth", "afc bournemouth", "brentford",
        "brighton", "brighton and hove albion", "brighton & hove albion", "burnley",
        "chelsea", "crystal palace", "everton", "fulham", "leeds", "leeds united",
        "liverpool", "manchester city", "man city", "manchester united", "man united",
        "newcastle", "newcastle united", "nottingham forest", "nottm forest",
        "sunderland", "tottenham", "tottenham hotspur", "spurs",
        "west ham", "west ham united", "wolverhampton wanderers", "wolves",
    ]

    private static func matchIncludesPremierLeagueTeam(_ match: WidgetMatch) -> Bool {
        premierLeagueTeamNames.contains(match.homeTeam.lowercased()) ||
        premierLeagueTeamNames.contains(match.awayTeam.lowercased())
    }

    static func groupedDays(from payload: WidgetSharedMatchesPayload?) -> [WidgetMatchDay] {
        guard let payload else { return [] }

        // The phone app payload is already filtered by the current preference snapshot.
        // Re-filtering inside the widget can diverge from what the app is showing.
        let sourceMatches: [WidgetMatch]
        if payload.snapshot.showAllMatches, !payload.unfilteredMatches.isEmpty {
            sourceMatches = payload.unfilteredMatches
        } else {
            sourceMatches = payload.matches
        }

        // Widgets are fixtures-first surfaces; keep today onwards to match the app's Fixtures view.
        let upcomingFixtures = filterFixtures(sourceMatches)
        let sorted = sortedMatches(upcomingFixtures)
        return groupMatches(sorted, premierLeagueMatchesFirst: payload.snapshot.premierLeagueMatchesFirst)
    }

    private static func filterFixtures(_ matches: [WidgetMatch]) -> [WidgetMatch] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        return matches.filter { match in
            // Widget is fixtures-focused; exclude completed matches.
            guard !match.isFinished else { return false }

            guard let date = WidgetMatchDateParser.shared.parse(date: match.date, time: "00:00") else {
                // Drop stale legacy result entries with non-ISO dates (e.g. "Sun, Jan 25").
                return false
            }
            return calendar.startOfDay(for: date) >= today
        }
    }

    private static func sortedMatches(_ matches: [WidgetMatch]) -> [WidgetMatch] {
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

    private static func groupMatches(_ matches: [WidgetMatch], premierLeagueMatchesFirst: Bool) -> [WidgetMatchDay] {
        let groupedByDate = Dictionary(grouping: matches) { $0.date }
        let dateKeys = groupedByDate.keys.sorted()

        return dateKeys.compactMap { dateKey in
            guard let matchesForDate = groupedByDate[dateKey], !matchesForDate.isEmpty else { return nil }
            let sortedDateMatches = sortedMatches(matchesForDate)

            let heading: String
            if let parsed = WidgetMatchDateParser.shared.parse(date: dateKey, time: "00:00") {
                heading = WidgetMatchDateParser.shared.displayDateWithRelative(parsed)
            } else {
                heading = dateKey
            }

            let groupedByLeague = Dictionary(grouping: sortedDateMatches) { $0.displayLeague }
            let orderedMatches = groupedByLeague.compactMap { entry -> (league: String, matches: [WidgetMatch], firstKickoff: Date, weight: Double)? in
                let (league, leagueMatches) = entry
                var sortedLeagueMatches = sortedMatches(leagueMatches)
                if premierLeagueMatchesFirst {
                    sortedLeagueMatches = sortedLeagueMatches.sorted { lhs, rhs in
                        let lhsEPL = matchIncludesPremierLeagueTeam(lhs)
                        let rhsEPL = matchIncludesPremierLeagueTeam(rhs)
                        if lhsEPL != rhsEPL { return lhsEPL && !rhsEPL }
                        return false
                    }
                }
                guard let firstMatch = sortedLeagueMatches.first else { return nil }
                return (
                    league: league,
                    matches: sortedLeagueMatches,
                    firstKickoff: matchSortDate(for: firstMatch),
                    weight: leagueMatches.map { competitionWeight(for: $0) }.max() ?? 0
                )
            }
            .sorted { lhs, rhs in
                // Competition groups are always ordered by weight descending —
                // Premier League (100) first, Championship (40) last, etc.
                // Kick-off time is a tiebreaker within the same weight.
                if lhs.weight != rhs.weight {
                    return lhs.weight > rhs.weight
                }
                if lhs.firstKickoff != rhs.firstKickoff {
                    return lhs.firstKickoff < rhs.firstKickoff
                }
                return lhs.league.localizedCaseInsensitiveCompare(rhs.league) == .orderedAscending
            }
            .flatMap(\.matches)

            return WidgetMatchDay(
                id: dateKey,
                dateKey: dateKey,
                heading: heading,
                matches: orderedMatches
            )
        }
    }

    private static func matchSortDate(for match: WidgetMatch) -> Date {
        match.dateTime ?? WidgetMatchDateParser.shared.parse(date: match.date, time: "00:00") ?? .distantFuture
    }

    private static func competitionWeight(for match: WidgetMatch) -> Double {
        match.competitionWeight ?? 0
    }

}

private final class WidgetMatchDateParser {
    static let shared = WidgetMatchDateParser()

    private let lock = NSLock()
    private let dateTimeFormatter: DateFormatter
    private let headingFormatter: DateFormatter

    private init() {
        let dateTimeFormatter = DateFormatter()
        dateTimeFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateTimeFormatter.timeZone = TimeZone.current
        dateTimeFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        self.dateTimeFormatter = dateTimeFormatter

        let headingFormatter = DateFormatter()
        headingFormatter.locale = Locale(identifier: "en_US_POSIX")
        headingFormatter.timeZone = TimeZone.current
        headingFormatter.dateFormat = "EEE, MMM d"
        self.headingFormatter = headingFormatter
    }

    func parse(date: String, time: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return dateTimeFormatter.date(from: "\(date) \(time)")
    }

    func displayDateWithRelative(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInTomorrow(date) {
            return "Tomorrow"
        }
        lock.lock()
        defer { lock.unlock() }
        return headingFormatter.string(from: date)
    }
}

private struct TopScoresWidgetEntry: TimelineEntry {
    let date: Date
    let days: [WidgetMatchDay]
    let lastUpdated: Date?
}

private struct TopScoresWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> TopScoresWidgetEntry {
        TopScoresWidgetEntry(date: Date(), days: sampleDays, lastUpdated: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (TopScoresWidgetEntry) -> Void) {
        completion(makeEntry(fallbackToSample: context.isPreview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TopScoresWidgetEntry>) -> Void) {
        let entry = makeEntry(fallbackToSample: false)

        // Determine refresh interval based on whether there are live matches
        let hasLiveMatches = entry.days.contains { day in
            day.matches.contains(where: \.isInProgress)
        }

        // Aggressive refresh for live matches: 30 seconds
        // Standard refresh for non-live: 10 minutes
        let refreshInterval: TimeInterval = hasLiveMatches ? 30 : 600
        let nextRefresh = Date().addingTimeInterval(refreshInterval)

        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func makeEntry(fallbackToSample: Bool) -> TopScoresWidgetEntry {
        let payload = WidgetMatchDataLoader.loadPayload()
        if let payload {
            let firstDate = payload.matches.first?.date ?? "none"
            NSLog("[Widget] payload loaded: matches=\(payload.matches.count) unfiltered=\(payload.unfilteredMatches.count) firstDate=\(firstDate) lastUpdated=\(payload.lastUpdated?.description ?? "nil")")
        } else {
            NSLog("[Widget] payload missing (shared-matches.json not available)")
        }
        let days = WidgetMatchPipeline.groupedDays(from: payload)
        NSLog("[Widget] grouped days=\(days.count) firstDay=\(days.first?.dateKey ?? "none")")

        if days.isEmpty, fallbackToSample {
            return TopScoresWidgetEntry(date: Date(), days: sampleDays, lastUpdated: nil)
        }

        return TopScoresWidgetEntry(date: Date(), days: days, lastUpdated: payload?.lastUpdated)
    }

    private var sampleDays: [WidgetMatchDay] {
        [
            WidgetMatchDay(
                id: "2026-02-12",
                dateKey: "2026-02-12",
                heading: "Today",
                matches: [
                    WidgetMatch(
                        date: "2026-02-12",
                        time: "20:00",
                        homeTeam: "Arsenal",
                        awayTeam: "Chelsea",
                        league: "Premier League",
                        leagueSubcategory: nil,
                        tvChannels: ["Sky Sports Main Event", "Sky Sports Football"],
                        homeScore: nil,
                        awayScore: nil,
                        scoreStatus: nil
                    ),
                    WidgetMatch(
                        date: "2026-02-12",
                        time: "22:00",
                        homeTeam: "Real Madrid",
                        awayTeam: "Barcelona",
                        league: "La Liga",
                        leagueSubcategory: nil,
                        tvChannels: ["ITV1"],
                        homeScore: nil,
                        awayScore: nil,
                        scoreStatus: nil
                    )
                ]
            )
        ]
    }
}

private struct TopScoresWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family

    let entry: TopScoresWidgetEntry

    var body: some View {
        switch family {
        case .systemSmall:
            CompactMatchesWidgetView(entry: entry, maxRows: 2, showDayHeading: true)
        case .systemMedium:
            CompactMatchesWidgetView(entry: entry, maxRows: 5, showDayHeading: true)
        case .systemLarge:
            LargeMatchesWidgetView(entry: entry, compact: false)
        default:
            CompactMatchesWidgetView(entry: entry, maxRows: 2, showDayHeading: true)
        }
    }
}

private struct CompactMatchesWidgetView: View {
    let entry: TopScoresWidgetEntry
    let maxRows: Int
    let showDayHeading: Bool

    private var firstHeading: String? {
        entry.days.first?.heading
    }

    private var visibleMatches: [WidgetMatch] {
        entry.days
            .flatMap(\.matches)
            .prefix(maxRows)
            .map { $0 }
    }

    var body: some View {
        Group {
            if visibleMatches.isEmpty {
                EmptyMatchesWidgetView()
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if showDayHeading, let firstHeading {
                        Text(firstHeading)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    ForEach(visibleMatches) { match in
                        CompactMatchRow(match: match)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

}

private struct CompactMatchRow: View {
    let match: WidgetMatch

    private let logoSize: CGFloat = 11
    private let centerColumnWidth: CGFloat = 38

    var body: some View {
        HStack(spacing: 4) {
            WidgetTeamLogo(
                teamName: match.homeTeam,
                teamId: match.homeTeamId,
                alternateNames: [match.homeShortName].compactMap { $0 },
                size: logoSize
            )

            Text(WidgetNameFormatter.abbreviated(match.displayHomeTeam, length: 7))
                .font(.caption2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(centerText)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: centerColumnWidth, alignment: .center)

            Text(WidgetNameFormatter.abbreviated(match.displayAwayTeam, length: 7))
                .font(.caption2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)

            WidgetTeamLogo(
                teamName: match.awayTeam,
                teamId: match.awayTeamId,
                alternateNames: [match.awayShortName].compactMap { $0 },
                size: logoSize
            )
        }
    }

    private var centerText: String {
        if let homeScore = match.homeScore, let awayScore = match.awayScore {
            return "\(homeScore)-\(awayScore)"
        }
        return match.time
    }
}

private struct LargeMatchesWidgetView: View {
    let entry: TopScoresWidgetEntry
    let compact: Bool

    private var headingHeight: CGFloat { compact ? 14 : 16 }
    private var rowHeight: CGFloat { compact ? 20 : 24 }
    private var verticalSpacing: CGFloat { compact ? 3 : 4 }

    var body: some View {
        GeometryReader { proxy in
            let verticalPadding = compact ? 16.0 : 20.0
            let items = LargeLayoutBuilder.items(
                days: entry.days,
                availableHeight: max(0, proxy.size.height - verticalPadding),
                headingHeight: headingHeight,
                rowHeight: rowHeight,
                spacing: verticalSpacing
            )

            if items.isEmpty {
                EmptyMatchesWidgetView()
            } else {
                VStack(alignment: .leading, spacing: verticalSpacing) {
                    ForEach(items) { item in
                        switch item.kind {
                        case .heading(let title):
                            Text(title)
                                .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(height: headingHeight, alignment: .leading)
                        case .match(let match):
                            LargeMatchRow(match: match, compact: compact)
                                .frame(height: rowHeight)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, compact ? 10 : 12)
                .padding(.vertical, compact ? 8 : 10)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct SmallMatchesWidgetView: View {
    let entry: TopScoresWidgetEntry

    private let headingHeight: CGFloat = 12
    private let rowHeight: CGFloat = 20
    private let verticalSpacing: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let verticalPadding = 16.0
            let items = SmallLayoutBuilder.items(
                days: entry.days,
                availableHeight: max(0, proxy.size.height - verticalPadding),
                headingHeight: headingHeight,
                rowHeight: rowHeight,
                spacing: verticalSpacing
            )

            if items.isEmpty {
                EmptyMatchesWidgetView()
            } else {
                VStack(alignment: .leading, spacing: verticalSpacing) {
                    ForEach(items) { item in
                        switch item.kind {
                        case .heading(let title):
                            Text(title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(height: headingHeight, alignment: .leading)
                        case .match(let match):
                            SmallMatchRow(match: match)
                                .frame(height: rowHeight)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct LargeMatchRow: View {
    let match: WidgetMatch
    let compact: Bool

    private var centerColumnWidth: CGFloat {
        // Use wider column when showing time to prevent truncation
        if match.hasScore {
            return compact ? 42 : 50
        } else {
            return compact ? 50 : 58
        }
    }

    private var maxTeamNameCharacters: Int {
        compact ? 12 : 18
    }

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            WidgetTeamLogo(
                teamName: match.homeTeam,
                teamId: match.homeTeamId,
                alternateNames: [match.homeShortName].compactMap { $0 },
                size: compact ? 14 : 16
            )

            Spacer(minLength: compact ? 1 : 4)

            Text(WidgetNameFormatter.hyphenated(match.displayHomeTeam, maxCharacters: maxTeamNameCharacters))
                .font(compact ? .caption2 : .caption)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .layoutPriority(1)

            centerContent
                .frame(width: centerColumnWidth, alignment: .center)

            Text(WidgetNameFormatter.hyphenated(match.displayAwayTeam, maxCharacters: maxTeamNameCharacters))
                .font(compact ? .caption2 : .caption)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            Spacer(minLength: compact ? 1 : 4)

            WidgetTeamLogo(
                teamName: match.awayTeam,
                teamId: match.awayTeamId,
                alternateNames: [match.awayShortName].compactMap { $0 },
                size: compact ? 14 : 16
            )
        }
    }

    @ViewBuilder
    private var centerContent: some View {
        if match.hasScore {
            HStack(spacing: compact ? 3 : 4) {
                Text("\(match.homeScore!)")
                    .font(compact ? .caption.weight(.semibold) : .caption.weight(.bold))
                    .monospacedDigit()
                    .fixedSize()

                if let status = match.displayScoreStatus {
                    Text(status)
                        .font(.system(size: compact ? 7 : 8))
                        .fontWeight(match.isInProgress ? .semibold : .regular)
                        .foregroundStyle(match.isInProgress ? .red : .secondary)
                        .padding(.horizontal, compact ? 3 : 4)
                        .padding(.vertical, compact ? 1 : 2)
                        .background(match.isInProgress ? Color.red.opacity(0.15) : Color.clear)
                        .cornerRadius(3)
                        .fixedSize()
                } else {
                    Text("-")
                        .font(.system(size: compact ? 7 : 8))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }

                Text("\(match.awayScore!)")
                    .font(compact ? .caption.weight(.semibold) : .caption.weight(.bold))
                    .monospacedDigit()
                    .fixedSize()
            }
        } else {
            VStack(spacing: compact ? 1 : 2) {
                if !match.isFinished {
                    WidgetChannelBadge(channels: match.tvChannels, compact: compact)
                }
                Text(match.time)
                    .font(.system(size: compact ? 8 : 9))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
    }
}

private struct SmallMatchRow: View {
    let match: WidgetMatch

    private let centerColumnWidth: CGFloat = 32

    var body: some View {
        HStack(spacing: 3) {
            WidgetTeamLogo(
                teamName: match.homeTeam,
                teamId: match.homeTeamId,
                alternateNames: [match.homeShortName].compactMap { $0 },
                size: 12
            )

            Spacer(minLength: 1)

            Text(WidgetNameFormatter.abbreviated(match.displayHomeTeam))
                .font(.caption2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .layoutPriority(1)

            centerContent
                .frame(width: centerColumnWidth, alignment: .center)

            Text(WidgetNameFormatter.abbreviated(match.displayAwayTeam))
                .font(.caption2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            Spacer(minLength: 1)

            WidgetTeamLogo(
                teamName: match.awayTeam,
                teamId: match.awayTeamId,
                alternateNames: [match.awayShortName].compactMap { $0 },
                size: 12
            )
        }
    }

    @ViewBuilder
    private var centerContent: some View {
        if match.hasScore {
            HStack(spacing: 2) {
                Text("\(match.homeScore!)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()

                if let status = match.displayScoreStatus {
                    Text(status)
                        .font(.system(size: 7))
                        .fontWeight(match.isInProgress ? .semibold : .regular)
                        .foregroundStyle(match.isInProgress ? .red : .secondary)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 1)
                        .background(match.isInProgress ? Color.red.opacity(0.15) : Color.clear)
                        .cornerRadius(2)
                } else {
                    Text("-")
                        .font(.system(size: 7))
                        .foregroundStyle(.secondary)
                }

                Text("\(match.awayScore!)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
            }
        } else {
            VStack(spacing: 1) {
                if !match.isFinished {
                    WidgetChannelBadge(channels: match.tvChannels, compact: true)
                }
                Text(match.time)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

private enum WidgetNameFormatter {
    static func hyphenated(_ name: String, maxCharacters: Int) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxCharacters > 1 else { return "-" }
        guard trimmed.count > maxCharacters else { return trimmed }

        let prefixLength = max(1, maxCharacters - 1)
        let prefix = String(trimmed.prefix(prefixLength))
        return "\(prefix)-"
    }

    static func abbreviated(_ name: String, length: Int = 3) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > length else { return trimmed }
        return String(trimmed.prefix(length))
    }
}

private struct WidgetTeamLogo: View {
    let teamName: String
    var teamId: String? = nil
    var alternateNames: [String] = []
    let size: CGFloat

    var body: some View {
        Group {
            if let image = WidgetTeamLogoResolver.shared.image(
                for: teamName,
                teamId: teamId,
                alternateNames: alternateNames,
                idealPointSize: size
            ) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "shield")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

private struct WidgetChannelBadge: View {
    let channels: [String]
    var logoKey: String? = nil
    let compact: Bool

    private var primaryChannel: String? { channels.first }
    private var preferredLogoIdentifier: String? {
        let trimmedLogoKey = logoKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedLogoKey.isEmpty {
            return trimmedLogoKey
        }
        return primaryChannel
    }

    var body: some View {
        Group {
            if let preferredLogoIdentifier,
               let image = WidgetTvLogoResolver.shared.image(
                   for: preferredLogoIdentifier,
                   idealPointSize: compact ? 12 : 14
               ) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: compact ? 10 : 12)
            } else {
                Image(systemName: "tv")
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct EmptyMatchesWidgetView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Top Scores")
                .font(.caption.weight(.semibold))
            Text("No matches for your filters")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }
}

private struct LargeLayoutItem: Identifiable {
    enum Kind {
        case heading(String)
        case match(WidgetMatch)
    }

    let id: String
    let kind: Kind
}

private enum LargeLayoutBuilder {
    static func items(
        days: [WidgetMatchDay],
        availableHeight: CGFloat,
        headingHeight: CGFloat,
        rowHeight: CGFloat,
        spacing: CGFloat
    ) -> [LargeLayoutItem] {
        guard availableHeight > 0 else { return [] }

        var usedHeight: CGFloat = 0
        var output: [LargeLayoutItem] = []

        func additionalCost(for height: CGFloat, existingCount: Int) -> CGFloat {
            height + (existingCount > 0 ? spacing : 0)
        }

        func canFit(_ height: CGFloat, existingCount: Int, currentUsed: CGFloat) -> Bool {
            currentUsed + additionalCost(for: height, existingCount: existingCount) <= availableHeight
        }

        func append(_ item: LargeLayoutItem, height: CGFloat) {
            usedHeight += additionalCost(for: height, existingCount: output.count)
            output.append(item)
        }

        for day in days {
            guard !day.matches.isEmpty else { continue }

            let usedAfterHeading = usedHeight + additionalCost(for: headingHeight, existingCount: output.count)
            let countAfterHeading = output.count + 1
            let canFitHeadingAndRow = usedAfterHeading + additionalCost(for: rowHeight, existingCount: countAfterHeading) <= availableHeight
            guard canFitHeadingAndRow else { break }

            append(LargeLayoutItem(id: "heading-\(day.id)", kind: .heading(day.heading)), height: headingHeight)

            for match in day.matches {
                guard canFit(rowHeight, existingCount: output.count, currentUsed: usedHeight) else {
                    return output
                }
                append(LargeLayoutItem(id: "match-\(match.id)", kind: .match(match)), height: rowHeight)
            }
        }

        return output
    }
}

private enum SmallLayoutBuilder {
    struct Item: Identifiable {
        enum Kind {
            case heading(String)
            case match(WidgetMatch)
        }

        let id: String
        let kind: Kind
    }

    static func items(
        days: [WidgetMatchDay],
        availableHeight: CGFloat,
        headingHeight: CGFloat,
        rowHeight: CGFloat,
        spacing: CGFloat
    ) -> [Item] {
        guard availableHeight > 0 else { return [] }

        var usedHeight: CGFloat = 0
        var output: [Item] = []

        func additionalCost(for height: CGFloat, existingCount: Int) -> CGFloat {
            height + (existingCount > 0 ? spacing : 0)
        }

        func canFit(_ height: CGFloat, existingCount: Int, currentUsed: CGFloat) -> Bool {
            currentUsed + additionalCost(for: height, existingCount: existingCount) <= availableHeight
        }

        func append(_ item: Item, height: CGFloat) {
            usedHeight += additionalCost(for: height, existingCount: output.count)
            output.append(item)
        }

        for day in days {
            guard !day.matches.isEmpty else { continue }

            let usedAfterHeading = usedHeight + additionalCost(for: headingHeight, existingCount: output.count)
            let countAfterHeading = output.count + 1
            let canFitHeadingAndRow = usedAfterHeading + additionalCost(for: rowHeight, existingCount: countAfterHeading) <= availableHeight
            guard canFitHeadingAndRow else { break }

            append(Item(id: "heading-\(day.id)", kind: .heading(day.heading)), height: headingHeight)

            for match in day.matches {
                guard canFit(rowHeight, existingCount: output.count, currentUsed: usedHeight) else {
                    return output
                }
                append(Item(id: "match-\(match.id)", kind: .match(match)), height: rowHeight)
            }
        }

        return output
    }
}

private final class WidgetTeamLogoResolver {
    static let shared = WidgetTeamLogoResolver()

    private let fallbackName = "_noTeamLogo"
    private let lock = NSLock()
    private let bundles: [Bundle]
    private var normalizedLookup: [String: URL] = [:]
    private var coreLookup: [String: [URL]] = [:]
    private var originalLookup: [String: URL] = [:]
    private var assetNormalizedLookup: [String: String] = [:]
    private var assetCoreLookup: [String: [String]] = [:]
    private var assetOriginalLookup: [String: String] = [:]
    private var fallbackAssetName: String?
    private var cache: [String: UIImage] = [:]

    private init() {
        bundles = Self.logoBundles()
        loadLogos()
    }

    func image(
        for teamName: String,
        teamId: String? = nil,
        alternateNames: [String] = [],
        variant: WidgetLogoAssetVariant = .standard,
        idealPointSize: CGFloat? = nil
    ) -> UIImage? {
        if let teamId, let badge = widgetBadgeImage(forTeamId: teamId) {
            return badge
        }
        return image(for: teamName, alternateNames: alternateNames, variant: variant, idealPointSize: idealPointSize)
    }

    private func widgetBadgeImage(forTeamId teamId: String) -> UIImage? {
        guard let dir = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: WidgetAppGroupConfig.identifier)?
            .appendingPathComponent("team-badges", isDirectory: true) else { return nil }
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode([String: String].self, from: data),
              let filename = manifest[teamId] else { return nil }
        let fileURL = dir.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return UIImage(contentsOfFile: fileURL.path)
    }

    func image(
        for teamName: String,
        alternateNames: [String] = [],
        variant: WidgetLogoAssetVariant = .standard,
        idealPointSize: CGFloat? = nil
    ) -> UIImage? {
        let cacheKey = Self.cacheKey(
            for: teamName,
            alternateNames: alternateNames,
            variant: variant,
            idealPointSize: idealPointSize
        )

        lock.lock()
        if let cached = cache[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        if let image = resolveAssetImage(
            for: teamName,
            alternateNames: alternateNames,
            variant: variant,
            idealPointSize: idealPointSize
        ) ??
            resolveAssetFallbackImage(variant: variant, idealPointSize: idealPointSize) {
            lock.lock()
            cache[cacheKey] = image
            lock.unlock()
            return image
        }

        let url = resolveURL(for: teamName, alternateNames: alternateNames) ??
            resolveURL(for: fallbackName)
        guard let url else { return nil }

        let image = Self.downsampledImage(at: url, idealPointSize: idealPointSize)
        if let image {
            lock.lock()
            cache[cacheKey] = image
            lock.unlock()
        }

        return image
    }

    func assetName(
        for teamName: String,
        alternateNames: [String] = [],
        variant: WidgetLogoAssetVariant = .standard,
        allowsFallback: Bool = true
    ) -> String? {
        let baseAssetName = resolveAssetName(for: teamName, alternateNames: alternateNames)
        return preferredAssetName(from: baseAssetName, variant: variant) ??
            (allowsFallback ? preferredAssetName(from: fallbackAssetName, variant: variant) : nil)
    }

    private func loadLogos() {
        let urls = bundles.flatMap { bundle in
            var resolved = bundle.urls(forResourcesWithExtension: "png", subdirectory: "team-logos") ?? []
            if resolved.isEmpty {
                resolved = bundle.urls(forResourcesWithExtension: "png", subdirectory: nil) ?? []
            }
            return resolved
        }
        for url in urls {
            let fileName = url.deletingPathExtension().lastPathComponent
            let normalized = Self.normalizedKey(fileName)
            normalizedLookup[normalized] = normalizedLookup[normalized] ?? url
            let core = Self.normalizedCoreKey(fileName)
            if !core.isEmpty {
                coreLookup[core, default: []].append(url)
            }
            originalLookup[fileName.lowercased()] = originalLookup[fileName.lowercased()] ?? url
        }

        loadAssetCatalogLogos()

        NSLog("[Widget] team logos file fallback loaded count=\(urls.count)")
    }

    private static func logoBundles() -> [Bundle] {
        var output: [Bundle] = []
        var seenURLs = Set<URL>()

        for bundle in [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks {
            let url = bundle.bundleURL
            guard !seenURLs.contains(url) else { continue }
            seenURLs.insert(url)
            output.append(bundle)
        }

        let mainBundleURL = Bundle.main.bundleURL
        if mainBundleURL.pathExtension == "appex" {
            let containingAppURL = mainBundleURL.deletingLastPathComponent().deletingLastPathComponent()
            if let containingAppBundle = Bundle(url: containingAppURL) {
                let url = containingAppBundle.bundleURL
                if !seenURLs.contains(url) {
                    seenURLs.insert(url)
                    output.append(containingAppBundle)
                }
            }
        }

        return output
    }

    private func loadAssetCatalogLogos() {
        var loadedNames = Set<String>()
        for bundle in bundles {
            guard let manifestURL = bundle.url(forResource: "team_logo_assets", withExtension: "json"),
                  let data = try? Data(contentsOf: manifestURL),
                  let assetNames = try? JSONDecoder().decode([String].self, from: data) else {
                continue
            }

            for name in assetNames {
                let key = name.lowercased()
                guard loadedNames.insert(key).inserted else { continue }
                registerAssetName(name)
            }
        }
    }

    private func registerAssetName(_ name: String) {
        let normalized = Self.normalizedKey(name)
        assetNormalizedLookup[normalized] = assetNormalizedLookup[normalized] ?? name

        let core = Self.normalizedCoreKey(name)
        if !core.isEmpty {
            assetCoreLookup[core, default: []].append(name)
        }

        assetOriginalLookup[name.lowercased()] = assetOriginalLookup[name.lowercased()] ?? name
        if Self.isFallbackName(name) {
            fallbackAssetName = name
        }
    }

    private func resolveAssetImage(
        for teamName: String,
        alternateNames: [String] = [],
        variant: WidgetLogoAssetVariant,
        idealPointSize: CGFloat?
    ) -> UIImage? {
        let baseAssetName = resolveAssetName(for: teamName, alternateNames: alternateNames)
        guard let assetName = preferredAssetName(from: baseAssetName, variant: variant) else {
            return nil
        }
        return imageFromAssets(named: assetName, idealPointSize: idealPointSize)
    }

    private func preferredAssetName(from baseAssetName: String?, variant: WidgetLogoAssetVariant) -> String? {
        guard let baseAssetName else { return nil }
        for candidate in variant.candidateAssetNames(for: baseAssetName) {
            if directAssetName(for: candidate) != nil {
                return candidate
            }
        }
        return nil
    }

    private func resolveAssetFallbackImage(
        variant: WidgetLogoAssetVariant,
        idealPointSize: CGFloat?
    ) -> UIImage? {
        if let fallbackAssetName = preferredAssetName(from: fallbackAssetName, variant: variant) {
            if let image = imageFromAssets(named: fallbackAssetName, idealPointSize: idealPointSize) {
                return image
            }
        }

        for candidate in [fallbackName, "\(fallbackName) 1"] {
            if let resolved = preferredAssetName(from: candidate, variant: variant),
               let image = imageFromAssets(named: resolved, idealPointSize: idealPointSize) {
                return image
            }
        }

        return nil
    }

    private func imageFromAssets(named name: String, idealPointSize: CGFloat?) -> UIImage? {
        for bundle in bundles {
            if let image = UIImage(named: name, in: bundle, compatibleWith: nil) {
                return Self.preparedImage(image, idealPointSize: idealPointSize)
            }
        }
        return nil
    }

    private static func cacheKey(
        for teamName: String,
        alternateNames: [String],
        variant: WidgetLogoAssetVariant,
        idealPointSize: CGFloat?
    ) -> String {
        let normalized = lookupCandidates(for: teamName, alternateNames: alternateNames)
            .map(normalizedKey)
            .joined(separator: "|")
        let pixelSize = Int(maxPixelSize(for: idealPointSize).rounded())
        return "\(variant.cacheKeyPrefix)|\(normalized)|\(pixelSize)"
    }

    private static func maxPixelSize(for idealPointSize: CGFloat?) -> CGFloat {
        guard let idealPointSize, idealPointSize > 0 else { return 0 }
        return max(ceil(idealPointSize * 3), 40)
    }

    private static func preparedImage(_ image: UIImage, idealPointSize: CGFloat?) -> UIImage {
        let targetPixels = maxPixelSize(for: idealPointSize)
        guard targetPixels > 0 else { return image }

        let sourceWidth = image.size.width * image.scale
        let sourceHeight = image.size.height * image.scale
        let largestSide = max(sourceWidth, sourceHeight)
        guard largestSide > targetPixels * 1.2 else { return image }
        guard sourceWidth > 0, sourceHeight > 0 else { return image }

        let scale = targetPixels / largestSide
        let targetSize = CGSize(
            width: max(1, floor(sourceWidth * scale)),
            height: max(1, floor(sourceHeight * scale))
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private static func downsampledImage(at url: URL, idealPointSize: CGFloat?) -> UIImage? {
        let targetPixels = maxPixelSize(for: idealPointSize)
        guard targetPixels > 0 else {
            return UIImage(contentsOfFile: url.path)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return UIImage(contentsOfFile: url.path)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(targetPixels.rounded(.up))
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(contentsOfFile: url.path)
        }

        return UIImage(cgImage: cgImage)
    }

    private func resolveAssetName(for teamName: String, alternateNames: [String] = []) -> String? {
        var fuzzyCandidates: [String] = []

        for candidate in Self.lookupCandidates(for: teamName, alternateNames: alternateNames) {
            let lower = candidate.lowercased()
            if let direct = assetOriginalLookup[lower] {
                return direct
            }

            if let direct = directAssetName(for: candidate) {
                return direct
            }

            for alias in Self.aliases(for: candidate) {
                if let directAlias = assetOriginalLookup[alias] {
                    return directAlias
                }

                if let directAlias = directAssetName(for: alias) {
                    return directAlias
                }

                let aliasKey = Self.normalizedKey(alias)
                if let match = assetNormalizedLookup[aliasKey] {
                    return match
                }
            }

            let normalized = Self.normalizedKey(candidate)
            if let match = assetNormalizedLookup[normalized] {
                return match
            }

            let core = Self.normalizedCoreKey(candidate)
            if let uniqueCoreMatch = uniqueAssetCoreMatch(for: core) {
                return uniqueCoreMatch
            }

            fuzzyCandidates.append(normalized)
        }

        for normalized in fuzzyCandidates {
            if let match = fuzzyAssetMatch(normalizedTeam: normalized) {
                return match
            }
        }

        return nil
    }

    private func directAssetName(for name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for bundle in bundles {
            if UIImage(named: trimmed, in: bundle, compatibleWith: nil) != nil {
                return trimmed
            }
        }
        return nil
    }

    private func uniqueAssetCoreMatch(for coreKey: String) -> String? {
        guard !coreKey.isEmpty else { return nil }
        guard let candidates = assetCoreLookup[coreKey], !candidates.isEmpty else { return nil }

        var seenNames = Set<String>()
        let unique = candidates.filter { seenNames.insert($0.lowercased()).inserted }
        guard unique.count == 1 else { return nil }
        return unique[0]
    }

    private func fuzzyAssetMatch(normalizedTeam: String) -> String? {
        guard !normalizedTeam.isEmpty else { return nil }

        var bestKey: String?
        var bestScore = 0.0

        for key in assetNormalizedLookup.keys {
            let score = Self.similarity(normalizedTeam, key)
            if score > bestScore {
                bestScore = score
                bestKey = key
            }
        }

        if let bestKey, bestScore >= 0.78 {
            return assetNormalizedLookup[bestKey]
        }

        return nil
    }

    private static func displayName(forAlias alias: String) -> String {
        alias
            .split(separator: " ")
            .map { token in
                switch token {
                case "fc":
                    return "FC"
                case "ac":
                    return "AC"
                case "sv":
                    return "SV"
                case "vfl":
                    return "VfL"
                case "vfb":
                    return "VfB"
                case "paok":
                    return "PAOK"
                case "psv":
                    return "PSV"
                default:
                    return token.prefix(1).uppercased() + String(token.dropFirst())
                }
            }
            .joined(separator: " ")
    }

    private func resolveURL(for teamName: String, alternateNames: [String] = []) -> URL? {
        var fuzzyCandidates: [String] = []

        for candidate in Self.lookupCandidates(for: teamName, alternateNames: alternateNames) {
            let lower = candidate.lowercased()
            if let direct = originalLookup[lower] {
                return direct
            }

            for alias in Self.aliases(for: candidate) {
                let aliasKey = Self.normalizedKey(alias)
                if let match = normalizedLookup[aliasKey] {
                    return match
                }
            }

            let normalized = Self.normalizedKey(candidate)
            if let match = normalizedLookup[normalized] {
                return match
            }

            let core = Self.normalizedCoreKey(candidate)
            if let uniqueCoreMatch = uniqueCoreMatch(for: core) {
                return uniqueCoreMatch
            }

            fuzzyCandidates.append(normalized)
        }

        for normalized in fuzzyCandidates {
            if let match = fuzzyMatch(normalizedTeam: normalized) {
                return match
            }
        }

        return nil
    }

    private func uniqueCoreMatch(for coreKey: String) -> URL? {
        guard !coreKey.isEmpty else { return nil }
        guard let candidates = coreLookup[coreKey], !candidates.isEmpty else { return nil }

        var seenPaths = Set<String>()
        let unique = candidates.filter { seenPaths.insert($0.path).inserted }
        guard unique.count == 1 else { return nil }
        return unique[0]
    }

    private func fuzzyMatch(normalizedTeam: String) -> URL? {
        guard !normalizedTeam.isEmpty else { return nil }

        var bestKey: String?
        var bestScore = 0.0

        for key in normalizedLookup.keys {
            let score = Self.similarity(normalizedTeam, key)
            if score > bestScore {
                bestScore = score
                bestKey = key
            }
        }

        if let bestKey, bestScore >= 0.78 {
            return normalizedLookup[bestKey]
        }

        return nil
    }

    private nonisolated static func normalizedKey(_ value: String) -> String {
        normalizedTokens(value).joined()
    }

    private nonisolated static func normalizedCoreKey(_ value: String) -> String {
        normalizedTokens(value, stripClubAffixes: true).joined()
    }

    private nonisolated static func normalizedTokens(_ value: String, stripClubAffixes: Bool = false) -> [String] {
        let lowered = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        return lowered
            .split { !$0.isLetter && !$0.isNumber }
            .map { String($0) }
            .filter { token in
                if stopWords.contains(token) {
                    return false
                }
                if stripClubAffixes, clubAffixWords.contains(token) {
                    return false
                }
                return true
            }
    }

    private static func aliases(for name: String) -> [String] {
        let lowered = name.lowercased()
        if let alias = aliasMap[lowered] {
            return [alias, lowered]
        }
        return [lowered]
    }

    private static func lookupCandidates(for teamName: String, alternateNames: [String]) -> [String] {
        var output: [String] = []
        var seen = Set<String>()

        func add(_ candidate: String) {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return }
            output.append(trimmed)
        }

        add(teamName)
        alternateNames.forEach(add)
        return output
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let distance = levenshtein(lhs, rhs)
        let maxLength = max(lhs.count, rhs.count)
        guard maxLength > 0 else { return 1 }
        return 1 - (Double(distance) / Double(maxLength))
    }

    private static func levenshtein(_ lhs: String, _ rhs: String) -> Int {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)

        var previous = Array(0...rhsChars.count)
        var current = Array(repeating: 0, count: rhsChars.count + 1)

        for (i, lhsChar) in lhsChars.enumerated() {
            current[0] = i + 1
            for (j, rhsChar) in rhsChars.enumerated() {
                let cost = lhsChar == rhsChar ? 0 : 1
                current[j + 1] = min(
                    previous[j + 1] + 1,
                    current[j] + 1,
                    previous[j] + cost
                )
            }
            previous = current
        }

        return previous[rhsChars.count]
    }

    private nonisolated static let stopWords: Set<String> = [
        "fc", "cf", "sc", "afc", "ac", "sv", "fk", "bk", "bc", "ks", "nk",
        "club", "de", "the", "and", "atletico", "athletic", "sporting"
    ]

    private nonisolated static let clubAffixWords: Set<String> = [
        "city", "town", "united", "rovers", "county", "albion", "wanderers",
        "hotspur", "saint", "st", "calcio"
    ]

    private static let aliasMap: [String: String] = [
        "manchester united": "man united",
        "manchester city": "man city",
        "tottenham hotspur": "tottenham",
        "wolverhampton wanderers": "wolves",
        "sheffield united": "sheff utd",
        "sheffield wednesday": "sheff wed",
        "nottingham forest": "nottm forest",
        "borussia dortmund": "dortmund",
        "borussia m'gladbach": "m'gladbach",
        "athletic club": "athletic",
        "real betis": "betis",
        "real sociedad": "real sociedad",
        "fc copenhagen": "copenhagen",
        "fc porto": "porto",
        "paok thessaloniki": "paok",
        "paok thessaloniki fc": "paok",
        "inter milan": "inter",
        "ac milan": "ac milan",
        "cabo verde": "cape verde",
        "china pr": "china",
        "congo dr": "dr congo",
        "cote d'ivoire": "ivory coast",
        "dominican rep": "dominican republic",
        "n. ireland": "northern ireland",
        "n. macedonia": "north macedonia",
        "rep. ireland": "ireland",
        "united states": "usa"
    ]

    private static func isFallbackName(_ name: String) -> Bool {
        let fallback = normalizedKey("_noTeamLogo")
        let normalized = normalizedKey(name)
        return normalized == fallback || normalized.hasPrefix(fallback)
    }
}

private enum WidgetLogoAssetVariant {
    case standard
    case liveActivity

    var cacheKeyPrefix: String {
        switch self {
        case .standard:
            return "std"
        case .liveActivity:
            return "la"
        }
    }

    func candidateAssetNames(for baseName: String) -> [String] {
        switch self {
        case .standard:
            return [baseName]
        case .liveActivity:
            return [
                "\(baseName) Live Activity",
                "\(baseName)LiveActivity",
                baseName,
            ]
        }
    }
}

private final class WidgetTvLogoResolver {
    static let shared = WidgetTvLogoResolver()

    private let fallbackName = "_noLogo"
    private let assetCatalogNames: [String: String] = [
        "amazon": "TVLogoAmazon",
        "bbc": "TVLogoBBC",
        "itv": "TVLogoITV",
        "sky": "TVLogoSky",
        "tnt": "TVLogoTNT",
        "apple": "TVLogoApple",
        "channel4": "TVLogoChannel4",
        "hbomax": "TVLogoHBOMax",
        "dazn": "TVLogoDAZN",
        "disneyplus": "TVLogoDisneyPlus",
        "premiersports": "TVLogoPremierSports",
        "laligatv": "TVLogoLaLigaTV",
        "nologo": "TVLogoFallback"
    ]
    private let lock = NSLock()
    private var normalizedLookup: [String: URL] = [:]
    private var cache: [String: UIImage] = [:]

    private init() {
        loadLogos()
    }

    func image(
        for channelName: String,
        allowsFallback: Bool = true,
        variant: WidgetLogoAssetVariant = .standard,
        idealPointSize: CGFloat? = nil
    ) -> UIImage? {
        let normalizedRequest = Self.normalizedKey(channelName)
        NSLog("[Widget][TvLogo] image(for:) channelName='\(channelName)' normalized='\(normalizedRequest)' lookupSize=\(normalizedLookup.count)")

        let cacheKey = Self.cacheKey(
            for: channelName,
            allowsFallback: allowsFallback,
            variant: variant,
            idealPointSize: idealPointSize
        )
        lock.lock()
        if let cached = cache[cacheKey] {
            lock.unlock()
            NSLog("[Widget][TvLogo] image(for:) cache HIT for '\(channelName)'")
            return cached
        }
        lock.unlock()

        if let assetImage = assetImage(
            for: channelName,
            allowsFallback: allowsFallback,
            variant: variant,
            idealPointSize: idealPointSize
        ) {
            lock.lock()
            cache[cacheKey] = assetImage
            lock.unlock()
            NSLog("[Widget][TvLogo] image(for:) asset HIT for '\(channelName)'")
            return assetImage
        }

        let url = if allowsFallback {
            resolveExplicitURL(for: channelName) ?? resolveURL(for: fallbackName)
        } else {
            resolveExplicitURL(for: channelName)
        }

        if let url {
            NSLog("[Widget][TvLogo] image(for:) resolved URL = \(url.path)")
        } else {
            NSLog("[Widget][TvLogo] image(for:) resolved URL = nil (returning nil image) for '\(channelName)'")
        }
        guard let url else { return nil }

        let image = Self.downsampledImage(at: url, idealPointSize: idealPointSize)
        NSLog("[Widget][TvLogo] image(for:) UIImage load \(image != nil ? "SUCCESS" : "FAILED") from \(url.lastPathComponent)")
        if let image {
            lock.lock()
            cache[cacheKey] = image
            lock.unlock()
        }

        return image
    }

    func preferredChannel(from channelNames: [String], requiresExplicitLogo: Bool = false) -> String? {
        let trimmedChannels = channelNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !trimmedChannels.isEmpty else { return nil }
        if !requiresExplicitLogo {
            return trimmedChannels.first
        }

        for channelName in trimmedChannels {
            if canResolveNonFallbackImage(for: channelName) {
                return channelName
            }
        }

        return nil
    }

    func assetName(
        for channelName: String,
        allowsFallback: Bool = true,
        variant: WidgetLogoAssetVariant = .standard
    ) -> String? {
        let baseAssetName = resolveAssetName(for: channelName, allowsFallback: allowsFallback)
        return preferredAssetName(from: baseAssetName, variant: variant)
    }

    private func loadLogos() {
        NSLog("[Widget][TvLogo] ── loadLogos START ──")
        NSLog("[Widget][TvLogo] Bundle.main.bundleURL = \(Bundle.main.bundleURL)")
        NSLog("[Widget][TvLogo] Bundle.main.bundlePath = \(Bundle.main.bundlePath)")
        NSLog("[Widget][TvLogo] Bundle.main.bundleURL.pathExtension = \(Bundle.main.bundleURL.pathExtension)")
        NSLog("[Widget][TvLogo] Bundle.allBundles.count = \(Bundle.allBundles.count)")
        NSLog("[Widget][TvLogo] Bundle.allFrameworks.count = \(Bundle.allFrameworks.count)")

        let bundles = logoBundles()
        NSLog("[Widget][TvLogo] logoBundles() returned \(bundles.count) bundle(s)")

        var allUrls: [URL] = []
        for (i, bundle) in bundles.enumerated() {
            let bundlePath = bundle.bundlePath
            NSLog("[Widget][TvLogo] Bundle[\(i)] path = \(bundlePath)")

            // Check tv-logos subdirectory existence via FileManager
            let tvLogosDir = URL(fileURLWithPath: bundlePath).appendingPathComponent("tv-logos")
            let tvLogosDirExists = FileManager.default.fileExists(atPath: tvLogosDir.path)
            NSLog("[Widget][TvLogo] Bundle[\(i)] tv-logos dir exists (FileManager) = \(tvLogosDirExists)")

            // Try Bundle API — subdirectory
            let fromSubdir = bundle.urls(forResourcesWithExtension: "png", subdirectory: "tv-logos") ?? []
            NSLog("[Widget][TvLogo] Bundle[\(i)] Bundle API tv-logos/png count = \(fromSubdir.count)")

            // Try Bundle API — root
            let fromRoot = bundle.urls(forResourcesWithExtension: "png", subdirectory: nil) ?? []
            NSLog("[Widget][TvLogo] Bundle[\(i)] Bundle API root/png count = \(fromRoot.count)")
            allUrls.append(contentsOf: fromSubdir)
            allUrls.append(contentsOf: fromRoot)

            // FileManager — tv-logos subdirectory
            if tvLogosDirExists {
                if let fmSubdir = try? FileManager.default.contentsOfDirectory(at: tvLogosDir, includingPropertiesForKeys: nil) {
                    let pngs = fmSubdir.filter { $0.pathExtension.lowercased() == "png" }
                    NSLog("[Widget][TvLogo] Bundle[\(i)] FileManager tv-logos/png count = \(pngs.count)")
                    if !pngs.isEmpty {
                        NSLog("[Widget][TvLogo] Bundle[\(i)] FileManager tv-logos first 5: \(pngs.prefix(5).map { $0.lastPathComponent })")
                    }
                    allUrls.append(contentsOf: pngs)
                } else {
                    NSLog("[Widget][TvLogo] Bundle[\(i)] FileManager tv-logos enumeration FAILED")
                }
            } else {
                // Log what IS in the bundle root to help diagnose where files ended up
                let bundleDir = URL(fileURLWithPath: bundlePath)
                if let rootContents = try? FileManager.default.contentsOfDirectory(at: bundleDir, includingPropertiesForKeys: nil) {
                    let names = rootContents.prefix(20).map { $0.lastPathComponent }
                    NSLog("[Widget][TvLogo] Bundle[\(i)] root contents (first 20): \(names)")
                    let rootPngs = rootContents.filter { $0.pathExtension.lowercased() == "png" }
                    NSLog("[Widget][TvLogo] Bundle[\(i)] FileManager root/png count = \(rootPngs.count)")
                    allUrls.append(contentsOf: rootPngs)
                } else {
                    NSLog("[Widget][TvLogo] Bundle[\(i)] root enumeration FAILED")
                }
            }
        }

        NSLog("[Widget][TvLogo] Total URLs collected before dedup: \(allUrls.count)")

        for url in allUrls {
            let fileName = url.deletingPathExtension().lastPathComponent
            guard !fileName.isEmpty else { continue }
            let normalized = Self.normalizedKey(fileName)
            guard !normalized.isEmpty else { continue }
            normalizedLookup[normalized] = normalizedLookup[normalized] ?? url
        }

        NSLog("[Widget][TvLogo] normalizedLookup count after bundle scan = \(normalizedLookup.count)")

        // Last-resort: explicit per-resource lookup via Bundle.main.path(forResource:ofType:)
        // This is the most direct Bundle API and works even when enumeration-based approaches fail.
        let knownLogoNames = ["amazon", "bbc", "sky", "itv", "tnt", "apple", "channel 4", "hbo max", "dazn", "disney+", "premier sports", "laliga tv", "_noLogo"]
        for name in knownLogoNames {
            let key = Self.normalizedKey(name)
            guard normalizedLookup[key] == nil else { continue }
            if let path = Bundle.main.path(forResource: name, ofType: "png") {
                let url = URL(fileURLWithPath: path)
                normalizedLookup[key] = url
                NSLog("[Widget][TvLogo] explicit path(forResource:) FOUND '\(name)' at \(path)")
            } else {
                NSLog("[Widget][TvLogo] explicit path(forResource:) MISSING '\(name)'")
            }
        }

        NSLog("[Widget][TvLogo] normalizedLookup count = \(normalizedLookup.count)")
        // Log whether specific keys we care about are present
        let keysToCheck = ["amazon", "amazonprime", "primevideo", "sky", "bbc", "itv"]
        for key in keysToCheck {
            NSLog("[Widget][TvLogo] key '\(key)' present = \(normalizedLookup[key] != nil)")
        }
        NSLog("[Widget][TvLogo] ── loadLogos END ──")
    }

    private func assetImage(
        for channelName: String,
        allowsFallback: Bool,
        variant: WidgetLogoAssetVariant,
        idealPointSize: CGFloat?
    ) -> UIImage? {
        let baseAssetName = resolveAssetName(for: channelName, allowsFallback: allowsFallback)
        guard let assetName = preferredAssetName(from: baseAssetName, variant: variant) else {
            return nil
        }

        for bundle in logoBundles() {
            if let image = UIImage(named: assetName, in: bundle, compatibleWith: nil) {
                return Self.preparedImage(image, idealPointSize: idealPointSize)
            }
        }

        if let image = UIImage(named: assetName) {
            return Self.preparedImage(image, idealPointSize: idealPointSize)
        }
        return nil
    }

    private static func cacheKey(
        for channelName: String,
        allowsFallback: Bool,
        variant: WidgetLogoAssetVariant,
        idealPointSize: CGFloat?
    ) -> String {
        let normalized = normalizedKey(channelName)
        let pixelSize = Int(maxPixelSize(for: idealPointSize).rounded())
        return "\(variant.cacheKeyPrefix)|\(allowsFallback ? "fallback" : "strict")|\(normalized)|\(pixelSize)"
    }

    private static func maxPixelSize(for idealPointSize: CGFloat?) -> CGFloat {
        guard let idealPointSize, idealPointSize > 0 else { return 0 }
        return max(ceil(idealPointSize * 3), 32)
    }

    private static func preparedImage(_ image: UIImage, idealPointSize: CGFloat?) -> UIImage {
        let targetPixels = maxPixelSize(for: idealPointSize)
        guard targetPixels > 0 else { return image }

        let sourceWidth = image.size.width * image.scale
        let sourceHeight = image.size.height * image.scale
        let largestSide = max(sourceWidth, sourceHeight)
        guard largestSide > targetPixels * 1.2 else { return image }
        guard sourceWidth > 0, sourceHeight > 0 else { return image }

        let scale = targetPixels / largestSide
        let targetSize = CGSize(
            width: max(1, floor(sourceWidth * scale)),
            height: max(1, floor(sourceHeight * scale))
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private static func downsampledImage(at url: URL, idealPointSize: CGFloat?) -> UIImage? {
        let targetPixels = maxPixelSize(for: idealPointSize)
        guard targetPixels > 0 else {
            return UIImage(contentsOfFile: url.path)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return UIImage(contentsOfFile: url.path)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(targetPixels.rounded(.up))
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(contentsOfFile: url.path)
        }

        return UIImage(cgImage: cgImage)
    }

    private func canResolveNonFallbackImage(for channelName: String) -> Bool {
        resolveAssetName(for: channelName, allowsFallback: false) != nil ||
            resolveExplicitURL(for: channelName) != nil
    }

    private func resolveAssetName(for channelName: String, allowsFallback: Bool) -> String? {
        let normalized = Self.normalizedKey(channelName)
        guard !normalized.isEmpty else {
            return allowsFallback ? assetCatalogNames[Self.normalizedKey(fallbackName)] : nil
        }

        if let direct = assetCatalogNames[normalized] {
            return direct
        }

        for (keyword, logoKey) in aliasKeywords {
            if normalized.contains(keyword), let assetName = assetCatalogNames[logoKey] {
                return assetName
            }
        }

        var bestKey: String?
        var bestScore = 0.0
        for key in assetCatalogNames.keys {
            let score = Self.similarity(normalized, key)
            if score > bestScore {
                bestScore = score
                bestKey = key
            }
        }

        if let bestKey, bestScore >= 0.72 {
            return assetCatalogNames[bestKey]
        }

        if allowsFallback {
            return assetCatalogNames[Self.normalizedKey(fallbackName)]
        }
        return nil
    }

    private func preferredAssetName(from baseAssetName: String?, variant: WidgetLogoAssetVariant) -> String? {
        guard let baseAssetName else { return nil }
        for candidate in variant.candidateAssetNames(for: baseAssetName) {
            for bundle in logoBundles() {
                if UIImage(named: candidate, in: bundle, compatibleWith: nil) != nil {
                    return candidate
                }
            }
        }
        return nil
    }

    private func logoBundles() -> [Bundle] {
        var output: [Bundle] = []
        var seenURLs = Set<URL>()

        for bundle in [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks {
            let url = bundle.bundleURL
            guard !seenURLs.contains(url) else { continue }
            seenURLs.insert(url)
            output.append(bundle)
        }

        let mainBundleURL = Bundle.main.bundleURL
        NSLog("[Widget][TvLogo] logoBundles: mainBundleURL.pathExtension = '\(mainBundleURL.pathExtension)'")
        if mainBundleURL.pathExtension == "appex" {
            let plugInsDir = mainBundleURL.deletingLastPathComponent()
            let containingAppURL = plugInsDir.deletingLastPathComponent()
            NSLog("[Widget][TvLogo] logoBundles: PlugIns dir = \(plugInsDir.path)")
            NSLog("[Widget][TvLogo] logoBundles: Derived containing app URL = \(containingAppURL.path)")
            let containingAppExists = FileManager.default.fileExists(atPath: containingAppURL.path)
            NSLog("[Widget][TvLogo] logoBundles: Containing app URL exists = \(containingAppExists)")
            if let containingAppBundle = Bundle(url: containingAppURL) {
                let url = containingAppBundle.bundleURL
                let alreadySeen = seenURLs.contains(url)
                NSLog("[Widget][TvLogo] logoBundles: Containing app bundle loaded, alreadySeen = \(alreadySeen)")
                if !seenURLs.contains(url) {
                    seenURLs.insert(url)
                    output.append(containingAppBundle)
                }
            } else {
                NSLog("[Widget][TvLogo] logoBundles: Bundle(url:) FAILED for containing app URL")
            }
        } else {
            NSLog("[Widget][TvLogo] logoBundles: NOT an .appex bundle — skipping containing app lookup")
        }

        NSLog("[Widget][TvLogo] logoBundles: returning \(output.count) bundles")
        return output
    }

    private func resolveURL(for channelName: String) -> URL? {
        let normalized = Self.normalizedKey(channelName)
        guard !normalized.isEmpty else { return nil }

        if let direct = normalizedLookup[normalized] {
            return direct
        }

        for (keyword, logoKey) in aliasKeywords {
            if normalized.contains(keyword), let url = normalizedLookup[logoKey] {
                return url
            }
        }

        return fuzzyMatch(normalizedChannel: normalized)
    }

    private func resolveExplicitURL(for channelName: String) -> URL? {
        guard let url = resolveURL(for: channelName), !isFallbackURL(url) else {
            return nil
        }
        return url
    }

    private func isFallbackURL(_ url: URL) -> Bool {
        Self.normalizedKey(url.deletingPathExtension().lastPathComponent) == Self.normalizedKey(fallbackName)
    }

    private func fuzzyMatch(normalizedChannel: String) -> URL? {
        guard !normalizedChannel.isEmpty else { return nil }

        var bestKey: String?
        var bestScore = 0.0

        for key in normalizedLookup.keys {
            let score = Self.similarity(normalizedChannel, key)
            if score > bestScore {
                bestScore = score
                bestKey = key
            }
        }

        if let bestKey, bestScore >= 0.72 {
            return normalizedLookup[bestKey]
        }

        return nil
    }

    private static func normalizedKey(_ value: String) -> String {
        let lowered = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "+", with: " plus ")

        let tokens = lowered
            .split { !$0.isLetter && !$0.isNumber }
            .map { String($0) }

        return tokens.joined()
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let distance = levenshtein(lhs, rhs)
        let maxLength = max(lhs.count, rhs.count)
        guard maxLength > 0 else { return 1 }
        return 1 - (Double(distance) / Double(maxLength))
    }

    private static func levenshtein(_ lhs: String, _ rhs: String) -> Int {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)

        var previous = Array(0...rhsChars.count)
        var current = Array(repeating: 0, count: rhsChars.count + 1)

        for (i, lhsChar) in lhsChars.enumerated() {
            current[0] = i + 1
            for (j, rhsChar) in rhsChars.enumerated() {
                let cost = lhsChar == rhsChar ? 0 : 1
                current[j + 1] = min(
                    previous[j + 1] + 1,
                    current[j] + 1,
                    previous[j] + cost
                )
            }
            previous = current
        }

        return previous[rhsChars.count]
    }

    private let aliasKeywords: [(String, String)] = [
        ("skysports", "sky"),
        ("sky", "sky"),
        ("tntsports", "tnt"),
        ("tnt", "tnt"),
        ("bt", "tnt"),
        ("amazonprime", "amazon"),
        ("primevideo", "amazon"),
        ("amazon", "amazon"),
        ("apple", "apple"),
        ("mlsseasonpass", "apple"),
        ("bbc", "bbc"),
        ("itv", "itv"),
        ("channel4", "channel4"),
        ("hbomax", "hbomax"),
        ("hbo", "hbomax"),
        ("dazn", "dazn"),
        ("disneyplus", "disneyplus"),
        ("disney", "disneyplus"),
        ("premiersports", "premiersports"),
        ("laligatv", "laligatv"),
        ("laliga", "laligatv")
    ]
}

@available(iOSApplicationExtension 16.1, *)
private struct TopScoresLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TopScoresLiveActivityAttributes.self) { context in
            TopScoresLiveActivityMinimalLockScreenView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color(red: 0.03, green: 0.04, blue: 0.09))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            return DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    TopScoresLiveActivityMinimalExpandedView(state: context.state, isStale: context.isStale)
                }
            } compactLeading: {
                Text(compactLeadingText(state: context.state))
                    .font(.caption2.weight(.semibold))
            } compactTrailing: {
                Text(compactTrailingText(state: context.state))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(compactTrailingOpacity(state: context.state)))
            } minimal: {
                Text("TS")
                    .font(.caption2.weight(.bold))
            }
        }
    }

    private func compactLeadingText(state: TopScoresLiveActivityAttributes.ContentState) -> String {
        guard let first = LiveActivityMatchDisplayFilter.displayMatches(for: state).first else { return "TS" }
        return String(first.displayHomeTeam.prefix(3)).uppercased()
    }

    private func compactTrailingText(state: TopScoresLiveActivityAttributes.ContentState) -> String {
        guard let first = LiveActivityMatchDisplayFilter.displayMatches(for: state).first else { return "" }
        if let penaltyShootoutScoreText = first.penaltyShootoutScoreText {
            return penaltyShootoutScoreText
        }
        if let home = first.homeScore, let away = first.awayScore {
            return "\(home)-\(away)"
        }
        if let matchTime = first.matchTime?.trimmingCharacters(in: .whitespacesAndNewlines),
           !matchTime.isEmpty {
            return matchTime
        }
        return first.time
    }

    private func compactTrailingOpacity(state: TopScoresLiveActivityAttributes.ContentState) -> Double {
        guard state.mode.contains("finished"),
              let first = LiveActivityMatchDisplayFilter.displayMatches(for: state).first,
              first.homeScore != nil,
              first.awayScore != nil else {
            return 1.0
        }
        return LiveActivityScoreStyle.finishedOpacity
    }
}

@available(iOSApplicationExtension 16.1, *)
private enum LiveActivityTvLogoAsset {
    static func assetName(for key: String?) -> String? {
        switch normalized(key) {
        case "amazon":
            return "TVLogoAmazon"
        case "bbc":
            return "TVLogoBBC"
        case "itv":
            return "TVLogoITV"
        case "sky":
            return "TVLogoSky"
        case "tnt":
            return "TVLogoTNT"
        case "apple":
            return "TVLogoApple"
        case "channel4":
            return "TVLogoChannel4"
        case "hbomax":
            return "TVLogoHBOMax"
        case "dazn":
            return "TVLogoDAZN"
        case "disneyplus":
            return "TVLogoDisneyPlus"
        case "premiersports":
            return "TVLogoPremierSports"
        case "laligatv":
            return "TVLogoLaLigaTV"
        default:
            return nil
        }
    }

    private static func normalized(_ key: String?) -> String {
        String(key ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct LiveActivityPrecomputedTvLogo: View {
    let logoKey: String?
    let height: CGFloat

    var body: some View {
        Group {
            if let assetName = LiveActivityTvLogoAsset.assetName(for: logoKey) {
                Image(assetName)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
            } else {
                Image(systemName: "tv")
                    .font(.system(size: max(8, height * 0.75), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))
            }
        }
        .frame(width: height * 1.85, height: height)
        .clipShape(RoundedRectangle(cornerRadius: max(2, height * 0.18), style: .continuous))
        .accessibilityHidden(true)
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct LiveActivityPrecomputedTeamLogo: View {
    let logoKey: String?
    let teamName: String
    let size: CGFloat

    var body: some View {
        Group {
            if let assetName = assetName {
                Image(assetName)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
            } else {
                Circle()
                    .fill(Color.white.opacity(0.16))
                    .overlay(
                        Text(String(teamName.prefix(1)).uppercased())
                            .font(.system(size: max(7, size * 0.48), weight: .bold))
                            .foregroundStyle(.white.opacity(0.76))
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var assetName: String? {
        let trimmedLogoKey = logoKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let primaryName = trimmedLogoKey.isEmpty ? teamName : trimmedLogoKey
        let alternateNames = trimmedLogoKey == teamName ? [] : [teamName]
        return WidgetTeamLogoResolver.shared.assetName(
            for: primaryName,
            alternateNames: alternateNames,
            allowsFallback: false
        )
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct TopScoresLiveActivityMinimalLockScreenView: View {
    let state: TopScoresLiveActivityAttributes.ContentState
    let isStale: Bool

    private var visibleMatches: [TopScoresLiveActivityMatchState] {
        Array(LiveActivityMatchDisplayFilter.displayMatches(for: state).prefix(6))
    }

    private var usesDenseRows: Bool {
        visibleMatches.count > 4
    }

    private var rowSpacing: CGFloat {
        usesDenseRows ? 3 : 5
    }

    private var teamLogoSize: CGFloat {
        usesDenseRows ? 12 : 14
    }

    private var tvLogoHeight: CGFloat {
        usesDenseRows ? 11 : 13
    }

    // Fixed widths for the middle columns. Because these are identical across
    // every row, the TV-logo column, away-logo column and status column all land
    // at the same x-position regardless of row type — while the flexible team
    // name columns on either side absorb the remaining width so the row fills.
    private var scoreColumnWidth: CGFloat {
        usesDenseRows ? 16 : 18
    }

    private var tvColumnWidth: CGFloat {
        usesDenseRows ? 22 : 26
    }

    private var statusColumnWidth: CGFloat {
        42
    }

    private var rowFont: Font {
        usesDenseRows ? .caption2.weight(.semibold) : .caption.weight(.semibold)
    }

    private var delayBannerText: String? {
        if isStale {
            return "Delayed | Tap to open"
        }
        if state.delayMinutes > 0 {
            return "Delayed \(state.delayMinutes) m | Tap to open"
        }
        return nil
    }

    private var fantasyScoreText: String? {
        guard let fantasyCurrentScore = state.fantasyCurrentScore else { return nil }
        return "\(fantasyCurrentScore)"
    }

    private var hasFooterContent: Bool {
        delayBannerText != nil || fantasyScoreText != nil
    }

    private var topScoresBlue: Color {
        Color(red: 0.00, green: 0.48, blue: 1.00)
    }

    private var fantasyRed: Color {
        Color(red: 0.85, green: 0.12, blue: 0.33)
    }

    private var footerBannerBackground: LinearGradient {
        if fantasyScoreText == nil {
            return LinearGradient(
                colors: [topScoresBlue, topScoresBlue],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        return LinearGradient(
            stops: [
                .init(color: topScoresBlue, location: 0.0),
                .init(color: topScoresBlue, location: 0.58),
                .init(color: fantasyRed.opacity(0.9), location: 0.82),
                .init(color: fantasyRed, location: 1.0),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: rowSpacing) {
                ForEach(visibleMatches, id: \.matchId) { match in
                    matchRow(for: match)
                }
            }
            .font(rowFont)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.top, usesDenseRows ? 7 : 8)
            .padding(.bottom, hasFooterContent ? (usesDenseRows ? 5 : 6) : (usesDenseRows ? 7 : 8))
            .frame(maxWidth: .infinity, alignment: .leading)

            if hasFooterContent {
                Spacer(minLength: 0)
                footerBanner
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // One HStack per match with the same column structure for every row
    // (home logo · home name · home score · TV/"vs" · away score · away name ·
    // away logo · status). The middle columns use fixed widths so the TV logo,
    // away logo and status all line up vertically across rows; the team-name
    // columns flex to fill the remaining width. Fixture rows leave the score
    // columns empty (but still reserved) so the TV logo stays in its column.
    private func matchRow(for match: TopScoresLiveActivityMatchState) -> some View {
        HStack(spacing: 5) {
            LiveActivityPrecomputedTeamLogo(
                logoKey: match.homeLogoKey,
                teamName: match.displayHomeTeam,
                size: teamLogoSize
            )

            Text(match.displayHomeTeam)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .trailing)

            homeScoreCell(for: match)
                .frame(width: scoreColumnWidth, alignment: .trailing)

            centerCell(for: match)
                .frame(width: tvColumnWidth, alignment: .center)

            awayScoreCell(for: match)
                .frame(width: scoreColumnWidth, alignment: .leading)

            Text(match.displayAwayTeam)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .leading)

            LiveActivityPrecomputedTeamLogo(
                logoKey: match.awayLogoKey,
                teamName: match.displayAwayTeam,
                size: teamLogoSize
            )

            Text(matchTimeText(for: match))
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(.white.opacity(statusOpacity(for: match)))
                .frame(width: statusColumnWidth, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func centerCell(for match: TopScoresLiveActivityMatchState) -> some View {
        if match.isFinished {
            Text("-")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(LiveActivityScoreStyle.finishedOpacity))
                .frame(width: usesDenseRows ? 16 : 18, height: tvLogoHeight)
        } else if !match.hasScore && !hasTvLogo(match) {
            Text("vs")
                .font(.system(size: usesDenseRows ? 7 : 8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.42))
                .frame(width: usesDenseRows ? 16 : 18, height: tvLogoHeight)
        } else {
            LiveActivityPrecomputedTvLogo(logoKey: match.tvLogoKey, height: tvLogoHeight)
        }
    }

    @ViewBuilder
    private func homeScoreCell(for match: TopScoresLiveActivityMatchState) -> some View {
        if match.hasScore {
            HStack(spacing: 3) {
                if let aggregateHomeText = aggregateHomeText(for: match) {
                    Text(aggregateHomeText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }

                Text(homeScoreText(for: match))
                    .font(usesDenseRows ? .caption2.weight(.bold) : .caption.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func awayScoreCell(for match: TopScoresLiveActivityMatchState) -> some View {
        if match.hasScore {
            HStack(spacing: 3) {
                Text(awayScoreText(for: match))
                    .font(usesDenseRows ? .caption2.weight(.bold) : .caption.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)

                if let aggregateAwayText = aggregateAwayText(for: match) {
                    Text(aggregateAwayText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }
            }
        } else {
            Color.clear
        }
    }

    private func statusOpacity(for match: TopScoresLiveActivityMatchState) -> Double {
        if match.isFinished { return LiveActivityScoreStyle.finishedOpacity }
        return match.hasScore ? 0.86 : 0.9
    }

    private func hasTvLogo(_ match: TopScoresLiveActivityMatchState) -> Bool {
        LiveActivityTvLogoAsset.assetName(for: match.tvLogoKey) != nil
    }

    private func homeScoreText(for match: TopScoresLiveActivityMatchState) -> String {
        guard let homeScore = match.homeScore else { return "-" }
        if match.penaltyShootoutScoreText != nil { return "\(homeScore)" }
        return match.homeWonOnPenalties ? "\(homeScore)P" : "\(homeScore)"
    }

    private func awayScoreText(for match: TopScoresLiveActivityMatchState) -> String {
        guard let awayScore = match.awayScore else { return "-" }
        if match.penaltyShootoutScoreText != nil { return "\(awayScore)" }
        return match.awayWonOnPenalties ? "\(awayScore)P" : "\(awayScore)"
    }

    private func aggregateHomeText(for match: TopScoresLiveActivityMatchState) -> String? {
        guard match.hasDisplayableAggregateScore,
              let aggregateHomeScore = match.resolvedAggregateHomeScore else {
            return nil
        }
        return "(\(aggregateHomeScore))"
    }

    private func aggregateAwayText(for match: TopScoresLiveActivityMatchState) -> String? {
        guard match.hasDisplayableAggregateScore,
              let aggregateAwayScore = match.resolvedAggregateAwayScore else {
            return nil
        }
        return "(\(aggregateAwayScore))"
    }

    private func matchTimeText(for match: TopScoresLiveActivityMatchState) -> String {
        if let penaltyShootoutScoreText = match.penaltyShootoutScoreText {
            return penaltyShootoutScoreText
        }
        if let matchTime = match.matchTime?.trimmingCharacters(in: .whitespacesAndNewlines),
           !matchTime.isEmpty {
            return matchTime
        }
        return match.time
    }

    @ViewBuilder
    private var footerBanner: some View {
        HStack(spacing: 8) {
            if let delayBannerText {
                Text(delayBannerText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .layoutPriority(1)
            }

            Spacer(minLength: 0)

            if let fantasyScoreText {
                HStack(spacing: 4) {
                    Image("FantasyPremierLeagueLion")
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: 13, height: 13)

                    Text(fantasyScoreText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .layoutPriority(2)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(footerBannerBackground)
        .clipShape(RoundedCornerShape(radius: 18, corners: [.bottomLeft, .bottomRight]))
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct TopScoresLiveActivityMinimalExpandedView: View {
    let state: TopScoresLiveActivityAttributes.ContentState
    let isStale: Bool

    private var visibleMatches: [TopScoresLiveActivityMatchState] {
        Array(LiveActivityMatchDisplayFilter.displayMatches(for: state).prefix(6))
    }

    private var usesDenseRows: Bool {
        visibleMatches.count > 4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: usesDenseRows ? 3 : 4) {
            ForEach(visibleMatches, id: \.matchId) { match in
                matchRow(for: match)
            }
        }
    }

    // Fixed-width middle columns (mirrors TopScoresLiveActivityMinimalLockScreenView)
    // so the TV logo, away logo and status column all line up vertically across
    // both fixture and scored rows, while the team-name columns flex to fill width.
    private let scoreColumnWidth: CGFloat = 14
    private let tvColumnWidth: CGFloat = 20
    private let statusColumnWidth: CGFloat = 32

    private func hasTvLogo(_ match: TopScoresLiveActivityMatchState) -> Bool {
        LiveActivityTvLogoAsset.assetName(for: match.tvLogoKey) != nil
    }

    private func matchRow(for match: TopScoresLiveActivityMatchState) -> some View {
        HStack(spacing: 5) {
            LiveActivityPrecomputedTeamLogo(
                logoKey: match.homeLogoKey,
                teamName: match.displayHomeTeam,
                size: 11
            )

            Text(match.displayHomeTeam)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .trailing)

            homeScoreCell(for: match)
                .frame(width: scoreColumnWidth, alignment: .trailing)

            centerCell(for: match)
                .frame(width: tvColumnWidth, alignment: .center)

            awayScoreCell(for: match)
                .frame(width: scoreColumnWidth, alignment: .leading)

            Text(match.displayAwayTeam)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .leading)

            LiveActivityPrecomputedTeamLogo(
                logoKey: match.awayLogoKey,
                teamName: match.displayAwayTeam,
                size: 11
            )

            Text(matchTimeText(for: match))
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(statusOpacity(for: match)))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: statusColumnWidth, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
    }

    @ViewBuilder
    private func centerCell(for match: TopScoresLiveActivityMatchState) -> some View {
        if match.isFinished {
            Text("-")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(LiveActivityScoreStyle.finishedOpacity))
                .frame(width: 14, height: 10)
        } else if !match.hasScore && !hasTvLogo(match) {
            Text("vs")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.7))
                .frame(width: 14, height: 10)
        } else {
            LiveActivityPrecomputedTvLogo(logoKey: match.tvLogoKey, height: 10)
        }
    }

    @ViewBuilder
    private func homeScoreCell(for match: TopScoresLiveActivityMatchState) -> some View {
        if match.hasScore {
            Text(homeScoreText(for: match))
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func awayScoreCell(for match: TopScoresLiveActivityMatchState) -> some View {
        if match.hasScore {
            Text(awayScoreText(for: match))
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
        } else {
            Color.clear
        }
    }

    private func statusOpacity(for match: TopScoresLiveActivityMatchState) -> Double {
        if match.isFinished { return LiveActivityScoreStyle.finishedOpacity }
        return match.hasScore ? 0.86 : 0.9
    }

    private func homeScoreText(for match: TopScoresLiveActivityMatchState) -> String {
        guard let homeScore = match.homeScore else { return "-" }
        if match.penaltyShootoutScoreText != nil { return "\(homeScore)" }
        return match.homeWonOnPenalties ? "\(homeScore)P" : "\(homeScore)"
    }

    private func awayScoreText(for match: TopScoresLiveActivityMatchState) -> String {
        guard let awayScore = match.awayScore else { return "-" }
        if match.penaltyShootoutScoreText != nil { return "\(awayScore)" }
        return match.awayWonOnPenalties ? "\(awayScore)P" : "\(awayScore)"
    }

    private func matchTimeText(for match: TopScoresLiveActivityMatchState) -> String {
        if let penaltyShootoutScoreText = match.penaltyShootoutScoreText {
            return penaltyShootoutScoreText
        }
        if let matchTime = match.matchTime?.trimmingCharacters(in: .whitespacesAndNewlines),
           !matchTime.isEmpty {
            return matchTime
        }
        return match.time
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct TopScoresLiveActivityLockScreenView: View {
    let state: TopScoresLiveActivityAttributes.ContentState
    let isStale: Bool
    var pinsFooterToBottom: Bool = true
    private let maxPrimaryMatches = 6
    private let maxTrailingUpcomingMatches = 5

    private var displayMatches: [TopScoresLiveActivityMatchState] {
        Array(LiveActivityMatchDisplayFilter.displayMatches(for: state).prefix(maxPrimaryMatches))
    }

    private var trailingDisplayMatches: [TopScoresLiveActivityMatchState] {
        Array(LiveActivityMatchDisplayFilter.trailingDisplayMatches(for: state).prefix(maxTrailingUpcomingMatches))
    }

    var body: some View {
        let isMultiMode = state.mode == "multi_live" || state.mode == "multi_upcoming" || state.mode == "multi_finished"
        let matches = displayMatches
        // In single live/finished mode the server appends today's upcoming matches after the
        // primary match so the widget shows the full picture of today's action.
        let trailingUpcoming: [TopScoresLiveActivityMatchState] = (state.mode == "single_live" || state.mode == "single_finished")
            ? trailingDisplayMatches
            : []
        let hasTrailingUpcoming = !trailingUpcoming.isEmpty
        let hasFooterContent = delayBannerText != nil || fantasyScoreText != nil
        let usesDenseLayout = isMultiMode || hasTrailingUpcoming
        let usesCompactSingleCardLayout = hasTrailingUpcoming || hasFooterContent
        Group {
            if pinsFooterToBottom && hasFooterContent {
                VStack(spacing: 0) {
                    matchContent(
                        matches: matches,
                        hasTrailingUpcoming: hasTrailingUpcoming,
                        trailingUpcoming: trailingUpcoming,
                        usesCompactSingleCardLayout: usesCompactSingleCardLayout
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, usesDenseLayout ? 4 : 8)

                    Spacer(minLength: 0)
                    footerBanner(usesDenseLayout: usesDenseLayout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                VStack(spacing: 0) {
                    matchContent(
                        matches: matches,
                        hasTrailingUpcoming: hasTrailingUpcoming,
                        trailingUpcoming: trailingUpcoming,
                        usesCompactSingleCardLayout: usesCompactSingleCardLayout
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, usesDenseLayout ? 4 : 8)

                    if hasFooterContent {
                        footerBanner(usesDenseLayout: usesDenseLayout)
                    }
                }
            }
        }
        .id(viewIdentity)
    }

    @ViewBuilder
    private func matchContent(
        matches: [TopScoresLiveActivityMatchState],
        hasTrailingUpcoming: Bool,
        trailingUpcoming: [TopScoresLiveActivityMatchState],
        usesCompactSingleCardLayout: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state.mode {
            case "single_upcoming":
                if let match = matches.first {
                    UnifiedMultiMatchListView(matches: [match])
                } else {
                    EmptyLiveActivityView()
                }
            case "single_live":
                if let match = matches.first {
                    let displayMatches = [match] + (hasTrailingUpcoming ? trailingUpcoming : [])
                    UnifiedMultiMatchListView(matches: displayMatches)
                } else {
                    EmptyLiveActivityView()
                }
            case "single_finished":
                if let match = matches.first {
                    let displayMatches = [match] + (hasTrailingUpcoming ? trailingUpcoming : [])
                    UnifiedMultiMatchListView(matches: displayMatches)
                } else {
                    EmptyLiveActivityView()
                }
            case "multi_upcoming":
                if matches.isEmpty {
                    EmptyLiveActivityView()
                } else {
                    UnifiedMultiMatchListView(matches: matches)
                }
            case "multi_live":
                if matches.isEmpty {
                    EmptyLiveActivityView()
                } else {
                    UnifiedMultiMatchListView(matches: matches)
                }
            case "multi_finished":
                if matches.isEmpty {
                    EmptyLiveActivityView()
                } else {
                    UnifiedMultiMatchListView(matches: matches)
                }
            case "ended":
                EndedLiveActivityView()
            default:
                EmptyLiveActivityView()
            }
        }
    }

    private var delayBannerText: String? {
        if state.delayMinutes > 0 {
            return "Delayed \(state.delayMinutes) m | Tap to open"
        }
        return nil
    }

    private var fantasyScoreText: String? {
        guard let fantasyCurrentScore = state.fantasyCurrentScore else { return nil }
        return "\(fantasyCurrentScore)"
    }

    private var topScoresBlue: Color {
        Color(red: 0.00, green: 0.48, blue: 1.00)
    }

    private var fantasyRed: Color {
        Color(red: 0.85, green: 0.12, blue: 0.33)
    }

    private var footerBannerBackground: LinearGradient {
        if fantasyScoreText == nil {
            return LinearGradient(
                colors: [topScoresBlue, topScoresBlue],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        return LinearGradient(
            stops: [
                .init(color: topScoresBlue, location: 0.0),
                .init(color: topScoresBlue, location: 0.58),
                .init(color: fantasyRed.opacity(0.9), location: 0.82),
                .init(color: fantasyRed, location: 1.0),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    @ViewBuilder
    private func footerBanner(usesDenseLayout: Bool) -> some View {
        Group {
            if let bannerText = delayBannerText, fantasyScoreText == nil {
                Text(bannerText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                HStack(spacing: 8) {
                    if let bannerText = delayBannerText {
                        Text(bannerText)
                            .lineLimit(1)
                            .layoutPriority(1)
                            .padding(.leading, 5)
                    }
                    Spacer(minLength: 0)
                    if let fantasyScoreText {
                        HStack(spacing: 3) {
                            Image("FantasyPremierLeagueLion")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 12, height: 12)
                            Text(fantasyScoreText)
                                .lineLimit(1)
                        }
                        .padding(.trailing, 5)
                    }
                }
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, usesDenseLayout ? 4 : 6)
        .frame(maxWidth: .infinity)
        .background(footerBannerBackground)
        .clipShape(RoundedCornerShape(radius: 18, corners: [.bottomLeft, .bottomRight]))
        .compositingGroup()
    }

    private var viewIdentity: String {
        let matchIdentity = state.matches.map(\.renderIdentity).joined(separator: "||")
        return "\(state.mode)|\(state.generatedAtEpochSeconds)|\(state.delayMinutes)|\(state.fantasyCurrentScore ?? -1)|\(matchIdentity)"
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct TopScoresLiveActivityExpandedView: View {
    let state: TopScoresLiveActivityAttributes.ContentState
    let isStale: Bool
    private let maxExpandedMatches = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleView
            MinimalExpandedActivitySummaryView(state: cappedState)
        }
    }

    @ViewBuilder
    private var titleView: some View {
        switch state.mode {
        case "single_live", "multi_live":
            Text("Live Matches")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        case "single_finished", "multi_finished":
            Text("Full-time")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        case "single_upcoming":
            UpcomingMatchesTitle(matches: state.matches)
        case "multi_upcoming":
            UpcomingMatchesTitle(matches: state.matches)
        default:
            Text("Top Scores")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var cappedState: TopScoresLiveActivityAttributes.ContentState {
        TopScoresLiveActivityAttributes.ContentState(
            mode: state.mode,
            generatedAtEpochSeconds: state.generatedAtEpochSeconds,
            delayMinutes: state.delayMinutes,
            fantasyCurrentScore: state.fantasyCurrentScore,
            matches: Array(state.matches.prefix(maxExpandedMatches))
        )
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct MinimalExpandedActivitySummaryView: View {
    let state: TopScoresLiveActivityAttributes.ContentState

    private var visibleMatches: [TopScoresLiveActivityMatchState] {
        Array(LiveActivityMatchDisplayFilter.displayMatches(for: state).prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(visibleMatches.enumerated()), id: \.element.renderIdentity) { index, match in
                HStack(spacing: 8) {
                    Text(match.displayHomeTeam)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(centerText(for: match))
                        .font(centerFont(for: match))
                        .foregroundStyle(.white.opacity(centerOpacity(for: match)))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(width: 56, alignment: .center)

                    Text(match.displayAwayTeam)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    Text(trailingText(for: match))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                        .frame(width: 34, alignment: .trailing)
                }

                if index < visibleMatches.count - 1 {
                    Rectangle()
                        .fill(.white.opacity(0.12))
                        .frame(height: 1)
                }
            }
        }
    }

    private func centerText(for match: TopScoresLiveActivityMatchState) -> String {
        if let home = match.homeScore, let away = match.awayScore {
            return "\(home)-\(away)"
        }
        return match.time
    }

    private func centerFont(for match: TopScoresLiveActivityMatchState) -> Font {
        if match.homeScore != nil, match.awayScore != nil {
            return .caption.monospacedDigit().weight(.bold)
        }
        return .caption2.monospacedDigit().weight(.semibold)
    }

    private func centerOpacity(for match: TopScoresLiveActivityMatchState) -> Double {
        if match.isFinished, match.homeScore != nil, match.awayScore != nil {
            return LiveActivityScoreStyle.finishedOpacity
        }
        return 1.0
    }

    private func trailingText(for match: TopScoresLiveActivityMatchState) -> String {
        if state.mode == "multi_live" || state.mode == "single_live" {
            let liveTime = match.matchTime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !liveTime.isEmpty {
                return liveTime
            }
        }
        let primaryChannel = match.tvChannels
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        if !primaryChannel.isEmpty {
            return String(primaryChannel.prefix(4)).uppercased()
        }
        return match.time
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct SingleUpcomingMatchView: View {
    let match: TopScoresLiveActivityMatchState

    var body: some View {
        SingleMatchCardChrome {
            VStack(alignment: .leading, spacing: 7) {
                SingleUpcomingGridRow {
                    Text(match.league)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                } center: {
                    if let primaryChannel {
                        LiveActivityChannelLogo(channelName: primaryChannel, size: 16)
                    } else {
                        Color.clear
                            .frame(width: 16 * 1.8, height: 16)
                    }
                } right: {
                    Text(headerTrailingText)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                SingleUpcomingGridRow {
                    LiveActivityTeamLogo(
                        teamName: match.homeTeam,
                        alternateNames: [match.homeShortName].compactMap { $0 },
                        size: 24
                    )
                } center: {
                    Text(match.time)
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                } right: {
                    LiveActivityTeamLogo(
                        teamName: match.awayTeam,
                        alternateNames: [match.awayShortName].compactMap { $0 },
                        size: 24
                    )
                }

                SingleUpcomingGridRow {
                    Text(match.displayHomeTeam)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                } center: {
                    if let aggregateText {
                        Text(aggregateText)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    } else {
                        Color.clear
                            .frame(height: 1)
                    }
                } right: {
                    Text(match.displayAwayTeam)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
            }
        }
    }

    private var primaryChannel: String? {
        let primary = match.tvChannels.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        return primary?.isEmpty == false ? primary : nil
    }

    private var headerTrailingText: String {
        if let primaryChannel {
            return primaryChannel
        }
        if let subheading = match.leagueSubcategory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !subheading.isEmpty {
            return subheading
        }
        return " "
    }

    private var aggregateText: String? {
        guard let home = match.resolvedAggregateHomeScore, let away = match.resolvedAggregateAwayScore else { return nil }
        guard match.hasDisplayableAggregateScore else { return nil }
        return "(\(home)-\(away))"
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct SingleLiveMatchView: View {
    let match: TopScoresLiveActivityMatchState
    var compact: Bool = false

    var body: some View {
        SingleMatchCardChrome(horizontalPadding: compact ? 10 : 11, verticalPadding: compact ? 7 : 10) {
            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                CompetitionHeaderRow(
                    league: match.league,
                    subheading: match.leagueSubcategory ?? "Live now",
                    primaryChannel: primaryChannel,
                    compact: compact
                )

                HStack(spacing: compact ? 8 : 10) {
                    LiveActivityTeamLogo(
                        teamName: match.homeTeam,
                        alternateNames: [match.homeShortName].compactMap { $0 },
                        size: 24
                    )
                    Spacer(minLength: 8)
                    LiveActivitySingleScoreRow(match: match, compact: compact)
                    Spacer(minLength: 8)
                    LiveActivityTeamLogo(
                        teamName: match.awayTeam,
                        alternateNames: [match.awayShortName].compactMap { $0 },
                        size: 24
                    )
                }

                TeamNamesWithAggregateRow(
                    homeTeam: match.displayHomeTeam,
                    awayTeam: match.displayAwayTeam,
                    aggregateInfo: aggregateText ?? " ",
                    compact: compact
                )
            }
        }
    }

    private var primaryChannel: String? {
        let primary = match.tvChannels.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        return primary?.isEmpty == false ? primary : nil
    }

    private var aggregateText: String? {
        guard let home = match.resolvedAggregateHomeScore, let away = match.resolvedAggregateAwayScore else { return nil }
        guard match.hasDisplayableAggregateScore else { return nil }
        return "Agg: \(home)-\(away)"
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct SingleFinishedMatchView: View {
    let match: TopScoresLiveActivityMatchState
    var compact: Bool = false

    var body: some View {
        SingleMatchCardChrome(horizontalPadding: compact ? 10 : 11, verticalPadding: compact ? 7 : 10) {
            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                CompetitionHeaderRow(
                    league: match.league,
                    subheading: match.leagueSubcategory ?? "Full time",
                    primaryChannel: primaryChannel,
                    compact: compact
                )

                HStack(spacing: compact ? 8 : 10) {
                    LiveActivityTeamLogo(
                        teamName: match.homeTeam,
                        alternateNames: [match.homeShortName].compactMap { $0 },
                        size: 24
                    )
                    Spacer(minLength: 8)
                    LiveActivitySingleScoreRow(match: match, compact: compact)
                    Spacer(minLength: 8)
                    LiveActivityTeamLogo(
                        teamName: match.awayTeam,
                        alternateNames: [match.awayShortName].compactMap { $0 },
                        size: 24
                    )
                }

                TeamNamesWithAggregateRow(
                    homeTeam: match.displayHomeTeam,
                    awayTeam: match.displayAwayTeam,
                    aggregateInfo: aggregateText ?? " ",
                    compact: compact
                )
            }
        }
    }

    private var primaryChannel: String? {
        let primary = match.tvChannels.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        return primary?.isEmpty == false ? primary : nil
    }

    private var aggregateText: String? {
        guard let home = match.resolvedAggregateHomeScore, let away = match.resolvedAggregateAwayScore else { return nil }
        guard match.hasDisplayableAggregateScore else { return nil }
        return "Agg: \(home)-\(away)"
    }
}

@available(iOSApplicationExtension 16.1, *)
private enum LiveActivityScoreStyle {
    static let finishedOpacity = 0.74
}

@available(iOSApplicationExtension 16.1, *)
private struct LiveActivitySingleScoreRow: View {
    let match: TopScoresLiveActivityMatchState
    var compact: Bool = false

    var body: some View {
        if let homeScore = match.homeScore, let awayScore = match.awayScore {
            HStack(spacing: compact ? 7 : 9) {
                Text(homeScoreText(homeScore))
                    .font(scoreFont)
                    .foregroundStyle(.white.opacity(scoreOpacity))
                Text(scoreSeparatorText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Text(awayScoreText(awayScore))
                    .font(scoreFont)
                    .foregroundStyle(.white.opacity(scoreOpacity))
            }
        } else {
            LiveActivityUpcomingCenterIndicator(match: match, logoSize: 18)
        }
    }

    private var scoreOpacity: Double {
        match.isFinished ? LiveActivityScoreStyle.finishedOpacity : 1.0
    }

    private var fallbackStatus: String {
        match.isFinished ? "FT" : "LIVE"
    }

    private var scoreSeparatorText: String {
        if let penaltyShootoutScoreText = match.penaltyShootoutScoreText {
            return penaltyShootoutScoreText
        }
        if match.homeWonOnPenalties || match.awayWonOnPenalties {
            return "-"
        }
        return match.matchTime ?? fallbackStatus
    }

    private var scoreFont: Font {
        compact
            ? .headline.monospacedDigit().weight(.bold)
            : .title3.monospacedDigit().weight(.bold)
    }

    private func homeScoreText(_ score: Int) -> String {
        if match.penaltyShootoutScoreText != nil { return "\(score)" }
        return match.homeWonOnPenalties ? "\(score) (P)" : "\(score)"
    }

    private func awayScoreText(_ score: Int) -> String {
        if match.penaltyShootoutScoreText != nil { return "\(score)" }
        return match.awayWonOnPenalties ? "\(score) (P)" : "\(score)"
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct LiveActivityUpcomingCenterIndicator: View {
    let match: TopScoresLiveActivityMatchState
    let logoSize: CGFloat
    var prefersChannelIndicatorWhenAvailable = false

    var body: some View {
        if showsCombinedAggregateAndChannelIndicator {
            HStack(alignment: .center, spacing: logoSize >= 18 ? 5 : 3) {
                if let aggregateHomeText {
                    Text(aggregateHomeText)
                        .font(aggregateFont)
                        .foregroundStyle(.white.opacity(0.72))
                }

                LiveActivityUpcomingIndicator(channels: match.tvChannels, logoSize: logoSize)

                if let aggregateAwayText {
                    Text(aggregateAwayText)
                        .font(aggregateFont)
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        } else if shouldShowAggregateInlineScore {
            HStack(alignment: .firstTextBaseline, spacing: logoSize >= 18 ? 4 : 2) {
                if let aggregateHomeText {
                    Text(aggregateHomeText)
                        .font(aggregateFont)
                        .foregroundStyle(.white.opacity(0.72))
                }

                Text("vs")
                    .font(vsFont)
                    .foregroundStyle(.white.opacity(0.85))

                if let aggregateAwayText {
                    Text(aggregateAwayText)
                        .font(aggregateFont)
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        } else {
            LiveActivityUpcomingIndicator(channels: match.tvChannels, logoSize: logoSize)
        }
    }

    private var showsCombinedAggregateAndChannelIndicator: Bool {
        prefersChannelIndicatorWhenAvailable &&
            primaryChannel != nil &&
            match.shouldShowAggregateBracketScoresInline
    }

    private var shouldShowAggregateInlineScore: Bool {
        if showsCombinedAggregateAndChannelIndicator {
            return false
        }
        if prefersChannelIndicatorWhenAvailable && primaryChannel != nil {
            return false
        }
        return match.shouldShowAggregateBracketScoresInline
    }

    private var primaryChannel: String? {
        WidgetTvLogoResolver.shared.preferredChannel(from: match.tvChannels)
    }

    private var aggregateHomeText: String? {
        guard let aggregateHomeScore = match.resolvedAggregateHomeScore, match.hasDisplayableAggregateScore else {
            return nil
        }
        return "(\(aggregateHomeScore))"
    }

    private var aggregateAwayText: String? {
        guard let aggregateAwayScore = match.resolvedAggregateAwayScore, match.hasDisplayableAggregateScore else {
            return nil
        }
        return "(\(aggregateAwayScore))"
    }

    private var aggregateFont: Font {
        logoSize >= 18
            ? .subheadline.monospacedDigit().weight(.medium)
            : .caption2.monospacedDigit().weight(.medium)
    }

    private var vsFont: Font {
        aggregateFont
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct LiveActivityUpcomingIndicator: View {
    let channels: [String]
    let logoSize: CGFloat

    var body: some View {
        if let primaryChannel {
            if let assetName = WidgetTvLogoResolver.shared.assetName(for: primaryChannel, allowsFallback: false) {
                Image(assetName)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: logoSize * 1.8, height: logoSize)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: max(2, logoSize * 0.18),
                            style: .continuous
                        )
                    )
            } else {
                Text(channelBadgeText(for: primaryChannel))
                    .font(channelBadgeFont)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, logoSize >= 18 ? 5 : 4)
                    .padding(.vertical, logoSize >= 18 ? 2 : 1)
                    .background(
                        RoundedRectangle(cornerRadius: max(3, logoSize * 0.22), style: .continuous)
                            .fill(.white.opacity(0.12))
                    )
            }
        } else {
            Text("vs")
                .font(fallbackVsFont)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var primaryChannel: String? {
        WidgetTvLogoResolver.shared.preferredChannel(from: channels)
    }

    private var fallbackVsFont: Font {
        logoSize >= 18
            ? .subheadline.monospacedDigit().weight(.semibold)
            : .caption2.monospacedDigit()
    }

    private var channelBadgeFont: Font {
        logoSize >= 18
            ? .caption2.monospacedDigit().weight(.semibold)
            : .system(size: 9, weight: .semibold, design: .rounded)
    }

    private func channelBadgeText(for channelName: String) -> String {
        let normalized = channelName
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        if normalized.contains("tnt") || normalized.contains("bt sport") {
            return "TNT"
        }
        if normalized.contains("amazon") || normalized.contains("prime") {
            return "AMZN"
        }
        if normalized.contains("sky") {
            return "SKY"
        }
        if normalized.contains("bbc") {
            return "BBC"
        }
        if normalized.contains("itv") {
            return "ITV"
        }
        if normalized.contains("apple") || normalized.contains("mls season pass") {
            return "TV"
        }
        if normalized.contains("channel 4") || normalized.contains("channel4") {
            return "C4"
        }

        let letters = channelName
            .split { !$0.isLetter && !$0.isNumber }
            .prefix(1)
            .flatMap { $0.prefix(4) }
        return letters.isEmpty ? "TV" : String(letters).uppercased()
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct SingleMatchCardChrome<Content: View>: View {
    private let content: Content
    private let horizontalPadding: CGFloat
    private let verticalPadding: CGFloat

    init(
        horizontalPadding: CGFloat = 11,
        verticalPadding: CGFloat = 10,
        @ViewBuilder content: () -> Content
    ) {
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct RoundedCornerShape: Shape {
    let radius: CGFloat
    let corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct CompetitionHeaderRow: View {
    let league: String
    let subheading: String
    let primaryChannel: String?
    var compact: Bool = false

    var body: some View {
        ZStack {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(league)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(topTrailingText)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if let primaryChannel {
                LiveActivityChannelLogo(channelName: primaryChannel, size: compact ? 14 : 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var topTrailingText: String {
        if let primaryChannel, !primaryChannel.isEmpty {
            return primaryChannel
        }
        return subheading
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct UpcomingCompetitionHeaderRow: View {
    let league: String
    let subheading: String?
    let kickoffDate: Date?
    let primaryChannel: String?

    var body: some View {
        ZStack {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(league)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                Spacer(minLength: 4)
                trailingStatusView
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
            }

            if let primaryChannel {
                LiveActivityChannelLogo(channelName: primaryChannel, size: 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var trailingStatusView: some View {
        if let primaryChannel, !primaryChannel.isEmpty {
            Text(primaryChannel)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
        } else if kickoffDate != nil {
            KickoffCountdownLabel(kickoffDate: kickoffDate)
        } else if let subheading, !subheading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(subheading)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
        } else {
            KickoffCountdownLabel(kickoffDate: kickoffDate)
        }
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct SingleUpcomingGridRow<Left: View, Center: View, Right: View>: View {
    private let left: Left
    private let center: Center
    private let right: Right

    init(
        @ViewBuilder left: () -> Left,
        @ViewBuilder center: () -> Center,
        @ViewBuilder right: () -> Right
    ) {
        self.left = left()
        self.center = center()
        self.right = right()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            left
                .frame(maxWidth: .infinity, alignment: .leading)

            center
                .frame(maxWidth: .infinity, alignment: .center)

            right
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct UpcomingMatchesTitle: View {
    let matches: [TopScoresLiveActivityMatchState]

    var body: some View {
        Text(titleText)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private var titleText: String {
        guard let nearestKickoffDate else { return "Kick off soon" }

        let secondsUntilKickoff = nearestKickoffDate.timeIntervalSinceNow
        if secondsUntilKickoff <= 15 * 60 {
            return "Kick off soon"
        }
        return "Kick off today"
    }

    private var nearestKickoffDate: Date? {
        matches
            .compactMap { WidgetMatchDateParser.shared.parse(date: $0.date, time: $0.time) }
            .sorted()
            .first
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct KickoffCountdownLabel: View {
    let kickoffDate: Date?

    var body: some View {
        Group {
            if let kickoffDate {
                if kickoffDate > Date() {
                    HStack(spacing: 0) {
                        Text("Kick off in ")
                        Text(
                            timerInterval: Date()...kickoffDate,
                            pauseTime: nil,
                            countsDown: true,
                            showsHours: false
                        )
                        .monospacedDigit()
                    }
                } else {
                    Text("Kick off now")
                }
            } else {
                Text("Kick off soon")
            }
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.55))
        .lineLimit(1)
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct TeamNamesWithAggregateRow: View {
    let homeTeam: String
    let awayTeam: String
    let aggregateInfo: String
    var compact: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: compact ? 8 : 10) {
            Text(homeTeam)
                .font(teamNameFont)
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)

            ZStack {
                Color.clear
                    .frame(width: centerSlotWidth, height: 1)

                if !aggregateInfo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(aggregateInfo)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            Text(awayTeam)
                .font(teamNameFont)
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
        }
    }

    private var teamNameFont: Font {
        compact ? .caption2.weight(.medium) : .caption.weight(.medium)
    }

    private var centerSlotWidth: CGFloat {
        compact ? 76 : 88
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct MultiMatchListView: View {
    let matches: [TopScoresLiveActivityMatchState]
    let live: Bool
    var maxMatches: Int = 8
    var compact: Bool = false
    var prefersSingleColumn: Bool = false
    var forceSingleColumn: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if usesSingleColumnLayout {
                ForEach(Array(visibleMatches.enumerated()), id: \.element.renderIdentity) { index, match in
                    MultiMatchEntryCell(match: match, live: live, compact: compact, expanded: true)
                    if index < visibleMatches.count - 1 {
                        Rectangle()
                            .fill(.white.opacity(0.16))
                            .frame(height: 1)
                    }
                }
            } else {
                ForEach(chunkedRows) { row in
                    GeometryReader { proxy in
                        let cellWidth = max(0, (proxy.size.width - 17) / 2)
                        HStack(spacing: 8) {
                            MultiMatchEntryCell(match: row.matches[0], live: live, compact: compact)
                                .frame(width: cellWidth, alignment: .leading)

                            Rectangle()
                                .fill(.white.opacity(0.16))
                                .frame(width: 1)
                                .padding(.vertical, 2)

                            if row.matches.count > 1 {
                                MultiMatchEntryCell(match: row.matches[1], live: live, compact: compact)
                                    .frame(width: cellWidth, alignment: .trailing)
                            } else {
                                Color.clear
                                    .frame(width: cellWidth)
                            }
                        }
                    }
                    .frame(height: compact ? 20 : 22)
                }
            }
        }
    }

    private var visibleMatches: [TopScoresLiveActivityMatchState] {
        Array(matches.prefix(maxMatches))
    }

    private var chunkedMatches: [[TopScoresLiveActivityMatchState]] {
        stride(from: 0, to: visibleMatches.count, by: 2).map { index in
            Array(visibleMatches[index..<min(index + 2, visibleMatches.count)])
        }
    }

    private var chunkedRows: [MultiMatchRow] {
        chunkedMatches.map(MultiMatchRow.init(matches:))
    }

    private var usesSingleColumnLayout: Bool {
        forceSingleColumn || (prefersSingleColumn && !compact && visibleMatches.count == 2)
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct UnifiedMultiMatchListView: View {
    let matches: [TopScoresLiveActivityMatchState]

    private var visibleMatches: [TopScoresLiveActivityMatchState] {
        Array(matches.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visibleMatches.enumerated()), id: \.element.renderIdentity) { index, match in
                HStack(spacing: 8) {
                    Text(match.displayHomeTeam)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    centerContent(for: match)
                        .frame(width: 78, alignment: .center)

                    Text(match.displayAwayTeam)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    trailingContent(for: match)
                        .frame(width: 44, alignment: .trailing)
                }
                .padding(.vertical, 4)

                if index < visibleMatches.count - 1 {
                    Rectangle()
                        .fill(.white.opacity(0.12))
                        .frame(height: 1)
                }
            }
        }
    }

    @ViewBuilder
    private func centerContent(for match: TopScoresLiveActivityMatchState) -> some View {
        switch rowKind(for: match) {
        case .upcoming:
            Group {
                if let primary = primaryChannel(for: match) {
                    LiveActivityChannelLogo(channelName: primary, size: 12)
                } else {
                    Text("vs")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
        case .live, .finished:
            Text(primaryStatusText(for: match))
                .font(primaryStatusFont(for: match))
                .foregroundStyle(.white.opacity(primaryStatusOpacity(for: match)))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    @ViewBuilder
    private func trailingContent(for match: TopScoresLiveActivityMatchState) -> some View {
        Text(trailingStatusText(for: match))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(rowKind(for: match) == .upcoming ? 0.72 : 0.65))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    private enum RowKind {
        case upcoming
        case live
        case finished
    }

    private func rowKind(for match: TopScoresLiveActivityMatchState) -> RowKind {
        if match.isFinished {
            return .finished
        }
        if match.isInProgress || match.homeScore != nil || match.awayScore != nil {
            return .live
        }
        return .upcoming
    }

    private func primaryChannel(for match: TopScoresLiveActivityMatchState) -> String? {
        let primary = match.tvChannels.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !primary.isEmpty else { return nil }
        return primary
    }

    private func primaryStatusText(for match: TopScoresLiveActivityMatchState) -> String {
        if let penaltyShootoutScoreText = match.penaltyShootoutScoreText {
            return penaltyShootoutScoreText
        }
        guard let home = match.homeScore, let away = match.awayScore else {
            return fallbackStatusText(for: match)
        }
        if let aggregateHome = match.resolvedAggregateHomeScore,
           let aggregateAway = match.resolvedAggregateAwayScore,
           match.hasDisplayableAggregateScore {
            return "(\(aggregateHome)) \(home)-\(away) (\(aggregateAway))"
        }
        return "\(home)-\(away)"
    }

    private func primaryStatusFont(for match: TopScoresLiveActivityMatchState) -> Font {
        if match.homeScore != nil, match.awayScore != nil {
            return .caption.monospacedDigit().weight(.bold)
        }
        return .caption2.monospacedDigit().weight(.semibold)
    }

    private func primaryStatusOpacity(for match: TopScoresLiveActivityMatchState) -> Double {
        match.isFinished ? LiveActivityScoreStyle.finishedOpacity : 1.0
    }

    private func trailingStatusText(for match: TopScoresLiveActivityMatchState) -> String {
        switch rowKind(for: match) {
        case .upcoming:
            return match.time
        case .finished:
            return "FT"
        case .live:
            let liveTime = match.matchTime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !liveTime.isEmpty {
                return liveTime
            }
            if let displayStatus = formattedMatchTime(for: match)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !displayStatus.isEmpty {
                return displayStatus
            }
            return match.time
        }
    }

    private func fallbackStatusText(for match: TopScoresLiveActivityMatchState) -> String {
        if let displayStatus = formattedMatchTime(for: match)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayStatus.isEmpty {
            return displayStatus
        }
        return match.time
    }

    private func formattedMatchTime(for match: TopScoresLiveActivityMatchState) -> String? {
        let normalized = match.matchTime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty else { return nil }
        let minutePattern = #"^\d{1,3}(?:\+\d{1,2})?'?$"#
        if normalized.range(of: minutePattern, options: .regularExpression) != nil {
            let minuteValue = normalized.replacingOccurrences(of: "'", with: "")
            return "\(minuteValue)'"
        }
        return normalized
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct MultiMatchRow: Identifiable {
    let matches: [TopScoresLiveActivityMatchState]

    var id: String {
        matches.map(\.renderIdentity).joined(separator: "|")
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct MultiMatchEntryCell: View {
    let match: TopScoresLiveActivityMatchState
    let live: Bool
    var compact: Bool = false
    var expanded: Bool = false

    var body: some View {
        Group {
            if expanded {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        LiveActivityTeamLogo(
                            teamName: match.homeTeam,
                            alternateNames: [match.homeShortName].compactMap { $0 },
                            size: 18
                        )
                        Text(match.displayHomeTeam)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    expandedCenterText
                        .frame(width: 50, alignment: .center)

                    HStack(spacing: 6) {
                        Text(match.displayAwayTeam)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        LiveActivityTeamLogo(
                            teamName: match.awayTeam,
                            alternateNames: [match.awayShortName].compactMap { $0 },
                            size: 18
                        )
                    }

                    expandedTrailingMetadata
                        .frame(width: 38, alignment: .trailing)
                }
            } else if live {
                HStack(spacing: 0) {
                    HStack(spacing: 8) {
                        LiveActivityTeamLogo(
                            teamName: match.homeTeam,
                            alternateNames: [match.homeShortName].compactMap { $0 },
                            size: 20
                        )
                            .frame(width: 20, alignment: .center)

                        liveScoreView
                            .frame(width: scoreSlotWidth, alignment: .center)

                        LiveActivityTeamLogo(
                            teamName: match.awayTeam,
                            alternateNames: [match.awayShortName].compactMap { $0 },
                            size: 20
                        )
                            .frame(width: 20, alignment: .center)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 6) {
                        Text(timeText)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(width: 32, alignment: .trailing)

                        liveChannelLogoSlot
                            .frame(width: 27, alignment: .leading)
                    }
                    .frame(width: 65, alignment: .trailing)
                }
            } else {
                HStack(spacing: 0) {
                    HStack(spacing: 8) {
                        LiveActivityTeamLogo(
                            teamName: match.homeTeam,
                            alternateNames: [match.homeShortName].compactMap { $0 },
                            size: 20
                        )
                            .frame(width: 20, alignment: .center)

                        scoreView
                            .frame(width: scoreSlotWidth, alignment: .center)

                        LiveActivityTeamLogo(
                            teamName: match.awayTeam,
                            alternateNames: [match.awayShortName].compactMap { $0 },
                            size: 20
                        )
                            .frame(width: 20, alignment: .center)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(match.time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .frame(minHeight: rowHeight, alignment: .leading)
    }

    @ViewBuilder
    private var liveScoreView: some View {
        if match.hasScore {
            scoreTextView
        } else {
            upcomingIndicatorView
        }
    }

    @ViewBuilder
    private var scoreView: some View {
        if match.hasScore {
            scoreTextView
        } else {
            upcomingIndicatorView
        }
    }

    @ViewBuilder
    private var centerMatchStateView: some View {
        if live {
            liveScoreView
        } else {
            scoreView
        }
    }

    private var upcomingIndicatorView: some View {
        LiveActivityUpcomingCenterIndicator(
            match: match,
            logoSize: expanded ? 18 : 15,
            prefersChannelIndicatorWhenAvailable: true
        )
    }

    private var scoreTextView: some View {
        HStack(alignment: .firstTextBaseline, spacing: showsAggregateScore ? 2 : 0) {
            if let aggregateHomeText {
                Text(aggregateHomeText)
                    .font(aggregateScoreFont)
                    .foregroundStyle(.white.opacity(0.72))
            }

            Text(scoreCoreText)
                .font(scoreFont)
                .foregroundStyle(.white.opacity(scoreOpacity))

            if let aggregateAwayText {
                Text(aggregateAwayText)
                    .font(aggregateScoreFont)
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }

    private var scoreCoreText: String {
        if let home = match.homeScore, let away = match.awayScore {
            return "\(home) - \(away)"
        }
        return "vs"
    }

    private var aggregateHomeText: String? {
        guard showsAggregateScore, let home = match.resolvedAggregateHomeScore else { return nil }
        return "(\(home))"
    }

    private var aggregateAwayText: String? {
        guard showsAggregateScore, let away = match.resolvedAggregateAwayScore else { return nil }
        return "(\(away))"
    }

    private var timeText: String {
        live ? (match.matchTime ?? match.time) : match.time
    }

    private var expandedCenterText: some View {
        Group {
            if let home = match.homeScore, let away = match.awayScore {
                Text("\(home)-\(away)")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white.opacity(scoreOpacity))
                    .lineLimit(1)
            } else {
                Text(match.time)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
            }
        }
    }

    private var primaryChannelName: String {
        let primary = match.tvChannels
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return primary ?? ""
    }

    @ViewBuilder
    private var liveChannelLogoSlot: some View {
        if showsChannelLogo {
            LiveActivityChannelLogo(channelName: primaryChannelName, size: expanded ? 16 : 15)
        } else {
            Color.clear
                .frame(width: liveChannelSlotWidth, height: expanded ? 16 : 15)
        }
    }

    private var showsChannelLogo: Bool {
        match.isInProgress && !primaryChannelName.isEmpty
    }

    private var showsAggregateScore: Bool {
        guard match.hasScore,
              match.hasDisplayableAggregateScore,
              match.resolvedAggregateHomeScore != nil,
              match.resolvedAggregateAwayScore != nil else {
            return false
        }
        return true
    }

    private var scoreSlotWidth: CGFloat {
        if showsUpcomingAggregateWithChannel {
            return expanded ? 94 : 88
        }
        if showsAggregateScore || match.shouldShowAggregateBracketScoresInline {
            return expanded ? 78 : 72
        }
        if expanded {
            return live ? 50 : 44
        }
        return live ? 38 : 32
    }

    private var scoreFont: Font {
        if showsAggregateScore {
            return expanded
                ? .callout.monospacedDigit().weight(.bold)
                : .caption.monospacedDigit().weight(.bold)
        }
        return expanded
            ? .headline.monospacedDigit().weight(.bold)
            : .callout.monospacedDigit().weight(.bold)
    }

    private var aggregateScoreFont: Font {
        if showsAggregateScore {
            return expanded
                ? .caption.monospacedDigit().weight(.semibold)
                : .caption.monospacedDigit().weight(.semibold)
        }
        return expanded
            ? .callout.monospacedDigit().weight(.semibold)
            : .callout.monospacedDigit().weight(.semibold)
    }

    private var scoreOpacity: Double {
        match.isFinished ? LiveActivityScoreStyle.finishedOpacity : 1.0
    }

    @ViewBuilder
    private var trailingMetadataView: some View {
        if live {
            HStack(spacing: 5) {
                Text(timeText)
                    .font(timeFont)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                if showsChannelLogo {
                    liveChannelLogoSlot
                }
            }
        } else {
            Text(match.time)
                .font(timeFont)
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    @ViewBuilder
    private var expandedTrailingMetadata: some View {
        if let primary = match.tvChannels.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           !primary.isEmpty {
            LiveActivityChannelLogo(channelName: primary, size: 14)
        } else if live {
            Text(timeText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
        } else {
            Color.clear
                .frame(width: 14, height: 14)
        }
    }

    private var logoSize: CGFloat {
        expanded ? 24 : 20
    }

    private var teamNameFont: Font {
        expanded ? .caption.weight(.semibold) : .caption2.weight(.medium)
    }

    private var timeFont: Font {
        expanded
            ? .caption.monospacedDigit().weight(.medium)
            : .caption2.monospacedDigit()
    }

    private var rowHeight: CGFloat {
        if compact {
            return 20
        }
        return expanded ? 28 : 22
    }

    private var trailingSlotWidth: CGFloat {
        if expanded {
            return live && showsChannelLogo ? 68 : 40
        }
        return live ? 65 : 36
    }

    private var liveChannelSlotWidth: CGFloat {
        expanded ? 29 : 27
    }

    private var showsUpcomingAggregateWithChannel: Bool {
        !match.hasScore &&
            match.shouldShowAggregateBracketScoresInline &&
            !primaryChannelName.isEmpty
    }
}

@available(iOSApplicationExtension 16.1, *)
private extension TopScoresLiveActivityMatchState {
    var renderIdentity: String {
        let parts: [String] = [
            matchId,
            date,
            time,
            league,
            homeTeam,
            awayTeam,
            homeLogoKey ?? "nil",
            awayLogoKey ?? "nil",
            homeScore.map(String.init) ?? "nil",
            awayScore.map(String.init) ?? "nil",
            aggregateHomeScore.map(String.init) ?? "nil",
            aggregateAwayScore.map(String.init) ?? "nil",
            matchTime ?? "nil",
            penaltyResult ?? "nil",
            tvLogoKey ?? "nil",
        ]
        return parts.joined(separator: "|")
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct ChannelInfoRow: View {
    let channels: [String]

    var body: some View {
        if let primary = channels.first {
            HStack(spacing: 4) {
                Text(primary)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 4)
                LiveActivityChannelLogo(channelName: primary, size: 15)
            }
        }
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct LiveActivityTeamLogo: View {
    let teamName: String
    var alternateNames: [String] = []
    let size: CGFloat

    var body: some View {
        let resolvedImage = WidgetTeamLogoResolver.shared.image(
            for: teamName,
            alternateNames: alternateNames,
            variant: .liveActivity,
            idealPointSize: size
        )
        Group {
            if let resolvedImage {
                Image(uiImage: resolvedImage)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.25))
                    .overlay(
                        Text(String(teamName.prefix(1)).uppercased())
                            .font(.system(size: max(8, size * 0.5), weight: .semibold))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct LiveActivityChannelLogo: View {
    let channelName: String
    let size: CGFloat

    var body: some View {
        let resolvedImage = WidgetTvLogoResolver.shared.image(
            for: channelName,
            variant: .liveActivity,
            idealPointSize: size
        )
        Group {
            if let resolvedImage {
                Image(uiImage: resolvedImage)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.gray.opacity(0.2))
                    .overlay(
                        Text("TV")
                            .font(.system(size: max(7, size * 0.45), weight: .medium))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: size * 1.8, height: size)
        .clipShape(RoundedRectangle(cornerRadius: max(2, size * 0.18), style: .continuous))
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct EndedLiveActivityView: View {
    var body: some View {
        Color.clear
            .frame(height: 1)
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct EmptyLiveActivityView: View {
    var body: some View {
        Text("No matches currently")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct TopScoresWidget: Widget {
    let kind: String = "TopScoresWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TopScoresWidgetProvider()) { entry in
            TopScoresWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Top Scores")
        .description("Upcoming televised fixtures based on your app preferences.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct Top_ScoresWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TopScoresWidget()
        if #available(iOSApplicationExtension 16.1, *) {
            TopScoresLiveActivityWidget()
        }
    }
}
