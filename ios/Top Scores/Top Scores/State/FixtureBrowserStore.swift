import Foundation
import Combine
import os

struct FixtureBrowseBucket: Codable, Hashable, Sendable {
    let matches: [Match]
    let fetchedAt: Date
    let lastUpdated: Date?
}

struct FixtureBrowseCachePayload: Codable, Sendable {
    let formatVersion: Int
    let contextKey: String
    var competitions: [CompetitionCatalogEntry]
    var calendarDays: [FixtureCalendarDay]
    var calendarSelectionApplied: Bool?
    var catalogFetchedAt: Date?
    var calendarFetchedAt: Date?
    var buckets: [String: FixtureBrowseBucket]
}

struct FixtureCalendarCompetitionSummary: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let matchCount: Int
    let weight: Double
}

struct FixtureBrowseMatchAvailability: Equatable, Sendable {
    let matchCount: Int
    let containsNextScheduledMatch: Bool
}

private actor FixtureBrowseCacheWriter {
    static let shared = FixtureBrowseCacheWriter()

    private var latestWriteRequest = UInt64.zero

    func write(
        _ payload: FixtureBrowseCachePayload,
        to cacheURL: URL,
        requestedAt: UInt64
    ) {
        guard requestedAt >= latestWriteRequest else { return }
        latestWriteRequest = requestedAt
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}

@MainActor
final class FixtureBrowsePageCache: ObservableObject {
    @Published private(set) var matchesByDate: [String: [Match]] = [:]

    fileprivate func replace(with matchesByDate: [String: [Match]]) {
        guard self.matchesByDate != matchesByDate else { return }
        self.matchesByDate = matchesByDate
    }

    fileprivate func set(_ matches: [Match], for dateKey: String) {
        guard matchesByDate[dateKey] != matches else { return }
        matchesByDate[dateKey] = matches
    }

    fileprivate func remove(_ dateKey: String) {
        guard matchesByDate[dateKey] != nil else { return }
        matchesByDate.removeValue(forKey: dateKey)
    }
}

nonisolated enum FixtureBrowsePrefetchPlanner {
    static func dateKeys(
        in days: [FixtureCalendarDay],
        centeredOn dateKey: String,
        radius: Int
    ) -> [String] {
        guard radius >= 0,
              let selectedIndex = days.firstIndex(where: { $0.date == dateKey }) else {
            return [dateKey]
        }
        let lowerBound = max(days.startIndex, selectedIndex - radius)
        let upperBound = min(days.index(before: days.endIndex), selectedIndex + radius)
        return days[lowerBound...upperBound].map(\.date)
    }

    static func range(for dateKeys: [String]) -> ClosedRange<String>? {
        guard let first = dateKeys.min(), let last = dateKeys.max() else { return nil }
        return first...last
    }
}

nonisolated enum FixtureBrowseAvailabilityPlanner {
    static let immediateFutureDayLimit = 14

    static func immediateDateKeys(
        calendarDays: [FixtureCalendarDay],
        selectedDateKey: String?,
        todayKey: String,
        selectedDateRadius: Int = 3
    ) -> Set<String> {
        let orderedDays = calendarDays.sorted { $0.date < $1.date }
        var dateKeys = Set(
            orderedDays
                .lazy
                .filter { $0.date >= todayKey && $0.matchCount > 0 }
                .prefix(immediateFutureDayLimit)
                .map(\.date)
        )
        if let selectedDateKey {
            dateKeys.formUnion(FixtureBrowsePrefetchPlanner.dateKeys(
                in: orderedDays,
                centeredOn: selectedDateKey,
                radius: selectedDateRadius
            ))
        }
        return dateKeys
    }
}

nonisolated enum FixtureBrowseWarmPlanner {
    static func batches(
        in days: [FixtureCalendarDay],
        startingAt dateKey: String,
        maximumMatchCount: Int = 1_800
    ) -> [[FixtureCalendarDay]] {
        let upcomingDays = days.filter { $0.date >= dateKey && $0.matchCount > 0 }
        guard !upcomingDays.isEmpty else { return [] }

        var batches: [[FixtureCalendarDay]] = []
        var currentBatch: [FixtureCalendarDay] = []
        var currentMatchCount = 0

        for day in upcomingDays {
            if !currentBatch.isEmpty,
               currentMatchCount + day.matchCount > maximumMatchCount {
                batches.append(currentBatch)
                currentBatch = []
                currentMatchCount = 0
            }
            currentBatch.append(day)
            currentMatchCount += day.matchCount
        }

        if !currentBatch.isEmpty {
            batches.append(currentBatch)
        }
        return batches
    }
}

nonisolated enum FixtureBrowseSelectionResolver {
    enum DateJumpDirection: Equatable, Sendable {
        case earlier
        case later
    }

    static func selectedCompetitionIDs(
        selectedLeagues: [String],
        competitions: [CompetitionCatalogEntry]
    ) -> Set<String> {
        let selectedKeys = Set(selectedLeagues.map(normalizedKey))
        return Set(competitions.compactMap { competition in
            competition.allNames.contains { selectedKeys.contains(normalizedKey($0)) }
                ? competition.stableID
                : nil
        })
    }

    static func availableDays(
        calendarDays: [FixtureCalendarDay],
        topMatchesOnly: Bool,
        selectedCompetitionIDs: Set<String>,
        selectionApplied: Bool = false,
        showAllMatches: Bool = false,
        knownMatchCountsByDate: [String: Int] = [:]
    ) -> [FixtureCalendarDay] {
        calendarDays.filter { day in
            if knownMatchCountsByDate[day.date] == 0 {
                return false
            }
            if selectionApplied || showAllMatches {
                return day.matchCount > 0
            }
            if topMatchesOnly {
                return day.topMatchCount > 0
            }
            return day.competitions.contains { selectedCompetitionIDs.contains($0.id) }
        }
    }

    static func defaultDateKey(
        from days: [FixtureCalendarDay],
        todayKey: String,
        topMatchesOnly: Bool,
        selectedCompetitionIDs: Set<String>,
        selectionApplied: Bool = false,
        showAllMatches: Bool = false,
        knownAvailability: [String: FixtureBrowseMatchAvailability] = [:]
    ) -> String? {
        upcomingDateKey(
            from: days,
            todayKey: todayKey,
            topMatchesOnly: topMatchesOnly,
            selectedCompetitionIDs: selectedCompetitionIDs,
            selectionApplied: selectionApplied,
            showAllMatches: showAllMatches,
            knownAvailability: knownAvailability
        ) ?? days.last?.date
    }

    static func upcomingDateKey(
        from days: [FixtureCalendarDay],
        todayKey: String,
        topMatchesOnly: Bool,
        selectedCompetitionIDs: Set<String>,
        selectionApplied: Bool = false,
        showAllMatches: Bool = false,
        knownAvailability: [String: FixtureBrowseMatchAvailability] = [:]
    ) -> String? {
        days.first { day in
            guard day.date >= todayKey else { return false }
            if let availability = knownAvailability[day.date] {
                return availability.containsNextScheduledMatch
            }
            if day.date > todayKey { return true }
            if selectionApplied || showAllMatches { return day.hasUnfinished }
            if topMatchesOnly { return day.topMatchesHaveUnfinished }
            return day.competitions.contains {
                selectedCompetitionIDs.contains($0.id) && $0.hasUnfinished
            }
        }?.date
    }

    static func dateJumpDirection(
        from selectedDateKey: String?,
        to targetDateKey: String?
    ) -> DateJumpDirection? {
        guard let selectedDateKey,
              let targetDateKey,
              selectedDateKey != targetDateKey else {
            return nil
        }
        return targetDateKey < selectedDateKey ? .earlier : .later
    }

    static func containsNextScheduledMatch(
        _ matches: [Match],
        dateKey: String,
        todayKey: String
    ) -> Bool {
        guard dateKey >= todayKey, !matches.isEmpty else { return false }
        if dateKey > todayKey { return true }
        return matches.contains { !$0.isFinished && !$0.isPostponed }
    }

    static func competitionSummaries(
        for day: FixtureCalendarDay,
        catalog: [CompetitionCatalogEntry],
        selectedCompetitionIDs: Set<String>?
    ) -> [FixtureCalendarCompetitionSummary] {
        let catalogByID = Dictionary(
            uniqueKeysWithValues: catalog.map { ($0.stableID, $0) }
        )
        return day.competitions.compactMap { competition in
            if let selectedCompetitionIDs,
               !selectedCompetitionIDs.contains(competition.id) {
                return nil
            }
            guard let catalogEntry = catalogByID[competition.id] else { return nil }
            return FixtureCalendarCompetitionSummary(
                id: competition.id,
                name: catalogEntry.name,
                matchCount: competition.matchCount,
                weight: catalogEntry.weight
            )
        }
        .sorted { lhs, rhs in
            if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func adjacentDateKey(
        in days: [FixtureCalendarDay],
        from selectedDateKey: String?,
        offset: Int
    ) -> String? {
        guard offset != 0,
              let selectedDateKey,
              let selectedIndex = days.firstIndex(where: { $0.date == selectedDateKey }) else {
            return nil
        }
        let targetIndex = selectedIndex + offset
        guard days.indices.contains(targetIndex) else { return nil }
        return days[targetIndex].date
    }

    static func swipeDateOffset(
        translationWidth: CGFloat,
        translationHeight: CGFloat,
        predictedEndTranslationWidth: CGFloat,
        containerWidth: CGFloat
    ) -> Int? {
        let horizontalDistance = abs(translationWidth)
        let verticalDistance = abs(translationHeight)
        guard horizontalDistance > verticalDistance * 1.15 else { return nil }

        let distanceThreshold = max(52, min(containerWidth * 0.22, 88))
        let projectedThreshold = max(72, containerWidth * 0.35)
        let projectionContinuesDirection = translationWidth * predictedEndTranslationWidth > 0
        let crossesDistanceThreshold = horizontalDistance >= distanceThreshold
        let crossesProjectedThreshold = projectionContinuesDirection &&
            abs(predictedEndTranslationWidth) >= projectedThreshold
        guard crossesDistanceThreshold || crossesProjectedThreshold else { return nil }

        return translationWidth < 0 ? 1 : -1
    }

    static func hasHorizontalSwipeIntent(
        translationWidth: CGFloat,
        translationHeight: CGFloat,
        activationDistance: CGFloat = 10
    ) -> Bool {
        let horizontalDistance = abs(translationWidth)
        let verticalDistance = abs(translationHeight)
        return max(horizontalDistance, verticalDistance) >= activationDistance &&
            horizontalDistance > verticalDistance
    }

    static func filterMatches(
        _ matches: [Match],
        topMatchesOnly: Bool,
        selectedCompetitionIDs: Set<String>,
        competitions: [CompetitionCatalogEntry],
        fixtureViewOptionIDs: Set<String> = [],
        showAllMatches: Bool = false,
        includePostponed: Bool,
        includeFACupEarlyRounds: Bool = PreferencesStore.defaultShowFACupEarlyRounds,
        topTeamsMatcher: TopTeamsPresetMatcher = TopTeamsPresetMatcher(definition: .fallback),
        premierLeagueTeamMatcher: PremierLeagueTeamMatcher = .empty
    ) -> [Match] {
        filterMatches(
            matches,
            topMatchesOnly: topMatchesOnly,
            selectedCompetitionIDs: selectedCompetitionIDs,
            competitions: competitions,
            fixtureViewOptionIDs: fixtureViewOptionIDs,
            showAllMatches: showAllMatches,
            includePostponed: includePostponed,
            includeFACupEarlyRounds: includeFACupEarlyRounds,
            topTeamsMatcher: topTeamsMatcher,
            premierLeagueTeamMatcher: premierLeagueTeamMatcher,
            competitionLookup: nil
        )
    }

    static func matchAvailabilityByDate(
        matchesByDate: [String: [Match]],
        todayKey: String,
        topMatchesOnly: Bool,
        selectedCompetitionIDs: Set<String>,
        competitions: [CompetitionCatalogEntry],
        fixtureViewOptionIDs: Set<String>,
        showAllMatches: Bool,
        includePostponed: Bool,
        includeFACupEarlyRounds: Bool = PreferencesStore.defaultShowFACupEarlyRounds,
        topTeamsMatcher: TopTeamsPresetMatcher,
        premierLeagueTeamMatcher: PremierLeagueTeamMatcher
    ) -> [String: FixtureBrowseMatchAvailability] {
        let filteredMatchesByDate = filterMatchesByDate(
            matchesByDate,
            topMatchesOnly: topMatchesOnly,
            selectedCompetitionIDs: selectedCompetitionIDs,
            competitions: competitions,
            fixtureViewOptionIDs: fixtureViewOptionIDs,
            showAllMatches: showAllMatches,
            includePostponed: includePostponed,
            includeFACupEarlyRounds: includeFACupEarlyRounds,
            topTeamsMatcher: topTeamsMatcher,
            premierLeagueTeamMatcher: premierLeagueTeamMatcher
        )
        return Dictionary(uniqueKeysWithValues: filteredMatchesByDate.map { dateKey, filtered in
            (
                dateKey,
                FixtureBrowseMatchAvailability(
                    matchCount: filtered.count,
                    containsNextScheduledMatch: containsNextScheduledMatch(
                        filtered,
                        dateKey: dateKey,
                        todayKey: todayKey
                    )
                )
            )
        })
    }

    static func filterMatchesByDate(
        _ matchesByDate: [String: [Match]],
        topMatchesOnly: Bool,
        selectedCompetitionIDs: Set<String>,
        competitions: [CompetitionCatalogEntry],
        fixtureViewOptionIDs: Set<String>,
        showAllMatches: Bool,
        includePostponed: Bool,
        includeFACupEarlyRounds: Bool = PreferencesStore.defaultShowFACupEarlyRounds,
        topTeamsMatcher: TopTeamsPresetMatcher,
        premierLeagueTeamMatcher: PremierLeagueTeamMatcher
    ) -> [String: [Match]] {
        let lookup = competitionLookup(competitions)
        return Dictionary(uniqueKeysWithValues: matchesByDate.map { dateKey, matches in
            let filtered = filterMatches(
                matches,
                topMatchesOnly: topMatchesOnly,
                selectedCompetitionIDs: selectedCompetitionIDs,
                competitions: competitions,
                fixtureViewOptionIDs: fixtureViewOptionIDs,
                showAllMatches: showAllMatches,
                includePostponed: includePostponed,
                includeFACupEarlyRounds: includeFACupEarlyRounds,
                topTeamsMatcher: topTeamsMatcher,
                premierLeagueTeamMatcher: premierLeagueTeamMatcher,
                competitionLookup: lookup
            )
            return (dateKey, filtered)
        })
    }

    private static func filterMatches(
        _ matches: [Match],
        topMatchesOnly: Bool,
        selectedCompetitionIDs: Set<String>,
        competitions: [CompetitionCatalogEntry],
        fixtureViewOptionIDs: Set<String>,
        showAllMatches: Bool,
        includePostponed: Bool,
        includeFACupEarlyRounds: Bool = PreferencesStore.defaultShowFACupEarlyRounds,
        topTeamsMatcher: TopTeamsPresetMatcher,
        premierLeagueTeamMatcher: PremierLeagueTeamMatcher,
        competitionLookup preparedCompetitionLookup: [String: String]?
    ) -> [Match] {
        let displayableMatches: [Match]
        #if DEBUG
        displayableMatches = matches
        #else
        displayableMatches = matches.filter { $0.isTestMatch != true }
        #endif

        let competitionFiltered: [Match]
        if showAllMatches {
            competitionFiltered = displayableMatches
        } else if fixtureViewOptionIDs == Set([FixtureViewOptionID.topTeamsPreset]) {
            let lookup = preparedCompetitionLookup ?? competitionLookup(competitions)
            competitionFiltered = displayableMatches.filter { match in
                topTeamsMatcher.matches(
                    match,
                    competitionID: topTeamsCompetitionID(
                        for: match,
                        competitionLookup: lookup
                    )
                )
            }
        } else if fixtureViewOptionIDs == FixtureViewOptionID.premierLeagueMatchesPresetOptionIDs {
            competitionFiltered = displayableMatches.filter(
                premierLeagueTeamMatcher.matches
            )
        } else if !fixtureViewOptionIDs.isEmpty {
            let lookup = preparedCompetitionLookup ?? competitionLookup(competitions)
            competitionFiltered = displayableMatches.filter { match in
                matchesFixtureViewOption(
                    match,
                    optionIDs: fixtureViewOptionIDs,
                    competitionLookup: lookup,
                    premierLeagueTeamMatcher: premierLeagueTeamMatcher
                )
            }
        } else if topMatchesOnly {
            competitionFiltered = displayableMatches
        } else {
            let lookup = preparedCompetitionLookup ?? competitionLookup(competitions)
            competitionFiltered = displayableMatches.filter { match in
                guard let competitionID = lookup[normalizedKey(match.league)] else { return false }
                return selectedCompetitionIDs.contains(competitionID)
            }
        }
        return competitionFiltered.filter {
            (includePostponed || !$0.isPostponed) &&
                (includeFACupEarlyRounds || !$0.isFACupEarlyRound)
        }
    }

    static func normalizedKey(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    private static func competitionLookup(_ competitions: [CompetitionCatalogEntry]) -> [String: String] {
        var lookup: [String: String] = [:]
        for competition in competitions {
            for name in competition.allNames {
                lookup[normalizedKey(name)] = competition.stableID
            }
        }
        return lookup
    }

    private static func topTeamsCompetitionID(
        for match: Match,
        competitionLookup: [String: String]
    ) -> String? {
        let leagueKey = normalizedKey(match.league)
        if let exact = competitionLookup[leagueKey] { return exact }
        if leagueKey.contains("champions league") { return "uefa-champions-league" }
        if leagueKey.contains("europa league") { return "uefa-europa-league" }
        if leagueKey.contains("conference league") { return "uefa-conference-league" }
        if leagueKey.contains("uefa super cup") { return "uefa-super-cup" }
        return nil
    }

    private static let fixtureTeamAliases: [String: Set<String>] = [
        "real-madrid": ["Real Madrid"],
        "barcelona": ["Barcelona", "FC Barcelona"],
        "celtic": ["Celtic", "Celtic FC"],
        "rangers": ["Rangers", "Rangers FC"],
        "bayern-munich": ["Bayern Munich", "Bayern München", "FC Bayern München"],
        "borussia-dortmund": ["Borussia Dortmund", "Dortmund", "BVB"],
        "inter": ["Inter", "Inter Milan", "Internazionale", "Internazionale Milano", "FC Internazionale Milano"],
        "ac-milan": ["AC Milan", "Milan", "AC Milan 1899"],
        "juventus": ["Juventus", "Juventus FC"],
        "paris-saint-germain": ["Paris Saint-Germain", "Paris St Germain", "Paris SG", "PSG"],
        "marseille": ["Marseille", "Olympique Marseille", "Olympique de Marseille", "OM"],
    ].mapValues { Set($0.map(normalizedKey)) }

    private static let fixtureRivalries: [String: (String, String)] = [
        "el-clasico": ("barcelona", "real-madrid"),
        "old-firm": ("celtic", "rangers"),
        "der-klassiker": ("bayern-munich", "borussia-dortmund"),
        "derby-della-madonnina": ("inter", "ac-milan"),
        "le-classique": ("paris-saint-germain", "marseille"),
    ]

    // The API applies the authoritative Elo-based rule. These aliases keep the
    // picker useful while talking to an older server that ignores view_option.
    private static let fallbackTopUEFAClubs: Set<String> = Set([
        "Arsenal", "Aston Villa", "Chelsea", "Liverpool", "Manchester City",
        "Manchester United", "Newcastle United", "Tottenham Hotspur",
        "Real Madrid", "Barcelona", "Atletico Madrid", "Atlético Madrid",
        "Bayern Munich", "Bayern München", "Borussia Dortmund", "Bayer Leverkusen",
        "Inter", "Inter Milan", "AC Milan", "Juventus", "Napoli",
        "Paris Saint-Germain", "Paris St Germain", "Marseille",
        "Ajax", "PSV Eindhoven", "Feyenoord", "Benfica", "Porto", "Sporting CP",
    ].map(normalizedKey))

    private static func matchesFixtureViewOption(
        _ match: Match,
        optionIDs: Set<String>,
        competitionLookup: [String: String],
        premierLeagueTeamMatcher: PremierLeagueTeamMatcher
    ) -> Bool {
        let competitionID = competitionLookup[normalizedKey(match.league)]
        let teamRuleIDs = optionIDs.intersection(
            FixtureViewOptionID.mutuallyExclusiveUEFATeamRules
        )
        let normalOptionIDs = optionIDs.subtracting(teamRuleIDs)
        guard let competitionID,
              FixtureViewOptionID.uefaClubCompetitionStableIDs.contains(competitionID),
              !teamRuleIDs.isEmpty else {
            return normalOptionIDs.contains {
                matchesNonRuleFixtureViewOption(
                    match,
                    optionID: $0,
                    competitionID: competitionID
                )
            }
        }

        let selectedUEFACompetitionIDs = Set(
            normalOptionIDs
                .compactMap(FixtureViewOptionID.competitionStableID)
                .filter(FixtureViewOptionID.uefaClubCompetitionStableIDs.contains)
        )
        let explicitNonCompetitionMatch = normalOptionIDs.contains { optionID in
            guard FixtureViewOptionID.competitionStableID(from: optionID) == nil else {
                return false
            }
            return matchesNonRuleFixtureViewOption(
                match,
                optionID: optionID,
                competitionID: competitionID
            )
        }
        let passesTeamRule = teamRuleIDs.contains {
            matchesUEFATeamRule(
                match,
                optionID: $0,
                premierLeagueTeamMatcher: premierLeagueTeamMatcher
            )
        }

        if !selectedUEFACompetitionIDs.isEmpty {
            return explicitNonCompetitionMatch || (
                selectedUEFACompetitionIDs.contains(competitionID) && passesTeamRule
            )
        }
        return explicitNonCompetitionMatch || passesTeamRule
    }

    private static func matchesNonRuleFixtureViewOption(
        _ match: Match,
        optionID: String,
        competitionID: String?
    ) -> Bool {
        if optionID == FixtureViewOptionID.all { return true }
        if let selectedCompetitionID = FixtureViewOptionID.competitionStableID(from: optionID) {
            return competitionID == selectedCompetitionID
        }
        if optionID.hasPrefix("team:") {
            let teamID = String(optionID.dropFirst("team:".count))
            return fixtureTeamMatches(match.homeTeam, teamID: teamID) ||
                fixtureTeamMatches(match.awayTeam, teamID: teamID)
        }
        if optionID.hasPrefix("rivalry:") {
            let rivalryID = String(optionID.dropFirst("rivalry:".count))
            guard let (firstTeamID, secondTeamID) = fixtureRivalries[rivalryID] else {
                return false
            }
            return (
                fixtureTeamMatches(match.homeTeam, teamID: firstTeamID) &&
                fixtureTeamMatches(match.awayTeam, teamID: secondTeamID)
            ) || (
                fixtureTeamMatches(match.homeTeam, teamID: secondTeamID) &&
                fixtureTeamMatches(match.awayTeam, teamID: firstTeamID)
            )
        }
        return false
    }

    private static func matchesUEFATeamRule(
        _ match: Match,
        optionID: String,
        premierLeagueTeamMatcher: PremierLeagueTeamMatcher
    ) -> Bool {
        if optionID == FixtureViewOptionID.topUEFAClubs {
            return fallbackTopUEFAClubs.contains(normalizedKey(match.homeTeam)) ||
                fallbackTopUEFAClubs.contains(normalizedKey(match.awayTeam))
        }
        if optionID == FixtureViewOptionID.premierLeagueTeams {
            return premierLeagueTeamMatcher.matches(match)
        }
        return false
    }

    private static func fixtureTeamMatches(_ teamName: String, teamID: String) -> Bool {
        if fixtureTeamAliases[teamID]?.contains(normalizedKey(teamName)) == true {
            return true
        }

        let selectedKey = TeamIdentityStore.normalizedKey(teamID)
        guard !selectedKey.isEmpty else { return false }
        return TeamIdentityStore.shared.normalizedKeys(for: teamName).contains(selectedKey)
    }
}

nonisolated enum FixtureBrowseAutoRefreshPolicy {
    static let liveIntervalSeconds = 15
    static let pendingTodayIntervalSeconds = 60
    static let fixtureMembershipRefreshInterval: TimeInterval = 60
    static let preMatchStateWindow: TimeInterval = 30 * 60
    static let postKickoffStateWindow: TimeInterval = 6 * 60 * 60

    static func intervalSeconds(
        selectedDateKey: String?,
        todayKey: String,
        matches: [Match]
    ) -> Int? {
        guard !matches.isEmpty else { return nil }
        if matches.contains(where: \.isInProgress) {
            return liveIntervalSeconds
        }
        guard selectedDateKey == todayKey else {
            return nil
        }
        return pendingTodayIntervalSeconds
    }

    static func shouldRefreshFixtureMembership(
        bucketFetchedAt: Date,
        now: Date = Date()
    ) -> Bool {
        now.timeIntervalSince(bucketFetchedAt) >= fixtureMembershipRefreshInterval
    }

    static func stateRefreshMatches(in matches: [Match], now: Date = Date()) -> [Match] {
        matches.filter { match in
            guard match.matchDetailsID != nil else { return false }
            if match.isInProgress { return true }
            guard !match.isFinished,
                  !match.isPostponed,
                  let kickoff = match.dateTime else {
                return false
            }
            return kickoff.timeIntervalSince(now) <= preMatchStateWindow &&
                now.timeIntervalSince(kickoff) <= postKickoffStateWindow
        }
    }
}

@MainActor
final class FixtureBrowserStore: ObservableObject {
    @Published private(set) var competitions: [CompetitionCatalogEntry] = []
    @Published private(set) var availableDays: [FixtureCalendarDay] = []
    @Published private(set) var visibleMatches: [Match] = []
    @Published private(set) var selectedDateUnfilteredMatches: [Match] = []
    @Published private(set) var selectedDateKey: String?
    @Published private(set) var isLoadingSelectedDate = false
    @Published private(set) var hasLoadedCalendar = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var todayDateKey: String
    @Published private(set) var nextMatchDateKey: String?

    let pageCache = FixtureBrowsePageCache()

    private let apiSession: URLSession?
    private var topTeamsMatcher: TopTeamsPresetMatcher
    private var topTeamsPresetCancellable: AnyCancellable?
    private var premierLeagueTeamMatcher: PremierLeagueTeamMatcher
    private var premierLeagueTeamsCancellable: AnyCancellable?

    init(apiSession: URLSession? = nil) {
        self.apiSession = apiSession
        todayDateKey = Self.dateFormatter.string(from: Date())
        let presetStore = TopTeamsPresetStore.shared
        topTeamsMatcher = TopTeamsPresetMatcher(definition: presetStore.preset)
        let premierLeagueTeamsStore = PremierLeagueTeamsStore.shared
        premierLeagueTeamMatcher = premierLeagueTeamsStore.matcher
        topTeamsPresetCancellable = presetStore.$preset
            .dropFirst()
            .sink { [weak self] preset in
                self?.applyTopTeamsPreset(preset)
            }
        premierLeagueTeamsCancellable = premierLeagueTeamsStore.$matcher
            .dropFirst()
            .sink { [weak self] matcher in
                self?.applyPremierLeagueTeamMatcher(matcher)
            }
    }

    var cachedMatchesByDate: [String: [Match]] {
        pageCache.matchesByDate
    }

    func cachedUnfilteredMatches(for dateKey: String) -> [Match] {
        guard let snapshot,
              let bucket = cachePayload?.buckets[Self.bucketKey(dateKey: dateKey)] else {
            return []
        }
        return unfilteredMatches(in: bucket, snapshot: snapshot)
    }

    var calendarCompetitionSummariesByDate: [String: [FixtureCalendarCompetitionSummary]] {
        guard let snapshot else { return [:] }

        let selectedCompetitionIDs: Set<String>? =
            snapshot.fixtureViewShowsAll || calendarRequiresMatchLevelFiltering(snapshot)
                ? nil
                : selectedCompetitionIDs(for: snapshot)

        return Dictionary(uniqueKeysWithValues: availableDays.map { day in
            let summaries = FixtureBrowseSelectionResolver.competitionSummaries(
                for: day,
                catalog: competitions,
                selectedCompetitionIDs: selectedCompetitionIDs
            )
            return (day.date, summaries)
        })
    }

    private static let cacheFormatVersion = 2
    private static let maximumCachedBuckets = 512
    private static let prefetchRadius = 3
    private static let pageCacheRadius = 1
    private static let maximumPreparedPageCount = 15
    private static let catalogFreshnessInterval: TimeInterval = 24 * 60 * 60
    private var snapshot: PreferencesSnapshot?
    private var contextKey: String?
    private var cachePayload: FixtureBrowseCachePayload?
    private var catalogFetchedAt: Date?
    private var refreshTask: Task<Void, Never>?
    private var selectedDateTask: Task<Void, Never>?
    private var selectedDateTaskDateKey: String?
    private var prefetchTask: Task<Void, Never>?
    private var allFixturesWarmTask: Task<Void, Never>?
    private var availabilityRefinementTask: Task<Void, Never>?
    private var pageCacheRebuildTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private var dateSwipeWorkReleaseTask: Task<Void, Never>?
    private var autoRefreshTaskID = UUID()
    private var isAutoRefreshEnabled = false
    private var refreshRequestID = UUID()
    private var selectedDateRequestID = UUID()
    private var prefetchRequestID = UUID()
    private var allFixturesWarmRequestID = UUID()
    private var availabilityRefinementRequestID = UUID()
    private var pageCacheRebuildRequestID = UUID()
    private var isTVListingsModeEnabled = false
    private var isDateSwipeInteractionActive = false

    func setDateSwipeInteractionActive(_ isActive: Bool) {
        dateSwipeWorkReleaseTask?.cancel()
        dateSwipeWorkReleaseTask = nil
        if isActive {
            isDateSwipeInteractionActive = true
            dateSwipeWorkReleaseTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                isDateSwipeInteractionActive = false
                dateSwipeWorkReleaseTask = nil
            }
            return
        }

        dateSwipeWorkReleaseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            isDateSwipeInteractionActive = false
            dateSwipeWorkReleaseTask = nil
        }
    }

    private func waitUntilDateSwipeWorkMayPublish() async throws {
        while isDateSwipeInteractionActive {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    func configure(
        preferences: PreferencesSnapshot,
        forceRefresh: Bool = false,
        resetSelectedDate: Bool = false
    ) {
        let previousSnapshot = snapshot
        let nextContextKey = Self.contextKey(for: preferences)
        let contextChanged = contextKey != nextContextKey
        snapshot = preferences

        let cacheAge = cachePayload?.calendarFetchedAt.map { Date().timeIntervalSince($0) }
        let calendarNeedsRefresh = forceRefresh || contextChanged || (
            refreshTask == nil && (cacheAge == nil || (cacheAge ?? .infinity) > 15 * 60)
        )
        if previousSnapshot == preferences,
           !resetSelectedDate,
           !calendarNeedsRefresh,
           selectedDateKey != nil {
            return
        }

        if Set(preferences.effectiveFixtureViewOptionIDs) ==
            FixtureViewOptionID.premierLeagueMatchesPresetOptionIDs {
            Task {
                await PremierLeagueTeamsStore.shared.ensureFresh(
                    apiBaseURL: preferences.apiBaseURL
                )
            }
        }

        if contextChanged {
            refreshTask?.cancel()
            refreshTask = nil
            selectedDateTask?.cancel()
            selectedDateTask = nil
            pageCacheRebuildTask?.cancel()
            pageCacheRebuildTask = nil
            pageCacheRebuildRequestID = UUID()
            selectedDateTaskDateKey = nil
            prefetchTask?.cancel()
            prefetchTask = nil
            allFixturesWarmTask?.cancel()
            allFixturesWarmTask = nil
            availabilityRefinementTask?.cancel()
            availabilityRefinementTask = nil
            isLoadingSelectedDate = false
            refreshRequestID = UUID()
            selectedDateRequestID = UUID()
            prefetchRequestID = UUID()
            allFixturesWarmRequestID = UUID()
            availabilityRefinementRequestID = UUID()
            nextMatchDateKey = nil
            contextKey = nextContextKey
            cachePayload = Self.loadCache(matching: nextContextKey)
            if let cachedCompetitions = cachePayload?.competitions,
               !cachedCompetitions.isEmpty {
                competitions = cachedCompetitions
                catalogFetchedAt = cachePayload?.catalogFetchedAt
            }
            pageCache.replace(with: [:])
            selectedDateUnfilteredMatches = []
            hasLoadedCalendar = !(cachePayload?.calendarDays.isEmpty ?? true)
            CompetitionBadgeCache.shared.warmIfNeeded(entries: competitions)
        }

        recomputeAvailableDays(keepCurrentDate: !contextChanged && !resetSelectedDate)
        loadSelectedDateIfNeeded(force: false)

        if calendarNeedsRefresh {
            refreshCatalogAndCalendar(force: forceRefresh)
        }
        scheduleAllUpcomingFixturesWarm()
    }

    func selectDate(_ dateKey: String) {
        guard availableDays.contains(where: { $0.date == dateKey }), selectedDateKey != dateKey else {
            return
        }
        let signpost = PerformanceSignposter.matches.beginInterval("FixtureBrowserSelectDate")
        let startedAt = Date()
        defer {
            PerformanceSignposter.matches.endInterval("FixtureBrowserSelectDate", signpost)
            let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
            if durationMilliseconds >= 16 {
                diagnosticLog(
                    "[FixtureBrowserStore] select_date_sync_complete date=%@ duration_ms=%d",
                    dateKey,
                    durationMilliseconds
                )
            }
        }
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchRequestID = UUID()
        selectedDateKey = dateKey
        let cachedMatches = pageCache.matchesByDate[dateKey] ?? []
        if visibleMatches != cachedMatches {
            visibleMatches = cachedMatches
        }
        if isTVListingsModeEnabled {
            refreshSelectedDateUnfilteredMatches()
        }
        schedulePageCacheRebuild()
        loadSelectedDateIfNeeded(force: false)
        if isAutoRefreshEnabled {
            startAutoRefreshLoop(refreshImmediately: true)
        }
    }

    func setTVListingsModeEnabled(_ enabled: Bool) {
        guard isTVListingsModeEnabled != enabled else { return }
        isTVListingsModeEnabled = enabled
        recomputeAvailableDays(keepCurrentDate: true)
        loadSelectedDateIfNeeded(force: false)
    }

    func adjacentDateKey(offset: Int) -> String? {
        FixtureBrowseSelectionResolver.adjacentDateKey(
            in: availableDays,
            from: selectedDateKey,
            offset: offset
        )
    }

    func refreshToday(now: Date = Date()) {
        let currentDateKey = Self.dateFormatter.string(from: now)
        guard todayDateKey != currentDateKey else { return }
        todayDateKey = currentDateKey
        recomputeAvailableDays(keepCurrentDate: true)
    }

    var nextMatchDateJumpDirection: FixtureBrowseSelectionResolver.DateJumpDirection? {
        FixtureBrowseSelectionResolver.dateJumpDirection(
            from: selectedDateKey,
            to: nextMatchDateKey
        )
    }

    func selectNextMatchDate() {
        guard let nextMatchDateKey else { return }
        selectDate(nextMatchDateKey)
    }

    func selectAdjacentDate(offset: Int) {
        guard let targetDateKey = adjacentDateKey(offset: offset) else { return }
        selectDate(targetDateKey)
    }

    func refresh() async {
        refreshCatalogAndCalendar(force: true)
        loadSelectedDateIfNeeded(force: true)
        let catalogTask = refreshTask
        let dateTask = selectedDateTask
        await catalogTask?.value
        await dateTask?.value
        await selectedDateTask?.value
    }

    func warmAllUpcomingFixtures() async {
        scheduleAllUpcomingFixturesWarm()
        await allFixturesWarmTask?.value
    }

    func setAutoRefreshEnabled(_ enabled: Bool, refreshImmediately: Bool = false) {
        let changed = isAutoRefreshEnabled != enabled
        isAutoRefreshEnabled = enabled
        guard enabled else {
            autoRefreshTask?.cancel()
            autoRefreshTask = nil
            autoRefreshTaskID = UUID()
            return
        }
        if changed || refreshImmediately || autoRefreshTask == nil {
            startAutoRefreshLoop(refreshImmediately: refreshImmediately)
        }
    }

    private func refreshCatalogAndCalendar(force: Bool) {
        guard let snapshot, let baseURL = URL(string: snapshot.apiBaseURL) else { return }
        if refreshTask != nil, !force { return }
        refreshTask?.cancel()
        let requestID = UUID()
        refreshRequestID = requestID
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                async let calendarTask = APIClient(
                    baseURL: baseURL,
                    session: apiSession
                ).fetchFixtureCalendar(preferences: snapshot)
                let shouldRefreshCatalog = competitions.isEmpty ||
                    Date().timeIntervalSince(catalogFetchedAt ?? .distantPast) >= Self.catalogFreshnessInterval
                let resolvedCompetitions: [CompetitionCatalogEntry]
                if shouldRefreshCatalog {
                    resolvedCompetitions = try await APIClient(
                        baseURL: baseURL,
                        session: apiSession
                    )
                        .fetchCompetitionCatalog()
                        .competitions
                } else {
                    resolvedCompetitions = competitions
                }
                let calendar = try await calendarTask
                guard !Task.isCancelled, refreshRequestID == requestID else { return }

                competitions = resolvedCompetitions
                if shouldRefreshCatalog {
                    catalogFetchedAt = Date()
                }
                hasLoadedCalendar = true
                errorMessage = nil
                let existingBuckets = cachePayload?.buckets ?? [:]
                cachePayload = FixtureBrowseCachePayload(
                    formatVersion: Self.cacheFormatVersion,
                    contextKey: Self.contextKey(for: snapshot),
                    competitions: resolvedCompetitions,
                    calendarDays: calendar.days,
                    calendarSelectionApplied: calendar.selectionApplied,
                    catalogFetchedAt: catalogFetchedAt,
                    calendarFetchedAt: Date(),
                    buckets: existingBuckets
                )
                CompetitionBadgeCache.shared.warmIfNeeded(entries: resolvedCompetitions)
                recomputeAvailableDays(keepCurrentDate: true)
                persistCache()
                loadSelectedDateIfNeeded(force: false)
                scheduleAllUpcomingFixturesWarm()
            } catch {
                if !Task.isCancelled, refreshRequestID == requestID {
                    errorMessage = "Unable to refresh fixture dates."
                }
            }
            if refreshRequestID == requestID {
                refreshTask = nil
            }
        }
    }

    private func recomputeAvailableDays(keepCurrentDate: Bool) {
        let signpost = PerformanceSignposter.matches.beginInterval("FixtureBrowserImmediateAvailability")
        defer { PerformanceSignposter.matches.endInterval("FixtureBrowserImmediateAvailability", signpost) }
        guard let snapshot else { return }
        let selectedIDs = selectedCompetitionIDs(for: snapshot)
        let requiresMatchLevelFiltering = !isTVListingsModeEnabled &&
            calendarRequiresMatchLevelFiltering(snapshot)
        let validatesMatchAvailability = requiresMatchLevelFiltering || !snapshot.showFACupEarlyRounds
        let canValidateCachedDates = !requiresMatchLevelFiltering ||
            Set(snapshot.effectiveFixtureViewOptionIDs) !=
                FixtureViewOptionID.premierLeagueMatchesPresetOptionIDs ||
            !premierLeagueTeamMatcher.isEmpty
        let immediateAvailability: [String: FixtureBrowseMatchAvailability]
        if validatesMatchAvailability, canValidateCachedDates {
            let immediateDateKeys = FixtureBrowseAvailabilityPlanner.immediateDateKeys(
                calendarDays: cachePayload?.calendarDays ?? [],
                selectedDateKey: selectedDateKey,
                todayKey: todayDateKey,
                selectedDateRadius: Self.prefetchRadius
            )
            let matchesByDate: [String: [Match]] = Dictionary(
                uniqueKeysWithValues: immediateDateKeys.compactMap { dateKey in
                    guard let bucket = cachePayload?.buckets[Self.bucketKey(dateKey: dateKey)],
                          Self.isFresh(bucket: bucket, dateKey: dateKey) else {
                        return nil
                    }
                    return (dateKey, bucket.matches)
                }
            )
            immediateAvailability = matchAvailabilityByDate(
                matchesByDate,
                snapshot: snapshot,
                selectedCompetitionIDs: selectedIDs
            )
        } else {
            immediateAvailability = [:]
        }

        applyAvailableDays(
            snapshot: snapshot,
            selectedCompetitionIDs: selectedIDs,
            requiresMatchLevelFiltering: requiresMatchLevelFiltering,
            knownAvailability: immediateAvailability,
            keepCurrentDate: keepCurrentDate
        )

        availabilityRefinementTask?.cancel()
        availabilityRefinementTask = nil
        availabilityRefinementRequestID = UUID()
        if validatesMatchAvailability, canValidateCachedDates {
            scheduleAvailabilityRefinement(
                snapshot: snapshot,
                selectedCompetitionIDs: selectedIDs,
                immediateDateKeys: Set(immediateAvailability.keys)
            )
        }
    }

    private func applyAvailableDays(
        snapshot: PreferencesSnapshot,
        selectedCompetitionIDs: Set<String>,
        requiresMatchLevelFiltering: Bool,
        knownAvailability: [String: FixtureBrowseMatchAvailability],
        keepCurrentDate: Bool
    ) {
        guard self.snapshot == snapshot else { return }
        let knownMatchCountsByDate = knownAvailability.mapValues(\.matchCount)
        let days = FixtureBrowseSelectionResolver.availableDays(
            calendarDays: cachePayload?.calendarDays ?? [],
            topMatchesOnly: calendarUsesTopMatches(snapshot),
            selectedCompetitionIDs: selectedCompetitionIDs,
            selectionApplied: requiresMatchLevelFiltering,
            showAllMatches: calendarShowsAllMatches(snapshot),
            knownMatchCountsByDate: knownMatchCountsByDate
        )
        if availableDays != days {
            availableDays = days
        }

        let resolvedNextMatchDateKey: String?
        if requiresMatchLevelFiltering {
            resolvedNextMatchDateKey = knownAvailability
                .filter { $0.value.containsNextScheduledMatch }
                .map(\.key)
                .min()
        } else {
            resolvedNextMatchDateKey = FixtureBrowseSelectionResolver.upcomingDateKey(
                from: days,
                todayKey: todayDateKey,
                topMatchesOnly: calendarUsesTopMatches(snapshot),
                selectedCompetitionIDs: selectedCompetitionIDs,
                selectionApplied: false,
                showAllMatches: calendarShowsAllMatches(snapshot),
                knownAvailability: knownAvailability
            )
        }
        if nextMatchDateKey != resolvedNextMatchDateKey {
            nextMatchDateKey = resolvedNextMatchDateKey
        }

        if keepCurrentDate,
           let selectedDateKey,
           days.contains(where: { $0.date == selectedDateKey }) {
            applyCachedBucketIfAvailable()
            schedulePageCacheRebuild()
            return
        }

        selectedDateKey = resolvedNextMatchDateKey ?? FixtureBrowseSelectionResolver.defaultDateKey(
            from: days,
            todayKey: todayDateKey,
            topMatchesOnly: calendarUsesTopMatches(snapshot),
            selectedCompetitionIDs: selectedCompetitionIDs,
            selectionApplied: requiresMatchLevelFiltering,
            showAllMatches: calendarShowsAllMatches(snapshot),
            knownAvailability: knownAvailability
        )
        visibleMatches = []
        applyCachedBucketIfAvailable()
        schedulePageCacheRebuild()
    }

    private func matchAvailabilityByDate(
        _ matchesByDate: [String: [Match]],
        snapshot: PreferencesSnapshot,
        selectedCompetitionIDs: Set<String>
    ) -> [String: FixtureBrowseMatchAvailability] {
        FixtureBrowseSelectionResolver.matchAvailabilityByDate(
            matchesByDate: matchesByDate,
            todayKey: todayDateKey,
            topMatchesOnly: calendarUsesTopMatches(snapshot),
            selectedCompetitionIDs: selectedCompetitionIDs,
            competitions: competitions,
            fixtureViewOptionIDs: Set(snapshot.effectiveFixtureViewOptionIDs),
            showAllMatches: calendarShowsAllMatches(snapshot),
            includePostponed: snapshot.showPostponedGames,
            includeFACupEarlyRounds: snapshot.showFACupEarlyRounds,
            topTeamsMatcher: topTeamsMatcher,
            premierLeagueTeamMatcher: premierLeagueTeamMatcher
        )
    }

    private func scheduleAvailabilityRefinement(
        snapshot: PreferencesSnapshot,
        selectedCompetitionIDs: Set<String>,
        immediateDateKeys: Set<String>
    ) {
        guard let payload = cachePayload else { return }
        let matchesByDate: [String: [Match]] = Dictionary(
            uniqueKeysWithValues: payload.buckets.compactMap { dateKey, bucket in
                guard !immediateDateKeys.contains(dateKey),
                      Self.isFresh(bucket: bucket, dateKey: dateKey) else {
                    return nil
                }
                return (dateKey, bucket.matches)
            }
        )
        guard !matchesByDate.isEmpty else { return }

        let requestID = UUID()
        availabilityRefinementRequestID = requestID
        let todayKey = todayDateKey
        let topMatchesOnly = calendarUsesTopMatches(snapshot)
        let fixtureViewOptionIDs = Set(snapshot.effectiveFixtureViewOptionIDs)
        let showAllMatches = calendarShowsAllMatches(snapshot)
        let includePostponed = snapshot.showPostponedGames
        let includeFACupEarlyRounds = snapshot.showFACupEarlyRounds
        let competitionSnapshot = competitions
        let topTeamsMatcherSnapshot = topTeamsMatcher
        let premierLeagueTeamMatcherSnapshot = premierLeagueTeamMatcher

        availabilityRefinementTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled,
                  let store = self,
                  await store.shouldContinueAvailabilityRefinement(
                    requestID: requestID,
                    snapshot: snapshot
                  ) else {
                return
            }

            let signpost = PerformanceSignposter.matches.beginInterval("FixtureBrowserAvailabilityRefinement")
            defer { PerformanceSignposter.matches.endInterval("FixtureBrowserAvailabilityRefinement", signpost) }
            let refinedAvailability = FixtureBrowseSelectionResolver.matchAvailabilityByDate(
                matchesByDate: matchesByDate,
                todayKey: todayKey,
                topMatchesOnly: topMatchesOnly,
                selectedCompetitionIDs: selectedCompetitionIDs,
                competitions: competitionSnapshot,
                fixtureViewOptionIDs: fixtureViewOptionIDs,
                showAllMatches: showAllMatches,
                includePostponed: includePostponed,
                includeFACupEarlyRounds: includeFACupEarlyRounds,
                topTeamsMatcher: topTeamsMatcherSnapshot,
                premierLeagueTeamMatcher: premierLeagueTeamMatcherSnapshot
            )
            guard !Task.isCancelled else { return }
            await store.applyRefinedAvailability(
                refinedAvailability,
                immediateDateKeys: immediateDateKeys,
                requestID: requestID,
                snapshot: snapshot,
                selectedCompetitionIDs: selectedCompetitionIDs
            )
        }
    }

    private func shouldContinueAvailabilityRefinement(
        requestID: UUID,
        snapshot: PreferencesSnapshot
    ) -> Bool {
        availabilityRefinementRequestID == requestID &&
            self.snapshot == snapshot &&
            allFixturesWarmTask == nil
    }

    private func applyRefinedAvailability(
        _ refinedAvailability: [String: FixtureBrowseMatchAvailability],
        immediateDateKeys: Set<String>,
        requestID: UUID,
        snapshot: PreferencesSnapshot,
        selectedCompetitionIDs: Set<String>
    ) async {
        do {
            try await waitUntilDateSwipeWorkMayPublish()
        } catch {
            return
        }
        guard availabilityRefinementRequestID == requestID,
              self.snapshot == snapshot else {
            return
        }
        let immediateMatchesByDate: [String: [Match]] = Dictionary(
            uniqueKeysWithValues: immediateDateKeys.compactMap { dateKey in
                guard let bucket = cachePayload?.buckets[Self.bucketKey(dateKey: dateKey)],
                      Self.isFresh(bucket: bucket, dateKey: dateKey) else {
                    return nil
                }
                return (dateKey, bucket.matches)
            }
        )
        let immediateAvailability = matchAvailabilityByDate(
            immediateMatchesByDate,
            snapshot: snapshot,
            selectedCompetitionIDs: selectedCompetitionIDs
        )
        applyAvailableDays(
            snapshot: snapshot,
            selectedCompetitionIDs: selectedCompetitionIDs,
            requiresMatchLevelFiltering: !isTVListingsModeEnabled && calendarRequiresMatchLevelFiltering(snapshot),
            knownAvailability: refinedAvailability.merging(immediateAvailability) { _, latest in latest },
            keepCurrentDate: true
        )
        availabilityRefinementTask = nil
    }

    private func loadSelectedDateIfNeeded(force: Bool) {
        guard let snapshot,
              let baseURL = URL(string: snapshot.apiBaseURL),
              let dateKey = selectedDateKey else {
            isLoadingSelectedDate = false
            return
        }
        let topMatchesOnly = snapshot.fixtureAllMajorMatchesEnabled
        let bucketKey = Self.bucketKey(dateKey: dateKey)
        if let bucket = cachePayload?.buckets[bucketKey] {
            if publish(bucket: bucket, dateKey: dateKey, topMatchesOnly: topMatchesOnly) {
                loadSelectedDateIfNeeded(force: false)
                return
            }
            if !force && Self.isFresh(bucket: bucket, dateKey: dateKey) {
                schedulePrefetch(from: dateKey)
                return
            }
        }

        if !force, selectedDateTaskDateKey == dateKey, selectedDateTask != nil {
            return
        }

        selectedDateTask?.cancel()
        let requestID = UUID()
        selectedDateRequestID = requestID
        selectedDateTaskDateKey = dateKey
        isLoadingSelectedDate = true
        selectedDateTask = Task { [weak self] in
            guard let self else { return }
            var removedUnavailableDate = false
            do {
                let targetDateKeys = Self.dateKeysToRefresh(
                    in: availableDays,
                    centeredOn: dateKey,
                    cachePayload: cachePayload,
                    forceDateKey: force ? dateKey : nil
                )
                guard let range = FixtureBrowsePrefetchPlanner.range(for: targetDateKeys) else { return }
                let response = try await APIClient(
                    baseURL: baseURL,
                    session: apiSession
                ).fetchFixtureBrowseMatches(
                    from: range.lowerBound,
                    through: range.upperBound,
                    preferences: snapshot,
                    hydrateStates: false
                )
                try await waitUntilDateSwipeWorkMayPublish()
                guard !Task.isCancelled, selectedDateRequestID == requestID else { return }
                let buckets = storeRangeResponse(
                    response,
                    for: targetDateKeys
                )
                if selectedDateKey == dateKey,
                   let bucket = buckets[dateKey] {
                    if publishCurrentSelection(bucket: bucket, dateKey: dateKey) {
                        removedUnavailableDate = true
                    }
                }
                recomputeAvailableDays(keepCurrentDate: true)
                if selectedDateKey != dateKey {
                    removedUnavailableDate = true
                }
                errorMessage = nil
                persistCache()
                if !removedUnavailableDate {
                    schedulePrefetch(from: dateKey)
                }
            } catch {
                if !Task.isCancelled, selectedDateRequestID == requestID {
                    errorMessage = "Unable to load matches for this date."
                }
            }
            if selectedDateRequestID == requestID {
                isLoadingSelectedDate = false
                selectedDateTask = nil
                selectedDateTaskDateKey = nil
                if removedUnavailableDate {
                    loadSelectedDateIfNeeded(force: false)
                }
            }
        }
    }

    private func applyCachedBucketIfAvailable() {
        guard let snapshot, let selectedDateKey else { return }
        let topMatchesOnly = snapshot.fixtureAllMajorMatchesEnabled
        let key = Self.bucketKey(dateKey: selectedDateKey)
        guard let bucket = cachePayload?.buckets[key] else { return }
        _ = publish(bucket: bucket, dateKey: selectedDateKey, topMatchesOnly: topMatchesOnly)
    }

    @discardableResult
    private func publishCurrentSelection(
        bucket: FixtureBrowseBucket,
        dateKey: String
    ) -> Bool {
        guard let snapshot else { return false }
        return publish(
            bucket: bucket,
            dateKey: dateKey,
            topMatchesOnly: snapshot.fixtureAllMajorMatchesEnabled
        )
    }

    @discardableResult
    private func publish(
        bucket: FixtureBrowseBucket,
        dateKey: String,
        topMatchesOnly: Bool
    ) -> Bool {
        guard let snapshot else { return false }
        let filtered = filteredMatches(in: bucket, snapshot: snapshot, topMatchesOnly: topMatchesOnly)
        if selectedDateKey == dateKey {
            let unfiltered = unfilteredMatches(in: bucket, snapshot: snapshot)
            if selectedDateUnfilteredMatches != unfiltered {
                selectedDateUnfilteredMatches = unfiltered
            }
        }
        if visibleMatches != filtered {
            visibleMatches = filtered
        }
        if pageCache.matchesByDate[dateKey] != filtered {
            pageCache.set(filtered, for: dateKey)
        }
        let updatedAt = bucket.lastUpdated ?? bucket.fetchedAt
        if lastUpdated != updatedAt {
            lastUpdated = updatedAt
        }
        if isLoadingSelectedDate {
            isLoadingSelectedDate = false
        }
        if isAutoRefreshEnabled, autoRefreshTask == nil {
            startAutoRefreshLoop(refreshImmediately: false)
        }
        guard !isTVListingsModeEnabled,
              filtered.isEmpty,
              selectedDateKey == dateKey else {
            return false
        }
        removeUnavailableDate(dateKey)
        return true
    }

    private func startAutoRefreshLoop(refreshImmediately: Bool) {
        autoRefreshTask?.cancel()
        let taskID = UUID()
        autoRefreshTaskID = taskID
        autoRefreshTask = Task { [weak self] in
            var shouldRefresh = refreshImmediately
            defer {
                if let self, self.autoRefreshTaskID == taskID {
                    self.autoRefreshTask = nil
                }
            }

            while !Task.isCancelled {
                guard let self, self.isAutoRefreshEnabled else { return }
                if self.selectedDateTask != nil || self.visibleMatches.isEmpty {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }

                guard let intervalSeconds = FixtureBrowseAutoRefreshPolicy.intervalSeconds(
                    selectedDateKey: self.selectedDateKey,
                    todayKey: Self.dateFormatter.string(from: Date()),
                    matches: self.visibleMatches
                ) else {
                    return
                }

                if shouldRefresh {
                    await self.refreshSelectedDateStates()
                    shouldRefresh = false
                    continue
                }

                do {
                    try await Task.sleep(for: .seconds(intervalSeconds))
                } catch {
                    return
                }
                shouldRefresh = true
            }
        }
    }

    private func refreshSelectedDateStates() async {
        guard isAutoRefreshEnabled,
              let snapshot,
              let baseURL = URL(string: snapshot.apiBaseURL),
              let dateKey = selectedDateKey else {
            return
        }
        let bucketKey = Self.bucketKey(dateKey: dateKey)
        guard let bucket = cachePayload?.buckets[bucketKey] else { return }

        if FixtureBrowseAutoRefreshPolicy.shouldRefreshFixtureMembership(
            bucketFetchedAt: bucket.fetchedAt
        ) {
            do {
                let response = try await APIClient(
                    baseURL: baseURL,
                    session: apiSession
                ).fetchFixtureBrowseMatches(
                    on: dateKey,
                    preferences: snapshot,
                    hydrateStates: false
                )
                try await waitUntilDateSwipeWorkMayPublish()
                guard !Task.isCancelled,
                      isAutoRefreshEnabled,
                      selectedDateKey == dateKey else {
                    return
                }

                let refreshedBuckets = storeRangeResponse(response, for: [dateKey])
                if let refreshedBucket = refreshedBuckets[dateKey] {
                    _ = publishCurrentSelection(bucket: refreshedBucket, dateKey: dateKey)
                }
                persistCache()
                return
            } catch is CancellationError {
                return
            } catch {
                diagnosticLog(
                    "[FixtureBrowserStore] fixture membership refresh failed: %@",
                    String(describing: error)
                )
            }
        }

        let refreshMatches = FixtureBrowseAutoRefreshPolicy.stateRefreshMatches(
            in: selectedDateUnfilteredMatches
        )
        let matchIDs = refreshMatches.compactMap(\.matchDetailsID)
        guard !matchIDs.isEmpty else { return }

        do {
            let statesByID = try await APIClient(
                baseURL: baseURL,
                session: apiSession
            ).fetchMatchStates(
                matchIDs: matchIDs,
                summaryOnly: true
            )
            try await waitUntilDateSwipeWorkMayPublish()
            guard !Task.isCancelled,
                  isAutoRefreshEnabled,
                  selectedDateKey == dateKey,
                  !statesByID.isEmpty else {
                return
            }

            let refreshedMatches = bucket.matches.map { match in
                guard let matchDetailsID = match.matchDetailsID,
                      let state = statesByID[matchDetailsID] else {
                    return match
                }
                return match.withLiveState(state)
            }
            let matchesChanged = refreshedMatches != bucket.matches
            let refreshedBucket = FixtureBrowseBucket(
                matches: refreshedMatches,
                fetchedAt: bucket.fetchedAt,
                lastUpdated: Date()
            )
            store(bucket: refreshedBucket, for: bucketKey)
            _ = publishCurrentSelection(bucket: refreshedBucket, dateKey: dateKey)
            if matchesChanged {
                persistCache()
            }
        } catch is CancellationError {
            return
        } catch {
            diagnosticLog("[FixtureBrowserStore] live state refresh failed: %@", String(describing: error))
        }
    }

    private func removeUnavailableDate(_ dateKey: String) {
        guard let removedIndex = availableDays.firstIndex(where: { $0.date == dateKey }) else {
            return
        }
        let removedSelectedDate = selectedDateKey == dateKey
        availableDays.remove(at: removedIndex)
        pageCache.remove(dateKey)
        guard removedSelectedDate else { return }
        guard !availableDays.isEmpty else {
            selectedDateKey = nil
            visibleMatches = []
            selectedDateUnfilteredMatches = []
            return
        }
        let replacementIndex = min(removedIndex, availableDays.count - 1)
        selectedDateKey = availableDays[replacementIndex].date
        visibleMatches = []
        refreshSelectedDateUnfilteredMatches()
    }

    private func schedulePrefetch(from dateKey: String) {
        guard let snapshot, let baseURL = URL(string: snapshot.apiBaseURL) else { return }
        prefetchTask?.cancel()
        let requestID = UUID()
        prefetchRequestID = requestID
        let targets = Self.dateKeysToRefresh(
            in: availableDays,
            centeredOn: dateKey,
            cachePayload: cachePayload
        )
        guard let range = FixtureBrowsePrefetchPlanner.range(for: targets) else {
            prefetchTask = nil
            return
        }

        prefetchTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, prefetchRequestID == requestID else { return }
            if let response = try? await APIClient(
                    baseURL: baseURL,
                    session: apiSession
                ).fetchFixtureBrowseMatches(
                    from: range.lowerBound,
                    through: range.upperBound,
                    preferences: snapshot,
                    hydrateStates: false
            ) {
                try? await waitUntilDateSwipeWorkMayPublish()
                guard !Task.isCancelled,
                      prefetchRequestID == requestID else {
                    return
                }
                _ = storeRangeResponse(
                    response,
                    for: targets
                )
                let previousDateKey = selectedDateKey
                recomputeAvailableDays(keepCurrentDate: true)
                if selectedDateKey != previousDateKey {
                    loadSelectedDateIfNeeded(force: false)
                }
            }
            if prefetchRequestID == requestID {
                persistCache()
                prefetchTask = nil
            }
        }
    }

    private func scheduleAllUpcomingFixturesWarm() {
        guard allFixturesWarmTask == nil,
              cachePayload != nil else {
            return
        }

        let requestID = UUID()
        allFixturesWarmRequestID = requestID
        allFixturesWarmTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled,
                  allFixturesWarmRequestID == requestID,
                  let snapshot,
                  let baseURL = URL(string: snapshot.apiBaseURL),
                  let payload = cachePayload else {
                return
            }

            let todayKey = Self.dateFormatter.string(from: Date())
            let missingDays = payload.calendarDays.filter { day in
                day.date >= todayKey &&
                    day.matchCount > 0 &&
                    payload.buckets[Self.bucketKey(dateKey: day.date)] == nil
            }
            let batches = FixtureBrowseWarmPlanner.batches(
                in: missingDays,
                startingAt: todayKey
            )

            for batch in batches {
                guard !Task.isCancelled,
                      allFixturesWarmRequestID == requestID,
                      let first = batch.first,
                      let last = batch.last else {
                    return
                }
                do {
                    let response = try await APIClient(
                        baseURL: baseURL,
                        session: apiSession
                    ).fetchFixtureBrowseMatches(
                        from: first.date,
                        through: last.date,
                        preferences: snapshot,
                        hydrateStates: false
                    )
                    try await waitUntilDateSwipeWorkMayPublish()
                    guard !Task.isCancelled,
                          allFixturesWarmRequestID == requestID else {
                        return
                    }
                    _ = storeRangeResponse(
                        response,
                        for: batch.map(\.date),
                        updatePageCache: false
                    )
                    let previousDateKey = selectedDateKey
                    recomputeAvailableDays(keepCurrentDate: true)
                    if selectedDateKey != previousDateKey {
                        loadSelectedDateIfNeeded(force: false)
                    }
                    persistCache()
                    await Task.yield()
                } catch {
                    diagnosticLog(
                        "[FixtureBrowserStore] all-competition cache warm failed: %@",
                        String(describing: error)
                    )
                    break
                }
            }

            if allFixturesWarmRequestID == requestID {
                allFixturesWarmTask = nil
                recomputeAvailableDays(keepCurrentDate: true)
            }
        }
    }

    private func store(bucket: FixtureBrowseBucket, for key: String) {
        store(buckets: [key: bucket])
    }

    private func store(buckets: [String: FixtureBrowseBucket]) {
        guard !buckets.isEmpty, var payload = cachePayload else { return }
        for (key, bucket) in buckets {
            payload.buckets[key] = bucket
        }
        if payload.buckets.count > Self.maximumCachedBuckets {
            let overflow = payload.buckets.count - Self.maximumCachedBuckets
            let oldestKeys = payload.buckets
                .sorted { $0.value.fetchedAt < $1.value.fetchedAt }
                .prefix(overflow)
                .map(\.key)
            oldestKeys.forEach { payload.buckets.removeValue(forKey: $0) }
        }
        cachePayload = payload
    }

    private func schedulePageCacheRebuild() {
        pageCacheRebuildTask?.cancel()
        guard let snapshot, let payload = cachePayload, let selectedDateKey else {
            pageCacheRebuildTask = nil
            return
        }

        let dateKeys = Set(FixtureBrowsePrefetchPlanner.dateKeys(
            in: availableDays,
            centeredOn: selectedDateKey,
            radius: Self.pageCacheRadius
        ))
        let matchesByDate: [String: [Match]] = Dictionary(
            uniqueKeysWithValues: dateKeys.compactMap { dateKey in
                guard let bucket = payload.buckets[Self.bucketKey(dateKey: dateKey)] else {
                    return nil
                }
                return (dateKey, bucket.matches)
            }
        )
        let requestID = UUID()
        pageCacheRebuildRequestID = requestID
        let topMatchesOnly = snapshot.fixtureAllMajorMatchesEnabled
        let selectedCompetitionIDs = selectedCompetitionIDs(for: snapshot)
        let competitionSnapshot = competitions
        let fixtureViewOptionIDs = Set(snapshot.effectiveFixtureViewOptionIDs)
        let showAllMatches = snapshot.fixtureViewShowsAll
        let includePostponed = snapshot.showPostponedGames
        let includeFACupEarlyRounds = snapshot.showFACupEarlyRounds
        let topTeamsMatcherSnapshot = topTeamsMatcher
        let premierLeagueTeamMatcherSnapshot = premierLeagueTeamMatcher

        pageCacheRebuildTask = Task.detached(priority: .utility) { [weak self] in
            let rebuilt = FixtureBrowseSelectionResolver.filterMatchesByDate(
                matchesByDate,
                topMatchesOnly: topMatchesOnly,
                selectedCompetitionIDs: selectedCompetitionIDs,
                competitions: competitionSnapshot,
                fixtureViewOptionIDs: fixtureViewOptionIDs,
                showAllMatches: showAllMatches,
                includePostponed: includePostponed,
                includeFACupEarlyRounds: includeFACupEarlyRounds,
                topTeamsMatcher: topTeamsMatcherSnapshot,
                premierLeagueTeamMatcher: premierLeagueTeamMatcherSnapshot
            ).filter { !$0.value.isEmpty }
            guard !Task.isCancelled else { return }
            await self?.applyPageCacheRebuild(
                rebuilt,
                requestID: requestID,
                selectedDateKey: selectedDateKey,
                snapshot: snapshot
            )
        }
    }

    private func applyPageCacheRebuild(
        _ rebuilt: [String: [Match]],
        requestID: UUID,
        selectedDateKey: String,
        snapshot: PreferencesSnapshot
    ) async {
        do {
            try await waitUntilDateSwipeWorkMayPublish()
        } catch {
            return
        }
        guard pageCacheRebuildRequestID == requestID,
              self.selectedDateKey == selectedDateKey,
              self.snapshot == snapshot else {
            return
        }
        var merged = pageCache.matchesByDate
        var hasChanges = false
        for (dateKey, matches) in rebuilt where merged[dateKey] != matches {
            merged[dateKey] = matches
            hasChanges = true
        }

        if merged.count > Self.maximumPreparedPageCount {
            let retainedDateKeys = Set(FixtureBrowsePrefetchPlanner.dateKeys(
                in: availableDays,
                centeredOn: selectedDateKey,
                radius: Self.maximumPreparedPageCount / 2
            ))
            let pruned = merged.filter { retainedDateKeys.contains($0.key) }
            if pruned.count != merged.count {
                merged = pruned
                hasChanges = true
            }
        }

        if hasChanges {
            pageCache.replace(with: merged)
        }
        pageCacheRebuildTask = nil
    }

    private func storeRangeResponse(
        _ response: MatchResponse,
        for dateKeys: [String],
        updatePageCache: Bool = true
    ) -> [String: FixtureBrowseBucket] {
        let matchesByDate = Dictionary(grouping: response.matches, by: \.date)
        let fetchedAt = Date()
        var bucketsByDate: [String: FixtureBrowseBucket] = [:]
        var cacheBuckets: [String: FixtureBrowseBucket] = [:]
        var cachedMatches = pageCache.matchesByDate

        for dateKey in dateKeys {
            let bucket = FixtureBrowseBucket(
                matches: matchesByDate[dateKey] ?? [],
                fetchedAt: fetchedAt,
                lastUpdated: response.lastUpdated
            )
            cacheBuckets[Self.bucketKey(dateKey: dateKey)] = bucket
            bucketsByDate[dateKey] = bucket

            guard updatePageCache, let snapshot else { continue }
            let filtered = filteredMatches(
                in: bucket,
                snapshot: snapshot,
                topMatchesOnly: snapshot.fixtureAllMajorMatchesEnabled
            )
            if filtered.isEmpty {
                cachedMatches.removeValue(forKey: dateKey)
            } else {
                cachedMatches[dateKey] = filtered
            }
        }

        // Mutate and publish the value-type cache once for the whole response.
        // Copying its full dictionary for every date made a multi-day response
        // disproportionately expensive on the main actor.
        store(buckets: cacheBuckets)

        if updatePageCache {
            pageCache.replace(with: cachedMatches)
        }
        return bucketsByDate
    }

    private static func dateKeysToRefresh(
        in days: [FixtureCalendarDay],
        centeredOn dateKey: String,
        cachePayload: FixtureBrowseCachePayload?,
        forceDateKey: String? = nil,
        now: Date = Date()
    ) -> [String] {
        FixtureBrowsePrefetchPlanner.dateKeys(
            in: days,
            centeredOn: dateKey,
            radius: prefetchRadius
        ).filter { candidateDateKey in
            if candidateDateKey == forceDateKey { return true }
            let key = bucketKey(dateKey: candidateDateKey)
            guard let bucket = cachePayload?.buckets[key] else { return true }
            return !isFresh(bucket: bucket, dateKey: candidateDateKey, now: now)
        }
    }

    private func selectedCompetitionIDs(
        for snapshot: PreferencesSnapshot
    ) -> Set<String> {
        let legacyIDs = FixtureBrowseSelectionResolver.selectedCompetitionIDs(
            selectedLeagues: snapshot.selectedLeagues,
            competitions: competitions
        )
        let optionIDs = snapshot.effectiveFixtureViewOptionIDs.compactMap(
            FixtureViewOptionID.competitionStableID
        )
        return legacyIDs.union(optionIDs)
    }

    private func calendarRequiresMatchLevelFiltering(
        _ snapshot: PreferencesSnapshot
    ) -> Bool {
        let optionIDs = Set(snapshot.effectiveFixtureViewOptionIDs)
        if optionIDs == Set([FixtureViewOptionID.topTeamsPreset]) {
            return true
        }
        if optionIDs == FixtureViewOptionID.premierLeagueMatchesPresetOptionIDs {
            return true
        }
        return optionIDs.contains { optionID in
            FixtureViewOptionID.teamStableID(from: optionID) != nil ||
                optionID.hasPrefix("rivalry:")
        }
    }

    private func calendarUsesTopMatches(_ snapshot: PreferencesSnapshot) -> Bool {
        snapshot.fixtureAllMajorMatchesEnabled &&
            snapshot.effectiveFixtureViewOptionIDs.isEmpty
    }

    private func calendarShowsAllMatches(_ snapshot: PreferencesSnapshot) -> Bool {
        isTVListingsModeEnabled || snapshot.fixtureViewShowsAll
    }

    private func filteredMatches(
        in bucket: FixtureBrowseBucket,
        snapshot: PreferencesSnapshot,
        topMatchesOnly: Bool
    ) -> [Match] {
        let selectedIDs = selectedCompetitionIDs(for: snapshot)
        return FixtureBrowseSelectionResolver.filterMatches(
            bucket.matches,
            topMatchesOnly: topMatchesOnly,
            selectedCompetitionIDs: selectedIDs,
            competitions: competitions,
            fixtureViewOptionIDs: Set(snapshot.effectiveFixtureViewOptionIDs),
            showAllMatches: snapshot.fixtureViewShowsAll,
            includePostponed: snapshot.showPostponedGames,
            includeFACupEarlyRounds: snapshot.showFACupEarlyRounds,
            topTeamsMatcher: topTeamsMatcher,
            premierLeagueTeamMatcher: premierLeagueTeamMatcher
        )
    }

    private func unfilteredMatches(
        in bucket: FixtureBrowseBucket,
        snapshot: PreferencesSnapshot
    ) -> [Match] {
        FixtureBrowseSelectionResolver.filterMatches(
            bucket.matches,
            topMatchesOnly: false,
            selectedCompetitionIDs: [],
            competitions: competitions,
            showAllMatches: true,
            includePostponed: snapshot.showPostponedGames,
            includeFACupEarlyRounds: snapshot.showFACupEarlyRounds
        )
    }

    private func refreshSelectedDateUnfilteredMatches() {
        guard let snapshot,
              let selectedDateKey,
              let bucket = cachePayload?.buckets[Self.bucketKey(dateKey: selectedDateKey)] else {
            if !selectedDateUnfilteredMatches.isEmpty {
                selectedDateUnfilteredMatches = []
            }
            return
        }
        let matches = unfilteredMatches(in: bucket, snapshot: snapshot)
        if selectedDateUnfilteredMatches != matches {
            selectedDateUnfilteredMatches = matches
        }
    }

    private func applyTopTeamsPreset(_ preset: TopTeamsPresetDefinition) {
        topTeamsMatcher = TopTeamsPresetMatcher(definition: preset)
        guard let snapshot,
              Set(snapshot.effectiveFixtureViewOptionIDs) == Set([FixtureViewOptionID.topTeamsPreset]) else {
            return
        }
        pageCache.replace(with: [:])
        recomputeAvailableDays(keepCurrentDate: true)
    }

    private func applyPremierLeagueTeamMatcher(_ matcher: PremierLeagueTeamMatcher) {
        guard premierLeagueTeamMatcher != matcher else { return }
        premierLeagueTeamMatcher = matcher
        guard let snapshot,
              Set(snapshot.effectiveFixtureViewOptionIDs) ==
                FixtureViewOptionID.premierLeagueMatchesPresetOptionIDs else {
            return
        }
        pageCache.replace(with: [:])
        recomputeAvailableDays(keepCurrentDate: true)
    }

    private func persistCache() {
        guard let payload = cachePayload else { return }
        let cacheURL = Self.cacheURL
        let requestedAt = DispatchTime.now().uptimeNanoseconds
        Task.detached(priority: .utility) {
            await FixtureBrowseCacheWriter.shared.write(
                payload,
                to: cacheURL,
                requestedAt: requestedAt
            )
        }
    }

    private static func isFresh(bucket: FixtureBrowseBucket, dateKey: String, now: Date = Date()) -> Bool {
        let today = dateFormatter.string(from: now)
        let age = now.timeIntervalSince(bucket.fetchedAt)
        if dateKey == today { return age < 30 }
        if dateKey < today { return age < 24 * 60 * 60 }
        guard let date = dateFormatter.date(from: dateKey) else { return age < 10 * 60 }
        let daysAway = Calendar.current.dateComponents([.day], from: now, to: date).day ?? 0
        return age < (daysAway <= 7 ? 10 * 60 : 6 * 60 * 60)
    }

    private static func bucketKey(dateKey: String) -> String {
        dateKey
    }

    private static func contextKey(for snapshot: PreferencesSnapshot) -> String {
        [
            snapshot.apiBaseURL,
            TimeZone.current.identifier,
            snapshot.channelFilterEnabled ? "channels" : "all-channels",
            snapshot.channelFilterEnabled
                ? ChannelSelection.normalizedSelectedOptions(snapshot.selectedChannels).joined(separator: "|")
                : "",
        ].joined(separator: ";")
    }

    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("fixture-browser-cache.json")
    }

    private static func loadCache(matching contextKey: String) -> FixtureBrowseCachePayload? {
        guard let data = try? Data(contentsOf: cacheURL),
              let payload = try? JSONDecoder().decode(FixtureBrowseCachePayload.self, from: data),
              payload.formatVersion == cacheFormatVersion,
              payload.contextKey == contextKey else {
            return nil
        }
        return payload
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
