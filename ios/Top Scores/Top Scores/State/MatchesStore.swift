import Foundation
import Combine
import os

struct MatchDay: Identifiable, Hashable, Sendable {
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

    static func applyScores(to matches: [Match], using bbcMatches: [BbcMatch]) -> [Match] {
        guard !bbcMatches.isEmpty else { return matches }
        let calendar = Calendar.current

        return matches.map { match in
            if let dateOnly = match.dateOnly, !calendar.isDateInToday(dateOnly) {
                return match
            }

            guard let candidate = bestCandidate(for: match, in: bbcMatches) else { return match }

            // Check for stale BBC data - reject if time or scores have regressed
            let matchTime = MatchStatusFormatter.parseMatchTimeMinutes(match.scoreStatus)
            let bbcTime = MatchStatusFormatter.parseMatchTimeMinutes(candidate.match.matchTime)

            let prefersIncomingStatus = MatchStatusFormatter.prefersIncomingStatus(
                current: match.scoreStatus,
                incoming: candidate.match.matchTime
            )

            if let matchTime = matchTime, let bbcTime = bbcTime, bbcTime < matchTime, !prefersIncomingStatus {
                return match // Keep existing data
            }

            // Check for score regression
            if let matchHome = match.homeScore, let matchAway = match.awayScore {
                let matchTotal = matchHome + matchAway
                let bbcTotal = candidate.match.homeScore + candidate.match.awayScore

                if bbcTotal < matchTotal && (bbcTime ?? Int.max) <= (matchTime ?? Int.max) {
                    return match // Keep existing data
                }
            }

            let finalStatus = MatchStatusFormatter.preferredStatus(
                current: match.scoreStatus,
                incoming: candidate.match.matchTime
            )

            return match.withScore(
                home: candidate.match.homeScore,
                away: candidate.match.awayScore,
                status: finalStatus,
                aggregateHome: candidate.match.aggregateHomeScore,
                aggregateAway: candidate.match.aggregateAwayScore
            )
        }
    }

    nonisolated static func preferredStatus(current: String?, incoming: String?) -> String? {
        MatchStatusFormatter.preferredStatus(current: current, incoming: incoming)
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
        var variants: [NameVariant] = []
        for candidate in TeamIdentityStore.shared.names(for: name) {
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

}

struct MatchLeague: Identifiable, Hashable, Sendable {
    let id: String
    let league: String
    let matches: [Match]
}

private enum MatchGroupingEngine {
    private final class GroupingMemo: @unchecked Sendable {
        private nonisolated(unsafe) var teamRatings: [String: Double] = [:]
        private nonisolated(unsafe) var matchRatings: [String: Double] = [:]
        private nonisolated(unsafe) var matchDates: [String: Date] = [:]

        nonisolated init() {}

        nonisolated func matchSortDate(for match: Match) -> Date {
            if let cached = matchDates[match.id] {
                return cached
            }
            let resolved = match.dateTime
                ?? MatchDateParser.parse(date: match.date, time: "00:00")
                ?? .distantFuture
            matchDates[match.id] = resolved
            return resolved
        }

        nonisolated func totalTeamRating(for match: Match, ratingLookup: TeamRatingLookup) -> Double {
            if let cached = matchRatings[match.id] {
                return cached
            }

            let resolved = teamRating(for: match.homeTeam, ratingLookup: ratingLookup) +
                teamRating(for: match.awayTeam, ratingLookup: ratingLookup)
            matchRatings[match.id] = resolved
            return resolved
        }

        nonisolated func totalTeamRating(for matches: [Match], ratingLookup: TeamRatingLookup) -> Double {
            matches.reduce(0) { partialResult, match in
                partialResult + totalTeamRating(for: match, ratingLookup: ratingLookup)
            }
        }

        private nonisolated func teamRating(for teamName: String, ratingLookup: TeamRatingLookup) -> Double {
            if let cached = teamRatings[teamName] {
                return cached
            }
            let resolved = ratingLookup.resolvedRating(for: teamName)
            teamRatings[teamName] = resolved
            return resolved
        }
    }

    nonisolated static func groupMatches(
        _ matches: [Match],
        descendingDates: Bool = false,
        sortOrder: MatchGroupSortOrder,
        ratingLookup: TeamRatingLookup,
        premierLeagueMatchesFirst: Bool = false
    ) -> [MatchDay] {
        let memo = GroupingMemo()
        let groupedByDate = Dictionary(grouping: matches) { $0.date }
        var dateKeys = groupedByDate.keys.sorted()
        if descendingDates {
            dateKeys.reverse()
        }
        let calendar = Calendar.current

        let dateDays: [MatchDay] = dateKeys.compactMap { dateKey -> MatchDay? in
            guard let matchesForDate = groupedByDate[dateKey] else { return nil }
            let displayDate: String
            let parsedDate = MatchDateParser.parse(date: dateKey, time: "00:00")
            let isToday = parsedDate.map { calendar.isDateInToday($0) } ?? false
            let isTomorrow = parsedDate.map { calendar.isDateInTomorrow($0) } ?? false
            if let parsedDate {
                displayDate = MatchDateParser.displayDateWithRelative(parsedDate)
            } else {
                displayDate = dateKey
            }

            let groupedByLeague = Dictionary(grouping: matchesForDate) { $0.displayLeague }
            let leagueSections = groupedByLeague.compactMap {
                entry -> (
                    league: String,
                    matches: [Match],
                    totalTeamRating: Double,
                    leadingMatchRating: Double,
                    leadingMatchKickoff: Date,
                    leadingMatchHomeTeam: String,
                    leadingMatchAwayTeam: String,
                    weight: Double
                )?
                in
                let (league, leagueMatches) = entry
                let sortedLeagueMatches = sortMatchesWithinLeague(
                    leagueMatches,
                    sortOrder: sortOrder,
                    ratingLookup: ratingLookup,
                    memo: memo,
                    premierLeagueMatchesFirst: premierLeagueMatchesFirst
                )
                guard let leadingMatch = sortedLeagueMatches.first else { return nil }
                return (
                    league: league,
                    matches: sortedLeagueMatches,
                    totalTeamRating: memo.totalTeamRating(for: leagueMatches, ratingLookup: ratingLookup),
                    leadingMatchRating: memo.totalTeamRating(for: leadingMatch, ratingLookup: ratingLookup),
                    leadingMatchKickoff: memo.matchSortDate(for: leadingMatch),
                    leadingMatchHomeTeam: leadingMatch.homeTeam,
                    leadingMatchAwayTeam: leadingMatch.awayTeam,
                    weight: competitionWeight(forCompetitionName: league)
                )
            }
            .sorted { lhs, rhs in
                switch sortOrder {
                case .kickoffThenTeamScore:
                    if lhs.leadingMatchKickoff != rhs.leadingMatchKickoff {
                        return lhs.leadingMatchKickoff < rhs.leadingMatchKickoff
                    }
                    if lhs.weight != rhs.weight {
                        return lhs.weight > rhs.weight
                    }
                    if lhs.leadingMatchRating != rhs.leadingMatchRating {
                        return lhs.leadingMatchRating > rhs.leadingMatchRating
                    }
                case .kickoffThenAlphabetical:
                    if lhs.leadingMatchKickoff != rhs.leadingMatchKickoff {
                        return lhs.leadingMatchKickoff < rhs.leadingMatchKickoff
                    }
                    if lhs.weight != rhs.weight {
                        return lhs.weight > rhs.weight
                    }
                    let homeCompare = lhs.leadingMatchHomeTeam.localizedCaseInsensitiveCompare(rhs.leadingMatchHomeTeam)
                    if homeCompare != .orderedSame {
                        return homeCompare == .orderedAscending
                    }
                    let awayCompare = lhs.leadingMatchAwayTeam.localizedCaseInsensitiveCompare(rhs.leadingMatchAwayTeam)
                    if awayCompare != .orderedSame {
                        return awayCompare == .orderedAscending
                    }
                case .teamScore, .alphabetical:
                    if lhs.weight != rhs.weight {
                        return lhs.weight > rhs.weight
                    }
                    if lhs.totalTeamRating != rhs.totalTeamRating {
                        return lhs.totalTeamRating > rhs.totalTeamRating
                    }
                    if lhs.leadingMatchRating != rhs.leadingMatchRating {
                        return lhs.leadingMatchRating > rhs.leadingMatchRating
                    }
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

    nonisolated static func matchSortDate(for match: Match) -> Date {
        match.dateTime ?? MatchDateParser.parse(date: match.date, time: "00:00") ?? .distantFuture
    }

    nonisolated static func competitionWeight(for match: Match) -> Double {
        if let displayWeight = CompetitionWeightConfig.weight(for: match.displayLeague) {
            return displayWeight
        }
        return CompetitionWeightConfig.weight(for: match.league) ?? 0
    }

    nonisolated static func competitionWeight(forCompetitionName competitionName: String) -> Double {
        CompetitionWeightConfig.weight(for: competitionName) ?? 0
    }

    private nonisolated static func matchIncludesPremierLeagueTeam(_ match: Match) -> Bool {
        let homeKeys = TeamIdentityStore.shared.normalizedKeys(for: match.homeTeam)
        let awayKeys = TeamIdentityStore.shared.normalizedKeys(for: match.awayTeam)
        return !homeKeys.isDisjoint(with: MatchesStore.premierLeagueTeamKeys) ||
            !awayKeys.isDisjoint(with: MatchesStore.premierLeagueTeamKeys)
    }

    private nonisolated static func sortMatchesWithinLeague(
        _ matches: [Match],
        sortOrder: MatchGroupSortOrder,
        ratingLookup: TeamRatingLookup,
        memo: GroupingMemo,
        premierLeagueMatchesFirst: Bool = false
    ) -> [Match] {
        matches.sorted { lhs, rhs in
            if lhs.isPostponed != rhs.isPostponed {
                return !lhs.isPostponed && rhs.isPostponed
            }

            switch sortOrder {
            case .teamScore:
                if premierLeagueMatchesFirst {
                    let lhsEPL = matchIncludesPremierLeagueTeam(lhs)
                    let rhsEPL = matchIncludesPremierLeagueTeam(rhs)
                    if lhsEPL != rhsEPL { return lhsEPL && !rhsEPL }
                }
                let leftScore = memo.totalTeamRating(for: lhs, ratingLookup: ratingLookup)
                let rightScore = memo.totalTeamRating(for: rhs, ratingLookup: ratingLookup)
                if leftScore != rightScore {
                    return leftScore > rightScore
                }
            case .alphabetical:
                if premierLeagueMatchesFirst {
                    let lhsEPL = matchIncludesPremierLeagueTeam(lhs)
                    let rhsEPL = matchIncludesPremierLeagueTeam(rhs)
                    if lhsEPL != rhsEPL { return lhsEPL && !rhsEPL }
                }
                let homeCompare = lhs.homeTeam.localizedCaseInsensitiveCompare(rhs.homeTeam)
                if homeCompare != .orderedSame {
                    return homeCompare == .orderedAscending
                }
                let awayCompare = lhs.awayTeam.localizedCaseInsensitiveCompare(rhs.awayTeam)
                if awayCompare != .orderedSame {
                    return awayCompare == .orderedAscending
                }
            case .kickoffThenTeamScore:
                let leftDate = memo.matchSortDate(for: lhs)
                let rightDate = memo.matchSortDate(for: rhs)
                if leftDate != rightDate {
                    return leftDate < rightDate
                }
                if premierLeagueMatchesFirst {
                    let lhsEPL = matchIncludesPremierLeagueTeam(lhs)
                    let rhsEPL = matchIncludesPremierLeagueTeam(rhs)
                    if lhsEPL != rhsEPL { return lhsEPL && !rhsEPL }
                }
                let leftScore = memo.totalTeamRating(for: lhs, ratingLookup: ratingLookup)
                let rightScore = memo.totalTeamRating(for: rhs, ratingLookup: ratingLookup)
                if leftScore != rightScore {
                    return leftScore > rightScore
                }
            case .kickoffThenAlphabetical:
                let leftDate = memo.matchSortDate(for: lhs)
                let rightDate = memo.matchSortDate(for: rhs)
                if leftDate != rightDate {
                    return leftDate < rightDate
                }
                if premierLeagueMatchesFirst {
                    let lhsEPL = matchIncludesPremierLeagueTeam(lhs)
                    let rhsEPL = matchIncludesPremierLeagueTeam(rhs)
                    if lhsEPL != rhsEPL { return lhsEPL && !rhsEPL }
                }
                let homeCompare = lhs.homeTeam.localizedCaseInsensitiveCompare(rhs.homeTeam)
                if homeCompare != .orderedSame {
                    return homeCompare == .orderedAscending
                }
                let awayCompare = lhs.awayTeam.localizedCaseInsensitiveCompare(rhs.awayTeam)
                if awayCompare != .orderedSame {
                    return awayCompare == .orderedAscending
                }
            }

            let leftDate = memo.matchSortDate(for: lhs)
            let rightDate = memo.matchSortDate(for: rhs)
            if leftDate != rightDate {
                return leftDate < rightDate
            }

            let homeCompare = lhs.homeTeam.localizedCaseInsensitiveCompare(rhs.homeTeam)
            if homeCompare != .orderedSame {
                return homeCompare == .orderedAscending
            }

            return lhs.awayTeam.localizedCaseInsensitiveCompare(rhs.awayTeam) == .orderedAscending
        }
    }

    nonisolated static func totalTeamRating(for matches: [Match], ratingLookup: TeamRatingLookup) -> Double {
        let memo = GroupingMemo()
        return memo.totalTeamRating(for: matches, ratingLookup: ratingLookup)
    }

    nonisolated static func totalTeamRating(for match: Match, ratingLookup: TeamRatingLookup) -> Double {
        let memo = GroupingMemo()
        return memo.totalTeamRating(for: match, ratingLookup: ratingLookup)
    }
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
        var groupedMatches: [MatchDay] = []
        var groupedMatchesRevision: Int?
        var page: Int = 0
        var hasMore: Bool = true
        var isLoading: Bool = false
        var lastUpdated: Date?
        var fixtureCoverageEnd: Date?
        var isUsingCache: Bool = false
        var errorMessage: String?
        var lastValidatedSnapshot: PreferencesSnapshot?
    }

    private var refreshTimer: Timer?
    private var currentSnapshot: PreferencesSnapshot?
    private var activeMode: MatchesViewMode = .fixtures
    private var visibleModes: Set<MatchesViewMode> = []
    private var modeStates: [MatchesViewMode: ModeState] = [
        .fixtures: ModeState(),
        .results: ModeState(),
    ]
    private var refreshTasks: [MatchesViewMode: Task<Void, Never>] = [:]
    private var refreshTaskIDs: [MatchesViewMode: UUID] = [:]
    private var refreshTaskSnapshots: [MatchesViewMode: PreferencesSnapshot] = [:]
    private var cachedBbcLiveMatches: [BbcMatch] = []
    private var bbcLiveLastFetchedAt: Date?
    private var cacheStateLastFetchedAt: Date?
    private var bbcLiveRefreshTask: Task<Void, Never>?
    private var fixturesBackgroundLoadTask: Task<Void, Never>?
    private var fixturesDeferredVisibleUpdatePending = false
    private var teamRankingsRefreshTask: Task<Void, Never>?
    private var groupingTask: Task<Void, Never>?
    private var groupingTaskID: UUID?
    private var cachePersistTask: Task<Void, Never>?
    private var lastAppliedTeamRankingEntries: [TeamRankingEntry] = []
    private var lastAppliedTeamRatingDefaultElo = TeamRankingSettings.defaultDefaultElo
    private var teamRatingLookup = TeamRatingLookup(
        entries: [],
        defaultPoints: TeamRankingSettings.defaultDefaultElo
    )
    private var groupingRevision = 0

    private let liveRefreshInterval: TimeInterval = 30
    private let bbcLiveRefreshInterval: TimeInterval = 90
    private let cacheStateRefreshInterval: TimeInterval = 30
    private let configureRefreshInterval: TimeInterval = 30
    private let fixturesInitialLoadDays = 14
    private let fixturesFutureLoadDays = 90
    private let fixturesLazyBatchDays = 14
    private let fixturesLazyParallelRequests = 1
    private let fixturesLazyPageSize = 2000
    private let fixturesLazyStartDelayNanos: UInt64 = 30_000_000_000
    private let fixturesLazyInterBatchDelayNanos: UInt64 = 5_000_000_000
    private let resultsHistoryLoadDays = 90
    private let resultsHistoryPageSize = 500
    private let teamRankingsRefreshDelayNanos: UInt64 = 4_000_000_000

    var hasInProgressMatches: Bool {
        modeStates.values.contains { state in
            state.matches.contains(where: \.isInProgress)
        }
    }

    func configure(with snapshot: PreferencesSnapshot) {
        configure(with: snapshot, mode: activeMode)
    }

    func configure(with snapshot: PreferencesSnapshot, mode: MatchesViewMode) {
        let signpost = PerformanceSignposter.matches.beginInterval("MatchesConfigure")
        defer { PerformanceSignposter.matches.endInterval("MatchesConfigure", signpost) }

        let previousSnapshot = currentSnapshot
        let modeChanged = activeMode != mode
        let snapshotChanged = previousSnapshot != snapshot
        let dataSourceChanged = previousSnapshot?.apiBaseURL != snapshot.apiBaseURL
        let sortOrderChanged = previousSnapshot?.matchGroupSortOrder != snapshot.matchGroupSortOrder
        if sortOrderChanged {
            groupingRevision &+= 1
        }
        currentSnapshot = snapshot
        activeMode = mode

        Self.log(
            "configure mode=\(mode.rawValue) selected_snapshot=\(Self.snapshotDebugSummary(snapshot)) " +
            "previous_snapshot=\(previousSnapshot.map(Self.snapshotDebugSummary) ?? "nil") " +
            "snapshot_changed=\(snapshotChanged) data_source_changed=\(dataSourceChanged) mode_changed=\(modeChanged)"
        )

        if dataSourceChanged || previousSnapshot == nil {
            loadCache(snapshot: snapshot)
        } else if snapshotChanged {
            reapplyLocalFilters(using: snapshot)
        }

        if mode == .fixtures, fixturesDeferredVisibleUpdatePending {
            applyDeferredFixtureVisibilityUpdate(snapshot: snapshot)
        }

        let currentModeState = state(for: mode)
        if dataSourceChanged ||
            currentModeState.matches.isEmpty ||
            shouldRefreshOnConfigure(currentModeState) {
            startRefreshTask(preferences: snapshot, mode: mode, reason: "configure")
        } else if mode == .fixtures {
            scheduleRemainingFixtureLoadingIfNeeded(preferences: snapshot)
        }

        let currentResultsState = state(for: .results)
        if mode != .results &&
            (
                dataSourceChanged ||
                previousSnapshot == nil ||
                currentResultsState.unfilteredMatches.isEmpty ||
                currentResultsState.isUsingCache
            ) {
            startRefreshTask(preferences: snapshot, mode: .results, reason: "startup_results_prefetch")
        }

        publishState(for: mode)
        refreshTeamRatingLookup(apiBaseURL: snapshot.apiBaseURL)
        updateRefreshTimer(using: snapshot, matches: combinedLoadedMatches())
    }

    private func shouldRefreshOnConfigure(_ state: ModeState, now: Date = Date()) -> Bool {
        if state.isUsingCache { return true }
        guard let lastUpdated = state.lastUpdated else { return true }
        guard now.timeIntervalSince(lastUpdated) >= configureRefreshInterval else { return false }

        // Don’t turn simple tab switches into refreshes when nothing is live.
        // Automatic timer refresh and explicit pull-to-refresh still cover freshness.
        return state.matches.contains(where: \.isInProgress)
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        cancelRefreshTasks(reason: "stop_auto_refresh")
        groupingTask?.cancel()
        groupingTask = nil
        groupingTaskID = nil
        bbcLiveRefreshTask?.cancel()
        bbcLiveRefreshTask = nil
        fixturesBackgroundLoadTask?.cancel()
        fixturesBackgroundLoadTask = nil
        cachePersistTask?.cancel()
        cachePersistTask = nil
        teamRankingsRefreshTask?.cancel()
        teamRankingsRefreshTask = nil
    }

    func prepareForPreferencesChange(_ snapshot: PreferencesSnapshot, publishVisibleState: Bool) {
        let previousSnapshot = currentSnapshot
        let dataSourceChanged = previousSnapshot?.apiBaseURL != snapshot.apiBaseURL
        currentSnapshot = snapshot

        Self.log(
            "prepare_preferences_change snapshot=\(Self.snapshotDebugSummary(snapshot)) " +
            "previous_snapshot=\(previousSnapshot.map(Self.snapshotDebugSummary) ?? "nil") " +
            "data_source_changed=\(dataSourceChanged) publish_visible=\(publishVisibleState)"
        )

        if dataSourceChanged || previousSnapshot == nil {
            loadCache(snapshot: snapshot)
        } else {
            reapplyLocalFilters(using: snapshot)
        }

        if publishVisibleState {
            publishState(for: activeMode)
        }
    }

    func refreshCompetitionCatalog(using snapshot: PreferencesSnapshot, publishVisibleState: Bool) {
        currentSnapshot = snapshot
        groupingRevision &+= 1
        reapplyLocalFilters(using: snapshot)
        persistCombinedCacheAndSync(snapshot: snapshot)
        if publishVisibleState {
            publishState(for: activeMode)
        }
    }

    func setModeVisibility(_ mode: MatchesViewMode, isVisible: Bool) {
        let wasVisible = visibleModes.contains(mode)
        if isVisible {
            visibleModes.insert(mode)
        } else {
            visibleModes.remove(mode)
        }

        guard wasVisible != isVisible else { return }

        Self.log("mode_visibility mode=\(mode.rawValue) visible=\(isVisible)")

        if mode == .fixtures {
            if isVisible {
                fixturesBackgroundLoadTask?.cancel()
                fixturesBackgroundLoadTask = nil
            } else if let snapshot = currentSnapshot {
                scheduleRemainingFixtureLoadingIfNeeded(preferences: resolvedSnapshot(for: snapshot))
            }
        }
    }

    func refresh(preferences: PreferencesSnapshot) async {
        await refresh(preferences: preferences, mode: activeMode)
    }

    func queueRefresh(
        preferences: PreferencesSnapshot,
        mode: MatchesViewMode,
        reason: String = "manual_refresh"
    ) {
        startRefreshTask(preferences: preferences, mode: mode, reason: reason)
    }

    func refresh(preferences: PreferencesSnapshot, mode: MatchesViewMode) async {
        if mode == .fixtures {
            await refreshFixtures(preferences: preferences)
        } else {
            await refreshResults(preferences: preferences)
        }
    }

    func prefetchIfNeeded(
        currentMatch: Match,
        preferences: PreferencesSnapshot,
        mode: MatchesViewMode
    ) async {
        guard mode == activeMode else { return }
        guard mode == .results else { return }
        _ = currentMatch
        _ = preferences
        // Results are fully hydrated up front; there is no scroll-driven paging anymore.
    }

    private func startRefreshTask(
        preferences: PreferencesSnapshot,
        mode: MatchesViewMode,
        reason: String
    ) {
        if refreshTasks[mode] != nil, refreshTaskSnapshots[mode] == preferences {
            Self.log(
                "refresh_task_skip mode=\(mode.rawValue) reason=\(reason) existing_in_flight=true snapshot_unchanged=true"
            )
            return
        }

        if let existingTask = refreshTasks[mode] {
            Self.log("refresh_task_cancel mode=\(mode.rawValue) reason=\(reason) existing_in_flight=true")
            existingTask.cancel()
            var currentModeState = state(for: mode)
            currentModeState.isLoading = false
            modeStates[mode] = currentModeState
        }

        let taskID = UUID()
        refreshTaskIDs[mode] = taskID
        refreshTaskSnapshots[mode] = preferences
        Self.log(
            "refresh_task_start mode=\(mode.rawValue) reason=\(reason) snapshot=\(Self.snapshotDebugSummary(preferences))"
        )
        let task = Task { [weak self] in
            guard let self else { return }
            await self.refresh(preferences: preferences, mode: mode)
            if self.refreshTaskIDs[mode] == taskID {
                self.refreshTasks[mode] = nil
                self.refreshTaskIDs[mode] = nil
                self.refreshTaskSnapshots[mode] = nil
            }
        }
        refreshTasks[mode] = task
    }

    private func cancelRefreshTasks(reason: String) {
        guard !refreshTasks.isEmpty else { return }
        Self.log("refresh_tasks_cancel_all reason=\(reason) count=\(refreshTasks.count)")
        refreshTasks.values.forEach { $0.cancel() }
        refreshTasks.removeAll()
        refreshTaskIDs.removeAll()
        refreshTaskSnapshots.removeAll()
    }

    private func refreshFixtures(preferences: PreferencesSnapshot) async {
        let signpost = PerformanceSignposter.matches.beginInterval("MatchesRefreshFixtures")
        defer { PerformanceSignposter.matches.endInterval("MatchesRefreshFixtures", signpost) }

        guard let baseURL = URL(string: preferences.apiBaseURL) else {
            setError("Invalid API base URL.", for: .fixtures)
            return
        }

        let client = APIClient(baseURL: baseURL)
        await reconcileServerCacheStateIfNeeded(client: client)

        var fixtureState = state(for: .fixtures)
        if fixtureState.isLoading {
            Self.log(
                "fixtures_refresh_skip reason=already_loading visible=\(fixtureState.matches.count) " +
                "stored=\(fixtureState.unfilteredMatches.count) coverage_end=\(Self.formatDateForLog(fixtureState.fixtureCoverageEnd))"
            )
            return
        }

        Self.log(
            "fixtures_refresh_begin snapshot=\(Self.snapshotDebugSummary(preferences)) " +
            "visible=\(fixtureState.matches.count) stored=\(fixtureState.unfilteredMatches.count) " +
            "coverage_end=\(Self.formatDateForLog(fixtureState.fixtureCoverageEnd))"
        )
        let requestStartedAt = Date()
        FixtureLoadDiagnosticsStore.shared.record(
            title: "Initial fixtures start",
            summary:
                "window=\(Self.formatDateForLog(Self.startOfToday()))...\(Self.formatDateForLog(Self.dayOffset(fixturesInitialLoadDays - 1, from: Self.startOfToday()))) " +
                "page_size=\(fixturesLazyPageSize) hydrate_states=false stored_before=\(fixtureState.unfilteredMatches.count)"
        )

        fixturesBackgroundLoadTask?.cancel()
        fixturesBackgroundLoadTask = nil

        fixtureState.isLoading = true
        fixtureState.errorMessage = nil
        fixtureState.isUsingCache = fixtureState.isUsingCache && !fixtureState.matches.isEmpty
        modeStates[.fixtures] = fixtureState
        if activeMode == .fixtures {
            publishState(for: .fixtures)
        }

        do {
            let today = Self.startOfToday()
            let initialEnd = Self.dayOffset(fixturesInitialLoadDays - 1, from: today)
            let ifModifiedSince = fixtureState.lastValidatedSnapshot == preferences
                ? fixtureState.lastUpdated
                : nil
            let response = try await client.fetchMatchesInRange(
                preferences: preferences,
                mode: .fixtures,
                startDate: today,
                endDate: initialEnd,
                pageSize: fixturesLazyPageSize,
                includePreferenceFilters: false,
                hydrateStates: false,
                ifModifiedSince: ifModifiedSince
            )
            let refreshCompletedAt = Date()

            if response.isNotModified {
                var nextState = state(for: .fixtures)
                nextState.lastUpdated = Self.maxDate(
                    nextState.lastUpdated,
                    response.lastUpdated ?? refreshCompletedAt
                )
                nextState.isLoading = false
                nextState.isUsingCache = false
                nextState.errorMessage = nil
                nextState.lastValidatedSnapshot = preferences
                modeStates[.fixtures] = nextState

                Self.log(
                    "fixtures_refresh_not_modified visible=\(nextState.matches.count) stored=\(nextState.unfilteredMatches.count) " +
                    "last_updated=\(Self.formatDateForLog(nextState.lastUpdated)) coverage_end=\(Self.formatDateForLog(nextState.fixtureCoverageEnd))"
                )
                FixtureLoadDiagnosticsStore.shared.record(
                    title: "Initial fixtures unchanged",
                    summary:
                        "window=\(Self.formatDateForLog(today))...\(Self.formatDateForLog(initialEnd)) " +
                        "duration_ms=\(Int(Date().timeIntervalSince(requestStartedAt) * 1000))"
                )

                if activeMode == .fixtures {
                    publishState(for: .fixtures)
                }
                scheduleRemainingFixtureLoadingIfNeeded(preferences: resolvedSnapshot(for: preferences))
                return
            }

            var incoming = response.matches

            #if !DEBUG
            incoming = incoming.filter { $0.isTestMatch != true }
            #endif

            let effectiveSnapshot = resolvedSnapshot(for: preferences)
            var nextState = state(for: .fixtures)
            nextState.unfilteredMatches = Self.replacingMatches(
                in: nextState.unfilteredMatches,
                with: incoming,
                within: today...initialEnd
            )
            nextState.matches = visibleMatches(
                from: nextState.unfilteredMatches,
                snapshot: effectiveSnapshot,
                mode: .fixtures
            )
            nextState.groupedMatches = []
            nextState.groupedMatchesRevision = nil
            nextState.lastUpdated = Self.maxDate(
                nextState.lastUpdated,
                response.lastUpdated ?? refreshCompletedAt
            )
            // Keep the interactive refresh window small so pull-to-refresh returns quickly.
            // Longer-range future fixtures are refreshed separately in background batches.
            nextState.fixtureCoverageEnd = initialEnd
            nextState.page = 0
            nextState.hasMore = false
            nextState.isLoading = false
            nextState.isUsingCache = false
            nextState.errorMessage = nil
            nextState.lastValidatedSnapshot = preferences
            modeStates[.fixtures] = nextState
            let durationMs = Int(Date().timeIntervalSince(requestStartedAt) * 1000)

            Self.log(
                "fixtures_refresh_complete visible=\(nextState.matches.count) stored=\(nextState.unfilteredMatches.count) " +
                "last_updated=\(Self.formatDateForLog(nextState.lastUpdated)) " +
                "coverage_end=\(Self.formatDateForLog(nextState.fixtureCoverageEnd)) " +
                "sample=\(Self.matchSample(nextState.matches))"
            )
            FixtureLoadDiagnosticsStore.shared.record(
                title: "Initial fixtures complete",
                summary:
                    "window=\(Self.formatDateForLog(today))...\(Self.formatDateForLog(initialEnd)) " +
                    "duration_ms=\(durationMs) returned=\(incoming.count) visible=\(nextState.matches.count) stored=\(nextState.unfilteredMatches.count) " +
                    "page_size=\(fixturesLazyPageSize) hydrate_states=false"
            )

            persistCombinedCacheAndSync(snapshot: effectiveSnapshot)

            if activeMode == .fixtures {
                publishState(for: .fixtures)
            }
            refreshTeamRatingLookup(apiBaseURL: effectiveSnapshot.apiBaseURL)
            updateRefreshTimer(using: effectiveSnapshot, matches: combinedLoadedMatches())
            scheduleRemainingFixtureLoadingIfNeeded(preferences: effectiveSnapshot)
        } catch {
            if Self.isCancellationError(error) {
                var cancelledState = state(for: .fixtures)
                cancelledState.isLoading = false
                cancelledState.errorMessage = nil
                modeStates[.fixtures] = cancelledState
                if activeMode == .fixtures {
                    publishState(for: .fixtures)
                }
                NSLog("Matches refresh cancelled for mode=%@", MatchesViewMode.fixtures.rawValue)
                return
            }
            NSLog("Matches refresh failed for mode=%@ error=%@", MatchesViewMode.fixtures.rawValue, String(describing: error))
            Self.log("fixtures_refresh_failed error=\(String(describing: error))")
            let durationMs = Int(Date().timeIntervalSince(requestStartedAt) * 1000)
            FixtureLoadDiagnosticsStore.shared.record(
                title: "Initial fixtures failed",
                summary: "duration_ms=\(durationMs) error=\(String(describing: error))"
            )
            setError("Unable to load matches. Check your API URL or connection.", for: .fixtures)
        }
    }

    private func refreshResults(preferences: PreferencesSnapshot) async {
        let signpost = PerformanceSignposter.matches.beginInterval("MatchesRefreshResults")
        defer { PerformanceSignposter.matches.endInterval("MatchesRefreshResults", signpost) }

        guard let baseURL = URL(string: preferences.apiBaseURL) else {
            setError("Invalid API base URL.", for: .results)
            return
        }

        let client = APIClient(baseURL: baseURL)
        await reconcileServerCacheStateIfNeeded(client: client)

        var resultState = state(for: .results)
        if resultState.isLoading {
            Self.log(
                "results_refresh_skip reason=already_loading visible=\(resultState.matches.count) " +
                "stored=\(resultState.unfilteredMatches.count)"
            )
            return
        }

        let today = Self.startOfToday()
        let historyStart = Self.dayOffset(-(resultsHistoryLoadDays - 1), from: today)
        let shouldReloadHistory =
            resultState.unfilteredMatches.isEmpty ||
            resultState.lastUpdated == nil ||
            resultState.isUsingCache
        let loadRange = shouldReloadHistory ? (historyStart...today) : (today...today)

        Self.log(
            "results_refresh_begin snapshot=\(Self.snapshotDebugSummary(preferences)) " +
            "visible=\(resultState.matches.count) stored=\(resultState.unfilteredMatches.count) " +
            "range=\(Self.formatDateForLog(loadRange.lowerBound))...\(Self.formatDateForLog(loadRange.upperBound)) " +
            "full_reload=\(shouldReloadHistory)"
        )
        let requestStartedAt = Date()

        resultState.isLoading = true
        resultState.errorMessage = nil
        resultState.isUsingCache = resultState.isUsingCache && !resultState.matches.isEmpty
        modeStates[.results] = resultState
        if activeMode == .results {
            publishState(for: .results)
        }

        do {
            let ifModifiedSince = resultState.lastValidatedSnapshot == preferences
                ? resultState.lastUpdated
                : nil
            let response = try await client.fetchMatchesInRange(
                preferences: preferences,
                mode: .results,
                startDate: loadRange.lowerBound,
                endDate: loadRange.upperBound,
                pageSize: resultsHistoryPageSize,
                includePreferenceFilters: false,
                hydrateStates: !shouldReloadHistory,
                ifModifiedSince: ifModifiedSince
            )
            let refreshCompletedAt = Date()

            if response.isNotModified {
                var nextState = state(for: .results)
                nextState.lastUpdated = Self.maxDate(
                    nextState.lastUpdated,
                    response.lastUpdated ?? refreshCompletedAt
                )
                nextState.isLoading = false
                nextState.isUsingCache = false
                nextState.errorMessage = nil
                nextState.lastValidatedSnapshot = preferences
                modeStates[.results] = nextState
                Self.log(
                    "results_refresh_not_modified visible=\(nextState.matches.count) stored=\(nextState.unfilteredMatches.count) " +
                    "range=\(Self.formatDateForLog(loadRange.lowerBound))...\(Self.formatDateForLog(loadRange.upperBound)) " +
                    "duration_ms=\(Int(Date().timeIntervalSince(requestStartedAt) * 1000))"
                )
                if activeMode == .results {
                    publishState(for: .results)
                }
                updateRefreshTimer(using: resolvedSnapshot(for: preferences), matches: combinedLoadedMatches())
                return
            }

            var incoming = response.matches

            #if !DEBUG
            incoming = incoming.filter { $0.isTestMatch != true }
            #endif

            let effectiveSnapshot = resolvedSnapshot(for: preferences)
            var nextState = state(for: .results)
            nextState.unfilteredMatches = Self.sortedMatches(
                Self.replacingMatches(
                    in: nextState.unfilteredMatches,
                    with: incoming,
                    within: loadRange
                ),
                descendingDates: true
            )
            nextState.matches = visibleMatches(
                from: nextState.unfilteredMatches,
                snapshot: effectiveSnapshot,
                mode: .results
            )
            nextState.groupedMatches = []
            nextState.groupedMatchesRevision = nil
            nextState.page = 0
            nextState.hasMore = false
            nextState.lastUpdated = Self.maxDate(
                nextState.lastUpdated,
                response.lastUpdated ?? refreshCompletedAt
            )
            nextState.isLoading = false
            nextState.isUsingCache = false
            nextState.errorMessage = nil
            nextState.lastValidatedSnapshot = preferences

            modeStates[.results] = nextState
            Self.log(
                "results_refresh_complete visible=\(nextState.matches.count) stored=\(nextState.unfilteredMatches.count) " +
                "range=\(Self.formatDateForLog(loadRange.lowerBound))...\(Self.formatDateForLog(loadRange.upperBound)) " +
                "duration_ms=\(Int(Date().timeIntervalSince(requestStartedAt) * 1000)) sample=\(Self.matchSample(nextState.matches))"
            )
            persistCombinedCacheAndSync(snapshot: effectiveSnapshot)

            if activeMode == .results {
                publishState(for: .results)
            }
            refreshTeamRatingLookup(apiBaseURL: effectiveSnapshot.apiBaseURL)
            updateRefreshTimer(using: effectiveSnapshot, matches: combinedLoadedMatches())
        } catch {
            if Self.isCancellationError(error) {
                var cancelledState = state(for: .results)
                cancelledState.isLoading = false
                cancelledState.errorMessage = nil
                modeStates[.results] = cancelledState
                if activeMode == .results {
                    publishState(for: .results)
                }
                NSLog("Matches refresh cancelled for mode=%@", MatchesViewMode.results.rawValue)
                return
            }
            NSLog("Matches refresh failed for mode=%@ error=%@", MatchesViewMode.results.rawValue, String(describing: error))
            setError("Unable to load matches. Check your API URL or connection.", for: .results)
        }
    }

    private struct FixtureRangeLoadResult: Sendable {
        let range: ClosedRange<Date>
        let matches: [Match]
        let lastUpdated: Date?
        let durationMs: Int
    }

    private func scheduleRemainingFixtureLoadingIfNeeded(preferences: PreferencesSnapshot) {
        guard fixturesBackgroundLoadTask == nil else { return }
        guard let baseURL = URL(string: preferences.apiBaseURL) else { return }

        let ranges = fixtureLazyLoadRanges(for: state(for: .fixtures).unfilteredMatches)
        guard !ranges.isEmpty else { return }

        fixturesBackgroundLoadTask = Task { [weak self] in
            guard let self else { return }
            let maxParallelRequests = max(1, self.fixturesLazyParallelRequests)
            let pageSize = self.fixturesLazyPageSize
            var appliedAnyRanges = false

            if self.fixturesLazyStartDelayNanos > 0 && !self.visibleModes.contains(.fixtures) {
                try? await Task.sleep(nanoseconds: self.fixturesLazyStartDelayNanos)
            }

            var nextIndex = 0
            while nextIndex < ranges.count {
                if Task.isCancelled { break }
                let batchEnd = min(ranges.count, nextIndex + maxParallelRequests)
                let batch = Array(ranges[nextIndex..<batchEnd])
                do {
                    let loadedRanges = try await withThrowingTaskGroup(
                        of: FixtureRangeLoadResult?.self,
                        returning: [FixtureRangeLoadResult].self
                    ) { group in
                        for range in batch {
                            group.addTask {
                                try await Self.loadFixtureRange(
                                    range,
                                    preferences: preferences,
                                    baseURL: baseURL,
                                    pageSize: pageSize
                                )
                            }
                        }

                        var loaded: [FixtureRangeLoadResult] = []
                        for try await result in group {
                            if let result {
                                loaded.append(result)
                            }
                        }
                        return loaded.sorted { $0.range.lowerBound < $1.range.lowerBound }
                    }
                    if Task.isCancelled { break }
                    if !loadedRanges.isEmpty {
                        appliedAnyRanges = true
                        applyLoadedFixtureRanges(
                            loadedRanges,
                            fallbackSnapshot: preferences,
                            publishImmediately: self.visibleModes.contains(.fixtures)
                        )
                    }
                } catch {
                    if Self.isCancellationError(error) {
                        break
                    }
                    NSLog("Fixtures lazy load failed error=%@", String(describing: error))
                    break
                }
                nextIndex = batchEnd
                if nextIndex < ranges.count && self.fixturesLazyInterBatchDelayNanos > 0 {
                    try? await Task.sleep(nanoseconds: self.fixturesLazyInterBatchDelayNanos)
                }
            }

            self.fixturesBackgroundLoadTask = nil
            let effectiveSnapshot = self.resolvedSnapshot(for: preferences)
            if !Task.isCancelled && appliedAnyRanges {
                self.finalizeDeferredFixtureLoad(snapshot: effectiveSnapshot)
            }
            if !Task.isCancelled {
                self.scheduleRemainingFixtureLoadingIfNeeded(preferences: effectiveSnapshot)
            }
        }
    }

    private func applyLoadedFixtureRanges(
        _ loadedRanges: [FixtureRangeLoadResult],
        fallbackSnapshot: PreferencesSnapshot,
        publishImmediately: Bool
    ) {
        let signpost = PerformanceSignposter.matches.beginInterval("MatchesApplyFixtureLazyBatch")
        defer { PerformanceSignposter.matches.endInterval("MatchesApplyFixtureLazyBatch", signpost) }

        guard !loadedRanges.isEmpty else { return }

        var fixtureState = state(for: .fixtures)
        var newestLastUpdated = fixtureState.lastUpdated

        for loadedRange in loadedRanges {
            fixtureState.unfilteredMatches = Self.replacingMatches(
                in: fixtureState.unfilteredMatches,
                with: loadedRange.matches,
                within: loadedRange.range
            )
            newestLastUpdated = Self.maxDate(newestLastUpdated, loadedRange.lastUpdated)
            fixtureState.fixtureCoverageEnd = Self.maxDate(
                fixtureState.fixtureCoverageEnd,
                loadedRange.range.upperBound
            )
        }

        if publishImmediately {
            let effectiveSnapshot = resolvedSnapshot(for: fallbackSnapshot)
            fixtureState.matches = visibleMatches(
                from: fixtureState.unfilteredMatches,
                snapshot: effectiveSnapshot,
                mode: .fixtures
            )
            fixtureState.groupedMatches = []
            fixtureState.groupedMatchesRevision = nil
            fixturesDeferredVisibleUpdatePending = false
        } else {
            fixturesDeferredVisibleUpdatePending = true
        }
        fixtureState.lastUpdated = newestLastUpdated
        fixtureState.isUsingCache = false
        modeStates[.fixtures] = fixtureState

        let rangeSummary = loadedRanges.map {
            "\(Self.formatDateForLog($0.range.lowerBound))...\(Self.formatDateForLog($0.range.upperBound))(\($0.matches.count))"
        }.joined(separator: ",")
        Self.log(
            "fixtures_lazy_batch_applied ranges=\(rangeSummary) visible=\(fixtureState.matches.count) " +
            "stored=\(fixtureState.unfilteredMatches.count) coverage_end=\(Self.formatDateForLog(fixtureState.fixtureCoverageEnd))"
        )
        loadedRanges.forEach { loadedRange in
            FixtureLoadDiagnosticsStore.shared.record(
                title: "Lazy fixture batch",
                summary:
                    "window=\(Self.formatDateForLog(loadedRange.range.lowerBound))...\(Self.formatDateForLog(loadedRange.range.upperBound)) " +
                    "duration_ms=\(loadedRange.durationMs) returned=\(loadedRange.matches.count) stored=\(fixtureState.unfilteredMatches.count) " +
                    "page_size=\(fixturesLazyPageSize) hydrate_states=false"
            )
        }

        persistDeferredFixtureCache(snapshot: resolvedSnapshot(for: fallbackSnapshot))
    }

    private func finalizeDeferredFixtureLoad(snapshot: PreferencesSnapshot) {
        var fixtureState = state(for: .fixtures)
        fixtureState.matches = visibleMatches(
            from: fixtureState.unfilteredMatches,
            snapshot: snapshot,
            mode: .fixtures
        )
        fixtureState.groupedMatches = []
        fixtureState.groupedMatchesRevision = nil
        fixtureState.isUsingCache = false
        modeStates[.fixtures] = fixtureState
        fixturesDeferredVisibleUpdatePending = false
        Self.log(
            "fixtures_lazy_finalize visible=\(fixtureState.matches.count) stored=\(fixtureState.unfilteredMatches.count) " +
            "coverage_end=\(Self.formatDateForLog(fixtureState.fixtureCoverageEnd))"
        )
        FixtureLoadDiagnosticsStore.shared.record(
            title: "Fixture backfill complete",
            summary:
                "coverage_end=\(Self.formatDateForLog(fixtureState.fixtureCoverageEnd)) visible=\(fixtureState.matches.count) " +
                "stored=\(fixtureState.unfilteredMatches.count)"
        )
        persistCombinedCacheAndSync(snapshot: snapshot)
        if activeMode == .fixtures && visibleModes.contains(.fixtures) {
            publishState(for: .fixtures)
        }
        updateRefreshTimer(using: snapshot, matches: combinedLoadedMatches())
    }

    private func applyDeferredFixtureVisibilityUpdate(snapshot: PreferencesSnapshot) {
        let signpost = PerformanceSignposter.matches.beginInterval("MatchesApplyDeferredFixtureVisibility")
        defer { PerformanceSignposter.matches.endInterval("MatchesApplyDeferredFixtureVisibility", signpost) }

        var fixtureState = state(for: .fixtures)
        fixtureState.matches = visibleMatches(
            from: fixtureState.unfilteredMatches,
            snapshot: snapshot,
            mode: .fixtures
        )
        fixtureState.groupedMatches = []
        fixtureState.groupedMatchesRevision = nil
        fixtureState.isUsingCache = false
        modeStates[.fixtures] = fixtureState
        fixturesDeferredVisibleUpdatePending = false
        Self.log(
            "fixtures_deferred_visible_apply visible=\(fixtureState.matches.count) stored=\(fixtureState.unfilteredMatches.count) " +
            "coverage_end=\(Self.formatDateForLog(fixtureState.fixtureCoverageEnd))"
        )
    }

    private func persistDeferredFixtureCache(snapshot: PreferencesSnapshot) {
        let unfilteredCollections = modeStates.values.map(\.unfilteredMatches)
        let latestUpdated = latestLastUpdatedAcrossModes()
        let fixtureCoverageEnd = state(for: .fixtures).fixtureCoverageEnd
        scheduleCachePersistence(
            visibleMatchCollections: [],
            unfilteredMatchCollections: unfilteredCollections,
            latestUpdated: latestUpdated,
            fixtureCoverageEnd: fixtureCoverageEnd,
            snapshot: snapshot,
            syncSharedBridge: false
        )
    }

    private func reapplyLocalFilters(using snapshot: PreferencesSnapshot) {
        for mode in modeStates.keys {
            var current = state(for: mode)
            guard !current.unfilteredMatches.isEmpty else { continue }
            current.matches = visibleMatches(
                from: current.unfilteredMatches,
                snapshot: snapshot,
                mode: mode
            )
            current.groupedMatches = []
            current.groupedMatchesRevision = nil
            modeStates[mode] = current
            Self.log(
                "reapply_local_filters mode=\(mode.rawValue) snapshot=\(Self.snapshotDebugSummary(snapshot)) " +
                "visible=\(current.matches.count) stored=\(current.unfilteredMatches.count) sample=\(Self.matchSample(current.matches))"
            )
        }
    }

    private func visibleMatches(
        from matches: [Match],
        snapshot: PreferencesSnapshot,
        mode: MatchesViewMode
    ) -> [Match] {
        let filtered = Self.applyPreferenceFilters(to: matches, snapshot: snapshot, mode: mode)
        let deduplicated = Self.deduplicatedMatches(filtered)
        return Self.sortedMatches(deduplicated, descendingDates: mode == .results)
    }

    private func fixtureLazyLoadRanges(for matches: [Match]) -> [ClosedRange<Date>] {
        let today = Self.startOfToday()
        let initialWindowEnd = Self.dayOffset(fixturesInitialLoadDays - 1, from: today)
        let overallEnd = Self.dayOffset(fixturesFutureLoadDays - 1, from: today)
        guard initialWindowEnd < overallEnd else { return [] }

        let loadedUntil = state(for: .fixtures).fixtureCoverageEnd ?? Self.loadedFixtureCoverageEnd(
            in: matches,
            minimumDate: initialWindowEnd
        )
        let nextStart = Self.dayOffset(1, from: loadedUntil ?? initialWindowEnd)
        guard nextStart <= overallEnd else { return [] }

        var ranges: [ClosedRange<Date>] = []
        var cursor = nextStart
        while cursor <= overallEnd {
            let end = min(
                Self.dayOffset(fixturesLazyBatchDays - 1, from: cursor),
                overallEnd
            )
            ranges.append(cursor...end)
            cursor = Self.dayOffset(1, from: end)
        }
        return ranges
    }

    private func resolvedSnapshot(for fallback: PreferencesSnapshot) -> PreferencesSnapshot {
        guard let snapshot = currentSnapshot, snapshot.apiBaseURL == fallback.apiBaseURL else {
            return fallback
        }
        return snapshot
    }

    private static func loadFixtureRange(
        _ range: ClosedRange<Date>?,
        preferences: PreferencesSnapshot,
        baseURL: URL,
        pageSize: Int
    ) async throws -> FixtureRangeLoadResult? {
        guard let range else { return nil }
        let client = APIClient(baseURL: baseURL)
        let startedAt = Date()

        let response = try await client.fetchMatchesInRange(
            preferences: preferences,
            mode: .fixtures,
            startDate: range.lowerBound,
            endDate: range.upperBound,
            pageSize: pageSize,
            includePreferenceFilters: false,
            hydrateStates: false
        )

        var matches = response.matches
        #if !DEBUG
        matches = matches.filter { $0.isTestMatch != true }
        #endif

        return FixtureRangeLoadResult(
            range: range,
            matches: matches,
            lastUpdated: response.lastUpdated ?? Date(),
            durationMs: Int(Date().timeIntervalSince(startedAt) * 1000)
        )
    }

    private func reconcileServerCacheStateIfNeeded(client: APIClient, force: Bool = false) async {
        guard shouldRefreshCacheState(force: force) else { return }
        let signpost = PerformanceSignposter.matches.beginInterval("MatchesCacheStateRefresh")
        defer { PerformanceSignposter.matches.endInterval("MatchesCacheStateRefresh", signpost) }
        do {
            let serverState = try await client.fetchCacheState()
            cacheStateLastFetchedAt = Date()
            applyCacheInvalidation(MatchCache.applyServerCacheState(serverState))
        } catch {
            NSLog("Cache state refresh failed error=%@", String(describing: error))
        }
    }

    private func shouldRefreshCacheState(force: Bool = false, now: Date = Date()) -> Bool {
        if force { return true }
        guard let last = cacheStateLastFetchedAt else { return true }
        return now.timeIntervalSince(last) >= cacheStateRefreshInterval
    }

    private func applyCacheInvalidation(_ invalidation: CacheInvalidationResult) {
        guard invalidation.hasChanges else { return }

        if invalidation.shouldClearMatchCaches {
            MatchCache.clear()
            SharedMatchesBridge.clear()
            fixturesBackgroundLoadTask?.cancel()
            fixturesBackgroundLoadTask = nil
            // Reset pagination state but keep in-memory matches visible until fresh data arrives.
            // Clearing modeStates here would blank the UI and force a full-screen spinner even
            // though the user has perfectly usable cached data. The incoming fetchPage (reset: true)
            // will replace this data via mergeRefreshedMatches once the first page returns.
            for key in modeStates.keys {
                var state = modeStates[key] ?? ModeState()
                state.page = 0
                state.hasMore = true
                state.fixtureCoverageEnd = nil
                state.isUsingCache = false
                modeStates[key] = state
            }
        }

        if invalidation.shouldClearBbcLiveCache {
            cachedBbcLiveMatches = []
            bbcLiveLastFetchedAt = nil
            bbcLiveRefreshTask?.cancel()
            bbcLiveRefreshTask = nil
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

        bbcLiveRefreshTask = Task { [weak self] in
            guard let self else { return }
            let fresh = (try? await client.fetchBbcLiveMatches()) ?? []
            if !fresh.isEmpty {
                self.cachedBbcLiveMatches = fresh
            }
            self.bbcLiveLastFetchedAt = Date()
            self.bbcLiveRefreshTask = nil
            self.rescoreVisibleFixtures()
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
        guard !fixtureState.unfilteredMatches.isEmpty else { return }
        let snapshot = currentSnapshot ?? PreferencesStore.loadSnapshot()
        fixtureState.matches = visibleMatches(
            from: fixtureState.unfilteredMatches,
            snapshot: snapshot,
            mode: .fixtures
        )
        fixtureState.groupedMatches = []
        fixtureState.groupedMatchesRevision = nil
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
        let deduplicatedCachedMatches = Self.deduplicatedMatches(cachedMatches)
        let unfilteredFixtures = Self.storageMatches(deduplicatedCachedMatches, for: .fixtures)
        let unfilteredResults = Self.storageMatches(deduplicatedCachedMatches, for: .results)

        var fixtureState = ModeState()
        fixtureState.unfilteredMatches = Self.sortedMatches(unfilteredFixtures)
        fixtureState.matches = visibleMatches(
            from: fixtureState.unfilteredMatches,
            snapshot: snapshot,
            mode: .fixtures
        )
        fixtureState.groupedMatches = []
        fixtureState.groupedMatchesRevision = nil
        fixtureState.lastUpdated = payload.lastUpdated
        fixtureState.fixtureCoverageEnd = payload.fixtureCoverageEnd
        fixtureState.isUsingCache = true

        var resultState = ModeState()
        resultState.unfilteredMatches = Self.sortedMatches(unfilteredResults, descendingDates: true)
        resultState.matches = visibleMatches(
            from: resultState.unfilteredMatches,
            snapshot: snapshot,
            mode: .results
        )
        resultState.groupedMatches = []
        resultState.groupedMatchesRevision = nil
        resultState.lastUpdated = payload.lastUpdated
        resultState.isUsingCache = true

        modeStates = [.fixtures: fixtureState, .results: resultState]
        bbcLiveLastFetchedAt = nil
        publishState(for: activeMode)
        scheduleCachePersistence(
            visibleMatchCollections: modeStates.values.map(\.matches),
            unfilteredMatchCollections: modeStates.values.map(\.unfilteredMatches),
            latestUpdated: payload.lastUpdated,
            fixtureCoverageEnd: payload.fixtureCoverageEnd,
            snapshot: snapshot,
            syncSharedBridge: true
        )
    }

    private func persistCombinedCacheAndSync(snapshot: PreferencesSnapshot) {
        let visibleCollections = modeStates.values.map(\.matches)
        let unfilteredCollections = modeStates.values.map(\.unfilteredMatches)
        let latestUpdated = latestLastUpdatedAcrossModes()
        let fixtureCoverageEnd = state(for: .fixtures).fixtureCoverageEnd
        scheduleCachePersistence(
            visibleMatchCollections: visibleCollections,
            unfilteredMatchCollections: unfilteredCollections,
            latestUpdated: latestUpdated,
            fixtureCoverageEnd: fixtureCoverageEnd,
            snapshot: snapshot,
            syncSharedBridge: true
        )
    }

    private func refreshTeamRatingLookup(apiBaseURL: String) {
        teamRankingsRefreshTask?.cancel()
        teamRankingsRefreshTask = Task { [weak self] in
            if let self, self.teamRankingsRefreshDelayNanos > 0 {
                try? await Task.sleep(nanoseconds: self.teamRankingsRefreshDelayNanos)
            }
            guard !Task.isCancelled else { return }

            let cachedSettings = await TeamRankingSettingsCatalog.shared.settings()
            let cachedEntries = await TeamRankingsCatalog.shared.cachedEntries()
            self?.applyTeamRatingSnapshot(
                entries: cachedEntries,
                defaultElo: cachedSettings.defaultElo
            )

            async let settingsRefresh: Void = TeamRankingSettingsCatalog.shared.ensureFresh(
                apiBaseURL: apiBaseURL
            )
            async let rankingsRefresh: Void = TeamRankingsCatalog.shared.ensureFresh(
                apiBaseURL: apiBaseURL
            )
            _ = await (settingsRefresh, rankingsRefresh)
            guard !Task.isCancelled else { return }

            let refreshedSettings = await TeamRankingSettingsCatalog.shared.settings()
            let refreshedEntries = await TeamRankingsCatalog.shared.cachedEntries()
            self?.applyTeamRatingSnapshot(
                entries: refreshedEntries,
                defaultElo: refreshedSettings.defaultElo
            )
        }
    }

    private func applyTeamRatingSnapshot(entries: [TeamRankingEntry], defaultElo: Double) {
        guard entries != lastAppliedTeamRankingEntries ||
                abs(defaultElo - lastAppliedTeamRatingDefaultElo) > 0.0001 else {
            return
        }
        lastAppliedTeamRankingEntries = entries
        lastAppliedTeamRatingDefaultElo = defaultElo
        let nextLookup = TeamRatingLookup(entries: entries, defaultPoints: defaultElo)
        teamRatingLookup = nextLookup
        groupingRevision &+= 1
        publishState(for: activeMode)
    }

    func teamRatingDebugText(for match: Match) -> String {
        let homeRating = teamRatingLookup.resolveRating(for: match.homeTeam)
        let awayRating = teamRatingLookup.resolveRating(for: match.awayTeam)
        let totalRating = homeRating.rating + awayRating.rating
        let homeText = "\(Int(homeRating.rating.rounded()))\(homeRating.usedDefault ? "*" : "")"
        let awayText = "\(Int(awayRating.rating.rounded()))\(awayRating.usedDefault ? "*" : "")"
        return "Elo \(homeText) + \(awayText) = \(Int(totalRating.rounded()))"
    }

    private func latestLastUpdatedAcrossModes() -> Date? {
        let updates = modeStates.values.compactMap(\.lastUpdated)
        return updates.max()
    }

    private func combinedLoadedMatches() -> [Match] {
        let allMatches = modeStates.values.flatMap(\.matches)
        return Self.deduplicatedMatches(Self.mergePages(existing: [], incoming: allMatches))
    }

    private func combinedUnfilteredMatches() -> [Match] {
        let allMatches = modeStates.values.flatMap(\.unfilteredMatches)
        return Self.deduplicatedMatches(Self.mergePages(existing: [], incoming: allMatches))
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
        let signpost = PerformanceSignposter.matches.beginInterval("MatchesPublishState")
        defer { PerformanceSignposter.matches.endInterval("MatchesPublishState", signpost) }

        activeMode = mode
        let current = state(for: mode)
        guard visibleModes.contains(mode) else { return }

        matches = current.matches
        isLoading = current.isLoading
        errorMessage = current.errorMessage
        lastUpdated = current.lastUpdated
        isUsingCache = current.isUsingCache

        // Cancel any previous grouping task so stale results can't overwrite newer ones.
        groupingTask?.cancel()
        groupingTaskID = nil
        if current.groupedMatchesRevision == groupingRevision {
            groupedMatches = current.groupedMatches
            return
        }

        let matchesToGroup = current.matches
        if matchesToGroup.isEmpty {
            groupedMatches = []
            var emptyState = current
            emptyState.groupedMatches = []
            emptyState.groupedMatchesRevision = groupingRevision
            modeStates[mode] = emptyState
            return
        }

        let descendingDates = (mode == .results)
        let sortOrder = currentSnapshot?.matchGroupSortOrder ?? PreferencesStore.defaultMatchGroupSortOrder
        let premierLeagueMatchesFirst = currentSnapshot?.premierLeagueMatchesFirst ?? PreferencesStore.defaultPremierLeagueMatchesFirst
        let ratingLookup = teamRatingLookup
        let groupingRevisionAtStart = groupingRevision
        let taskID = UUID()
        groupingTaskID = taskID
        groupingTask = Task.detached(priority: .userInitiated) { [weak self] in
            let signpost = PerformanceSignposter.matches.beginInterval("MatchesGroupMatches")
            defer { PerformanceSignposter.matches.endInterval("MatchesGroupMatches", signpost) }

            let startedAt = Date()
            let grouped = MatchGroupingEngine.groupMatches(
                matchesToGroup,
                descendingDates: descendingDates,
                sortOrder: sortOrder,
                ratingLookup: ratingLookup,
                premierLeagueMatchesFirst: premierLeagueMatchesFirst
            )
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      self.groupingTaskID == taskID,
                      self.groupingRevision == groupingRevisionAtStart,
                      self.activeMode == mode,
                      self.visibleModes.contains(mode) else { return }
                if durationMs >= 100 {
                    MatchesStore.log(
                        "grouping_complete mode=\(mode.rawValue) matches=\(matchesToGroup.count) days=\(grouped.count) duration_ms=\(durationMs)"
                    )
                }
                var cachedState = self.state(for: mode)
                cachedState.groupedMatches = grouped
                cachedState.groupedMatchesRevision = groupingRevisionAtStart
                self.modeStates[mode] = cachedState
                self.groupedMatches = grouped
            }
        }

        if let snapshot = currentSnapshot {
            let allMatches = combinedLoadedMatches()
            Task {
                await AppIconBadgeManager.update(preferences: snapshot, matches: allMatches)
            }
        }
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
                if self.activeMode != .results {
                    await self.refresh(preferences: snapshot, mode: .results)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private nonisolated static func mergePages(existing: [Match], incoming: [Match]) -> [Match] {
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

    private nonisolated static func deduplicatedMatches(_ matches: [Match]) -> [Match] {
        var deduplicated: [Match] = []
        var indicesByIdentity: [String: Int] = [:]

        for match in matches {
            let identities = matchIdentityKeys(for: match)
            let existingIndex = identities.compactMap { indicesByIdentity[$0] }.first

            if let existingIndex {
                let preferred = preferredMatch(existing: deduplicated[existingIndex], incoming: match)
                deduplicated[existingIndex] = preferred
                for key in matchIdentityKeys(for: preferred) {
                    indicesByIdentity[key] = existingIndex
                }
            } else {
                let nextIndex = deduplicated.count
                deduplicated.append(match)
                for key in identities {
                    indicesByIdentity[key] = nextIndex
                }
            }
        }

        return deduplicated
    }

    private nonisolated static func matchIdentityKeys(for match: Match) -> [String] {
        var keys: [String] = []
        if let matchDetailsID = match.matchDetailsID, !matchDetailsID.isEmpty {
            keys.append("match:\(matchDetailsID)")
        }

        let homeTeamKey = TeamIdentityStore.normalizedKey(
            TeamIdentityStore.shared.canonicalName(for: match.homeTeam)
        )
        let awayTeamKey = TeamIdentityStore.normalizedKey(
            TeamIdentityStore.shared.canonicalName(for: match.awayTeam)
        )
        let normalizedTime = match.time.trimmingCharacters(in: .whitespacesAndNewlines)

        if !match.date.isEmpty, !homeTeamKey.isEmpty, !awayTeamKey.isEmpty {
            keys.append("fixture:\(match.date)|\(homeTeamKey)|\(awayTeamKey)")
            if !normalizedTime.isEmpty {
                keys.append("fixture_time:\(match.date)|\(normalizedTime)|\(homeTeamKey)|\(awayTeamKey)")
            }
        }

        keys.append("row:\(match.id)")
        return Array(Set(keys))
    }

    nonisolated static func mergeRefreshedMatches(existing: [Match], incoming: [Match]) -> [Match] {
        guard !existing.isEmpty else { return incoming }

        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        return incoming.map { incomingMatch in
            guard let existingMatch = existingByID[incomingMatch.id] else {
                return incomingMatch
            }
            return preferredMatch(existing: existingMatch, incoming: incomingMatch)
        }
    }

    private nonisolated static func preferredMatch(existing: Match, incoming: Match) -> Match {
        if hasRicherKnockoutMetadata(incoming, than: existing) {
            return incoming
        }
        if hasRicherKnockoutMetadata(existing, than: incoming) {
            return existing
        }

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
        if incoming.isUpcomingScorelessFixture && !existing.isUpcomingScorelessFixture {
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

    private nonisolated static func hasRicherKnockoutMetadata(_ lhs: Match, than rhs: Match) -> Bool {
        if lhs.penaltyResult != nil && rhs.penaltyResult == nil {
            return true
        }
        if lhs.hasDisplayableAggregateScore && !rhs.hasDisplayableAggregateScore {
            return true
        }
        return false
    }

    private nonisolated static func normalizedStatus(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value.uppercased()
    }

    private static let homeNationsTeamKeys: Set<String> = [
        "England",
        "Northern Ireland",
        "Scotland",
        "Wales",
    ].map(TeamIdentityStore.normalizedKey).reduce(into: Set<String>()) { partialResult, key in
        if !key.isEmpty {
            partialResult.insert(key)
        }
    }

    fileprivate static let premierLeagueTeamKeys: Set<String> = [
        "Arsenal",
        "Aston Villa",
        "Bournemouth",
        "AFC Bournemouth",
        "Brentford",
        "Brighton",
        "Brighton and Hove Albion",
        "Brighton & Hove Albion",
        "Burnley",
        "Chelsea",
        "Crystal Palace",
        "Everton",
        "Fulham",
        "Leeds",
        "Leeds United",
        "Liverpool",
        "Manchester City",
        "Man City",
        "Manchester United",
        "Man United",
        "Newcastle",
        "Newcastle United",
        "Nottingham Forest",
        "Nottm Forest",
        "Sunderland",
        "Tottenham",
        "Tottenham Hotspur",
        "Spurs",
        "West Ham",
        "West Ham United",
        "Wolverhampton Wanderers",
        "Wolves",
    ].map(TeamIdentityStore.normalizedKey).reduce(into: Set<String>()) { partialResult, key in
        if !key.isEmpty {
            partialResult.insert(key)
        }
    }

    static func filterMatches(_ matches: [Match], for mode: MatchesViewMode) -> [Match] {
        let calendar = Calendar.current
        let today = startOfToday()
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

    private nonisolated static func storageMatches(_ matches: [Match], for mode: MatchesViewMode) -> [Match] {
        let calendar = Calendar.current
        let today = startOfToday()
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

    static func applyPreferenceFilters(
        to matches: [Match],
        snapshot: PreferencesSnapshot,
        mode: MatchesViewMode
    ) -> [Match] {
        let safeguarded = applyCompetitionScrapeSafeguards(to: matches)
        let competitionFiltered = applyCompetitionFilters(
            to: safeguarded,
            selectedLeagues: snapshot.selectedLeagues,
            isEnabled: snapshot.competitionFilterEnabled,
            englishPremierLeagueTeamsOnly: snapshot.effectiveEnglishPremierLeagueTeamsOnly,
            majorUEFAClubGamesEnabled: snapshot.effectiveMajorUEFAClubGamesEnabled,
            homeNationsFilterEnabled: snapshot.effectiveHomeNationsFilterEnabled,
            majorTournamentsFilterEnabled: snapshot.effectiveMajorTournamentsFilterEnabled
        )
        let dateFiltered = filterMatches(competitionFiltered, for: mode)
        guard mode == .fixtures, snapshot.channelFilterEnabled else { return dateFiltered }
        return applyChannelFilters(to: dateFiltered, selectedChannels: snapshot.selectedChannels)
    }

    private static func applyCompetitionScrapeSafeguards(to matches: [Match]) -> [Match] {
        matches.filter { match in
            CompetitionWeightConfig.isAllowedCompetitionForPublicDisplay(match.league)
        }
    }

    private final class MatchSortMemo: @unchecked Sendable {
        private nonisolated(unsafe) var datesByMatchID: [String: Date] = [:]
        private nonisolated(unsafe) var weightsByMatchID: [String: Double] = [:]

        nonisolated init() {}

        nonisolated func sortDate(for match: Match) -> Date {
            if let cached = datesByMatchID[match.id] {
                return cached
            }
            let resolved = MatchGroupingEngine.matchSortDate(for: match)
            datesByMatchID[match.id] = resolved
            return resolved
        }

        nonisolated func competitionWeight(for match: Match) -> Double {
            if let cached = weightsByMatchID[match.id] {
                return cached
            }
            let resolved = MatchGroupingEngine.competitionWeight(for: match)
            weightsByMatchID[match.id] = resolved
            return resolved
        }
    }

    private nonisolated static func sortedMatches(_ matches: [Match], descendingDates: Bool = false) -> [Match] {
        let memo = MatchSortMemo()
        return matches.sorted { lhs, rhs in
            let leftDate = memo.sortDate(for: lhs)
            let rightDate = memo.sortDate(for: rhs)
            if leftDate != rightDate {
                return descendingDates ? leftDate > rightDate : leftDate < rightDate
            }

            let leftWeight = memo.competitionWeight(for: lhs)
            let rightWeight = memo.competitionWeight(for: rhs)
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
        isEnabled: Bool,
        englishPremierLeagueTeamsOnly: Bool = false,
        majorUEFAClubGamesEnabled: Bool = false,
        homeNationsFilterEnabled: Bool = false,
        majorTournamentsFilterEnabled: Bool = false
    ) -> [Match] {
        let selected = Set(selectedLeagues.map(CompetitionWeightConfig.canonicalFilterName))
        let hasLeagueFilter = isEnabled && !selected.isEmpty
        let hasCategoryFilters =
            englishPremierLeagueTeamsOnly ||
            majorUEFAClubGamesEnabled ||
            homeNationsFilterEnabled ||
            majorTournamentsFilterEnabled

        guard hasLeagueFilter || hasCategoryFilters else { return matches }

        return matches.filter { match in
            let matchesSelectedLeague =
                !hasLeagueFilter ||
                selected.contains(CompetitionWeightConfig.canonicalFilterName(match.league))
            guard matchesSelectedLeague else { return false }

            guard hasCategoryFilters else { return true }
            return matchPassesCompetitionCategoryFilters(
                match,
                englishPremierLeagueTeamsOnly: englishPremierLeagueTeamsOnly,
                majorUEFAClubGamesEnabled: majorUEFAClubGamesEnabled,
                homeNationsFilterEnabled: homeNationsFilterEnabled,
                majorTournamentsFilterEnabled: majorTournamentsFilterEnabled
            )
        }
    }

    private static func matchPassesCompetitionCategoryFilters(
        _ match: Match,
        englishPremierLeagueTeamsOnly: Bool,
        majorUEFAClubGamesEnabled: Bool,
        homeNationsFilterEnabled: Bool,
        majorTournamentsFilterEnabled: Bool
    ) -> Bool {
        let includesHomeNation = matchIncludesHomeNation(match)
        let isMajorTournament = matchIsMajorTournament(match)

        if matchIsInternationalCompetition(match) {
            let includeAsMajorTournament = isMajorTournament && majorTournamentsFilterEnabled
            let includeAsHomeNation = includesHomeNation && homeNationsFilterEnabled
            return includeAsMajorTournament || includeAsHomeNation
        }

        if majorUEFAClubGamesEnabled && matchIsMajorUEFAClubKnockoutFixture(match) {
            return true
        }

        return !englishPremierLeagueTeamsOnly || matchIncludesPremierLeagueTeam(match)
    }

    private static func matchIncludesPremierLeagueTeam(_ match: Match) -> Bool {
        let homeKeys = TeamIdentityStore.shared.normalizedKeys(for: match.homeTeam)
        let awayKeys = TeamIdentityStore.shared.normalizedKeys(for: match.awayTeam)
        return !homeKeys.isDisjoint(with: premierLeagueTeamKeys) ||
            !awayKeys.isDisjoint(with: premierLeagueTeamKeys)
    }

    private static func matchIncludesHomeNation(_ match: Match) -> Bool {
        let homeKeys = TeamIdentityStore.shared.normalizedKeys(for: match.homeTeam)
        let awayKeys = TeamIdentityStore.shared.normalizedKeys(for: match.awayTeam)
        return !homeKeys.isDisjoint(with: homeNationsTeamKeys) ||
            !awayKeys.isDisjoint(with: homeNationsTeamKeys)
    }

    private static func matchIsMajorTournament(_ match: Match) -> Bool {
        let league = CompetitionWeightConfig.normalizeCompetitionName(match.league)
        let subcategory = CompetitionWeightConfig.normalizeCompetitionName(match.leagueSubcategory ?? "")
        guard !league.isEmpty else { return false }
        if league.range(of: #"\bqualif(?:ying|ication)\b"#, options: .regularExpression) != nil ||
            subcategory.range(of: #"\bqualif(?:ying|ication)\b"#, options: .regularExpression) != nil {
            return false
        }

        return league.range(
            of: #"^(?:fifa world cup(?:\s+\d{4})?|(?:uefa\s+)?european championship(?:\s+\d{4})?|(?:uefa\s+)?euro(?:\s+\d{4})?)$"#,
            options: .regularExpression
        ) != nil
    }

    private static func matchIsInternationalCompetition(_ match: Match) -> Bool {
        let league = CompetitionWeightConfig.normalizeCompetitionName(match.league)
        let subcategory = CompetitionWeightConfig.normalizeCompetitionName(match.leagueSubcategory ?? "")
        guard !league.isEmpty else { return false }

        let internationalPatterns = [
            #"\bfifa\b"#,
            #"\bworld cup\b"#,
            #"\beuropean championship\b"#,
            #"^(?:uefa\s+)?euro(?:\s+\d{4})?$"#,
            #"\bnations league\b"#,
            #"\bqualif(?:ying|ication)\b"#,
            #"\bfriendly\b"#,
            #"\binternational\b"#
        ]

        for pattern in internationalPatterns {
            if league.range(of: pattern, options: .regularExpression) != nil ||
                subcategory.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }

        if matchIncludesHomeNation(match) {
            return true
        }

        return false
    }

    private static func matchIsMajorUEFAClubKnockoutFixture(_ match: Match) -> Bool {
        let league = CompetitionWeightConfig.canonicalFilterName(match.league)
        let normalizedLeague = CompetitionWeightConfig.normalizeCompetitionName(match.league)
        let subcategory = CompetitionWeightConfig.normalizeCompetitionName(match.leagueSubcategory ?? "")

        let majorUEFAClubCompetitions: Set<String> = [
            "uefa champions league",
            "uefa europa league",
            "uefa conference league"
        ]

        guard majorUEFAClubCompetitions.contains(league) else { return false }
        let descriptor = [normalizedLeague, subcategory]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !descriptor.isEmpty else { return false }

        return descriptor.range(
            of: #"\b(?:quarter(?:\s|-)?finals?|semi(?:\s|-)?finals?|final)\b"#,
            options: .regularExpression
        ) != nil
    }

    private nonisolated static func replacingMatches(
        in existing: [Match],
        with incoming: [Match],
        within range: ClosedRange<Date>
    ) -> [Match] {
        let preserved = existing.filter { !matchesDate($0, within: range) }
        return mergePages(existing: preserved, incoming: incoming)
    }

    private nonisolated static func matchesDate(_ match: Match, within range: ClosedRange<Date>) -> Bool {
        guard let date = match.dateOnly.map({ Calendar.current.startOfDay(for: $0) }) else {
            return false
        }
        return range.contains(date)
    }

    private nonisolated static func loadedFixtureCoverageEnd(
        in matches: [Match],
        minimumDate: Date
    ) -> Date? {
        let fixtureDates = storageMatches(matches, for: .fixtures)
            .compactMap(\.dateOnly)
            .map { Calendar.current.startOfDay(for: $0) }
            .filter { $0 >= minimumDate }
        return fixtureDates.max()
    }

    private nonisolated static func startOfToday(now: Date = Date()) -> Date {
        Calendar.current.startOfDay(for: now)
    }

    private nonisolated static func dayOffset(_ value: Int, from date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: value, to: date) ?? date
    }

    private nonisolated static func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (left?, right?):
            return max(left, right)
        case let (left?, nil):
            return left
        case let (nil, right?):
            return right
        case (nil, nil):
            return nil
        }
    }

    private static func snapshotDebugSummary(_ snapshot: PreferencesSnapshot) -> String {
        "competition=\(snapshot.competitionFilterEnabled) leagues=\(snapshot.selectedLeagues.count) " +
        "channels=\(snapshot.channelFilterEnabled) selected_channels=\(snapshot.selectedChannels.count) " +
        "epl=\(snapshot.englishPremierLeagueTeamsOnly)/effective=\(snapshot.effectiveEnglishPremierLeagueTeamsOnly) " +
        "major_uefa=\(snapshot.majorUEFAClubGamesEnabled)/effective=\(snapshot.effectiveMajorUEFAClubGamesEnabled) " +
        "home_nations=\(snapshot.homeNationsFilterEnabled)/effective=\(snapshot.effectiveHomeNationsFilterEnabled) " +
        "major=\(snapshot.majorTournamentsFilterEnabled)/effective=\(snapshot.effectiveMajorTournamentsFilterEnabled) " +
        "show_all=\(snapshot.showAllMatches)"
    }

    private static func matchSample(_ matches: [Match], limit: Int = 4) -> String {
        let sample = matches.prefix(limit).map { match in
            "\(match.homeTeam) v \(match.awayTeam) [\(match.league)]"
        }
        return sample.isEmpty ? "[]" : "[\(sample.joined(separator: " | "))]"
    }

    private nonisolated static func formatDateForLog(_ date: Date?) -> String {
        guard let date else { return "nil" }
        let components = Calendar.current.dateComponents(in: TimeZone.current, from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return "nil"
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    nonisolated private static func log(_ message: String) {
        NSLog("[MatchesStore] %@", message)
    }

    private func scheduleCachePersistence(
        visibleMatchCollections: [[Match]],
        unfilteredMatchCollections: [[Match]],
        latestUpdated: Date?,
        fixtureCoverageEnd: Date?,
        snapshot: PreferencesSnapshot,
        syncSharedBridge: Bool
    ) {
        cachePersistTask?.cancel()
        cachePersistTask = Task.detached(priority: .utility) {
            let unfilteredCombined = Self.sortedMatches(
                Self.deduplicatedMatches(
                    Self.mergePages(existing: [], incoming: unfilteredMatchCollections.flatMap { $0 })
                )
            )
            guard !Task.isCancelled, !unfilteredCombined.isEmpty else { return }

            MatchCache.save(
                matches: unfilteredCombined,
                lastUpdated: latestUpdated,
                fixtureCoverageEnd: fixtureCoverageEnd,
                snapshot: snapshot
            )

            guard syncSharedBridge, !Task.isCancelled else { return }

            let combined = Self.sortedMatches(
                Self.deduplicatedMatches(
                    Self.mergePages(existing: [], incoming: visibleMatchCollections.flatMap { $0 })
                )
            )

            guard !Task.isCancelled else { return }
            SharedMatchesBridge.saveAndSync(
                matches: combined,
                unfilteredMatches: unfilteredCombined,
                lastUpdated: latestUpdated,
                snapshot: snapshot
            )
        }
    }

}
