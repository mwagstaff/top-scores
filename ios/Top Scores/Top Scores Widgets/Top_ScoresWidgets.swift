import SwiftUI
import UIKit
import WidgetKit

private enum WidgetAppGroupConfig {
    static let identifier = "group.dev.skynolimit.topscores"
    static let sharedMatchesFileName = "shared-matches.json"
}

private struct WidgetPreferencesSnapshot: Codable, Equatable {
    let selectedLeagues: [String]
    let selectedChannels: [String]
    let englishPremierLeagueTeamsOnly: Bool
    let apiBaseURL: String
    let refreshIntervalMinutes: Int
}

private struct WidgetMatch: Identifiable, Codable, Hashable {
    let date: String
    let time: String
    let homeTeam: String
    let awayTeam: String
    let league: String
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
        homeScore != nil && awayScore != nil
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
        let normalized = scoreStatus.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized == "FT" || normalized == "AET"
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

    func withTvChannels(_ channels: [String]) -> WidgetMatch {
        WidgetMatch(
            date: date,
            time: time,
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            league: league,
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
        case tvChannels = "tv_channels"
        case homeScore = "home_score"
        case awayScore = "away_score"
        case scoreStatus = "score_status"
    }
}

private struct WidgetSharedMatchesPayload: Codable {
    let snapshot: WidgetPreferencesSnapshot
    let matches: [WidgetMatch]
    let lastUpdated: Date?
    let generatedAt: Date
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
    static func loadPayload() -> WidgetSharedMatchesPayload? {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: WidgetAppGroupConfig.identifier)?
            .appendingPathComponent(WidgetAppGroupConfig.sharedMatchesFileName),
            let data = try? Data(contentsOf: url)
        else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSharedMatchesPayload.self, from: data)
    }
}

private enum WidgetMatchPipeline {
    static func groupedDays(from payload: WidgetSharedMatchesPayload?) -> [WidgetMatchDay] {
        guard let payload else { return [] }

        let leagueFiltered = applyLeagueFilters(to: payload.matches, selectedLeagues: payload.snapshot.selectedLeagues)
        let channelFiltered = applyChannelFilters(to: leagueFiltered, selectedChannels: payload.snapshot.selectedChannels)
        let sorted = sortedMatches(channelFiltered)
        return groupMatches(sorted)
    }

    private static func applyLeagueFilters(to matches: [WidgetMatch], selectedLeagues: [String]) -> [WidgetMatch] {
        guard !selectedLeagues.isEmpty else { return matches }
        let leagueSet = Set(selectedLeagues.map(normalized))

        return matches.filter { match in
            leagueSet.contains(normalized(match.league))
        }
    }

    private static func applyChannelFilters(to matches: [WidgetMatch], selectedChannels: [String]) -> [WidgetMatch] {
        guard !selectedChannels.isEmpty else { return matches }

        return matches.compactMap { match in
            let relevantChannels = WidgetChannelSelection.filterChannels(match.tvChannels, selectedOptions: selectedChannels)
            guard !relevantChannels.isEmpty else { return nil }
            return match.withTvChannels(relevantChannels)
        }
    }

    private static func sortedMatches(_ matches: [WidgetMatch]) -> [WidgetMatch] {
        matches.sorted {
            let leftDate = $0.dateTime ?? WidgetMatchDateParser.shared.parse(date: $0.date, time: "00:00") ?? .distantFuture
            let rightDate = $1.dateTime ?? WidgetMatchDateParser.shared.parse(date: $1.date, time: "00:00") ?? .distantFuture
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

    private static func groupMatches(_ matches: [WidgetMatch]) -> [WidgetMatchDay] {
        let groupedByDate = Dictionary(grouping: matches) { $0.date }
        let dateKeys = groupedByDate.keys.sorted()

        return dateKeys.compactMap { dateKey in
            guard let matchesForDate = groupedByDate[dateKey], !matchesForDate.isEmpty else { return nil }

            let heading: String
            if let parsed = WidgetMatchDateParser.shared.parse(date: dateKey, time: "00:00") {
                heading = WidgetMatchDateParser.shared.displayDateWithRelative(parsed)
            } else {
                heading = dateKey
            }

            return WidgetMatchDay(
                id: dateKey,
                dateKey: dateKey,
                heading: heading,
                matches: matchesForDate
            )
        }
    }

    nonisolated private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class WidgetMatchDateParser {
    static let shared = WidgetMatchDateParser()

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
        dateTimeFormatter.date(from: "\(date) \(time)")
    }

    func displayDateWithRelative(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInTomorrow(date) {
            return "Tomorrow"
        }
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
        let days = WidgetMatchPipeline.groupedDays(from: payload)

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
            SmallMatchesWidgetView(entry: entry)
        case .systemMedium, .systemLarge:
            LargeMatchesWidgetView(entry: entry, compact: family == .systemMedium)
        default:
            SmallMatchesWidgetView(entry: entry)
        }
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
    private var normalizedLookup: [String: URL] = [:]
    private var coreLookup: [String: [URL]] = [:]
    private var originalLookup: [String: URL] = [:]
    private var cache: [String: UIImage] = [:]

    private init() {
        loadLogos()
    }

    func image(for teamName: String) -> UIImage? {
        if let cached = cache[teamName] {
            return cached
        }

        let url = resolveURL(for: teamName) ?? resolveURL(for: fallbackName)
        guard let url else { return nil }

        let image = UIImage(contentsOfFile: url.path)
        if let image {
            cache[teamName] = image
        }

        return image
    }

    private func loadLogos() {
        for bundle in bundlesToSearch {
            var urls = bundle.urls(forResourcesWithExtension: "png", subdirectory: "team-logos") ?? []
            if urls.isEmpty {
                urls = bundle.urls(forResourcesWithExtension: "png", subdirectory: nil) ?? []
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
        }
    }

    private var bundlesToSearch: [Bundle] {
        var bundles: [Bundle] = [Bundle.main]

        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "appex" {
            let containingAppURL = bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            if let containingAppBundle = Bundle(url: containingAppURL) {
                bundles.append(containingAppBundle)
            }
        }

        return bundles
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
}

private final class WidgetTvLogoResolver {
    static let shared = WidgetTvLogoResolver()

    private let fallbackName = "_noLogo"
    private var normalizedLookup: [String: URL] = [:]
    private var cache: [String: UIImage] = [:]

    private init() {
        loadLogos()
    }

    func image(for channelName: String) -> UIImage? {
        if let cached = cache[channelName] {
            return cached
        }

        let url = resolveURL(for: channelName) ?? resolveURL(for: fallbackName)
        guard let url else { return nil }

        let image = UIImage(contentsOfFile: url.path)
        if let image {
            cache[channelName] = image
        }

        return image
    }

    private func loadLogos() {
        for bundle in bundlesToSearch {
            var urls = bundle.urls(forResourcesWithExtension: "png", subdirectory: "tv-logos") ?? []
            if urls.isEmpty {
                urls = bundle.urls(forResourcesWithExtension: "png", subdirectory: nil) ?? []
            }

            for url in urls {
                let fileName = url.deletingPathExtension().lastPathComponent
                let normalized = Self.normalizedKey(fileName)
                normalizedLookup[normalized] = normalizedLookup[normalized] ?? url
            }
        }
    }

    private var bundlesToSearch: [Bundle] {
        var bundles: [Bundle] = [Bundle.main]

        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "appex" {
            let containingAppURL = bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            if let containingAppBundle = Bundle(url: containingAppURL) {
                bundles.append(containingAppBundle)
            }
        }

        return bundles
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

struct TopScoresWidget: Widget {
    let kind: String = "TopScoresWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TopScoresWidgetProvider()) { entry in
            TopScoresWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Top Scores")
        .description("Upcoming televised matches based on your app preferences.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct Top_ScoresWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TopScoresWidget()
    }
}
