import SwiftUI
import UIKit
import WidgetKit
import ActivityKit

private enum WidgetAppGroupConfig {
    static let identifier = "group.dev.skynolimit.topscores"
    static let sharedMatchesFileName = "shared-matches.json"
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

private struct WidgetMatch: Identifiable, Codable, Hashable {
    let date: String
    let time: String
    let homeTeam: String
    let awayTeam: String
    let league: String
    let leagueSubcategory: String?
    let tvChannels: [String]
    let homeScore: Int?
    let awayScore: Int?
    let scoreStatus: String?

    var id: String {
        "\(date)|\(time)|\(league)|\(homeTeam)|\(awayTeam)"
    }

    var dateTime: Date? {
        WidgetMatchDateParser.shared.parse(date: date, time: time)
    }

    var hasScore: Bool {
        rawHasScore && !shouldSuppressScoreDisplay
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
        return normalized.hasPrefix("FT") || normalized.hasPrefix("AET")
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

    func withTvChannels(_ channels: [String]) -> WidgetMatch {
        WidgetMatch(
            date: date,
            time: time,
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            league: league,
            leagueSubcategory: leagueSubcategory,
            tvChannels: channels,
            homeScore: homeScore,
            awayScore: awayScore,
            scoreStatus: scoreStatus
        )
    }

    enum CodingKeys: String, CodingKey {
        case date
        case time
        case homeTeam = "home_team"
        case awayTeam = "away_team"
        case league
        case leagueSubcategory = "league_subcategory"
        case tvChannels = "tv_channels"
        case homeScore = "home_score"
        case awayScore = "away_score"
        case scoreStatus = "score_status"
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
    let homeScore: Int?
    let awayScore: Int?
    let aggregateHomeScore: Int?
    let aggregateAwayScore: Int?
    let matchTime: String?
    let homeTeamScore: Double?
    let awayTeamScore: Double?
    let totalTeamScore: Double?
    let tvChannels: [String]

    var hasScore: Bool {
        rawHasScore && !shouldSuppressScoreDisplay
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
        return normalized.hasPrefix("FT") || normalized.hasPrefix("AET")
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
}

@available(iOSApplicationExtension 16.1, *)
struct TopScoresLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let mode: String
        let generatedAtEpochSeconds: Int
        let delayMinutes: Int
        let delayLabel: String?
        let fantasyCurrentScore: Int?
        let matches: [TopScoresLiveActivityMatchState]
    }

    let appScope: String
}

private enum LiveActivityRenderDiagnostics {
    private static let lock = NSLock()
    private static var loggedKeys = Set<String>()

    static func logIfNeeded(state: TopScoresLiveActivityAttributes.ContentState, surface: String) {
        let key = "\(surface)|\(state.mode)|\(state.generatedAtEpochSeconds)|\(summary(for: state))"
        lock.lock()
        let inserted = loggedKeys.insert(key).inserted
        lock.unlock()
        guard inserted else { return }
        NSLog("[LiveActivityWidget] render surface=%@ %@", surface, summary(for: state))
    }

    static func summary(for state: TopScoresLiveActivityAttributes.ContentState) -> String {
        let matches = state.matches.prefix(4).map { match -> String in
            let score: String
            if match.hasScore, let home = match.homeScore, let away = match.awayScore {
                score = "\(home)-\(away)"
            } else if let suppressed = match.suppressedScoreSummary {
                score = "suppressed:\(suppressed)"
            } else {
                score = "nil"
            }
            return "\(match.homeTeam) v \(match.awayTeam) \(score) \(match.matchTime ?? "nil")"
        }.joined(separator: " | ")
        return "mode=\(state.mode) generatedAt=\(state.generatedAtEpochSeconds) delay=\(state.delayMinutes) matches=\(state.matches.count) [\(matches)]"
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
        "ITV (all)": "itv",
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
        return groupMatches(sorted)
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

    private static func groupMatches(_ matches: [WidgetMatch]) -> [WidgetMatchDay] {
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
        if let displayWeight = WidgetCompetitionWeightConfig.weight(for: match.displayLeague) {
            return displayWeight
        }
        return WidgetCompetitionWeightConfig.weight(for: match.league) ?? 0
    }

    private static func competitionWeight(forCompetitionName competitionName: String) -> Double {
        WidgetCompetitionWeightConfig.weight(for: competitionName) ?? 0
    }

}

private enum WidgetCompetitionWeightConfig {
    private static let fileName = "competition_weights"
    private static let fileExtension = "json"
    private static let weightsByName: [String: Double] = loadWeights()

    static func weight(for competitionName: String) -> Double? {
        let normalized = normalizeCompetitionName(competitionName)
        guard !normalized.isEmpty else { return nil }
        return weightsByName[normalized]
    }

    private static func normalizeCompetitionName(_ competitionName: String) -> String {
        competitionName
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func loadWeights() -> [String: Double] {
        guard let fileURL = Bundle.main.url(forResource: fileName, withExtension: fileExtension) else {
            return [:]
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let json = try JSONSerialization.jsonObject(with: data, options: [])
            guard let rawWeights = json as? [String: Any] else {
                return [:]
            }

            var normalizedWeights: [String: Double] = [:]
            for (competitionName, rawValue) in rawWeights {
                guard let number = rawValue as? NSNumber else { continue }
                let normalized = normalizeCompetitionName(competitionName)
                guard !normalized.isEmpty else { continue }
                normalizedWeights[normalized] = number.doubleValue
            }
            return normalizedWeights
        } catch {
            return [:]
        }
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
            WidgetTeamLogo(teamName: match.homeTeam, size: logoSize)

            Text(WidgetNameFormatter.abbreviated(match.homeTeam, length: 7))
                .font(.caption2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(centerText)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: centerColumnWidth, alignment: .center)

            Text(WidgetNameFormatter.abbreviated(match.awayTeam, length: 7))
                .font(.caption2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)

            WidgetTeamLogo(teamName: match.awayTeam, size: logoSize)
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
            WidgetTeamLogo(teamName: match.homeTeam, size: compact ? 14 : 16)

            Spacer(minLength: compact ? 1 : 4)

            Text(WidgetNameFormatter.hyphenated(match.homeTeam, maxCharacters: maxTeamNameCharacters))
                .font(compact ? .caption2 : .caption)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .layoutPriority(1)

            centerContent
                .frame(width: centerColumnWidth, alignment: .center)

            Text(WidgetNameFormatter.hyphenated(match.awayTeam, maxCharacters: maxTeamNameCharacters))
                .font(compact ? .caption2 : .caption)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            Spacer(minLength: compact ? 1 : 4)

            WidgetTeamLogo(teamName: match.awayTeam, size: compact ? 14 : 16)
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
            WidgetTeamLogo(teamName: match.homeTeam, size: 12)

            Spacer(minLength: 1)

            Text(WidgetNameFormatter.abbreviated(match.homeTeam))
                .font(.caption2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .layoutPriority(1)

            centerContent
                .frame(width: centerColumnWidth, alignment: .center)

            Text(WidgetNameFormatter.abbreviated(match.awayTeam))
                .font(.caption2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            Spacer(minLength: 1)

            WidgetTeamLogo(teamName: match.awayTeam, size: 12)
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
    let size: CGFloat

    var body: some View {
        Group {
            if let image = WidgetTeamLogoResolver.shared.image(for: teamName) {
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
    let compact: Bool

    private var primaryChannel: String? { channels.first }

    var body: some View {
        Group {
            if let primaryChannel,
               let image = WidgetTvLogoResolver.shared.image(for: primaryChannel) {
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

    func image(for teamName: String) -> UIImage? {
        lock.lock()
        if let cached = cache[teamName] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        if let image = resolveAssetImage(for: teamName) ?? resolveAssetFallbackImage() {
            lock.lock()
            cache[teamName] = image
            lock.unlock()
            return image
        }

        let url = resolveURL(for: teamName) ?? resolveURL(for: fallbackName)
        guard let url else { return nil }

        let image = UIImage(contentsOfFile: url.path)
        if let image {
            lock.lock()
            cache[teamName] = image
            lock.unlock()
        }

        return image
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

    private func resolveAssetImage(for teamName: String) -> UIImage? {
        guard let assetName = resolveAssetName(for: teamName) else { return nil }
        return imageFromAssets(named: assetName)
    }

    private func resolveAssetFallbackImage() -> UIImage? {
        if let fallbackAssetName {
            if let image = imageFromAssets(named: fallbackAssetName) {
                return image
            }
        }

        for candidate in [fallbackName, "\(fallbackName) 1"] {
            if let image = imageFromAssets(named: candidate) {
                return image
            }
        }

        return nil
    }

    private func imageFromAssets(named name: String) -> UIImage? {
        for bundle in bundles {
            if let image = UIImage(named: name, in: bundle, compatibleWith: nil) {
                return image
            }
        }
        return nil
    }

    private func resolveAssetName(for teamName: String) -> String? {
        let trimmed = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        if let direct = assetOriginalLookup[lower] {
            return direct
        }

        for alias in Self.aliases(for: trimmed) {
            if let directAlias = assetOriginalLookup[alias] {
                return directAlias
            }

            let aliasKey = Self.normalizedKey(alias)
            if let match = assetNormalizedLookup[aliasKey] {
                return match
            }
        }

        let normalized = Self.normalizedKey(trimmed)
        if let match = assetNormalizedLookup[normalized] {
            return match
        }

        let core = Self.normalizedCoreKey(trimmed)
        if let uniqueCoreMatch = uniqueAssetCoreMatch(for: core) {
            return uniqueCoreMatch
        }

        return fuzzyAssetMatch(normalizedTeam: normalized)
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

    private func resolveURL(for teamName: String) -> URL? {
        let trimmed = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        if let direct = originalLookup[lower] {
            return direct
        }

        for alias in Self.aliases(for: trimmed) {
            let aliasKey = Self.normalizedKey(alias)
            if let match = normalizedLookup[aliasKey] {
                return match
            }
        }

        let normalized = Self.normalizedKey(trimmed)
        if let match = normalizedLookup[normalized] {
            return match
        }

        let core = Self.normalizedCoreKey(trimmed)
        if let uniqueCoreMatch = uniqueCoreMatch(for: core) {
            return uniqueCoreMatch
        }

        return fuzzyMatch(normalizedTeam: normalized)
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

    private static func normalizedKey(_ value: String) -> String {
        normalizedTokens(value).joined()
    }

    private static func normalizedCoreKey(_ value: String) -> String {
        normalizedTokens(value, stripClubAffixes: true).joined()
    }

    private static func normalizedTokens(_ value: String, stripClubAffixes: Bool = false) -> [String] {
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

    private static let stopWords: Set<String> = [
        "fc", "cf", "sc", "afc", "ac", "sv", "fk", "bk", "bc", "ks", "nk",
        "club", "de", "the", "and", "atletico", "athletic", "sporting"
    ]

    private static let clubAffixWords: Set<String> = [
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
        "ac milan": "ac milan"
    ]

    private static func isFallbackName(_ name: String) -> Bool {
        let fallback = normalizedKey("_noTeamLogo")
        let normalized = normalizedKey(name)
        return normalized == fallback || normalized.hasPrefix(fallback)
    }
}

private final class WidgetTvLogoResolver {
    static let shared = WidgetTvLogoResolver()

    private let fallbackName = "_noLogo"
    private let lock = NSLock()
    private var normalizedLookup: [String: URL] = [:]
    private var cache: [String: UIImage] = [:]

    private init() {
        loadLogos()
    }

    func image(for channelName: String, allowsFallback: Bool = true) -> UIImage? {
        let cacheKey = "\(allowsFallback ? "fallback" : "strict")|\(channelName)"
        lock.lock()
        if let cached = cache[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let url = if allowsFallback {
            resolveExplicitURL(for: channelName) ?? resolveURL(for: fallbackName)
        } else {
            resolveExplicitURL(for: channelName)
        }
        guard let url else { return nil }

        let image = UIImage(contentsOfFile: url.path)
        if let image {
            lock.lock()
            cache[cacheKey] = image
            lock.unlock()
        }

        return image
    }

    private func loadLogos() {
        let urls = logoBundles().flatMap { bundle in
            var resolved = bundle.urls(forResourcesWithExtension: "png", subdirectory: "tv-logos") ?? []
            if resolved.isEmpty {
                resolved = bundle.urls(forResourcesWithExtension: "png", subdirectory: nil) ?? []
            }
            return resolved
        }
        for url in urls {
            let fileName = url.deletingPathExtension().lastPathComponent
            let normalized = Self.normalizedKey(fileName)
            normalizedLookup[normalized] = normalizedLookup[normalized] ?? url
        }

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
        ("channel4", "channel4")
    ]
}

@available(iOSApplicationExtension 16.1, *)
private struct TopScoresLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TopScoresLiveActivityAttributes.self) { context in
            TopScoresLiveActivityLockScreenView(state: context.state)
                .activityBackgroundTint(Color(red: 0.03, green: 0.04, blue: 0.09))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    TopScoresLiveActivityExpandedView(state: context.state)
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
        guard let first = state.matches.first else { return "TS" }
        return String(first.homeTeam.prefix(3)).uppercased()
    }

    private func compactTrailingText(state: TopScoresLiveActivityAttributes.ContentState) -> String {
        guard let first = state.matches.first else { return "" }
        if (state.mode.contains("live") || state.mode.contains("finished")),
           let home = first.homeScore,
           let away = first.awayScore {
            return "\(home)-\(away)"
        }
        if state.mode.contains("finished") {
            return first.matchTime ?? first.time
        }
        return first.time
    }

    private func compactTrailingOpacity(state: TopScoresLiveActivityAttributes.ContentState) -> Double {
        guard state.mode.contains("finished"),
              let first = state.matches.first,
              first.homeScore != nil,
              first.awayScore != nil else {
            return 1.0
        }
        return LiveActivityScoreStyle.finishedOpacity
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct TopScoresLiveActivityLockScreenView: View {
    let state: TopScoresLiveActivityAttributes.ContentState

    /// Deduplicates `state.matches` as a last-resort guard against duplicate entries that can
    /// occur when a match's kickoff time or match ID drifts between data sources server-side.
    /// Dedup is keyed first by non-empty `matchId`, then by date + lowercased team names
    /// (time-insensitive) so the same fixture at slightly different scheduled times is collapsed.
    private var deduplicatedMatches: [TopScoresLiveActivityMatchState] {
        var seenMatchIds = Set<String>()
        var seenTeamPairs = Set<String>()
        return state.matches.filter { match in
            if !match.matchId.isEmpty {
                return seenMatchIds.insert(match.matchId).inserted
            }
            let key = "\(match.date)|\(match.homeTeam.lowercased())|\(match.awayTeam.lowercased())"
            return seenTeamPairs.insert(key).inserted
        }
    }

    var body: some View {
        let isMultiMode = state.mode == "multi_live" || state.mode == "multi_upcoming" || state.mode == "multi_finished"
        let matches = deduplicatedMatches
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                switch state.mode {
                case "single_upcoming":
                    if let match = matches.first {
                        SingleUpcomingMatchView(match: match)
                    } else {
                        EmptyLiveActivityView()
                    }
                case "single_live":
                    if let match = matches.first {
                        SingleLiveMatchView(match: match)
                    } else {
                        EmptyLiveActivityView()
                    }
                case "single_finished":
                    if let match = matches.first {
                        SingleFinishedMatchView(match: match)
                    } else {
                        EmptyLiveActivityView()
                    }
                case "multi_upcoming":
                    MultiMatchListView(matches: matches, live: false)
                case "multi_live":
                    MultiMatchListView(matches: matches, live: true)
                case "multi_finished":
                    MultiMatchListView(matches: matches, live: true)
                case "ended":
                    EndedLiveActivityView()
                default:
                    EmptyLiveActivityView()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, isMultiMode ? 6 : 8)

            if delayBannerText != nil || fantasyScoreText != nil {
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
                                Text(fantasyScoreText)
                                    .lineLimit(1)
                                    .padding(.trailing, 5)
                            }
                        }
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(footerBannerBackground)
            }
        }
        .task(id: renderDiagnosticsKey) {
            LiveActivityRenderDiagnostics.logIfNeeded(state: state, surface: "lock_screen")
        }
    }

    private var delayBannerText: String? {
        if state.delayMinutes > 0 {
            return "Delayed \(state.delayMinutes) m | Tap to open"
        }
        guard let delayLabel = state.delayLabel, !delayLabel.isEmpty else { return nil }
        return "\(delayLabel) | Tap to open"
    }

    private var fantasyScoreText: String? {
        guard let fantasyCurrentScore = state.fantasyCurrentScore else { return nil }
        return "FF: \(fantasyCurrentScore)"
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

    private var renderDiagnosticsKey: String {
        "\(state.mode)|\(state.generatedAtEpochSeconds)|\(state.matches.count)|\(state.fantasyCurrentScore ?? -1)"
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct TopScoresLiveActivityExpandedView: View {
    let state: TopScoresLiveActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleView
            TopScoresLiveActivityLockScreenView(state: state)
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
}

@available(iOSApplicationExtension 16.1, *)
private struct SingleUpcomingMatchView: View {
    let match: TopScoresLiveActivityMatchState

    var body: some View {
        SingleMatchCardChrome {
            VStack(alignment: .leading, spacing: 8) {
                UpcomingCompetitionHeaderRow(
                    league: match.league,
                    subheading: match.leagueSubcategory,
                    kickoffDate: kickoffDate,
                    primaryChannel: primaryChannel
                )

                HStack(spacing: 0) {
                    HStack(spacing: 14) {
                        LiveActivityTeamLogo(teamName: match.homeTeam, size: 24)
                        LiveActivityUpcomingIndicator(channels: match.tvChannels, logoSize: 18)
                        LiveActivityTeamLogo(teamName: match.awayTeam, size: 24)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(match.time)
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 44, alignment: .trailing)
                }

                TeamNamesWithAggregateRow(
                    homeTeam: match.homeTeam,
                    awayTeam: match.awayTeam,
                    aggregateInfo: "Kick-off"
                )
            }
        }
    }

    private var kickoffDate: Date? {
        WidgetMatchDateParser.shared.parse(date: match.date, time: match.time)
    }

    private var primaryChannel: String? {
        let primary = match.tvChannels.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        return primary?.isEmpty == false ? primary : nil
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct SingleLiveMatchView: View {
    let match: TopScoresLiveActivityMatchState

    var body: some View {
        SingleMatchCardChrome {
            VStack(alignment: .leading, spacing: 8) {
                CompetitionHeaderRow(
                    league: match.league,
                    subheading: match.leagueSubcategory ?? "Live now",
                    primaryChannel: primaryChannel
                )

                HStack(spacing: 10) {
                    LiveActivityTeamLogo(teamName: match.homeTeam, size: 24)
                    Spacer(minLength: 8)
                    LiveActivitySingleScoreRow(match: match)
                    Spacer(minLength: 8)
                    LiveActivityTeamLogo(teamName: match.awayTeam, size: 24)
                }

                TeamNamesWithAggregateRow(
                    homeTeam: match.homeTeam,
                    awayTeam: match.awayTeam,
                    aggregateInfo: " "
                )
            }
        }
    }

    private var primaryChannel: String? {
        let primary = match.tvChannels.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        return primary?.isEmpty == false ? primary : nil
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct SingleFinishedMatchView: View {
    let match: TopScoresLiveActivityMatchState

    var body: some View {
        SingleMatchCardChrome {
            VStack(alignment: .leading, spacing: 8) {
                CompetitionHeaderRow(
                    league: match.league,
                    subheading: match.leagueSubcategory ?? "Full time",
                    primaryChannel: primaryChannel
                )

                HStack(spacing: 10) {
                    LiveActivityTeamLogo(teamName: match.homeTeam, size: 24)
                    Spacer(minLength: 8)
                    LiveActivitySingleScoreRow(match: match)
                    Spacer(minLength: 8)
                    LiveActivityTeamLogo(teamName: match.awayTeam, size: 24)
                }

                TeamNamesWithAggregateRow(
                    homeTeam: match.homeTeam,
                    awayTeam: match.awayTeam,
                    aggregateInfo: " "
                )
            }
        }
    }

    private var primaryChannel: String? {
        let primary = match.tvChannels.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        return primary?.isEmpty == false ? primary : nil
    }
}

@available(iOSApplicationExtension 16.1, *)
private enum LiveActivityScoreStyle {
    static let finishedOpacity = 0.74
}

@available(iOSApplicationExtension 16.1, *)
private struct LiveActivitySingleScoreRow: View {
    let match: TopScoresLiveActivityMatchState

    var body: some View {
        if let homeScore = match.homeScore, let awayScore = match.awayScore {
            HStack(spacing: 9) {
                Text("\(homeScore)")
                    .font(.title3.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white.opacity(scoreOpacity))
                Text(match.matchTime ?? fallbackStatus)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Text("\(awayScore)")
                    .font(.title3.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white.opacity(scoreOpacity))
            }
        } else {
            LiveActivityUpcomingIndicator(channels: match.tvChannels, logoSize: 18)
        }
    }

    private var scoreOpacity: Double {
        match.isFinished ? LiveActivityScoreStyle.finishedOpacity : 1.0
    }

    private var fallbackStatus: String {
        match.isFinished ? "FT" : "LIVE"
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct LiveActivityUpcomingIndicator: View {
    let channels: [String]
    let logoSize: CGFloat

    var body: some View {
        if let primaryChannel,
           let image = WidgetTvLogoResolver.shared.image(for: primaryChannel, allowsFallback: false) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: logoSize * 1.8, height: logoSize)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: max(2, logoSize * 0.18),
                        style: .continuous
                    )
                )
        } else {
            Text("vs")
                .font(.title3.monospacedDigit().weight(.bold))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var primaryChannel: String? {
        channels
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct SingleMatchCardChrome<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct CompetitionHeaderRow: View {
    let league: String
    let subheading: String
    let primaryChannel: String?

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
                LiveActivityChannelLogo(channelName: primaryChannel, size: 16)
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
                    (Text("Kick off in ")
                        + Text(
                            timerInterval: Date()...kickoffDate,
                            pauseTime: nil,
                            countsDown: true,
                            showsHours: false
                        )
                        .monospacedDigit())
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

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                Text(homeTeam)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(awayTeam)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
            }

            if !aggregateInfo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(aggregateInfo)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
        }
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct MultiMatchListView: View {
    let matches: [TopScoresLiveActivityMatchState]
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(chunkedMatches.enumerated()), id: \.offset) { _, rowMatches in
                HStack(spacing: 8) {
                    MultiMatchEntryCell(match: rowMatches[0], live: live)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Rectangle()
                        .fill(.white.opacity(0.16))
                        .frame(width: 1)
                        .padding(.vertical, 2)

                    if rowMatches.count > 1 {
                        MultiMatchEntryCell(match: rowMatches[1], live: live)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var visibleMatches: [TopScoresLiveActivityMatchState] {
        Array(matches.prefix(8))
    }

    private var chunkedMatches: [[TopScoresLiveActivityMatchState]] {
        stride(from: 0, to: visibleMatches.count, by: 2).map { index in
            Array(visibleMatches[index..<min(index + 2, visibleMatches.count)])
        }
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct MultiMatchEntryCell: View {
    let match: TopScoresLiveActivityMatchState
    let live: Bool

    var body: some View {
        Group {
            if live {
                HStack(spacing: 0) {
                    HStack(spacing: 8) {
                        LiveActivityTeamLogo(teamName: match.homeTeam, size: 20)
                            .frame(width: 20, alignment: .center)

                        liveScoreView
                            .frame(width: 38, alignment: .center)

                        LiveActivityTeamLogo(teamName: match.awayTeam, size: 20)
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
                        LiveActivityTeamLogo(teamName: match.homeTeam, size: 20)
                            .frame(width: 20, alignment: .center)

                        scoreView
                            .frame(width: 32, alignment: .center)

                        LiveActivityTeamLogo(teamName: match.awayTeam, size: 20)
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
        .frame(minHeight: 22, alignment: .leading)
    }

    @ViewBuilder
    private var liveScoreView: some View {
        Text(match.hasScore ? scoreCoreText : "vs")
            .font(.callout.monospacedDigit().weight(.bold))
            .foregroundStyle(.white.opacity(scoreOpacity))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    @ViewBuilder
    private var scoreView: some View {
        if match.hasScore {
            HStack(spacing: 2) {
                Text(scoreCoreText)
                    .font(.callout.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white.opacity(scoreOpacity))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        } else {
            LiveActivityUpcomingIndicator(channels: match.tvChannels, logoSize: 15)
        }
    }

    private var scoreCoreText: String {
        if let home = match.homeScore, let away = match.awayScore {
            return "\(home) - \(away)"
        }
        return "vs"
    }

    private var timeText: String {
        live ? (match.matchTime ?? match.time) : match.time
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
            LiveActivityChannelLogo(channelName: primaryChannelName, size: 15)
        } else {
            Color.clear
                .frame(width: 27, height: 15)
        }
    }

    private var showsChannelLogo: Bool {
        match.isInProgress && !primaryChannelName.isEmpty
    }

    private var scoreOpacity: Double {
        match.isFinished ? LiveActivityScoreStyle.finishedOpacity : 1.0
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
    let size: CGFloat

    var body: some View {
        Group {
            if let image = WidgetTeamLogoResolver.shared.image(for: teamName) {
                Image(uiImage: image)
                    .resizable()
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
        Group {
            if let image = WidgetTvLogoResolver.shared.image(for: channelName) {
                Image(uiImage: image)
                    .resizable()
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
