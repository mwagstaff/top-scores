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
    var calendarFetchedAt: Date?
    var buckets: [String: FixtureBrowseBucket]
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
        selectedCompetitionIDs: Set<String>
    ) -> [FixtureCalendarDay] {
        calendarDays.filter { day in
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
        selectedCompetitionIDs: Set<String>
    ) -> String? {
        upcomingDateKey(
            from: days,
            todayKey: todayKey,
            topMatchesOnly: topMatchesOnly,
            selectedCompetitionIDs: selectedCompetitionIDs
        ) ?? days.last?.date
    }

    static func upcomingDateKey(
        from days: [FixtureCalendarDay],
        todayKey: String,
        topMatchesOnly: Bool,
        selectedCompetitionIDs: Set<String>
    ) -> String? {
        days.first { day in
            guard day.date >= todayKey else { return false }
            if day.date > todayKey { return true }
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

    static func filterMatches(
        _ matches: [Match],
        topMatchesOnly: Bool,
        selectedCompetitionIDs: Set<String>,
        competitions: [CompetitionCatalogEntry],
        includePostponed: Bool
    ) -> [Match] {
        let competitionFiltered: [Match]
        if topMatchesOnly {
            competitionFiltered = matches
        } else {
            let lookup = competitionLookup(competitions)
            competitionFiltered = matches.filter { match in
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

    private static let cacheFormatVersion = 1
    private static let maximumCachedBuckets = 24
    private var snapshot: PreferencesSnapshot?
    private var contextKey: String?
    private var cachePayload: FixtureBrowseCachePayload?
    private var refreshTask: Task<Void, Never>?
    private var selectedDateTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
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
            refreshRequestID = UUID()
            selectedDateRequestID = UUID()
            prefetchRequestID = UUID()
            contextKey = nextContextKey
            cachePayload = Self.loadCache(matching: nextContextKey)
            competitions = cachePayload?.competitions ?? []
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
        selectedDateKey = dateKey
        visibleMatches = []
        loadSelectedDateIfNeeded(force: false)
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
            selectedCompetitionIDs: selectedIDs
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
        guard let targetDateKey = FixtureBrowseSelectionResolver.adjacentDateKey(
            in: availableDays,
            from: selectedDateKey,
            offset: offset
        ) else { return }
        selectDate(targetDateKey)
    }

    func refresh() {
        refreshCatalogAndCalendar(force: true)
        loadSelectedDateIfNeeded(force: true)
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
                async let catalogTask = APIClient(baseURL: baseURL).fetchCompetitionCatalog()
                async let calendarTask = APIClient(baseURL: baseURL).fetchFixtureCalendar(preferences: snapshot)
                let (catalog, calendar) = try await (catalogTask, calendarTask)
                guard !Task.isCancelled, refreshRequestID == requestID else { return }

                competitions = catalog.competitions
                hasLoadedCalendar = true
                errorMessage = nil
                let existingBuckets = cachePayload?.buckets ?? [:]
                cachePayload = FixtureBrowseCachePayload(
                    formatVersion: Self.cacheFormatVersion,
                    contextKey: Self.contextKey(for: snapshot),
                    competitions: catalog.competitions,
                    calendarDays: calendar.days,
                    calendarFetchedAt: Date(),
                    buckets: existingBuckets
                )
                CompetitionBadgeCache.shared.warmIfNeeded(entries: catalog.competitions)
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
            selectedCompetitionIDs: selectedIDs
        )
        availableDays = days

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
            selectedCompetitionIDs: selectedIDs
        )
        visibleMatches = []
        applyCachedBucketIfAvailable()
    }

    private func loadSelectedDateIfNeeded(force: Bool) {
        guard let snapshot,
              let baseURL = URL(string: snapshot.apiBaseURL),
              let dateKey = selectedDateKey else {
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
        isLoadingSelectedDate = visibleMatches.isEmpty
        selectedDateTask = Task { [weak self] in
            guard let self else { return }
            do {
                var removedUnavailableDate = false
                let response = try await APIClient(baseURL: baseURL).fetchFixtureBrowseMatches(
                    on: dateKey,
                    preferences: snapshot,
                    topMatchesOnly: topMatchesOnly
                )
                guard !Task.isCancelled, selectedDateRequestID == requestID else { return }
                let bucket = FixtureBrowseBucket(
                    matches: response.matches,
                    fetchedAt: Date(),
                    lastUpdated: response.lastUpdated
                )
                store(bucket: bucket, for: bucketKey)
                if selectedDateKey == dateKey,
                   self.snapshot?.fixtureAllMajorMatchesEnabled == topMatchesOnly {
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
        let selectedIDs = FixtureBrowseSelectionResolver.selectedCompetitionIDs(
            selectedLeagues: snapshot.selectedLeagues,
            competitions: competitions
        )
        visibleMatches = FixtureBrowseSelectionResolver.filterMatches(
            bucket.matches,
            topMatchesOnly: topMatchesOnly,
            selectedCompetitionIDs: selectedIDs,
            competitions: competitions,
            includePostponed: snapshot.showPostponedGames
        )
        lastUpdated = bucket.lastUpdated ?? bucket.fetchedAt
        isLoadingSelectedDate = false
        guard visibleMatches.isEmpty, selectedDateKey == dateKey else { return false }
        removeUnavailableDate(dateKey)
        return true
    }

    private func removeUnavailableDate(_ dateKey: String) {
        guard let removedIndex = availableDays.firstIndex(where: { $0.date == dateKey }) else {
            return
        }
        availableDays.remove(at: removedIndex)
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
        let days = availableDays
        let selectedIndex = days.firstIndex(where: { $0.date == dateKey })
        var targets: [(String, Bool)] = []
        if let selectedIndex {
            for offset in [-1, 1, -2, 2] {
                let index = selectedIndex + offset
                guard days.indices.contains(index) else { continue }
                targets.append((days[index].date, topMatchesOnly))
            }
        }
        if topMatchesOnly {
            targets.insert((dateKey, false), at: 0)
        }

        prefetchTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            for (targetDate, targetTopMatchesOnly) in targets {
                guard !Task.isCancelled, prefetchRequestID == requestID else { return }
                let key = Self.bucketKey(
                    dateKey: targetDate,
                    topMatchesOnly: targetTopMatchesOnly
                )
                if let existing = cachePayload?.buckets[key],
                   Self.isFresh(bucket: existing, dateKey: targetDate) {
                    continue
                }
                guard let response = try? await APIClient(baseURL: baseURL).fetchFixtureBrowseMatches(
                    on: targetDate,
                    preferences: snapshot,
                    topMatchesOnly: targetTopMatchesOnly
                ) else {
                    continue
                }
                let bucket = FixtureBrowseBucket(
                    matches: response.matches,
                    fetchedAt: Date(),
                    lastUpdated: response.lastUpdated
                )
                store(bucket: bucket, for: key)
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

    private func persistCache() {
        guard let payload = cachePayload else { return }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let cacheURL = Self.cacheURL
        Task.detached(priority: .utility) {
            try? data.write(to: cacheURL, options: .atomic)
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
