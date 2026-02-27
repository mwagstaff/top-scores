import Foundation
import Combine

struct MatchDay: Identifiable, Hashable {
    let id: String
    let dateKey: String
    let displayDate: String
    let isToday: Bool
    let isTomorrow: Bool
    let leagues: [MatchLeague]
}

enum MatchScoreResolver {
    private struct NameVariant: Hashable {
        let key: String
        let tokens: [String]
    }

    private struct ScoreCandidate {
        let match: BbcMatch
        let confidence: Double
        let minTeamConfidence: Double
    }

    private static let minCombinedConfidence = 0.82
    private static let minTeamConfidence = 0.70
    private static let swappedPenalty = 0.08
    private static let prefixBoost = 0.35
    private static let singleTokenPenalty = 0.12
    private static let finishedStatuses: Set<String> = ["FT", "AET"]
    private static let inProgressTokens: Set<String> = ["HT", "ET", "LIVE", "PENS", "PEN", "PEN."]

    static func applyScores(to matches: [Match], using bbcMatches: [BbcMatch]) -> [Match] {
        guard !bbcMatches.isEmpty else { return matches }
        let calendar = Calendar.current

        return matches.map { match in
            if let dateOnly = match.dateOnly, !calendar.isDateInToday(dateOnly) {
                return match
            }

            guard let candidate = bestCandidate(for: match, in: bbcMatches) else { return match }

            // Check for stale BBC data - reject if time or scores have regressed
            let matchTime = parseMatchTimeMinutes(match.scoreStatus)
            let bbcTime = parseMatchTimeMinutes(candidate.match.matchTime)

            NSLog("[DEBUG applyScores] Comparing times for %@ vs %@ - matchStatus=\"%@\" parsed=%@ bbcStatus=\"%@\" parsed=%@",
                  match.homeTeam, match.awayTeam,
                  match.scoreStatus ?? "nil", matchTime.map(String.init) ?? "nil",
                  candidate.match.matchTime, bbcTime.map(String.init) ?? "nil")

            if let matchTime = matchTime, let bbcTime = bbcTime, bbcTime < matchTime {
                NSLog("[STALE DATA] Rejecting stale BBC Live data for %@ vs %@ - time regressed from %d' to %d'",
                      match.homeTeam, match.awayTeam, matchTime, bbcTime)
                return match // Keep existing data
            }

            // Check for score regression
            if let matchHome = match.homeScore, let matchAway = match.awayScore {
                let matchTotal = matchHome + matchAway
                let bbcTotal = candidate.match.homeScore + candidate.match.awayScore

                if bbcTotal < matchTotal && (bbcTime ?? Int.max) <= (matchTime ?? Int.max) {
                    NSLog("[STALE DATA] Rejecting stale BBC Live data for %@ vs %@ - scores regressed from %d-%d to %d-%d",
                          match.homeTeam, match.awayTeam, matchHome, matchAway,
                          candidate.match.homeScore, candidate.match.awayScore)
                    return match // Keep existing data
                }
            }

            let finalStatus = preferredStatus(current: match.scoreStatus, incoming: candidate.match.matchTime)

            return match.withScore(
                home: candidate.match.homeScore,
                away: candidate.match.awayScore,
                status: finalStatus,
                aggregateHome: candidate.match.aggregateHomeScore,
                aggregateAway: candidate.match.aggregateAwayScore
            )
        }
    }

    private static func parseMatchTimeMinutes(_ matchTime: String?) -> Int? {
        guard let matchTime = matchTime?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }

        // Extract minute value (e.g., "45+2" -> 47, "90" -> 90)
        if let match = matchTime.range(of: #"^(\d+)(?:\+(\d+))?[']?$"#, options: .regularExpression) {
            let components = matchTime[match].split(separator: "+")
            let base = Int(components[0].trimmingCharacters(in: CharacterSet(charactersIn: "'"))) ?? 0
            let added = components.count > 1 ? Int(components[1].trimmingCharacters(in: CharacterSet(charactersIn: "'"))) ?? 0 : 0
            return base + added
        }

        // Handle special statuses
        let upper = matchTime.uppercased()
        if upper.contains("HT") || upper.contains("HALF") { return 45 }
        if upper.contains("FT") || upper.contains("FULL") { return 90 }
        if upper == "AET" { return 120 }
        if upper == "PENS" || upper == "PEN" || upper == "PEN." { return 120 }

        return nil
    }

    static func preferredStatus(current: String?, incoming: String?) -> String? {
        let currentStatus = normalizedStatus(current)
        let incomingStatus = normalizedStatus(incoming)

        guard let currentStatus else { return incomingStatus }
        guard let incomingStatus else { return currentStatus }

        let currentState = statusState(for: currentStatus)
        let incomingState = statusState(for: incomingStatus)

        if currentState == .finished && incomingState != .finished {
            return currentStatus
        }
        if incomingState == .finished && currentState != .finished {
            return incomingStatus
        }
        if currentState == .finished && incomingState == .finished {
            if currentStatus == "AET" && incomingStatus == "FT" {
                return currentStatus
            }
            if incomingStatus == "AET" && currentStatus == "FT" {
                return incomingStatus
            }
            return incomingStatus
        }

        let currentMinute = parseMatchTimeMinutes(currentStatus)
        let incomingMinute = parseMatchTimeMinutes(incomingStatus)
        if let currentMinute, let incomingMinute {
            return incomingMinute >= currentMinute ? incomingStatus : currentStatus
        }
        if currentMinute != nil && incomingMinute == nil {
            return currentStatus
        }
        if incomingMinute != nil && currentMinute == nil {
            return incomingStatus
        }

        return incomingStatus
    }

    private static func normalizedStatus(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value.uppercased()
    }

    private static func statusState(for status: String) -> StatusState {
        if finishedStatuses.contains(status) {
            return .finished
        }
        if parseMatchTimeMinutes(status) != nil || inProgressTokens.contains(status) {
            return .inProgress
        }
        return .unknown
    }

    private enum StatusState {
        case finished
        case inProgress
        case unknown
    }

    private static func bestCandidate(for match: Match, in bbcMatches: [BbcMatch]) -> ScoreCandidate? {
        var best: ScoreCandidate?

        for bbc in bbcMatches {
            let direct = score(
                home: match.homeTeam,
                away: match.awayTeam,
                bbcHome: bbc.homeTeam,
                bbcAway: bbc.awayTeam,
                penalty: 0
            )
            let swapped = score(
                home: match.homeTeam,
                away: match.awayTeam,
                bbcHome: bbc.awayTeam,
                bbcAway: bbc.homeTeam,
                penalty: swappedPenalty
            )

            let chosen = direct.confidence >= swapped.confidence ? direct : swapped
            let candidate = ScoreCandidate(
                match: bbc,
                confidence: chosen.confidence,
                minTeamConfidence: chosen.minTeamConfidence
            )

            if best == nil || candidate.confidence > (best?.confidence ?? 0) {
                best = candidate
            }
        }

        guard let best,
              best.confidence >= minCombinedConfidence,
              best.minTeamConfidence >= minTeamConfidence
        else {
            return nil
        }

        return best
    }

    private static func score(
        home: String,
        away: String,
        bbcHome: String,
        bbcAway: String,
        penalty: Double
    ) -> (confidence: Double, minTeamConfidence: Double) {
        let homeScore = similarityScore(home, bbcHome)
        let awayScore = similarityScore(away, bbcAway)
        let combined = max(0, ((homeScore + awayScore) / 2) - penalty)
        return (combined, min(homeScore, awayScore))
    }

    private static func similarityScore(_ lhs: String, _ rhs: String) -> Double {
        let leftVariants = variants(for: lhs)
        let rightVariants = variants(for: rhs)
        var best = 0.0

        for left in leftVariants {
            for right in rightVariants {
                let base = similarity(left.key, right.key)
                let dice = diceCoefficient(left.tokens, right.tokens)
                let prefix = prefixScore(left, right)
                var candidate = max(base, dice, prefix)

                if left.tokens.count >= 2 && right.tokens.count >= 2 {
                    let intersection = tokenIntersectionCount(left.tokens, right.tokens)
                    if intersection == 1 {
                        candidate = max(0, candidate - singleTokenPenalty)
                    }
                }

                best = max(best, candidate)
            }
        }

        return min(1, best)
    }

    private static func variants(for name: String) -> [NameVariant] {
        let lowered = name.lowercased()
        var candidates: [String] = [lowered]
        if let alias = aliasMap[lowered] {
            candidates.append(alias)
        }

        var variants: [NameVariant] = []
        for candidate in candidates {
            let tokens = normalizedTokens(candidate)
            let key = tokens.joined()
            guard !key.isEmpty else { continue }
            let variant = NameVariant(key: key, tokens: tokens)
            if !variants.contains(variant) {
                variants.append(variant)
            }
        }

        return variants
    }

    private static func normalizedTokens(_ value: String) -> [String] {
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
            .filter { !stopWords.contains($0) }
    }

    private static func diceCoefficient(_ lhs: [String], _ rhs: [String]) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 1 }
        let intersection = tokenIntersectionCount(lhs, rhs)
        return (2 * Double(intersection)) / Double(lhs.count + rhs.count)
    }

    private static func tokenIntersectionCount(_ lhs: [String], _ rhs: [String]) -> Int {
        let left = Set(lhs)
        let right = Set(rhs)
        return left.intersection(right).count
    }

    private static func prefixScore(_ lhs: NameVariant, _ rhs: NameVariant) -> Double {
        guard min(lhs.tokens.count, rhs.tokens.count) == 1 else { return 0 }
        if lhs.key.hasPrefix(rhs.key) || rhs.key.hasPrefix(lhs.key) {
            let minLength = min(lhs.key.count, rhs.key.count)
            let maxLength = max(lhs.key.count, rhs.key.count)
            guard maxLength > 0 else { return 1 }
            return min(1, (Double(minLength) / Double(maxLength)) + prefixBoost)
        }
        return 0
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
        "club", "de", "the", "and"
    ]

    private static let aliasMap: [String: String] = [
        "manchester united": "man united",
        "manchester city": "man city",
        "tottenham hotspur": "tottenham",
        "wolverhampton wanderers": "wolves",
        "sheffield united": "sheff utd",
        "sheffield wednesday": "sheff wed",
        "nottingham forest": "nottm forest",
        "brighton & hove albion": "brighton",
        "brighton and hove albion": "brighton",
        "borussia dortmund": "dortmund",
        "borussia m'gladbach": "m'gladbach",
        "athletic club": "athletic",
        "real betis": "betis",
        "fc copenhagen": "copenhagen",
        "fc porto": "porto",
        "paok thessaloniki": "paok",
        "paok thessaloniki fc": "paok",
        "inter milan": "inter",
        "ac milan": "ac milan"
    ]
}

struct MatchLeague: Identifiable, Hashable {
    let id: String
    let league: String
    let matches: [Match]
}

@MainActor
final class MatchesStore: ObservableObject {
    @Published private(set) var matches: [Match] = []
    @Published private(set) var groupedMatches: [MatchDay] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?
    @Published var isUsingCache = false

    private struct ModeState {
        var matches: [Match] = []
        var unfilteredMatches: [Match] = []
        var page: Int = 0
        var hasMore: Bool = true
        var isLoading: Bool = false
        var lastUpdated: Date?
        var isUsingCache: Bool = false
        var errorMessage: String?
    }

    private var refreshTimer: Timer?
    private var currentSnapshot: PreferencesSnapshot?
    private var activeMode: MatchesViewMode = .fixtures
    private var modeStates: [MatchesViewMode: ModeState] = [
        .fixtures: ModeState(),
        .results: ModeState(),
    ]
    private var cachedBbcLiveMatches: [BbcMatch] = []
    private var bbcLiveLastFetchedAt: Date?
    private var bbcLiveRefreshTask: Task<Void, Never>?

    private let liveRefreshInterval: TimeInterval = 30
    private let bbcLiveRefreshInterval: TimeInterval = 90
    private let pageSize = 120
    // Results are filtered client-side after paging; advance a few pages to avoid empty-first-page windows.
    private let resultsAutoAdvancePageLimit = 8
    private let prefetchThreshold = 20

    var hasInProgressMatches: Bool {
        modeStates.values.contains { state in
            state.matches.contains(where: \.isInProgress)
        }
    }

    func configure(with snapshot: PreferencesSnapshot) {
        configure(with: snapshot, mode: activeMode)
    }

    func configure(with snapshot: PreferencesSnapshot, mode: MatchesViewMode) {
        let modeChanged = activeMode != mode
        let snapshotChanged = currentSnapshot != snapshot
        currentSnapshot = snapshot
        activeMode = mode

        if snapshotChanged {
            loadCache(snapshot: snapshot)
            Task { await refresh(preferences: snapshot, mode: mode) }
        } else if state(for: mode).matches.isEmpty || modeChanged {
            Task { await refresh(preferences: snapshot, mode: mode) }
        }

        publishState(for: mode)
        updateRefreshTimer(using: snapshot, matches: combinedLoadedMatches())
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        bbcLiveRefreshTask?.cancel()
        bbcLiveRefreshTask = nil
    }

    func refresh(preferences: PreferencesSnapshot) async {
        await refresh(preferences: preferences, mode: activeMode)
    }

    func refresh(preferences: PreferencesSnapshot, mode: MatchesViewMode) async {
        await fetchPage(preferences: preferences, mode: mode, reset: true)
    }

    func prefetchIfNeeded(
        currentMatch: Match,
        preferences: PreferencesSnapshot,
        mode: MatchesViewMode
    ) async {
        guard mode == activeMode else { return }
        let currentState = state(for: mode)
        guard !currentState.isLoading, currentState.hasMore else { return }
        guard let index = currentState.matches.firstIndex(where: { $0.id == currentMatch.id }) else { return }
        let triggerIndex = max(0, currentState.matches.count - prefetchThreshold)
        guard index >= triggerIndex else { return }
        await fetchPage(preferences: preferences, mode: mode, reset: false)
    }

    private func fetchPage(preferences: PreferencesSnapshot, mode: MatchesViewMode, reset: Bool) async {
        guard let baseURL = URL(string: preferences.apiBaseURL) else {
            setError("Invalid API base URL.", for: mode)
            return
        }

        var current = state(for: mode)
        if current.isLoading { return }
        if !reset && !current.hasMore { return }

        current.isLoading = true
        current.errorMessage = nil
        if reset {
            current.page = 0
            current.hasMore = true
        }
        modeStates[mode] = current
        if mode == activeMode {
            publishState(for: mode)
        }

        do {
            let client = APIClient(baseURL: baseURL)
            if mode == .fixtures && cachedBbcLiveMatches.isEmpty {
                await hydrateBbcLiveCacheIfNeeded(client: client)
            }
            var requestedPage = reset ? 1 : max(1, current.page + 1)
            var pagesFetched = 0
            var nextHasMore = false
            var newestLastUpdated: Date?
            var mergedIncoming: [Match] = []
            var mergedModeFiltered: [Match] = []

            repeat {
                let pageResponse = try await client.fetchMatchesPage(
                    preferences: preferences,
                    mode: mode,
                    page: requestedPage,
                    pageSize: pageSize
                )

                var incoming = pageResponse.matches

                // Filter out test matches in non-DEBUG builds
                #if !DEBUG
                incoming = incoming.filter { $0.isTestMatch != true }
                #endif

                // Debug log for Birmingham vs Leeds match
                if let birdsMatch = incoming.first(where: { $0.homeTeam.contains("Birmingham") && $0.awayTeam.contains("Leeds") }) {
                    NSLog("[DEBUG fetchPage] Birmingham vs Leeds decoded with status=%@ hasScore=%d", birdsMatch.scoreStatus ?? "nil", birdsMatch.hasScore)
                }
                if mode == .fixtures {
                    incoming = MatchScoreResolver.applyScores(to: incoming, using: cachedBbcLiveMatches)
                    scheduleBbcLiveRefreshIfNeeded(client: client, force: cachedBbcLiveMatches.isEmpty)
                }

                let competitionFiltered = Self.applyCompetitionFilters(
                    to: incoming,
                    selectedLeagues: preferences.selectedLeagues,
                    isEnabled: preferences.competitionFilterEnabled
                )

                let dateFiltered = Self.filterMatches(competitionFiltered, for: mode)

                let modeFiltered: [Match]
                if mode == .fixtures && preferences.channelFilterEnabled {
                    modeFiltered = Self.applyChannelFilters(
                        to: dateFiltered,
                        selectedChannels: preferences.selectedChannels
                    )
                } else {
                    modeFiltered = dateFiltered
                }

                mergedIncoming = Self.mergePages(existing: mergedIncoming, incoming: incoming)
                mergedModeFiltered = Self.mergePages(existing: mergedModeFiltered, incoming: modeFiltered)

                if let updated = pageResponse.lastUpdated {
                    if let currentNewest = newestLastUpdated {
                        newestLastUpdated = max(currentNewest, updated)
                    } else {
                        newestLastUpdated = updated
                    }
                }

                requestedPage = pageResponse.page + 1
                nextHasMore = pageResponse.hasMore
                pagesFetched += 1
            } while (
                reset &&
                mode == .results &&
                mergedModeFiltered.isEmpty &&
                nextHasMore &&
                pagesFetched < resultsAutoAdvancePageLimit
            )

            var nextState = state(for: mode)
            let mergedVisibleMatches = reset
                ? mergedModeFiltered
                : Self.mergePages(existing: nextState.matches, incoming: mergedModeFiltered)
            let mergedUnfilteredMatches = reset
                ? mergedIncoming
                : Self.mergePages(existing: nextState.unfilteredMatches, incoming: mergedIncoming)

            nextState.matches = Self.sortedMatches(mergedVisibleMatches, descendingDates: mode == .results)
            nextState.unfilteredMatches = Self.sortedMatches(mergedUnfilteredMatches, descendingDates: mode == .results)
            nextState.page = max(0, requestedPage - 1)
            nextState.hasMore = nextHasMore
            if let updated = newestLastUpdated {
                nextState.lastUpdated = updated
            }
            nextState.isLoading = false
            nextState.isUsingCache = false
            nextState.errorMessage = nil

            modeStates[mode] = nextState
            persistCombinedCacheAndSync(snapshot: preferences)

            if mode == activeMode {
                publishState(for: mode)
            }
            updateRefreshTimer(using: preferences, matches: combinedLoadedMatches())
        } catch {
            if Self.isCancellationError(error) {
                var cancelledState = state(for: mode)
                cancelledState.isLoading = false
                cancelledState.errorMessage = nil
                modeStates[mode] = cancelledState
                if mode == activeMode {
                    publishState(for: mode)
                }
                NSLog("Matches refresh cancelled for mode=%@", mode.rawValue)
                return
            }
            NSLog("Matches refresh failed for mode=%@ error=%@", mode.rawValue, String(describing: error))
            setError("Unable to load matches. Check your API URL or connection.", for: mode)
        }
    }

    private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func hydrateBbcLiveCacheIfNeeded(client: APIClient) async {
        guard cachedBbcLiveMatches.isEmpty else { return }
        if let last = bbcLiveLastFetchedAt,
           Date().timeIntervalSince(last) < bbcLiveRefreshInterval {
            return
        }
        do {
            let fresh = try await client.fetchBbcLiveMatches()
            if !fresh.isEmpty {
                cachedBbcLiveMatches = fresh
            }
            bbcLiveLastFetchedAt = Date()
        } catch {
            NSLog("BBC live prefetch failed error=%@", String(describing: error))
        }
    }

    private func scheduleBbcLiveRefreshIfNeeded(client: APIClient, force: Bool = false) {
        guard shouldRefreshBbcLive(force: force) else { return }
        guard bbcLiveRefreshTask == nil else { return }

        bbcLiveRefreshTask = Task {
            let fresh = (try? await client.fetchBbcLiveMatches()) ?? []
            await MainActor.run {
                if !fresh.isEmpty {
                    self.cachedBbcLiveMatches = fresh
                }
                self.bbcLiveLastFetchedAt = Date()
                self.bbcLiveRefreshTask = nil
                self.rescoreVisibleFixtures()
            }
        }
    }

    private func shouldRefreshBbcLive(force: Bool = false, now: Date = Date()) -> Bool {
        if force { return true }
        if cachedBbcLiveMatches.isEmpty { return true }
        guard let last = bbcLiveLastFetchedAt else { return true }
        return now.timeIntervalSince(last) >= bbcLiveRefreshInterval
    }

    private func rescoreVisibleFixtures() {
        var fixtureState = state(for: .fixtures)
        guard !fixtureState.matches.isEmpty else { return }
        let rescored = MatchScoreResolver.applyScores(to: fixtureState.matches, using: cachedBbcLiveMatches)
        fixtureState.matches = rescored
        modeStates[.fixtures] = fixtureState
        if activeMode == .fixtures {
            publishState(for: .fixtures)
        }
    }

    private func loadCache(snapshot: PreferencesSnapshot) {
        guard let payload = MatchCache.load(for: snapshot) else {
            modeStates = [.fixtures: ModeState(), .results: ModeState()]
            publishState(for: activeMode)
            return
        }

        let cachedMatches = payload.matches
        let competitionFiltered = Self.applyCompetitionFilters(
            to: cachedMatches,
            selectedLeagues: snapshot.selectedLeagues,
            isEnabled: snapshot.competitionFilterEnabled
        )
        let fixturesBase = Self.filterMatches(competitionFiltered, for: .fixtures)
        let fixtures = snapshot.channelFilterEnabled
            ? Self.applyChannelFilters(to: fixturesBase, selectedChannels: snapshot.selectedChannels)
            : fixturesBase
        let results = Self.filterMatches(competitionFiltered, for: .results)

        let unfilteredFixtures = Self.filterMatches(cachedMatches, for: .fixtures)
        let unfilteredResults = Self.filterMatches(cachedMatches, for: .results)

        var fixtureState = ModeState()
        fixtureState.matches = Self.sortedMatches(fixtures)
        fixtureState.unfilteredMatches = Self.sortedMatches(unfilteredFixtures)
        fixtureState.lastUpdated = payload.lastUpdated
        fixtureState.isUsingCache = true

        var resultState = ModeState()
        resultState.matches = Self.sortedMatches(results, descendingDates: true)
        resultState.unfilteredMatches = Self.sortedMatches(unfilteredResults, descendingDates: true)
        resultState.lastUpdated = payload.lastUpdated
        resultState.isUsingCache = true

        modeStates = [.fixtures: fixtureState, .results: resultState]
        bbcLiveLastFetchedAt = nil
        publishState(for: activeMode)

        let combinedFiltered = Self.sortedMatches(fixtures + results)
        let combinedUnfiltered = Self.sortedMatches(cachedMatches)
        SharedMatchesBridge.saveAndSync(
            matches: combinedFiltered,
            unfilteredMatches: combinedUnfiltered,
            lastUpdated: payload.lastUpdated,
            snapshot: snapshot
        )
    }

    private func persistCombinedCacheAndSync(snapshot: PreferencesSnapshot) {
        let combined = Self.sortedMatches(combinedLoadedMatches())
        let unfilteredCombined = Self.sortedMatches(combinedUnfilteredMatches())
        guard !combined.isEmpty else { return }
        let latestUpdated = latestLastUpdatedAcrossModes()
        MatchCache.save(matches: unfilteredCombined, lastUpdated: latestUpdated, snapshot: snapshot)
        SharedMatchesBridge.saveAndSync(
            matches: combined,
            unfilteredMatches: unfilteredCombined,
            lastUpdated: latestUpdated,
            snapshot: snapshot
        )
    }

    private func latestLastUpdatedAcrossModes() -> Date? {
        let updates = modeStates.values.compactMap(\.lastUpdated)
        return updates.max()
    }

    private func combinedLoadedMatches() -> [Match] {
        let allMatches = modeStates.values.flatMap(\.matches)
        return Self.mergePages(existing: [], incoming: allMatches)
    }

    private func combinedUnfilteredMatches() -> [Match] {
        let allMatches = modeStates.values.flatMap(\.unfilteredMatches)
        return Self.mergePages(existing: [], incoming: allMatches)
    }

    private func setError(_ message: String, for mode: MatchesViewMode) {
        var current = state(for: mode)
        current.isLoading = false
        current.errorMessage = message
        modeStates[mode] = current
        if mode == activeMode {
            publishState(for: mode)
        }
    }

    private func state(for mode: MatchesViewMode) -> ModeState {
        modeStates[mode] ?? ModeState()
    }

    private func publishState(for mode: MatchesViewMode) {
        activeMode = mode
        let current = state(for: mode)
        matches = current.matches
        groupedMatches = Self.groupMatches(current.matches, descendingDates: mode == .results)
        isLoading = current.isLoading
        errorMessage = current.errorMessage
        lastUpdated = current.lastUpdated
        isUsingCache = current.isUsingCache
    }

    private func updateRefreshTimer(using snapshot: PreferencesSnapshot, matches: [Match]? = nil) {
        scheduleTimer(interval: effectiveRefreshInterval(for: snapshot, matches: matches ?? self.matches))
    }

    private func effectiveRefreshInterval(for snapshot: PreferencesSnapshot, matches: [Match]) -> TimeInterval {
        let configuredInterval = TimeInterval(max(1, snapshot.refreshIntervalMinutes) * 60)
        guard matches.contains(where: \.isInProgress) else { return configuredInterval }
        return min(configuredInterval, liveRefreshInterval)
    }

    private func scheduleTimer(interval: TimeInterval) {
        let boundedInterval = max(1, interval)

        if let refreshTimer, abs(refreshTimer.timeInterval - boundedInterval) < 1 {
            return
        }

        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: boundedInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let snapshot = self.currentSnapshot else { return }
                await self.refresh(preferences: snapshot, mode: self.activeMode)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private static func mergePages(existing: [Match], incoming: [Match]) -> [Match] {
        var merged = existing
        var indicesByID: [String: Int] = [:]
        for (index, match) in merged.enumerated() {
            indicesByID[match.id] = index
        }

        for match in incoming {
            if let existingIndex = indicesByID[match.id] {
                let preferred = preferredMatch(existing: merged[existingIndex], incoming: match)
                merged[existingIndex] = preferred
            } else {
                indicesByID[match.id] = merged.count
                merged.append(match)
            }
        }
        return merged
    }

    private static func preferredMatch(existing: Match, incoming: Match) -> Match {
        let preferredStatus = MatchScoreResolver.preferredStatus(
            current: existing.scoreStatus,
            incoming: incoming.scoreStatus
        )
        let existingStatus = normalizedStatus(existing.scoreStatus)
        let incomingStatus = normalizedStatus(incoming.scoreStatus)

        if preferredStatus == existingStatus && preferredStatus != incomingStatus {
            return existing
        }
        if preferredStatus == incomingStatus && preferredStatus != existingStatus {
            return incoming
        }
        if incoming.hasScore && !existing.hasScore {
            return incoming
        }
        if existing.hasScore && !incoming.hasScore {
            return existing
        }
        if incoming.tvChannels.count != existing.tvChannels.count {
            return incoming.tvChannels.count > existing.tvChannels.count ? incoming : existing
        }
        return incoming
    }

    private static func normalizedStatus(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value.uppercased()
    }

    private static func filterMatches(_ matches: [Match], for mode: MatchesViewMode) -> [Match] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return matches.filter { match in
            guard let date = match.dateOnly else {
                return mode == .fixtures
            }
            let day = calendar.startOfDay(for: date)
            switch mode {
            case .fixtures:
                return day >= today
            case .results:
                if day < today { return true }
                if day > today { return false }
                return match.isInProgress || match.isFinished
            }
        }
    }

    private static func sortedMatches(_ matches: [Match], descendingDates: Bool = false) -> [Match] {
        matches.sorted { lhs, rhs in
            let leftDate = matchSortDate(for: lhs)
            let rightDate = matchSortDate(for: rhs)
            if leftDate != rightDate {
                return descendingDates ? leftDate > rightDate : leftDate < rightDate
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

    private static func matchSortDate(for match: Match) -> Date {
        match.dateTime ?? MatchDateParser.shared.parse(date: match.date, time: "00:00") ?? .distantFuture
    }

    private static func competitionWeight(for match: Match) -> Double {
        if let displayWeight = CompetitionWeightConfig.weight(for: match.displayLeague) {
            return displayWeight
        }
        return CompetitionWeightConfig.weight(for: match.league) ?? 0
    }

    private static func competitionWeight(forCompetitionName competitionName: String) -> Double {
        CompetitionWeightConfig.weight(for: competitionName) ?? 0
    }

    private static func applyChannelFilters(to matches: [Match], selectedChannels: [String]) -> [Match] {
        guard !selectedChannels.isEmpty else { return matches }

        return matches.compactMap { match in
            let relevantChannels = ChannelSelection.filterChannels(match.tvChannels, selectedOptions: selectedChannels)
            guard !relevantChannels.isEmpty else { return nil }
            return match.withTvChannels(relevantChannels)
        }
    }

    private static func applyCompetitionFilters(
        to matches: [Match],
        selectedLeagues: [String],
        isEnabled: Bool
    ) -> [Match] {
        guard isEnabled else { return matches }
        guard !selectedLeagues.isEmpty else { return matches }

        let selected = Set(selectedLeagues.map {
            $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        })

        return matches.filter { match in
            selected.contains(
                match.league
                    .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            )
        }
    }

    private static func groupMatches(_ matches: [Match], descendingDates: Bool = false) -> [MatchDay] {
        let groupedByDate = Dictionary(grouping: matches) { $0.date }
        var dateKeys = groupedByDate.keys.sorted()
        if descendingDates {
            dateKeys.reverse()
        }
        let calendar = Calendar.current

        let dateDays: [MatchDay] = dateKeys.compactMap { dateKey -> MatchDay? in
            guard let matchesForDate = groupedByDate[dateKey] else { return nil }
            let sortedDateMatches = Self.sortedMatches(matchesForDate)
            let displayDate: String
            let parsedDate = MatchDateParser.shared.parse(date: dateKey, time: "00:00")
            let isToday = parsedDate.map { calendar.isDateInToday($0) } ?? false
            let isTomorrow = parsedDate.map { calendar.isDateInTomorrow($0) } ?? false
            if let parsedDate {
                displayDate = MatchDateParser.shared.displayDateWithRelative(parsedDate)
            } else {
                displayDate = dateKey
            }

            let groupedByLeague = Dictionary(grouping: sortedDateMatches) { $0.displayLeague }
            let leagueSections = groupedByLeague.compactMap { entry -> (league: String, matches: [Match], firstKickoff: Date, weight: Double)? in
                let (league, leagueMatches) = entry
                let sortedLeagueMatches = Self.sortedMatches(leagueMatches)
                guard let firstMatch = sortedLeagueMatches.first else { return nil }
                return (
                    league: league,
                    matches: sortedLeagueMatches,
                    firstKickoff: Self.matchSortDate(for: firstMatch),
                    weight: Self.competitionWeight(forCompetitionName: league)
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
            .map { section in
                MatchLeague(id: "\(dateKey)|\(section.league)", league: section.league, matches: section.matches)
            }

            return MatchDay(
                id: dateKey,
                dateKey: dateKey,
                displayDate: displayDate,
                isToday: isToday,
                isTomorrow: isTomorrow,
                leagues: leagueSections
            )
        }

        return dateDays
    }
}
