import Observation
import SwiftUI

struct TeamDetailsContext: Hashable, Identifiable, Sendable {
    let teamID: String?
    let teamName: String
    let displayName: String
    let alternateNames: [String]
    let originatingLeagueID: String?
    let originatingLeagueName: String
    let originatingMatch: Match?

    var id: String {
        let teamKey = teamID ?? TeamIdentityStore.normalizedKey(teamName)
        return "\(teamKey)|\(originatingLeagueID ?? originatingLeagueName)|\(originatingMatchID ?? "")"
    }

    var originatingMatchID: String? {
        originatingMatch?.matchDetailsID ?? originatingMatch?.id
    }

    var canonicalName: String {
        let canonical = TeamIdentityStore.shared.canonicalName(for: teamName)
        return canonical.isEmpty ? displayName : canonical
    }
}

struct TeamSeasonStanding: Hashable, Sendable {
    let leagueID: String
    let leagueName: String
    let groupName: String?
    let realtime: Bool
    let row: LeagueTableRow
}

enum TeamDetailsStandingResolver {
    static func resolve(
        context: TeamDetailsContext,
        response: LeagueTablesResponse
    ) -> TeamSeasonStanding? {
        var candidates: [(score: Int, order: Int, standing: TeamSeasonStanding)] = []

        for (tableIndex, table) in response.leagues.enumerated() {
            let topLevelRows = table.rows.map { (groupName: Optional<String>.none, row: $0) }
            let groupedRows = table.groups.flatMap { group in
                group.rows.map { (groupName: group.name, row: $0) }
            }

            for item in topLevelRows + groupedRows {
                guard TeamIdentityStore.shared.matches(item.row.team, context.teamName) else {
                    continue
                }

                var score = 0
                if let leagueID = context.originatingLeagueID,
                   table.leagueID.caseInsensitiveCompare(leagueID) == .orderedSame {
                    score += 2_000
                }
                if table.leagueName.localizedCaseInsensitiveCompare(context.originatingLeagueName) == .orderedSame {
                    score += 1_000
                }

                candidates.append((
                    score: score,
                    order: tableIndex,
                    standing: TeamSeasonStanding(
                        leagueID: table.leagueID,
                        leagueName: table.leagueName,
                        groupName: item.groupName,
                        realtime: table.realtime,
                        row: item.row
                    )
                ))
            }
        }

        return candidates.max { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score < rhs.score
            }
            return lhs.order > rhs.order
        }?.standing
    }
}

enum TeamDetailsMatchStandingResolver {
    static func resolve(
        teamName: String,
        leagueID: String?,
        leagueName: String,
        response: LeagueTablesResponse?
    ) -> TeamSeasonStanding? {
        guard let response else { return nil }

        let nameMatchingTables = response.leagues.filter {
            $0.leagueName.localizedCaseInsensitiveCompare(leagueName) == .orderedSame
        }
        let idMatchingTables = response.leagues.filter { table in
            guard !nameMatchingTables.contains(where: { $0.id == table.id }) else { return false }
            return leagueID.map {
                table.leagueID.caseInsensitiveCompare($0) == .orderedSame
            } ?? false
        }

        for table in nameMatchingTables + idMatchingTables {
            let topLevelRows = table.rows.map { (groupName: Optional<String>.none, row: $0) }
            let groupedRows = table.groups.flatMap { group in
                group.rows.map { (groupName: group.name, row: $0) }
            }
            if let item = (topLevelRows + groupedRows).first(where: {
                TeamIdentityStore.shared.matches($0.row.team, teamName)
            }) {
                return TeamSeasonStanding(
                    leagueID: table.leagueID,
                    leagueName: table.leagueName,
                    groupName: item.groupName,
                    realtime: table.realtime,
                    row: item.row
                )
            }
        }

        return nil
    }
}

enum TeamDetailsSeason {
    static func startDate(containing date: Date, calendar: Calendar = .current) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let year = components.year, let month = components.month else { return date }

        var startComponents = DateComponents()
        startComponents.calendar = calendar
        startComponents.timeZone = calendar.timeZone
        startComponents.year = month >= 7 ? year : year - 1
        startComponents.month = 7
        startComponents.day = 1
        return calendar.date(from: startComponents) ?? date
    }

    static func contains(_ match: Match, asOf date: Date, calendar: Calendar = .current) -> Bool {
        guard let matchDate = match.dateTime ?? match.dateOnly else { return false }
        return matchDate >= startDate(containing: date, calendar: calendar)
    }
}

enum TeamDetailsMatchResolver {
    static func upcomingFixtures(
        context: TeamDetailsContext,
        from matches: [Match],
        limit: Int = 200,
        now: Date = Date()
    ) -> [Match] {
        let authoritativeMatch = context.originatingMatch
        var merged = matches.filter { match in
            guard !match.isFinished, !match.isPostponed else { return false }
            guard let matchDate = match.dateTime ?? match.dateOnly, matchDate >= now else { return false }
            guard let authoritativeMatch else { return true }
            return !isSameMatch(match, as: authoritativeMatch)
        }

        if let authoritativeMatch,
           !authoritativeMatch.isFinished,
           !authoritativeMatch.isPostponed,
           let matchDate = authoritativeMatch.dateTime ?? authoritativeMatch.dateOnly,
           matchDate >= now {
            merged.append(authoritativeMatch)
        }

        let sorted = merged.enumerated().sorted { lhs, rhs in
            let lhsDate = lhs.element.dateTime ?? .distantFuture
            let rhsDate = rhs.element.dateTime ?? .distantFuture
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        return Array(sorted.prefix(max(0, limit)))
    }

    static func previousMatches(
        context: TeamDetailsContext,
        from matches: [Match],
        limit: Int = 200,
        now: Date = Date()
    ) -> [Match] {
        let authoritativeMatch = context.originatingMatch
        var merged = matches.filter { match in
            guard !match.isPostponed else { return false }
            guard TeamDetailsSeason.contains(match, asOf: now) else { return false }
            guard let authoritativeMatch else { return true }
            return !isSameMatch(match, as: authoritativeMatch)
        }

        if let authoritativeMatch,
           authoritativeMatch.isFinished,
           !authoritativeMatch.isPostponed,
           TeamDetailsSeason.contains(authoritativeMatch, asOf: now) {
            merged.append(authoritativeMatch)
        }

        let sorted = merged.enumerated().sorted { lhs, rhs in
            let lhsDate = lhs.element.dateTime ?? .distantPast
            let rhsDate = rhs.element.dateTime ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            if let authoritativeMatch {
                let lhsIsAuthoritative = lhs.element == authoritativeMatch
                let rhsIsAuthoritative = rhs.element == authoritativeMatch
                if lhsIsAuthoritative != rhsIsAuthoritative {
                    return lhsIsAuthoritative
                }
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        return Array(sorted.prefix(max(0, limit)))
    }

    private static func isSameMatch(_ candidate: Match, as authoritative: Match) -> Bool {
        if let candidateID = candidate.matchDetailsID,
           let authoritativeID = authoritative.matchDetailsID,
           candidateID == authoritativeID {
            return true
        }
        if candidate.id == authoritative.id {
            return true
        }
        return candidate.date == authoritative.date &&
            TeamIdentityStore.shared.matches(candidate.homeTeam, authoritative.homeTeam) &&
            TeamIdentityStore.shared.matches(candidate.awayTeam, authoritative.awayTeam)
    }
}

enum TeamDetailsPagination {
    static let collapsedCount = 10

    static func visibleMatches(_ matches: [Match], showsAll: Bool) -> [Match] {
        showsAll ? matches : Array(matches.prefix(collapsedCount))
    }
}

enum TeamDetailsFormResolver {
    static func recentForm(
        teamName: String,
        leagueID: String? = nil,
        leagueName: String? = nil,
        matches: [Match],
        now: Date = Date()
    ) -> [String] {
        matches.filter { match in
            let involvesTeam = TeamIdentityStore.shared.matches(match.homeTeam, teamName) ||
                TeamIdentityStore.shared.matches(match.awayTeam, teamName)
            let matchesLeagueID = leagueID.map { expectedID in
                match.leagueId?.caseInsensitiveCompare(expectedID) == .orderedSame
            } ?? false
            let matchesLeagueName = leagueName.map { expectedName in
                match.league.localizedCaseInsensitiveCompare(expectedName) == .orderedSame
            } ?? false
            let matchesCompetition = (leagueID == nil && leagueName == nil) ||
                matchesLeagueID || matchesLeagueName
            return involvesTeam &&
                matchesCompetition &&
                match.isFinished &&
                match.hasScore &&
                !match.isPostponed &&
                TeamDetailsSeason.contains(match, asOf: now)
        }
        .sorted {
            ($0.dateTime ?? .distantPast) > ($1.dateTime ?? .distantPast)
        }
        .prefix(5)
        .compactMap { match -> String? in
            guard let homeScore = match.homeScore, let awayScore = match.awayScore else { return nil }
            if homeScore == awayScore {
                return "D"
            }
            let teamIsHome = TeamIdentityStore.shared.matches(match.homeTeam, teamName)
            let teamWon = teamIsHome ? homeScore > awayScore : awayScore > homeScore
            return teamWon ? "W" : "L"
        }
    }

    static func recentForm(
        context: TeamDetailsContext,
        standing: TeamSeasonStanding,
        matches: [Match],
        now: Date = Date()
    ) -> [String] {
        let derived = recentForm(teamName: context.teamName, matches: matches, now: now)

        if !derived.isEmpty {
            return derived
        }

        let fallbackCount = min(5, max(0, standing.row.played))
        return Array(standing.row.form.prefix(fallbackCount))
    }
}

struct TeamDetailsMatchRowFormRequest: Hashable, Sendable {
    let teamName: String
    let leagueID: String?
    let leagueName: String

    var key: String {
        TeamDetailsMatchRowFormResolver.key(
            for: teamName,
            leagueID: leagueID,
            leagueName: leagueName
        )
    }
}

enum TeamDetailsMatchRowFormResolver {
    static func key(for teamName: String, leagueID: String?, leagueName: String) -> String {
        let teamKey = TeamIdentityStore.normalizedKey(teamName)
        let leagueNameKey = TeamIdentityStore.normalizedKey(leagueName)
        let competitionKey = leagueNameKey.isEmpty ? (leagueID ?? "") : leagueNameKey
        return "\(teamKey)|\(competitionKey.lowercased())"
    }

    static func form(
        for teamName: String,
        leagueID: String?,
        leagueName: String,
        viewedTeamName: String,
        viewedTeamForm: [String]?,
        resolvedFormsByRequestKey: [String: [String]]
    ) -> [String] {
        if TeamIdentityStore.shared.matches(teamName, viewedTeamName),
           let viewedTeamForm {
            return viewedTeamForm
        }
        return resolvedFormsByRequestKey[key(
            for: teamName,
            leagueID: leagueID,
            leagueName: leagueName
        )] ?? []
    }
}

private actor TeamMatchesCatalog {
    static let shared = TeamMatchesCatalog()

    private struct CacheEntry: Sendable {
        let matches: [Match]
        let fetchedAt: Date
    }

    private static let cacheTTL: TimeInterval = 5 * 60
    private var entries: [String: CacheEntry] = [:]

    func cachedMatches(teamName: String, mode: MatchesViewMode, apiBaseURL: String) -> [Match]? {
        entries[cacheKey(teamName: teamName, mode: mode, apiBaseURL: apiBaseURL)]?.matches
    }

    func matches(
        teamName: String,
        mode: MatchesViewMode,
        apiBaseURL: String,
        force: Bool,
        limit: Int = 200
    ) async throws -> [Match] {
        let key = cacheKey(teamName: teamName, mode: mode, apiBaseURL: apiBaseURL)
        if !force,
           let cached = entries[key],
           Date().timeIntervalSince(cached.fetchedAt) < Self.cacheTTL {
            return cached.matches
        }
        guard let baseURL = URL(string: apiBaseURL) else {
            throw LeagueTablesCatalogError.invalidBaseURL(apiBaseURL)
        }

        let client = APIClient(baseURL: baseURL)
        let matches: [Match]
        switch mode {
        case .fixtures:
            matches = try await client.fetchTeamFixtures(teamName: teamName, limit: limit).matches
        case .results:
            matches = try await client.fetchTeamResults(teamName: teamName, limit: limit).matches
        }
        try Task.checkCancellation()
        entries[key] = CacheEntry(matches: matches, fetchedAt: Date())
        return matches
    }

    private func cacheKey(teamName: String, mode: MatchesViewMode, apiBaseURL: String) -> String {
        "\(apiBaseURL)|\(mode.rawValue)|\(TeamIdentityStore.normalizedKey(teamName))"
    }
}

@MainActor
@Observable
private final class TeamDetailsViewModel {
    private(set) var standing: TeamSeasonStanding?
    private(set) var tablesResponse: LeagueTablesResponse?
    private(set) var upcomingFixtures: [Match] = []
    private(set) var previousMatches: [Match] = []
    private(set) var matchRowFormsByRequestKey: [String: [String]] = [:]
    private(set) var isLoadingStanding = true
    private(set) var isLoadingMatches = true
    private(set) var standingErrorMessage: String?
    private(set) var matchesErrorMessage: String?

    private var activeLoadKey: String?

    func load(
        context: TeamDetailsContext,
        apiBaseURL: String,
        force: Bool = false
    ) async {
        let loadKey = "\(context.id)|\(apiBaseURL)"
        if activeLoadKey != loadKey {
            activeLoadKey = loadKey
            standing = nil
            tablesResponse = nil
            upcomingFixtures = TeamDetailsMatchResolver.upcomingFixtures(
                context: context,
                from: []
            )
            previousMatches = TeamDetailsMatchResolver.previousMatches(
                context: context,
                from: []
            )
            matchRowFormsByRequestKey = [:]
            standingErrorMessage = nil
            matchesErrorMessage = nil
        }

        if !force {
            if let cachedTables = await LeagueTablesCatalog.shared.cachedResponse(apiBaseURL: apiBaseURL) {
                tablesResponse = cachedTables
                standing = TeamDetailsStandingResolver.resolve(context: context, response: cachedTables)
            }
            if let cachedFixtures = await TeamMatchesCatalog.shared.cachedMatches(
                teamName: context.teamName,
                mode: .fixtures,
                apiBaseURL: apiBaseURL
            ) {
                upcomingFixtures = TeamDetailsMatchResolver.upcomingFixtures(
                    context: context,
                    from: cachedFixtures
                )
            }
            if let cachedMatches = await TeamMatchesCatalog.shared.cachedMatches(
                teamName: context.teamName,
                mode: .results,
                apiBaseURL: apiBaseURL
            ) {
                previousMatches = TeamDetailsMatchResolver.previousMatches(
                    context: context,
                    from: cachedMatches
                )
            }
        }

        isLoadingStanding = standing == nil
        isLoadingMatches = upcomingFixtures.isEmpty && previousMatches.isEmpty
        standingErrorMessage = nil
        matchesErrorMessage = nil

        async let standingOutcome = Self.fetchStanding(
            context: context,
            apiBaseURL: apiBaseURL,
            force: force
        )
        async let matchesOutcome = Self.fetchMatches(
            context: context,
            apiBaseURL: apiBaseURL,
            force: force
        )
        let (resolvedStanding, resolvedMatches) = await (standingOutcome, matchesOutcome)

        guard !Task.isCancelled, activeLoadKey == loadKey else { return }

        if let value = resolvedStanding.value {
            standing = value
        }
        if let response = resolvedStanding.response {
            tablesResponse = response
        }
        standingErrorMessage = resolvedStanding.errorMessage
        isLoadingStanding = false

        if let value = resolvedMatches.value {
            upcomingFixtures = value.fixtures
            previousMatches = value.results
        }
        matchesErrorMessage = resolvedMatches.errorMessage
        isLoadingMatches = false
    }

    func loadMatchRowForms(
        requests: [TeamDetailsMatchRowFormRequest],
        apiBaseURL: String,
        now: Date = Date()
    ) async {
        var seenKeys = Set<String>()
        let missingRequests = requests.filter { request in
            guard !request.key.isEmpty, seenKeys.insert(request.key).inserted else { return false }
            return matchRowFormsByRequestKey[request.key] == nil
        }
        guard !missingRequests.isEmpty,
              let baseURL = URL(string: apiBaseURL) else { return }

        do {
            let matches = try await APIClient(baseURL: baseURL).fetchTeamResults(
                teamNames: missingRequests.map(\.teamName),
                since: TeamDetailsSeason.startDate(containing: now),
                now: now
            ).matches
            try Task.checkCancellation()

            for request in missingRequests {
                matchRowFormsByRequestKey[request.key] =
                    TeamDetailsFormResolver.recentForm(
                        teamName: request.teamName,
                        leagueID: request.leagueID,
                        leagueName: request.leagueName,
                        matches: matches,
                        now: now
                    )
            }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            // Missing form is preferable to presenting stale prior-season data.
        }
    }

    private static func fetchStanding(
        context: TeamDetailsContext,
        apiBaseURL: String,
        force: Bool
    ) async -> StandingOutcome {
        do {
            let response = try await LeagueTablesCatalog.shared.refresh(
                apiBaseURL: apiBaseURL,
                force: force
            )
            return StandingOutcome(
                value: TeamDetailsStandingResolver.resolve(context: context, response: response),
                response: response,
                errorMessage: nil
            )
        } catch is CancellationError {
            return StandingOutcome(value: nil, response: nil, errorMessage: nil)
        } catch {
            return StandingOutcome(value: nil, response: nil, errorMessage: error.localizedDescription)
        }
    }

    private static func fetchMatches(
        context: TeamDetailsContext,
        apiBaseURL: String,
        force: Bool
    ) async -> MatchesOutcome {
        do {
            async let fixtures = TeamMatchesCatalog.shared.matches(
                teamName: context.teamName,
                mode: .fixtures,
                apiBaseURL: apiBaseURL,
                force: force
            )
            async let results = TeamMatchesCatalog.shared.matches(
                teamName: context.teamName,
                mode: .results,
                apiBaseURL: apiBaseURL,
                force: force
            )
            let (fixtureMatches, resultMatches) = try await (fixtures, results)
            return MatchesOutcome(
                value: TeamMatchLists(
                    fixtures: TeamDetailsMatchResolver.upcomingFixtures(
                        context: context,
                        from: fixtureMatches
                    ),
                    results: TeamDetailsMatchResolver.previousMatches(
                        context: context,
                        from: resultMatches
                    )
                ),
                errorMessage: nil
            )
        } catch is CancellationError {
            return MatchesOutcome(value: nil, errorMessage: nil)
        } catch {
            return MatchesOutcome(value: nil, errorMessage: error.localizedDescription)
        }
    }

    private struct StandingOutcome: Sendable {
        let value: TeamSeasonStanding?
        let response: LeagueTablesResponse?
        let errorMessage: String?
    }

    private struct MatchesOutcome: Sendable {
        let value: TeamMatchLists?
        let errorMessage: String?
    }

    private struct TeamMatchLists: Sendable {
        let fixtures: [Match]
        let results: [Match]
    }
}

struct TeamDetailsView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject private var teamColorCatalog = TeamColorCatalog.shared

    let context: TeamDetailsContext
    @State private var viewModel = TeamDetailsViewModel()
    @State private var showsAllUpcomingFixtures = false
    @State private var showsAllPreviousMatches = false
    @State private var hasAppeared = false
    @State private var badgeCacheVersion = 0

    private var taskKey: String {
        "\(context.id)|\(preferences.apiBaseURL)"
    }

    private var accentColors: TeamAccentColors {
        teamColorCatalog.accentColors(for: context.teamName)
    }

    private var competitionID: String? {
        viewModel.standing?.leagueID ?? context.originatingLeagueID
    }

    private var competitionName: String {
        viewModel.standing?.leagueName ?? context.originatingLeagueName
    }

    private var heroHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 390 : 328
    }

    private var currentTeamForm: [String]? {
        guard let standing = viewModel.standing else { return nil }
        return TeamDetailsFormResolver.recentForm(
            context: context,
            standing: standing,
            matches: viewModel.previousMatches
        )
    }

    private var visibleMatchRowFormRequests: [TeamDetailsMatchRowFormRequest] {
        let visibleMatches = TeamDetailsPagination.visibleMatches(
            viewModel.upcomingFixtures,
            showsAll: showsAllUpcomingFixtures
        ) + TeamDetailsPagination.visibleMatches(
            viewModel.previousMatches,
            showsAll: showsAllPreviousMatches
        )

        return visibleMatches.flatMap { match in
            [match.homeTeam, match.awayTeam].compactMap { teamName in
                guard !TeamIdentityStore.shared.matches(teamName, context.teamName) else {
                    return nil
                }
                return TeamDetailsMatchRowFormRequest(
                    teamName: teamName,
                    leagueID: match.leagueId,
                    leagueName: match.league
                )
            }
        }
    }

    private var matchRowFormsTaskKey: String {
        let requestKeys = Set(visibleMatchRowFormRequests.map(\.key))
        return "\(taskKey)|forms|\(requestKeys.sorted().joined(separator: ","))"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                teamHero
                    .padding(.horizontal, 16)
                    .padding(.top, 14)

                LazyVStack(alignment: .leading, spacing: 24) {
                    currentSeasonSection
                    upcomingFixturesSection
                    previousMatchesSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 28)
            }
        }
        .coordinateSpace(name: "TeamDetailsScroll")
        .environment(\.colorScheme, .dark)
        .background(FootballVisualStyle.pageBackground.ignoresSafeArea())
        .navigationTitle("Team Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(FootballVisualStyle.pageBackground.opacity(0.96), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationDestination(for: TeamDetailsContext.self) { destinationContext in
            TeamDetailsView(context: destinationContext)
        }
        .onAppear {
            guard !hasAppeared else { return }
            if accessibilityReduceMotion {
                hasAppeared = true
            } else {
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.28)) {
                    hasAppeared = true
                }
            }
        }
        .task(id: taskKey) {
            showsAllUpcomingFixtures = false
            showsAllPreviousMatches = false
            await viewModel.load(context: context, apiBaseURL: preferences.apiBaseURL)
        }
        .task(id: matchRowFormsTaskKey) {
            await viewModel.loadMatchRowForms(
                requests: visibleMatchRowFormRequests,
                apiBaseURL: preferences.apiBaseURL
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: TeamBadgeCache.badgesUpdatedNotification)) { _ in
            badgeCacheVersion += 1
        }
        .refreshable {
            await viewModel.load(
                context: context,
                apiBaseURL: preferences.apiBaseURL,
                force: true
            )
        }
    }

    private var teamHero: some View {
        GeometryReader { proxy in
            let scrollOffset = proxy.frame(in: .named("TeamDetailsScroll")).minY
            let _ = badgeCacheVersion

            ZStack {
                Image(
                    MatchStadiumArtworkResolver.shared.teamHeroAssetName(
                        teamID: context.teamID,
                        teamName: context.teamName
                    )
                )
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: heroHeight + 28)
                    .scaleEffect(1.08)
                    .blur(radius: 2.5, opaque: true)
                    .offset(y: accessibilityReduceMotion ? 0 : -scrollOffset * 0.10)
                    .opacity(hasAppeared ? 1 : 0.72)
                    .accessibilityHidden(true)

                LinearGradient(
                    colors: [
                        FootballVisualStyle.pageBackground.opacity(0.30),
                        FootballVisualStyle.pageBackground.opacity(0.48),
                        FootballVisualStyle.pageBackground.opacity(0.98),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                RadialGradient(
                    colors: [.clear, FootballVisualStyle.pageBackground.opacity(0.68)],
                    center: .center,
                    startRadius: 100,
                    endRadius: max(proxy.size.width, heroHeight) * 0.72
                )

                LinearGradient(
                    colors: [accentColors.primary.opacity(0.18), .clear, accentColors.secondary.opacity(0.06)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack(spacing: dynamicTypeSize.isAccessibilitySize ? 16 : 12) {
                    Spacer(minLength: 18)

                    ZStack {
                        Circle()
                            .fill(accentColors.primary.opacity(0.18))
                            .frame(width: 150, height: 150)
                            .blur(radius: 24)

                        Group {
                            if let image = LogoResolver.shared.image(
                                for: context.teamName,
                                teamId: context.teamID,
                                alternateNames: context.alternateNames
                            ) {
                                Image(uiImage: image)
                                    .resizable()
                                    .interpolation(.high)
                                    .scaledToFit()
                            } else {
                                Image(systemName: "shield.fill")
                                    .font(.system(size: 72, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.90))
                            }
                        }
                        .frame(width: 100, height: 100)
                        .shadow(color: accentColors.primary.opacity(0.44), radius: 18)
                        .shadow(color: .black.opacity(0.62), radius: 12, y: 8)
                    }
                    .scaleEffect(hasAppeared ? 1 : 0.96)
                    .opacity(hasAppeared ? 1 : 0)

                    Text(context.canonicalName)
                        .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .minimumScaleFactor(0.72)
                        .padding(.horizontal, 20)

                    HStack(spacing: 9) {
                        TeamDetailsCompetitionBadge(
                            competitionID: competitionID,
                            competitionName: competitionName,
                            size: 25,
                            foregroundColor: .white
                        )
                        Text(competitionName)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 18)

                    Spacer(minLength: 22)
                }
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 10)
            }
        }
        .frame(height: heroHeight)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(0.18), radius: 22, x: 0, y: 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(context.canonicalName), \(competitionName)")
    }

    @ViewBuilder
    private var currentSeasonSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Current Season")

            if let standing = viewModel.standing {
                currentSeasonCard(standing)
            } else if viewModel.isLoadingStanding {
                loadingCard(label: "Loading current season statistics")
            } else {
                unavailableCard(
                    title: "Statistics unavailable",
                    message: "No current league table was found for \(context.canonicalName).",
                    systemImage: "chart.bar.xaxis"
                )
            }

            if let errorMessage = viewModel.standingErrorMessage, viewModel.standing != nil {
                inlineError(errorMessage)
            }
        }
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 14)
    }

    private func currentSeasonCard(_ standing: TeamSeasonStanding) -> some View {
        let recentForm = TeamDetailsFormResolver.recentForm(
            context: context,
            standing: standing,
            matches: viewModel.previousMatches
        )
        let metrics = [
            TeamStatistic(
                label: "Position",
                value: Self.ordinal(standing.row.position),
                systemImage: "trophy.fill",
                tint: .white,
                isPrimary: true
            ),
            TeamStatistic(label: "Played", value: String(standing.row.played), systemImage: "sportscourt"),
            TeamStatistic(label: "Won", value: String(standing.row.won), systemImage: "checkmark.circle", tint: .green),
            TeamStatistic(label: "Drawn", value: String(standing.row.drawn), systemImage: "minus.circle", tint: .yellow),
            TeamStatistic(label: "Lost", value: String(standing.row.lost), systemImage: "xmark.circle", tint: .red),
            TeamStatistic(label: "Goals for", value: String(standing.row.goalsFor), systemImage: "soccerball", tint: Color.accentColor),
            TeamStatistic(label: "Goals against", value: String(standing.row.goalsAgainst), systemImage: "soccerball", tint: .red),
            TeamStatistic(label: "Goal difference", value: Self.signed(standing.row.goalDifference), iconText: "+/−"),
            TeamStatistic(label: "Points", value: String(standing.row.points), systemImage: "star.fill"),
        ]
        let columnCount = dynamicTypeSize.isAccessibilitySize ? 2 : 4
        let columns = Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: 0, alignment: .top),
            count: columnCount
        )
        let accessibilitySummary = metrics
            .map { "\($0.label) \($0.value)" }
            .joined(separator: ", ")

        return Button {
            TablesNavigationCoordinator.shared.navigate(
                leagueID: standing.leagueID,
                teamName: context.teamName,
                returnTitle: "Back to team details"
            )
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                currentSeasonHeader(standing)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 14)

                LazyVGrid(
                    columns: columns,
                    alignment: .leading,
                    spacing: 0
                ) {
                    ForEach(Array(metrics.enumerated()), id: \.element.id) { index, statistic in
                        TeamStatisticTile(
                            statistic: statistic,
                            accentColor: accentColors.primary,
                            showsTrailingDivider: (index + 1).isMultiple(of: columnCount) == false && index < metrics.count - 1,
                            showsBottomDivider: index < metrics.count - columnCount,
                            usesAccessibilityLayout: dynamicTypeSize.isAccessibilitySize
                        )
                    }
                }
                .padding(.horizontal, 10)

                if !recentForm.isEmpty {
                    HStack(spacing: 12) {
                        Text("RECENT FORM")
                            .font(.caption2.weight(.semibold))
                            .tracking(0.7)
                            .foregroundStyle(.white.opacity(0.55))

                        Spacer(minLength: 8)

                        HStack(spacing: 6) {
                            ForEach(Array(recentForm.enumerated()), id: \.offset) { _, result in
                                TeamFormBadge(result: result, size: 25)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Recent form, \(recentForm.joined(separator: ", "))")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 16)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Color.white.opacity(0.07))
                            .frame(height: 0.5)
                            .padding(.horizontal, 16)
                    }
                }
            }
            .background {
                TeamSeasonCardBackground(accentColor: accentColors.primary)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.34), radius: 20, y: 12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(standing.leagueName), \(accessibilitySummary)")
        .accessibilityHint("Shows \(context.canonicalName) highlighted in the league table")
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .animation(
            accessibilityReduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.26),
            value: standing
        )
    }

    @ViewBuilder
    private func currentSeasonHeader(_ standing: TeamSeasonStanding) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                seasonCompetitionIdentity(standing)
                HStack(spacing: 10) {
                    if standing.realtime || standing.row.live {
                        seasonLiveBadge
                    }
                    Spacer(minLength: 8)
                    viewTableLabel
                }
            }
        } else {
            HStack(alignment: .center, spacing: 11) {
                seasonCompetitionIdentity(standing)
                Spacer(minLength: 8)
                if standing.realtime || standing.row.live {
                    seasonLiveBadge
                }
                viewTableLabel
            }
        }
    }

    private func seasonCompetitionIdentity(_ standing: TeamSeasonStanding) -> some View {
        HStack(spacing: 11) {
            TeamDetailsCompetitionBadge(
                competitionID: standing.leagueID,
                competitionName: standing.leagueName,
                size: 30,
                foregroundColor: .white
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(standing.leagueName)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                if let groupName = standing.groupName, !groupName.isEmpty {
                    Text(groupName)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
        }
    }

    private var seasonLiveBadge: some View {
        Label("Live", systemImage: "dot.radiowaves.left.and.right")
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.green.opacity(0.94))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.green.opacity(0.14), in: Capsule())
    }

    private var viewTableLabel: some View {
        HStack(spacing: 4) {
            Text("View table")
            Image(systemName: "chevron.right")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color.accentColor)
    }

    private var upcomingFixturesSection: some View {
        matchListSection(
            title: "Upcoming Fixtures",
            matches: viewModel.upcomingFixtures,
            showsAll: showsAllUpcomingFixtures,
            loadingLabel: "Loading upcoming fixtures",
            emptyTitle: "No upcoming fixtures",
            emptyMessage: "No scheduled matches were found for this team.",
            emptySystemImage: "calendar.badge.exclamationmark"
        ) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showsAllUpcomingFixtures.toggle()
            }
        }
    }

    private var previousMatchesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            matchListSection(
                title: "Previous Matches",
                matches: viewModel.previousMatches,
                showsAll: showsAllPreviousMatches,
                loadingLabel: "Loading previous matches",
                emptyTitle: "No previous matches",
                emptyMessage: "No completed matches were found for this team in the current season.",
                emptySystemImage: "clock.arrow.circlepath"
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showsAllPreviousMatches.toggle()
                }
            }

            if let errorMessage = viewModel.matchesErrorMessage,
               (!viewModel.upcomingFixtures.isEmpty || !viewModel.previousMatches.isEmpty) {
                inlineError(errorMessage)
            }
        }
    }

    @ViewBuilder
    private func matchListSection(
        title: String,
        matches: [Match],
        showsAll: Bool,
        loadingLabel: String,
        emptyTitle: String,
        emptyMessage: String,
        emptySystemImage: String,
        onToggle: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(title)

            if matches.isEmpty && viewModel.isLoadingMatches {
                loadingCard(label: loadingLabel)
            } else if matches.isEmpty {
                unavailableCard(
                    title: emptyTitle,
                    message: emptyMessage,
                    systemImage: emptySystemImage
                )
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(TeamDetailsPagination.visibleMatches(matches, showsAll: showsAll)) { match in
                        TeamDetailsMatchRow(
                            match: match,
                            tablesResponse: viewModel.tablesResponse,
                            viewedTeamName: context.teamName,
                            viewedTeamForm: currentTeamForm,
                            resolvedFormsByRequestKey: viewModel.matchRowFormsByRequestKey
                        )
                    }
                }

                if matches.count > TeamDetailsPagination.collapsedCount {
                    Button(action: onToggle) {
                        HStack(spacing: 6) {
                            Text(showsAll ? "Show less" : "View all")
                            if !showsAll {
                                Text("(\(matches.count))")
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: showsAll ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(showsAll ? "Show fewer \(title.lowercased())" : "View all \(matches.count) \(title.lowercased())")
                }
            }
        }
    }

    private func sectionHeading(_ title: String) -> some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 3, height: 24)
                .shadow(color: Color.accentColor.opacity(0.42), radius: 5)

            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadingCard(label: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(Color.accentColor)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.66))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(FootballVisualStyle.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private func unavailableCard(title: String, message: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
            Button("Try again") {
                Task {
                    await viewModel.load(
                        context: context,
                        apiBaseURL: preferences.apiBaseURL,
                        force: true
                    )
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(FootballVisualStyle.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        }
    }

    private func inlineError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.62))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func ordinal(_ value: Int) -> String {
        let remainder100 = value % 100
        if remainder100 >= 11 && remainder100 <= 13 {
            return "\(value)th"
        }
        switch value % 10 {
        case 1: return "\(value)st"
        case 2: return "\(value)nd"
        case 3: return "\(value)rd"
        default: return "\(value)th"
        }
    }

    private static func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : String(value)
    }
}

private struct TeamDetailsMatchRow: View {
    @EnvironmentObject private var preferences: PreferencesStore

    let match: Match
    let tablesResponse: LeagueTablesResponse?
    let viewedTeamName: String
    let viewedTeamForm: [String]?
    let resolvedFormsByRequestKey: [String: [String]]

    private var homeStanding: TeamSeasonStanding? {
        TeamDetailsMatchStandingResolver.resolve(
            teamName: match.homeTeam,
            leagueID: match.leagueId,
            leagueName: match.league,
            response: tablesResponse
        )
    }

    private var awayStanding: TeamSeasonStanding? {
        TeamDetailsMatchStandingResolver.resolve(
            teamName: match.awayTeam,
            leagueID: match.leagueId,
            leagueName: match.league,
            response: tablesResponse
        )
    }

    private var homeSummary: MatchRowTeamSummary? {
        homeStanding.map {
            MatchRowTeamSummary(
                position: $0.row.position,
                form: TeamDetailsMatchRowFormResolver.form(
                    for: match.homeTeam,
                    leagueID: match.leagueId,
                    leagueName: match.league,
                    viewedTeamName: viewedTeamName,
                    viewedTeamForm: viewedTeamForm,
                    resolvedFormsByRequestKey: resolvedFormsByRequestKey
                )
            )
        }
    }

    private var awaySummary: MatchRowTeamSummary? {
        awayStanding.map {
            MatchRowTeamSummary(
                position: $0.row.position,
                form: TeamDetailsMatchRowFormResolver.form(
                    for: match.awayTeam,
                    leagueID: match.leagueId,
                    leagueName: match.league,
                    viewedTeamName: viewedTeamName,
                    viewedTeamForm: viewedTeamForm,
                    resolvedFormsByRequestKey: resolvedFormsByRequestKey
                )
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(Self.displayDate(for: match))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(match.displayLeague)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)

            NavigationLink {
                MatchDetailView(match: match, showFantasyBadge: false)
            } label: {
                HStack(spacing: 0) {
                    MatchRow(
                        match: match,
                        showLeague: false,
                        showFantasyBadge: false,
                        teamLogoScale: 1.518,
                        showsFinishedInlineAggregateBrackets: true,
                        layoutStyle: .compactFixture,
                        rowPreferences: MatchRowPreferences(
                            preferences: preferences,
                            hasFantasyManagerEntry: false
                        ),
                        homeTeamSummary: homeSummary,
                        awayTeamSummary: awaySummary,
                        enablesTeamDetailsNavigation: false
                    )

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28)
                        .frame(minHeight: 60)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(matchAccessibilityLabel)
            .accessibilityHint("View match details")
        }
    }

    private var matchAccessibilityLabel: String {
        [
            accessibilitySummary(teamName: match.homeTeam, summary: homeSummary),
            match.time,
            accessibilitySummary(teamName: match.awayTeam, summary: awaySummary),
        ].joined(separator: ", ")
    }

    private func accessibilitySummary(
        teamName: String,
        summary: MatchRowTeamSummary?
    ) -> String {
        guard let summary else { return teamName }
        var parts = [teamName, "position \(summary.position)"]
        if !summary.form.isEmpty {
            parts.append("form \(summary.form.joined(separator: ", "))")
        }
        return parts.joined(separator: ", ")
    }

    private static func displayDate(for match: Match) -> String {
        guard let date = match.dateOnly else { return match.date }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
    }

}

private struct TeamStatistic: Identifiable {
    let label: String
    let value: String
    var systemImage: String?
    var iconText: String?
    var tint: Color = .white.opacity(0.70)
    var isPrimary = false

    var id: String { label }
}

private struct TeamStatisticTile: View {
    let statistic: TeamStatistic
    let accentColor: Color
    let showsTrailingDivider: Bool
    let showsBottomDivider: Bool
    let usesAccessibilityLayout: Bool

    var body: some View {
        VStack(spacing: 5) {
            Group {
                if let iconText = statistic.iconText {
                    Text(iconText)
                } else if let systemImage = statistic.systemImage {
                    Image(systemName: systemImage)
                }
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(statistic.isPrimary ? Color.white.opacity(0.92) : statistic.tint)
            .accessibilityHidden(true)

            Text(statistic.value)
                .font(.system(size: statistic.isPrimary ? 30 : 27, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())

            Text(statistic.label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.45)
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: usesAccessibilityLayout ? 112 : 96)
        .padding(.horizontal, 5)
        .background {
            if statistic.isPrimary {
                LinearGradient(
                    colors: [accentColor.opacity(0.72), accentColor.opacity(0.24)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(5)
            }
        }
        .overlay(alignment: .trailing) {
            if showsTrailingDivider {
                Rectangle()
                    .fill(Color.white.opacity(0.075))
                    .frame(width: 0.5)
                    .padding(.vertical, 13)
            }
        }
        .overlay(alignment: .bottom) {
            if showsBottomDivider {
                Rectangle()
                    .fill(Color.white.opacity(0.075))
                    .frame(height: 0.5)
                    .padding(.horizontal, 10)
            }
        }
        .shadow(color: statistic.isPrimary ? accentColor.opacity(0.22) : .clear, radius: 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(statistic.label), \(statistic.value)")
    }
}

private struct TeamDetailsCompetitionBadge: View {
    let competitionID: String?
    let competitionName: String
    let size: CGFloat
    let foregroundColor: Color
    @State private var badgeCacheVersion = 0

    var body: some View {
        Group {
            if let image = CompetitionBadgeCache.shared.image(
                competitionID: competitionID,
                competitionName: competitionName
            ) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "soccerball")
                    .font(.system(size: size * 0.78, weight: .medium))
                    .foregroundStyle(foregroundColor.opacity(0.82))
            }
        }
        .frame(width: size, height: size)
        .onReceive(NotificationCenter.default.publisher(for: CompetitionBadgeCache.badgesUpdatedNotification)) { _ in
            badgeCacheVersion &+= 1
        }
        .accessibilityHidden(true)
    }
}

private struct TeamSeasonCardBackground: View {
    let accentColor: Color

    var body: some View {
        FootballCardSurface(accentColor: accentColor, showsPitchMarkings: true)
    }
}

private struct TeamFormBadge: View {
    let result: String
    var size: CGFloat = 27

    private var normalizedResult: String {
        String(result.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().prefix(1))
    }

    private var color: Color {
        switch normalizedResult {
        case "W": return .green
        case "D": return .gray
        case "L": return .red
        default: return .secondary
        }
    }

    var body: some View {
        Text(normalizedResult.isEmpty ? "–" : normalizedResult)
            .font((size < 24 ? Font.caption2 : Font.caption).weight(.bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: Circle())
    }
}
