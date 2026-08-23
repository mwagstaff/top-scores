import Foundation
import Combine

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
        showAllMatches: Bool = false
    ) -> [FixtureCalendarDay] {
        calendarDays.filter { day in
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
        showAllMatches: Bool = false
    ) -> String? {
        upcomingDateKey(
            from: days,
            todayKey: todayKey,
            topMatchesOnly: topMatchesOnly,
            selectedCompetitionIDs: selectedCompetitionIDs,
            selectionApplied: selectionApplied,
            showAllMatches: showAllMatches
        ) ?? days.last?.date
    }

    static func upcomingDateKey(
        from days: [FixtureCalendarDay],
        todayKey: String,
        topMatchesOnly: Bool,
        selectedCompetitionIDs: Set<String>,
        selectionApplied: Bool = false,
        showAllMatches: Bool = false
    ) -> String? {
        days.first { day in
            guard day.date >= todayKey else { return false }
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
        includePostponed: Bool
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
        } else if !fixtureViewOptionIDs.isEmpty {
            let lookup = competitionLookup(competitions)
            competitionFiltered = displayableMatches.filter { match in
                matchesFixtureViewOption(
                    match,
                    optionIDs: fixtureViewOptionIDs,
                    competitionLookup: lookup
                )
            }
        } else if topMatchesOnly {
            competitionFiltered = displayableMatches
        } else {
            let lookup = competitionLookup(competitions)
            competitionFiltered = displayableMatches.filter { match in
                guard let competitionID = lookup[normalizedKey(match.league)] else { return false }
                return selectedCompetitionIDs.contains(competitionID)
            }
        }
        guard !includePostponed else { return competitionFiltered }
        return competitionFiltered.filter { !$0.isPostponed }
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
        competitionLookup: [String: String]
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
            matchesUEFATeamRule(match, optionID: $0)
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

    private static func matchesUEFATeamRule(_ match: Match, optionID: String) -> Bool {
        if optionID == FixtureViewOptionID.topUEFAClubs {
            return fallbackTopUEFAClubs.contains(normalizedKey(match.homeTeam)) ||
                fallbackTopUEFAClubs.contains(normalizedKey(match.awayTeam))
        }
        if optionID == FixtureViewOptionID.premierLeagueTeams {
            return MatchesStore.matchIncludesPremierLeagueTeam(match)
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
        guard selectedDateKey == todayKey,
              matches.contains(where: { !$0.isFinished && !$0.isPostponed }) else {
            return nil
        }
        return pendingTodayIntervalSeconds
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
    @Published private(set) var selectedDateKey: String?
    @Published private(set) var isLoadingSelectedDate = false
    @Published private(set) var hasLoadedCalendar = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?

    let pageCache = FixtureBrowsePageCache()

    var cachedMatchesByDate: [String: [Match]] {
        pageCache.matchesByDate
    }

    private static let cacheFormatVersion = 1
    private static let maximumCachedBuckets = 24
    private static let prefetchRadius = 3
    private static let catalogFreshnessInterval: TimeInterval = 24 * 60 * 60
    private var snapshot: PreferencesSnapshot?
    private var contextKey: String?
    private var cachePayload: FixtureBrowseCachePayload?
    private var catalogFetchedAt: Date?
    private var refreshTask: Task<Void, Never>?
    private var selectedDateTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private var autoRefreshTaskID = UUID()
    private var isAutoRefreshEnabled = false
    private var refreshRequestID = UUID()
    private var selectedDateRequestID = UUID()
    private var prefetchRequestID = UUID()

    func configure(
        preferences: PreferencesSnapshot,
        forceRefresh: Bool = false,
        resetSelectedDate: Bool = false
    ) {
        let nextContextKey = Self.contextKey(for: preferences)
        let contextChanged = contextKey != nextContextKey
        snapshot = preferences

        if contextChanged {
            refreshTask?.cancel()
            selectedDateTask?.cancel()
            prefetchTask?.cancel()
            isLoadingSelectedDate = false
            refreshRequestID = UUID()
            selectedDateRequestID = UUID()
            prefetchRequestID = UUID()
            contextKey = nextContextKey
            cachePayload = Self.loadCache(matching: nextContextKey)
            if let cachedCompetitions = cachePayload?.competitions,
               !cachedCompetitions.isEmpty {
                competitions = cachedCompetitions
                catalogFetchedAt = cachePayload?.catalogFetchedAt
            }
            pageCache.replace(with: [:])
            hasLoadedCalendar = !(cachePayload?.calendarDays.isEmpty ?? true)
            CompetitionBadgeCache.shared.warmIfNeeded(entries: competitions)
        }

        recomputeAvailableDays(keepCurrentDate: !contextChanged && !resetSelectedDate)
        loadSelectedDateIfNeeded(force: false)

        let cacheAge = cachePayload?.calendarFetchedAt.map { Date().timeIntervalSince($0) }
        if forceRefresh || contextChanged || cacheAge == nil || (cacheAge ?? .infinity) > 15 * 60 {
            refreshCatalogAndCalendar(force: forceRefresh)
        }
    }

    func selectDate(_ dateKey: String) {
        guard availableDays.contains(where: { $0.date == dateKey }), selectedDateKey != dateKey else {
            return
        }
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchRequestID = UUID()
        selectedDateKey = dateKey
        let cachedMatches = pageCache.matchesByDate[dateKey] ?? []
        if visibleMatches != cachedMatches {
            visibleMatches = cachedMatches
        }
        loadSelectedDateIfNeeded(force: false)
        if isAutoRefreshEnabled {
            startAutoRefreshLoop(refreshImmediately: true)
        }
    }

    func adjacentDateKey(offset: Int) -> String? {
        FixtureBrowseSelectionResolver.adjacentDateKey(
            in: availableDays,
            from: selectedDateKey,
            offset: offset
        )
    }

    var nextMatchDateKey: String? {
        guard let snapshot else { return nil }
        let selectedIDs = FixtureBrowseSelectionResolver.selectedCompetitionIDs(
            selectedLeagues: snapshot.selectedLeagues,
            competitions: competitions
        )
        return FixtureBrowseSelectionResolver.upcomingDateKey(
            from: availableDays,
            todayKey: Self.dateFormatter.string(from: Date()),
            topMatchesOnly: snapshot.fixtureAllMajorMatchesEnabled,
            selectedCompetitionIDs: selectedIDs,
            selectionApplied: cachePayload?.calendarSelectionApplied == true,
            showAllMatches: snapshot.fixtureViewShowsAll
        )
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
                async let calendarTask = APIClient(baseURL: baseURL).fetchFixtureCalendar(preferences: snapshot)
                let shouldRefreshCatalog = competitions.isEmpty ||
                    Date().timeIntervalSince(catalogFetchedAt ?? .distantPast) >= Self.catalogFreshnessInterval
                let resolvedCompetitions: [CompetitionCatalogEntry]
                if shouldRefreshCatalog {
                    resolvedCompetitions = try await APIClient(baseURL: baseURL)
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
        guard let snapshot else { return }
        let selectedIDs = FixtureBrowseSelectionResolver.selectedCompetitionIDs(
            selectedLeagues: snapshot.selectedLeagues,
            competitions: competitions
        )
        let days = FixtureBrowseSelectionResolver.availableDays(
            calendarDays: cachePayload?.calendarDays ?? [],
            topMatchesOnly: snapshot.fixtureAllMajorMatchesEnabled,
            selectedCompetitionIDs: selectedIDs,
            selectionApplied: cachePayload?.calendarSelectionApplied == true,
            showAllMatches: snapshot.fixtureViewShowsAll
        )
        if availableDays != days {
            availableDays = days
        }
        rebuildCachedMatchesByDate()

        if keepCurrentDate,
           let selectedDateKey,
           days.contains(where: { $0.date == selectedDateKey }) {
            applyCachedBucketIfAvailable()
            return
        }

        selectedDateKey = FixtureBrowseSelectionResolver.defaultDateKey(
            from: days,
            todayKey: Self.dateFormatter.string(from: Date()),
            topMatchesOnly: snapshot.fixtureAllMajorMatchesEnabled,
            selectedCompetitionIDs: selectedIDs,
            selectionApplied: cachePayload?.calendarSelectionApplied == true,
            showAllMatches: snapshot.fixtureViewShowsAll
        )
        visibleMatches = []
        applyCachedBucketIfAvailable()
    }

    private func loadSelectedDateIfNeeded(force: Bool) {
        guard let snapshot,
              let baseURL = URL(string: snapshot.apiBaseURL),
              let dateKey = selectedDateKey else {
            isLoadingSelectedDate = false
            return
        }
        let topMatchesOnly = snapshot.fixtureAllMajorMatchesEnabled
        let bucketKey = Self.bucketKey(dateKey: dateKey, topMatchesOnly: topMatchesOnly)
        if let bucket = cachePayload?.buckets[bucketKey] {
            if publish(bucket: bucket, dateKey: dateKey, topMatchesOnly: topMatchesOnly) {
                loadSelectedDateIfNeeded(force: false)
                return
            }
            if !force && Self.isFresh(bucket: bucket, dateKey: dateKey) {
                schedulePrefetch(from: dateKey, topMatchesOnly: topMatchesOnly)
                return
            }
        }

        selectedDateTask?.cancel()
        let requestID = UUID()
        selectedDateRequestID = requestID
        isLoadingSelectedDate = true
        selectedDateTask = Task { [weak self] in
            guard let self else { return }
            do {
                let targetDateKeys = Self.dateKeysToRefresh(
                    in: availableDays,
                    centeredOn: dateKey,
                    topMatchesOnly: topMatchesOnly,
                    cachePayload: cachePayload,
                    forceDateKey: force ? dateKey : nil
                )
                guard let range = FixtureBrowsePrefetchPlanner.range(for: targetDateKeys) else { return }
                let response = try await APIClient(baseURL: baseURL).fetchFixtureBrowseMatches(
                    from: range.lowerBound,
                    through: range.upperBound,
                    preferences: snapshot,
                    topMatchesOnly: topMatchesOnly,
                    hydrateStates: false
                )
                guard !Task.isCancelled, selectedDateRequestID == requestID else { return }
                let buckets = storeRangeResponse(
                    response,
                    for: targetDateKeys,
                    topMatchesOnly: topMatchesOnly
                )
                var removedUnavailableDate = false
                if selectedDateKey == dateKey,
                   self.snapshot?.fixtureAllMajorMatchesEnabled == topMatchesOnly,
                   let bucket = buckets[dateKey] {
                    if publish(bucket: bucket, dateKey: dateKey, topMatchesOnly: topMatchesOnly) {
                        removedUnavailableDate = true
                        loadSelectedDateIfNeeded(force: false)
                    }
                }
                errorMessage = nil
                persistCache()
                if !removedUnavailableDate {
                    schedulePrefetch(from: dateKey, topMatchesOnly: topMatchesOnly)
                }
            } catch {
                if !Task.isCancelled, selectedDateRequestID == requestID {
                    errorMessage = "Unable to load matches for this date."
                }
            }
            if selectedDateRequestID == requestID {
                isLoadingSelectedDate = false
                selectedDateTask = nil
            }
        }
    }

    private func applyCachedBucketIfAvailable() {
        guard let snapshot, let selectedDateKey else { return }
        let topMatchesOnly = snapshot.fixtureAllMajorMatchesEnabled
        let key = Self.bucketKey(dateKey: selectedDateKey, topMatchesOnly: topMatchesOnly)
        guard let bucket = cachePayload?.buckets[key] else { return }
        _ = publish(bucket: bucket, dateKey: selectedDateKey, topMatchesOnly: topMatchesOnly)
    }

    @discardableResult
    private func publish(
        bucket: FixtureBrowseBucket,
        dateKey: String,
        topMatchesOnly: Bool
    ) -> Bool {
        guard let snapshot else { return false }
        let filtered = filteredMatches(in: bucket, snapshot: snapshot, topMatchesOnly: topMatchesOnly)
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
        guard filtered.isEmpty, selectedDateKey == dateKey else { return false }
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
        let topMatchesOnly = snapshot.fixtureAllMajorMatchesEnabled
        let bucketKey = Self.bucketKey(dateKey: dateKey, topMatchesOnly: topMatchesOnly)
        guard let bucket = cachePayload?.buckets[bucketKey] else { return }

        let refreshMatches = FixtureBrowseAutoRefreshPolicy.stateRefreshMatches(
            in: visibleMatches
        )
        let matchIDs = refreshMatches.compactMap(\.matchDetailsID)
        guard !matchIDs.isEmpty else { return }

        do {
            let statesByID = try await APIClient(baseURL: baseURL).fetchMatchStates(
                matchIDs: matchIDs,
                summaryOnly: true
            )
            guard !Task.isCancelled,
                  isAutoRefreshEnabled,
                  selectedDateKey == dateKey,
                  self.snapshot?.fixtureAllMajorMatchesEnabled == topMatchesOnly,
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
                fetchedAt: Date(),
                lastUpdated: Date()
            )
            store(bucket: refreshedBucket, for: bucketKey)
            _ = publish(
                bucket: refreshedBucket,
                dateKey: dateKey,
                topMatchesOnly: topMatchesOnly
            )
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
            return
        }
        let replacementIndex = min(removedIndex, availableDays.count - 1)
        selectedDateKey = availableDays[replacementIndex].date
        visibleMatches = []
    }

    private func schedulePrefetch(from dateKey: String, topMatchesOnly: Bool) {
        guard let snapshot, let baseURL = URL(string: snapshot.apiBaseURL) else { return }
        prefetchTask?.cancel()
        let requestID = UUID()
        prefetchRequestID = requestID
        let targets = Self.dateKeysToRefresh(
            in: availableDays,
            centeredOn: dateKey,
            topMatchesOnly: topMatchesOnly,
            cachePayload: cachePayload
        )
        guard let range = FixtureBrowsePrefetchPlanner.range(for: targets) else {
            prefetchTask = nil
            return
        }

        prefetchTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, prefetchRequestID == requestID else { return }
            if let response = try? await APIClient(baseURL: baseURL).fetchFixtureBrowseMatches(
                    from: range.lowerBound,
                    through: range.upperBound,
                    preferences: snapshot,
                    topMatchesOnly: topMatchesOnly,
                    hydrateStates: false
            ) {
                guard !Task.isCancelled,
                      prefetchRequestID == requestID,
                      self.snapshot == snapshot else {
                    return
                }
                _ = storeRangeResponse(
                    response,
                    for: targets,
                    topMatchesOnly: topMatchesOnly
                )
            }
            if prefetchRequestID == requestID {
                persistCache()
                prefetchTask = nil
            }
        }
    }

    private func store(bucket: FixtureBrowseBucket, for key: String) {
        guard var payload = cachePayload else { return }
        payload.buckets[key] = bucket
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

    private func rebuildCachedMatchesByDate() {
        guard let snapshot, let payload = cachePayload else {
            if !pageCache.matchesByDate.isEmpty {
                pageCache.replace(with: [:])
            }
            return
        }
        let topMatchesOnly = snapshot.fixtureAllMajorMatchesEnabled
        let availableDateKeys = Set(availableDays.map(\.date))
        var rebuilt: [String: [Match]] = [:]
        for dateKey in availableDateKeys {
            let key = Self.bucketKey(dateKey: dateKey, topMatchesOnly: topMatchesOnly)
            guard let bucket = payload.buckets[key] else { continue }
            let filtered = filteredMatches(
                in: bucket,
                snapshot: snapshot,
                topMatchesOnly: topMatchesOnly
            )
            if !filtered.isEmpty {
                rebuilt[dateKey] = filtered
            }
        }
        if pageCache.matchesByDate != rebuilt {
            pageCache.replace(with: rebuilt)
        }
    }

    private func storeRangeResponse(
        _ response: MatchResponse,
        for dateKeys: [String],
        topMatchesOnly: Bool
    ) -> [String: FixtureBrowseBucket] {
        let matchesByDate = Dictionary(grouping: response.matches, by: \.date)
        let fetchedAt = Date()
        var bucketsByDate: [String: FixtureBrowseBucket] = [:]
        var cachedMatches = pageCache.matchesByDate

        for dateKey in dateKeys {
            let bucket = FixtureBrowseBucket(
                matches: matchesByDate[dateKey] ?? [],
                fetchedAt: fetchedAt,
                lastUpdated: response.lastUpdated
            )
            store(
                bucket: bucket,
                for: Self.bucketKey(dateKey: dateKey, topMatchesOnly: topMatchesOnly)
            )
            bucketsByDate[dateKey] = bucket

            guard let snapshot,
                  topMatchesOnly == snapshot.fixtureAllMajorMatchesEnabled else {
                continue
            }
            let filtered = filteredMatches(
                in: bucket,
                snapshot: snapshot,
                topMatchesOnly: topMatchesOnly
            )
            if filtered.isEmpty {
                cachedMatches.removeValue(forKey: dateKey)
            } else {
                cachedMatches[dateKey] = filtered
            }
        }

        pageCache.replace(with: cachedMatches)
        return bucketsByDate
    }

    private static func dateKeysToRefresh(
        in days: [FixtureCalendarDay],
        centeredOn dateKey: String,
        topMatchesOnly: Bool,
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
            let key = bucketKey(
                dateKey: candidateDateKey,
                topMatchesOnly: topMatchesOnly
            )
            guard let bucket = cachePayload?.buckets[key] else { return true }
            return !isFresh(bucket: bucket, dateKey: candidateDateKey, now: now)
        }
    }

    private func filteredMatches(
        in bucket: FixtureBrowseBucket,
        snapshot: PreferencesSnapshot,
        topMatchesOnly: Bool
    ) -> [Match] {
        let selectedIDs = FixtureBrowseSelectionResolver.selectedCompetitionIDs(
            selectedLeagues: snapshot.selectedLeagues,
            competitions: competitions
        )
        return FixtureBrowseSelectionResolver.filterMatches(
            bucket.matches,
            topMatchesOnly: topMatchesOnly,
            selectedCompetitionIDs: selectedIDs,
            competitions: competitions,
            fixtureViewOptionIDs: Set(snapshot.effectiveFixtureViewOptionIDs),
            showAllMatches: snapshot.fixtureViewShowsAll,
            includePostponed: snapshot.showPostponedGames
        )
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

    private static func bucketKey(dateKey: String, topMatchesOnly: Bool) -> String {
        "\(dateKey)|\(topMatchesOnly ? "top" : "all")"
    }

    private static func contextKey(for snapshot: PreferencesSnapshot) -> String {
        [
            snapshot.apiBaseURL,
            TimeZone.current.identifier,
            snapshot.channelFilterEnabled ? "channels" : "all-channels",
            snapshot.channelFilterEnabled
                ? ChannelSelection.normalizedSelectedOptions(snapshot.selectedChannels).joined(separator: "|")
                : "",
            snapshot.showPostponedGames ? "include-postponed" : "hide-postponed",
            snapshot.fixtureAllMajorMatchesEnabled ? "favourites" : (snapshot.fixtureViewShowsAll ? "all" : "custom"),
            snapshot.effectiveFixtureViewOptionIDs.sorted().joined(separator: "|"),
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
