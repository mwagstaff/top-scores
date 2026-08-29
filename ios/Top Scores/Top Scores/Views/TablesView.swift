import Combine
import SwiftUI

struct TablesView: View {
    @EnvironmentObject private var preferences: PreferencesStore

    @State private var leagues: [LeagueTable]
    @State private var selectedLeagueID: String
    @State private var isLoading: Bool
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    @State private var shortNameRefreshVersion = 0
    @State private var screenOpenedAt: Date?
    @State private var isVisible = false
    @State private var scrollTargetRowID: String?
    @State private var highlightedRowID: String?
    @State private var showsStats = false
    @State private var catalogCompetitionWeights: [String: Double] = [:]
    @State private var matchSectionsByLeagueID: [String: TableMatchesSection] = [:]
    @State private var loadedMatchSectionLeagueIDs: Set<String> = []
    @State private var loadingMatchSectionLeagueIDs: Set<String> = []
    @ObservedObject private var navigationCoordinator = TablesNavigationCoordinator.shared

    @ScaledMetric(relativeTo: .caption) private var competitionPickerHeight: CGFloat = 103.4

    // While the Tables screen is visible, refresh on a live cadence so
    // in-progress scores flow into the (server-recomputed) standings within
    // ~30s. The endpoint is cached server-side, so this stays cheap.
    private let liveRefreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    init() {
        let apiBaseURL = PreferencesStore.resolvedAPIBaseURL()
        let cachedResponse = LeagueTablesCache.load(for: apiBaseURL)?.response
        let initialLeagues = cachedResponse?.leagues ?? []

        _leagues = State(initialValue: initialLeagues)
        _selectedLeagueID = State(initialValue: Self.defaultLeagueID(from: initialLeagues))
        _isLoading = State(initialValue: initialLeagues.isEmpty)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    FootballVisualStyle.pageBackground
                        .ignoresSafeArea()

                    FootballScreenBackdrop()

                    VStack(spacing: 0) {
                        FootballHeroHeader(title: "Tables", subtitle: tablesHeaderSubtitle)
                            .overlay(alignment: .topLeading) {
                                if navigationCoordinator.returnTabIndex != nil {
                                    Button {
                                        navigationCoordinator.requestReturn()
                                    } label: {
                                        Image(systemName: "chevron.backward")
                                            .font(.body.weight(.semibold))
                                            .frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Color.white.opacity(0.92))
                                    .accessibilityLabel(navigationCoordinator.returnTitle)
                                    .padding(.leading, 8)
                                }
                            }
                        contentView
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            isVisible = true
            guard !hasLoaded else { return }
            hasLoaded = true
            screenOpenedAt = Date()
            applyCachedTables(for: preferences.apiBaseURL, clearWhenMissing: false)
            Task {
                await refreshTeamShortNames(apiBaseURL: preferences.apiBaseURL)
                await loadTables(force: false)
                let durationMs = screenOpenedAt.map { Int(Date().timeIntervalSince($0) * 1000) }
                screenOpenedAt = nil
                AppMetricsService.shared.fireScreenView(screen: "tables", durationMs: durationMs, apiBaseURL: preferences.apiBaseURL)
                // Pull fresh (server-recomputed) standings right away so any live
                // match shows immediately, rather than waiting for the first timer tick.
                await liveRefreshTables()
            }
        }
        .onDisappear {
            isVisible = false
            // Leaving Tables for any reason — tapping the return button, or
            // switching to another tab directly — drops the stale return
            // target and the pulsing row highlight, so neither lingers if
            // the user comes back to Tables later for an unrelated reason.
            _ = navigationCoordinator.consumeReturnTabIndex()
            highlightedRowID = nil
        }
        .onChange(of: preferences.apiBaseURL) { _, newValue in
            matchSectionsByLeagueID.removeAll()
            loadedMatchSectionLeagueIDs.removeAll()
            loadingMatchSectionLeagueIDs.removeAll()
            applyCachedTables(for: newValue, clearWhenMissing: true)
            Task {
                await refreshTeamShortNames(apiBaseURL: newValue)
                await loadTables(force: true)
            }
        }
        .onReceive(liveRefreshTimer) { _ in
            guard isVisible, hasLoaded else { return }
            Task {
                await liveRefreshTables()
                await refreshSelectedCompetitionMatchesIfLive()
            }
        }
        .onChange(of: navigationCoordinator.pendingTarget) { _, _ in
            consumePendingNavigationIfNeeded()
        }
        .onChange(of: leagues) { _, _ in
            consumePendingNavigationIfNeeded()
        }
        .task(id: preferences.apiBaseURL) {
            await loadCompetitionMetadata(apiBaseURL: preferences.apiBaseURL)
        }
        .task(id: competitionMatchesTaskID) {
            await loadSelectedCompetitionMatches(force: false)
        }
    }

    private var tablesHeaderSubtitle: String? {
        guard let leagueName = leagues
            .first(where: { $0.leagueID == selectedLeagueID })?
            .leagueName
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !leagueName.isEmpty else {
            return nil
        }
        return leagueName
    }

    private var competitionMatchesTaskID: String {
        "\(preferences.apiBaseURL)|\(selectedLeagueID)"
    }

    // Applies a cross-tab navigation request from MatchDetailView (selects the
    // league, then scrolls to + highlights the team's row) once the matching
    // league/row are available, then clears the request. The highlight pulses
    // indefinitely — it only moves when a new navigation request arrives.
    private func consumePendingNavigationIfNeeded() {
        guard let target = navigationCoordinator.pendingTarget else { return }
        guard let league = leagues.first(where: { $0.leagueID == target.leagueID }) else { return }
        guard let row = matchingRow(forTeamName: target.teamName, in: league) else {
            _ = navigationCoordinator.consumeTarget()
            return
        }

        _ = navigationCoordinator.consumeTarget()
        selectedLeagueID = target.leagueID

        // A short delay lets the newly-selected league's rows lay out before
        // ScrollViewReader can resolve the target id.
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            scrollTargetRowID = row.id
            highlightedRowID = row.id
        }
    }

    private func matchingRow(forTeamName teamName: String, in league: LeagueTable) -> LeagueTableRow? {
        let target = TeamIdentityStore.shared.canonicalName(for: teamName).lowercased()
        let allRows = league.rows + league.groups.flatMap(\.rows)
        return allRows.first { TeamIdentityStore.shared.canonicalName(for: $0.team).lowercased() == target }
    }

    private var contentView: some View {
        Group {
            if isLoading && leagues.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(Color.accentColor)
                    Text("Loading tables")
                        .font(.subheadline)
                        .foregroundStyle(FootballVisualStyle.mutedText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if leagues.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "tablecells")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.accentColor)
                    Text("No tables to show")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.96))
                    Text(errorMessage ?? "League tables will appear here once available.")
                        .font(.subheadline)
                        .foregroundStyle(errorMessage == nil ? FootballVisualStyle.mutedText : Color.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    competitionCarousel
                    TabView(selection: $selectedLeagueID) {
                        ForEach(sortedLeagues) { league in
                            leaguePage(league)
                                .tag(league.leagueID)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private static let fallbackCompetitionWeights: [String: Double] = [
        "Premier League": 100,
        "UEFA Champions League": 90,
        "FIFA World Cup 2026": 85,
        "UEFA Europa League": 80,
        "UEFA Conference League": 70,
        "UEFA Nations League": 69,
        "UEFA Super Cup": 68,
        "FA Cup": 65,
        "English League Cup": 60,
        "Copa del Rey": 49,
        "La Liga": 50,
        "Bundesliga": 48,
        "Serie A": 45,
        "Ligue 1": 44,
        "Championship": 40,
        "EFL Cup": 60,
        "Scottish Premiership": 30,
        "Scottish Championship": 25,
        "Scottish League One": 20,
        "Scottish League Two": 15,
        "League One": 14,
        "League Two": 12,
        "International Friendly": 10
    ]

    private var sortedLeagues: [LeagueTable] {
        leagues.sorted {
            if $0.hasLiveRows != $1.hasLiveRows {
                return $0.hasLiveRows
            }
            let weightA = competitionWeight(for: $0)
            let weightB = competitionWeight(for: $1)
            if weightA != weightB { return weightA > weightB }
            return $0.leagueName.localizedCaseInsensitiveCompare($1.leagueName) == .orderedAscending
        }
    }

    private var competitionCarousel: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(sortedLeagues) { league in
                        Button {
                            withAnimation(.snappy) {
                                selectedLeagueID = league.leagueID
                            }
                        } label: {
                            CompetitionPickerItem(
                                league: league,
                                isSelected: selectedLeagueID == league.leagueID
                            )
                        }
                        .buttonStyle(.plain)
                        .id(league.leagueID)
                        .accessibilityLabel(league.leagueName)
                        .accessibilityValue(competitionAccessibilityValue(for: league))
                        .accessibilityAddTraits(
                            selectedLeagueID == league.leagueID ? .isSelected : []
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .frame(height: min(competitionPickerHeight, 132))
            .onAppear {
                proxy.scrollTo(selectedLeagueID, anchor: .center)
            }
            .onChange(of: selectedLeagueID) { _, newValue in
                withAnimation(.snappy) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func leaguePage(_ league: LeagueTable) -> some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(spacing: 14) {
                    statsToggle
                    LeagueTableCard(
                        league: league,
                        showsStats: showsStats,
                        highlightedRowID: highlightedRowID
                    )
                    .id("\(league.id)-\(shortNameRefreshVersion)")

                    if let section = matchSectionsByLeagueID[league.leagueID] {
                        TableMatchesSectionView(league: league, section: section)
                    } else if loadingMatchSectionLeagueIDs.contains(league.leagueID) {
                        TableMatchesLoadingView()
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .refreshable {
                let refreshStart = Date()
                await loadTables(force: true)
                await loadSelectedCompetitionMatches(force: true)
                let durationMs = Int(Date().timeIntervalSince(refreshStart) * 1000)
                AppMetricsService.shared.fireActivity("manual_refresh", screen: "tables", durationMs: durationMs, apiBaseURL: preferences.apiBaseURL)
            }
            .safeAreaPadding(.bottom, 80)
            .onChange(of: scrollTargetRowID) { _, newValue in
                guard league.leagueID == selectedLeagueID, let newValue else { return }
                withAnimation {
                    scrollProxy.scrollTo(newValue, anchor: .center)
                }
                scrollTargetRowID = nil
            }
        }
    }

    private var statsToggle: some View {
        HStack(spacing: 12) {
            Text("Team")
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
            Toggle("Stats view", isOn: $showsStats)
                .font(.subheadline)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(FootballVisualStyle.elevatedSurface.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(FootballVisualStyle.border, lineWidth: 1)
        }
    }

    private func loadTables(force: Bool) async {
        let apiBaseURL = preferences.apiBaseURL
        await MainActor.run {
            applyCachedTables(for: apiBaseURL, clearWhenMissing: false)
        }

        guard !apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await MainActor.run {
                errorMessage = "Invalid API base URL"
                isLoading = false
            }
            return
        }

        await MainActor.run {
            if force || leagues.isEmpty {
                isLoading = true
            }
            errorMessage = nil
        }

        do {
            let response = try await LeagueTablesCatalog.shared.refresh(
                apiBaseURL: apiBaseURL,
                force: force
            )
            await MainActor.run {
                apply(response: response)
                isLoading = false
                errorMessage = nil
            }
        } catch {
            let cachedResponse = await LeagueTablesCatalog.shared.cachedResponse(apiBaseURL: apiBaseURL)
            await MainActor.run {
                if let cachedResponse {
                    apply(response: cachedResponse)
                }
                isLoading = false
                errorMessage = leagues.isEmpty
                    ? "Failed to load tables: \(error.localizedDescription)"
                    : "Couldn't refresh tables. Showing saved data."
            }
        }
    }

    // Silent live refresh: force-fetches the latest (server-recomputed) tables
    // without toggling the loading spinner, so the standings update in place.
    private func liveRefreshTables() async {
        let apiBaseURL = preferences.apiBaseURL
        guard !apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let response = try await LeagueTablesCatalog.shared.refresh(apiBaseURL: apiBaseURL, force: true)
            await MainActor.run { apply(response: response) }
        } catch {
            // Keep showing existing data on a transient failure.
        }
    }

    private func loadSelectedCompetitionMatches(force: Bool) async {
        guard let league = leagues.first(where: { $0.leagueID == selectedLeagueID }) else {
            return
        }
        guard force || !loadedMatchSectionLeagueIDs.contains(league.leagueID) else {
            return
        }

        let apiBaseURL = preferences.apiBaseURL
        guard let baseURL = URL(string: apiBaseURL) else { return }

        loadingMatchSectionLeagueIDs.insert(league.leagueID)
        defer { loadingMatchSectionLeagueIDs.remove(league.leagueID) }

        do {
            let matches = try await APIClient(baseURL: baseURL).fetchCompetitionSeasonMatches(
                leagueName: league.leagueName
            )
            guard !Task.isCancelled, preferences.apiBaseURL == apiBaseURL else { return }

            loadedMatchSectionLeagueIDs.insert(league.leagueID)
            if let section = TableMatchesSection.resolve(from: matches) {
                matchSectionsByLeagueID[league.leagueID] = section
            } else {
                matchSectionsByLeagueID.removeValue(forKey: league.leagueID)
            }
        } catch is CancellationError {
            return
        } catch {
            // The table remains useful on its own if companion match data is
            // temporarily unavailable. Pull-to-refresh will retry the request.
        }
    }

    private func refreshSelectedCompetitionMatchesIfLive() async {
        guard let league = leagues.first(where: { $0.leagueID == selectedLeagueID }) else {
            return
        }
        let sectionIsLive = matchSectionsByLeagueID[league.leagueID]?.kind == .inProgress
        guard league.hasLiveRows || sectionIsLive else { return }
        await loadSelectedCompetitionMatches(force: true)
    }

    private func refreshTeamShortNames(apiBaseURL: String) async {
        await FantasyTeamShortNameMappingsCatalog.shared.ensureFresh(apiBaseURL: apiBaseURL)
        await MainActor.run {
            shortNameRefreshVersion &+= 1
        }
    }

    private func loadCompetitionMetadata(apiBaseURL: String) async {
        guard let baseURL = URL(string: apiBaseURL) else { return }
        guard let catalog = try? await APIClient(baseURL: baseURL).fetchCompetitionCatalog() else {
            return
        }
        guard !Task.isCancelled else { return }

        CompetitionBadgeCache.shared.warmIfNeeded(entries: catalog.competitions)
        var weights: [String: Double] = [:]
        for competition in catalog.competitions {
            weights[Self.normalizedCompetitionKey(competition.stableID)] = competition.weight
            for name in competition.allNames {
                weights[Self.normalizedCompetitionKey(name)] = competition.weight
            }
        }
        catalogCompetitionWeights = weights
    }

    private func competitionWeight(for league: LeagueTable) -> Double {
        catalogCompetitionWeights[Self.normalizedCompetitionKey(league.leagueID)]
            ?? catalogCompetitionWeights[Self.normalizedCompetitionKey(league.leagueName)]
            ?? Self.fallbackCompetitionWeights[league.leagueName]
            ?? 0
    }

    private func competitionAccessibilityValue(for league: LeagueTable) -> String {
        let selection = selectedLeagueID == league.leagueID ? "Selected" : "Not selected"
        return league.hasLiveRows ? "\(selection), matches currently in play" : selection
    }

    private static func normalizedCompetitionKey(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func applyCachedTables(for apiBaseURL: String, clearWhenMissing: Bool) {
        guard let cachedResponse = LeagueTablesCache.load(for: apiBaseURL)?.response else {
            guard clearWhenMissing else { return }
            leagues = []
            selectedLeagueID = Self.defaultLeagueID(from: [])
            return
        }

        apply(response: cachedResponse)
    }

    private func apply(response: LeagueTablesResponse) {
        leagues = response.leagues
        selectedLeagueID = resolvedLeagueID(
            from: response.leagues,
            currentSelection: selectedLeagueID
        )
    }

    private func resolvedLeagueID(from leagues: [LeagueTable], currentSelection: String) -> String {
        guard !leagues.isEmpty else { return Self.defaultLeagueID(from: leagues) }
        if leagues.contains(where: { $0.leagueID == currentSelection }) {
            return currentSelection
        }
        return Self.defaultLeagueID(from: leagues)
    }

    private static func defaultLeagueID(from leagues: [LeagueTable]) -> String {
        if leagues.contains(where: { $0.leagueID == "premier-league" }) {
            return "premier-league"
        }
        return leagues
            .sorted {
                if $0.hasLiveRows != $1.hasLiveRows {
                    return $0.hasLiveRows
                }
                let weightA = fallbackCompetitionWeights[$0.leagueName] ?? 0
                let weightB = fallbackCompetitionWeights[$1.leagueName] ?? 0
                if weightA != weightB { return weightA > weightB }
                return $0.leagueName.localizedCaseInsensitiveCompare($1.leagueName) == .orderedAscending
            }
            .first?
            .leagueID ?? "premier-league"
    }
}

struct TableMatchesSection: Equatable {
    enum Kind: Equatable {
        case inProgress
        case latestResults
        case futureFixtures

        var title: String {
            switch self {
            case .inProgress:
                return "Matches in progress"
            case .latestResults:
                return "Latest results"
            case .futureFixtures:
                return "Future fixtures"
            }
        }
    }

    let kind: Kind
    let matches: [Match]

    static func resolve(from matches: [Match]) -> TableMatchesSection? {
        let availableMatches = matches.filter { !$0.isPostponed }
        let liveMatches = sorted(availableMatches.filter(\.isInProgress))
        if !liveMatches.isEmpty {
            return TableMatchesSection(kind: .inProgress, matches: liveMatches)
        }

        let finishedMatches = availableMatches.filter(\.isFinished)
        if let latestResult = sorted(finishedMatches).last {
            let latestRoundResults = matchesInRound(
                containing: latestResult,
                from: availableMatches
            )
            .filter(\.isFinished)
            return TableMatchesSection(
                kind: .latestResults,
                matches: sorted(latestRoundResults)
            )
        }

        let futureMatches = sorted(availableMatches.filter(\.isUpcomingScorelessFixture))
        guard let nextFixture = futureMatches.first else { return nil }
        let nextRoundFixtures = matchesInRound(
            containing: nextFixture,
            from: availableMatches
        )
        .filter(\.isUpcomingScorelessFixture)
        guard !nextRoundFixtures.isEmpty else { return nil }
        return TableMatchesSection(
            kind: .futureFixtures,
            matches: sorted(nextRoundFixtures)
        )
    }

    private static func matchesInRound(containing anchor: Match, from matches: [Match]) -> [Match] {
        if let roundNumber = anchor.roundNumber {
            let sameRound = matches.filter { match in
                guard match.roundNumber == roundNumber else { return false }
                guard let seasonID = anchor.seasonID else { return true }
                return match.seasonID == nil || match.seasonID == seasonID
            }
            if !sameRound.isEmpty { return sameRound }
        }

        if let stage = roundSpecificStage(anchor.leagueSubcategory) {
            let sameStage = matches.filter {
                $0.leagueSubcategory?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(stage) == .orderedSame
            }
            if !sameStage.isEmpty { return sameStage }
        }

        return inferredRounds(from: matches)
            .first(where: { round in round.contains(where: { $0.id == anchor.id }) })
            ?? [anchor]
    }

    private static func roundSpecificStage(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.lowercased()
        let identifiesRound = normalized.rangeOfCharacter(from: .decimalDigits) != nil ||
            normalized.contains("round") ||
            normalized.contains("final") ||
            normalized.contains("semi") ||
            normalized.contains("quarter") ||
            normalized.contains("playoff") ||
            normalized.contains("play-off")
        return identifiesRound ? trimmed : nil
    }

    private static func inferredRounds(from matches: [Match]) -> [[Match]] {
        var rounds: [[Match]] = []
        var currentRound: [Match] = []
        var participatingTeams: Set<String> = []

        for match in sorted(matches) {
            let homeKey = teamKey(id: match.homeTeamId, name: match.homeTeam)
            let awayKey = teamKey(id: match.awayTeamId, name: match.awayTeam)
            if !currentRound.isEmpty,
               (participatingTeams.contains(homeKey) || participatingTeams.contains(awayKey)) {
                rounds.append(currentRound)
                currentRound = []
                participatingTeams.removeAll(keepingCapacity: true)
            }

            currentRound.append(match)
            participatingTeams.insert(homeKey)
            participatingTeams.insert(awayKey)
        }

        if !currentRound.isEmpty {
            rounds.append(currentRound)
        }
        return rounds
    }

    private static func teamKey(id: String?, name: String) -> String {
        if let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return "id:\(id)"
        }
        return "name:" + name
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func sorted(_ matches: [Match]) -> [Match] {
        matches.sorted {
            let leftDate = $0.dateTime ?? $0.dateOnly ?? .distantFuture
            let rightDate = $1.dateTime ?? $1.dateOnly ?? .distantFuture
            if leftDate != rightDate { return leftDate < rightDate }
            return $0.id < $1.id
        }
    }
}

private struct TableMatchesSectionView: View {
    let league: LeagueTable
    let section: TableMatchesSection

    private var accentColor: Color {
        if section.kind == .inProgress { return .liveMatch }
        return CompetitionAccentRole.resolve(
            competitionID: league.leagueID,
            competitionName: league.leagueName
        ).color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(section.kind.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.96))

                if section.kind == .inProgress {
                    LiveCompetitionDot()
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(section.matches.enumerated()), id: \.element.id) { index, match in
                    NavigationLink {
                        MatchDetailView(match: match, showFantasyBadge: false)
                    } label: {
                        HStack(spacing: 0) {
                            MatchesListRowLabel(
                                match: match,
                                isFixtureMode: false,
                                rowPreferences: .disabledFantasy,
                                fantasyContext: .empty,
                                predictionDisplay: .hidden
                            )
                            .equatable()

                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(Color(.tertiaryLabel))
                                .frame(width: 16)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)

                    if index < section.matches.count - 1 {
                        Rectangle()
                            .fill(FootballVisualStyle.divider)
                            .frame(height: 0.5)
                            .padding(.horizontal, 16)
                    }
                }
            }
            .background {
                FootballCardSurface(accentColor: accentColor.opacity(0.65))
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: FootballVisualStyle.cardCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: FootballVisualStyle.cardCornerRadius,
                    style: .continuous
                )
                .stroke(
                    LinearGradient(
                        colors: [
                            accentColor.opacity(0.32),
                            FootballVisualStyle.border,
                            FootballVisualStyle.border,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.6
                )
            }
            .shadow(color: .black.opacity(0.24), radius: 16, y: 9)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct TableMatchesLoadingView: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.accentColor)
            Text("Loading matches")
                .font(.footnote.weight(.medium))
                .foregroundStyle(FootballVisualStyle.mutedText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}

private struct CompetitionPickerItem: View {
    let league: LeagueTable
    let isSelected: Bool

    @ScaledMetric(relativeTo: .caption) private var iconSize: CGFloat = 30
    @ScaledMetric(relativeTo: .caption) private var itemWidth: CGFloat = 91.2

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    TableCompetitionBadge(
                        competitionID: league.leagueID,
                        competitionName: league.leagueName,
                        size: min(iconSize, 38)
                    )

                    if league.hasLiveRows {
                        LiveCompetitionDot()
                            .offset(x: 5, y: -4)
                    }
                }

                Text(shortLabel)
                    .font(.caption2.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.78))
                    .lineLimit(shortLabel.contains(" ") ? 2 : 1)
                    .minimumScaleFactor(0.68)
                    .allowsTightening(true)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .top)
            }
            .padding(.horizontal, 6)
            .padding(.top, 7)
            .padding(.bottom, 5)
            .frame(width: min(itemWidth, 115.2), height: 72.6)
            .background(FootballVisualStyle.elevatedSurface.opacity(isSelected ? 0.96 : 0.78))
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.78) : FootballVisualStyle.border,
                        lineWidth: isSelected ? 1.25 : 1
                    )
            }

            Capsule()
                .fill(isSelected ? Color.accentColor : Color.clear)
                .frame(width: 40, height: 3)
                .shadow(color: isSelected ? Color.accentColor.opacity(0.45) : .clear, radius: 3)
        }
        .frame(width: min(itemWidth, 115.2))
        .contentShape(Rectangle())
    }

    private var shortLabel: String {
        let name = league.leagueName
        if name.localizedCaseInsensitiveContains("Champions League") { return "UCL" }
        if name.localizedCaseInsensitiveContains("Europa League") { return "Europa" }
        if name.localizedCaseInsensitiveContains("Conference League") { return "Conference" }
        if name.localizedCaseInsensitiveContains("World Cup 2026") { return "World Cup" }
        if name.localizedCaseInsensitiveContains("World Cup Qualifying") { return "World Cup Qual." }
        if name.localizedCaseInsensitiveContains("International Friendly") { return "Friendlies" }
        if name.localizedCaseInsensitiveContains("English League Cup") { return "EFL Cup" }
        return name
    }
}

private struct TableCompetitionBadge: View {
    let competitionID: String
    let competitionName: String
    let size: CGFloat

    @State private var badgeCacheVersion = 0

    private var accentColor: Color {
        CompetitionAccentRole.resolve(
            competitionID: competitionID,
            competitionName: competitionName
        ).color
    }

    var body: some View {
        let _ = badgeCacheVersion
        Group {
            if let assetName = BundledCompetitionLogo.assetName(
                competitionID: competitionID,
                competitionName: competitionName
            ) {
                if assetName == "CompetitionLogo7" {
                    Image(assetName)
                        .resizable()
                        .renderingMode(.template)
                        .foregroundStyle(Color.white.opacity(0.94))
                        .scaledToFit()
                } else {
                    Image(assetName)
                        .resizable()
                        .scaledToFit()
                }
            } else if let image = CompetitionBadgeCache.shared.image(
                competitionID: competitionID,
                competitionName: competitionName
            ) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                ZStack {
                    Circle()
                        .fill(accentColor.opacity(0.16))
                    Image(systemName: fallbackSymbolName)
                        .font(.system(size: size * 0.54, weight: .semibold))
                        .foregroundStyle(accentColor)
                }
            }
        }
        .frame(width: size, height: size)
        .onReceive(NotificationCenter.default.publisher(for: CompetitionBadgeCache.badgesUpdatedNotification)) { _ in
            badgeCacheVersion &+= 1
        }
        .accessibilityHidden(true)
    }

    private var fallbackSymbolName: String {
        let key = competitionName.lowercased()
        if key.contains("world cup") || key.contains("nations league") || key.contains("friendly") {
            return "globe.europe.africa.fill"
        }
        if key.contains("cup") {
            return "trophy.fill"
        }
        if key.contains("champions league") {
            return "star.circle.fill"
        }
        return "shield.fill"
    }
}

private enum BundledCompetitionLogo {
    private static let assetNamesByLeagueID: [String: String] = [
        "1": "FantasyPremierLeagueLion",
        "3": "CompetitionLogo3",
        "4": "CompetitionLogo4",
        "5": "CompetitionLogo5",
        "6": "CompetitionLogo6",
        "7": "CompetitionLogo7",
        "8": "CompetitionLogo8",
        "10": "CompetitionLogo10",
        "12": "CompetitionLogo12",
        "13": "CompetitionLogo13",
        "27": "CompetitionLogo27",
        "39": "CompetitionLogo39",
        "40": "CompetitionLogo40",
        "41": "CompetitionLogo41",
        "42": "CompetitionLogo42",
        "43": "CompetitionLogo43",
        "44": "CompetitionLogo44",
        "58": "CompetitionLogo27",
        "59": "CompetitionLogo27",
        "62": "CompetitionLogo27",
        "63": "CompetitionLogo27",
        "64": "CompetitionLogo64",
        "83": "CompetitionLogo83",
        "86": "CompetitionLogo86",
        "87": "CompetitionLogo87",
        "90": "CompetitionLogo90"
    ]

    private static let assetNamesByCompetitionName: [String: String] = [
        "bundesliga": "CompetitionLogo5",
        "championship": "CompetitionLogo12",
        "copa del rey": "CompetitionLogo41",
        "coppa italia": "CompetitionLogo42",
        "coupe de france": "CompetitionLogo44",
        "dfb pokal": "CompetitionLogo43",
        "dutch eredivisie": "CompetitionLogo10",
        "efl cup": "CompetitionLogo40",
        "fa cup": "CompetitionLogo39",
        "fifa world cup 2026": "CompetitionLogo27",
        "la liga": "CompetitionLogo3",
        "league one": "CompetitionLogo86",
        "league two": "CompetitionLogo87",
        "ligue 1": "CompetitionLogo6",
        "premier league": "FantasyPremierLeagueLion",
        "scottish premiership": "CompetitionLogo13",
        "serie a": "CompetitionLogo4",
        "uefa champions league": "CompetitionLogo7",
        "uefa conference league": "CompetitionLogo83",
        "uefa europa league": "CompetitionLogo8",
        "uefa nations league": "CompetitionLogo64",
        "uefa super cup": "CompetitionLogo90",
        "world cup qualifying concacaf": "CompetitionLogo27",
        "world cup qualifying conmebol": "CompetitionLogo27",
        "world cup qualifying ofc": "CompetitionLogo27",
        "world cup qualifying uefa": "CompetitionLogo27"
    ]

    static func assetName(competitionID: String, competitionName: String) -> String? {
        assetNamesByLeagueID[competitionID]
            ?? assetNamesByCompetitionName[normalizedName(competitionName)]
    }

    private static func normalizedName(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }
}

private struct LiveCompetitionDot: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.liveMatch.opacity(accessibilityReduceMotion ? 0 : 0.34))
                .frame(width: 14, height: 14)
                .scaleEffect(isPulsing ? 1.45 : 0.75)
                .opacity(isPulsing ? 0 : 1)

            Circle()
                .fill(Color.liveMatch)
                .frame(width: 7, height: 7)
                .overlay {
                    Circle()
                        .stroke(Color.black.opacity(0.48), lineWidth: 1)
                }
        }
        .frame(width: 14, height: 14)
        .animation(
            accessibilityReduceMotion
                ? nil
                : .easeOut(duration: 1.1).repeatForever(autoreverses: false),
            value: isPulsing
        )
        .onAppear {
            isPulsing = !accessibilityReduceMotion
        }
        .onChange(of: accessibilityReduceMotion) { _, reduceMotion in
            isPulsing = !reduceMotion
        }
        .accessibilityHidden(true)
    }
}

private struct LeagueTableCard: View {
    let league: LeagueTable
    let showsStats: Bool
    var highlightedRowID: String?

    private var accentColor: Color {
        CompetitionAccentRole.resolve(
            competitionID: league.leagueID,
            competitionName: league.leagueName
        ).color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if league.hasLiveRows {
                LiveInPlayStandingsNote()
            }
            if league.hasRows {
                VStack(spacing: 0) {
                    headingRow
                    tableSeparator(isThick: false)
                    ForEach(Array(displayGroups.enumerated()), id: \.element.id) { groupIndex, group in
                        if let heading = groupHeading(for: group) {
                            groupHeadingRow(heading)
                        }

                        ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                            VStack(spacing: 0) {
                                ForEach(lookDownZonesStarting(at: row.position)) { zone in
                                    zoneBoundary(zone)
                                }

                                rowView(row)

                                ForEach(lookUpZonesEnding(at: row.position)) { zone in
                                    zoneBoundary(zone)
                                }

                                if shouldShowStandardSeparator(in: group.rows, after: index) {
                                    tableSeparator(isThick: isBenefitBoundary(in: group.rows, after: index))
                                }
                            }
                        }

                        if groupIndex < displayGroups.count - 1 {
                            tableSeparator(isThick: true)
                        }
                    }
                }
                .background {
                    FootballCardSurface(accentColor: accentColor, showsPitchMarkings: true)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(FootballVisualStyle.border, lineWidth: 1)
                }
            } else {
                Text("This table will be populated once the season is underway.")
                    .font(.subheadline)
                    .foregroundStyle(FootballVisualStyle.mutedText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 28)
                    .background {
                        FootballCardSurface(accentColor: accentColor, showsPitchMarkings: true)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(FootballVisualStyle.border, lineWidth: 1)
                    }
            }
        }
    }

    private var displayGroups: [LeagueTableGroup] {
        let groupsWithRows = league.groups.filter { !$0.rows.isEmpty }
        if !groupsWithRows.isEmpty {
            return groupsWithRows
        }
        return [LeagueTableGroup(name: visibleStageName, rows: league.rows)]
    }

    private var visibleStageName: String? {
        let stage = String(league.stageName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stage.isEmpty else { return nil }
        if stage.caseInsensitiveCompare("Regular Season") == .orderedSame {
            return nil
        }
        return stage
    }

    private var headingRow: some View {
        Group {
            if showsStats {
                HStack(spacing: 0) {
                    statsHeading("#", width: 30, alignment: .leading)
                    Color.clear.frame(width: 8)
                    Color.clear.frame(width: 24)
                    statsHeading("P", width: 24)
                    statsHeading("W", width: 24)
                    statsHeading("D", width: 24)
                    statsHeading("L", width: 24)
                    statsHeading("GF", width: 27)
                    statsHeading("GA", width: 27)
                    statsHeading("GD", width: 27)
                    statsHeading("Pts", width: 30)
                    statsHeading("Form", width: 55)
                }
            } else {
                HStack(spacing: 6) {
                    Text("")
                        .frame(width: 40, alignment: .trailing)
                    Text("")
                        .frame(width: 24)
                    Text("Team")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    shortHeading("P", width: 30)
                    shortHeading("GD", width: 34)
                    shortHeading("Pts", width: 38)
                }
            }
        }
        .padding(.horizontal, showsStats ? 8 : 10)
        .padding(.vertical, 10)
        .foregroundStyle(.secondary)
    }

    private func groupHeadingRow(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func rowView(_ row: LeagueTableRow) -> some View {
        NavigationLink {
            TeamDetailsView(context: teamDetailsContext(for: row))
        } label: {
            Group {
                if showsStats {
                    HStack(spacing: 0) {
                        compactPositionCell(row)
                        Color.clear.frame(width: 8)
                        TableTeamLogo(name: row.team)
                            .frame(width: 24)
                        statsCell(row.played, width: 24)
                        statsCell(row.won, width: 24)
                        statsCell(row.drawn, width: 24)
                        statsCell(row.lost, width: 24)
                        statsCell(row.goalsFor, width: 27)
                        statsCell(row.goalsAgainst, width: 27)
                        statsCell(row.goalDifference, width: 27, signed: true)
                        statsCell(row.points, width: 30, weight: .semibold)
                        compactForm(row.form)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                } else {
                    HStack(spacing: 6) {
                        positionCell(row)
                        TableTeamLogo(name: row.team)
                        Text(displayTeamName(for: row))
                            .font(.subheadline)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        cell(String(row.played), width: 30)
                        subtleCell(signedNumber(row.goalDifference), width: 34)
                        cell(String(row.points), width: 38, weight: .semibold)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(HighlightedTableRowBackground(isActive: highlightedRowID == row.id))
        .background(LiveStandingsRowBackground(isActive: row.live))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.team)
        .accessibilityValue(accessibilityStats(for: row))
        .accessibilityHint("View team details")
        .id(row.id)
    }

    private func tableSeparator(isThick: Bool) -> some View {
        Rectangle()
            .fill(Color.white.opacity(isThick ? 0.16 : 0.075))
            .frame(height: isThick ? 2.5 : 1)
    }

    private func zoneBoundary(_ zone: LeagueTableZone) -> some View {
        let color = zoneColor(zone)
        return HStack(spacing: 6) {
            ZoneDashedLine(color: color)
            Text(zoneDisplayLabel(zone))
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Image(systemName: zone.usesLookDownBoundary ? "chevron.down.circle" : "chevron.up.circle")
                .font(.caption.weight(.semibold))
            ZoneDashedLine(color: color)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(zoneDisplayLabel(zone)) positions \(zone.from) to \(zone.to)")
    }

    private func groupHeading(for group: LeagueTableGroup) -> String? {
        let name = String(group.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard let visibleStageName else { return name }
        if name.range(of: "phase", options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            return name
        }
        return "\(visibleStageName) \(name)"
    }

    private func isBenefitBoundary(in rows: [LeagueTableRow], after index: Int) -> Bool {
        guard index >= 0, index < rows.count - 1 else { return false }
        let current = normalizedRankStatus(rows[index].rankStatus)
        let next = normalizedRankStatus(rows[index + 1].rankStatus)
        return current != next
    }

    private func normalizedRankStatus(_ value: String?) -> String {
        String(value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func shortHeading(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .frame(width: width, alignment: .trailing)
    }

    private func statsHeading(
        _ text: String,
        width: CGFloat,
        alignment: Alignment = .center
    ) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: width, alignment: alignment)
    }

    private func cell(_ text: String, width: CGFloat, weight: Font.Weight = .regular) -> some View {
        Text(text)
            .font(.body.monospacedDigit().weight(weight))
            .scaleEffect(0.7)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }

    private func positionCell(_ row: LeagueTableRow) -> some View {
        HStack(spacing: 2) {
            trendIcon(for: row)
            Text(String(row.position))
                .font(.body.monospacedDigit())
                .scaleEffect(0.7)
                .lineLimit(1)
        }
        .frame(width: 40, alignment: .trailing)
        .overlay(alignment: .leading) {
            positionRail(for: row, height: 28)
        }
    }

    private func compactPositionCell(_ row: LeagueTableRow) -> some View {
        HStack(spacing: 1) {
            trendIcon(for: row)
            Text(String(row.position))
                .font(.caption.monospacedDigit())
                .lineLimit(1)
        }
        .padding(.leading, league.zones.isEmpty ? 0 : 6)
        .frame(width: 30, alignment: .leading)
        .overlay(alignment: .leading) {
            positionRail(for: row, height: 26)
        }
    }

    @ViewBuilder
    private func positionRail(for row: LeagueTableRow, height: CGFloat) -> some View {
        if !league.zones.isEmpty {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(zone(at: row.position).map(zoneColor) ?? Color.secondary.opacity(0.52))
                .frame(width: 3, height: height)
                .accessibilityHidden(true)
        }
    }

    private func statsCell(
        _ value: Int,
        width: CGFloat,
        signed: Bool = false,
        weight: Font.Weight = .regular
    ) -> some View {
        Text(signed ? signedNumber(value) : String(value))
            .font(.caption.monospacedDigit().weight(weight))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: width, alignment: .center)
    }

    private func compactForm(_ form: [String]) -> some View {
        let results = Array(form.prefix(5))
        return HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { index in
                if index < results.count {
                    formSymbol(results[index])
                } else {
                    Image(systemName: "minus")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .font(.system(size: 8, weight: .bold))
        .frame(width: 55)
        .accessibilityLabel(formAccessibilityLabel(results))
    }

    private func formSymbol(_ result: String) -> some View {
        let normalized = result.uppercased()
        return Image(
            systemName: normalized == "W"
                ? "checkmark.circle.fill"
                : normalized == "L" ? "xmark.circle.fill" : "minus.circle.fill"
        )
        .foregroundStyle(
            normalized == "W" ? Color.green : normalized == "L" ? Color.red : Color.secondary
        )
    }

    private func formAccessibilityLabel(_ form: [String]) -> String {
        guard !form.isEmpty else { return "No recent form" }
        let results = form.map { result in
            switch result.uppercased() {
            case "W": return "win"
            case "L": return "loss"
            default: return "draw"
            }
        }
        return "Recent form: \(results.joined(separator: ", "))"
    }

    private func accessibilityStats(for row: LeagueTableRow) -> String {
        let zoneDescription = zone(at: row.position)
            .map { " \(zoneDisplayLabel($0)) zone." } ?? ""
        return "Position \(row.position), played \(row.played), won \(row.won), drawn \(row.drawn), lost \(row.lost), goals for \(row.goalsFor), goals against \(row.goalsAgainst), goal difference \(signedNumber(row.goalDifference)), \(row.points) points.\(zoneDescription) \(formAccessibilityLabel(Array(row.form.prefix(5))))"
    }

    @ViewBuilder
    private func trendIcon(for row: LeagueTableRow) -> some View {
        switch row.positionTrend {
        case .up:
            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.liveMatch)
        case .down:
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.red)
        case .same:
            Image(systemName: "minus")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.secondary)
        case .none:
            EmptyView()
        }
    }

    private func subtleCell(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }

    private func signedNumber(_ value: Int) -> String {
        if value > 0 {
            return "+\(value)"
        }
        return String(value)
    }

    private func displayTeamName(for row: LeagueTableRow) -> String {
        let canonicalName = TeamIdentityStore.shared.canonicalName(for: row.team)
        return FantasyTeamShortNameMappingsStore.shared.resolveTeamName(for: canonicalName)
    }

    private func teamDetailsContext(for row: LeagueTableRow) -> TeamDetailsContext {
        let canonicalName = TeamIdentityStore.shared.canonicalName(for: row.team)
        let teamName = canonicalName.isEmpty ? row.team : canonicalName
        return TeamDetailsContext(
            teamID: nil,
            teamName: teamName,
            displayName: displayTeamName(for: row),
            alternateNames: teamName == row.team ? [] : [row.team],
            originatingLeagueID: league.leagueID,
            originatingLeagueName: league.leagueName,
            originatingMatch: nil
        )
    }

    private func zone(at position: Int) -> LeagueTableZone? {
        league.zones.first { $0.contains(position: position) }
    }

    private func lookDownZonesStarting(at position: Int) -> [LeagueTableZone] {
        league.zones.filter { $0.usesLookDownBoundary && $0.from == position }
    }

    private func lookUpZonesEnding(at position: Int) -> [LeagueTableZone] {
        league.zones.filter { !$0.usesLookDownBoundary && $0.to == position }
    }

    private func shouldShowStandardSeparator(in rows: [LeagueTableRow], after index: Int) -> Bool {
        guard index >= 0, index < rows.count - 1 else { return false }
        guard lookUpZonesEnding(at: rows[index].position).isEmpty else { return false }
        return lookDownZonesStarting(at: rows[index + 1].position).isEmpty
    }

    private func zoneColor(_ zone: LeagueTableZone) -> Color {
        let descriptor = "\(zone.key) \(zone.label) \(zone.type)".lowercased()
        if descriptor.contains("playoff") || descriptor.contains("play-off") {
            return descriptor.contains("releg") ? .orange : .blue
        }
        if descriptor.contains("releg") {
            return .red
        }
        if descriptor.contains("promo") {
            return .green
        }
        return accentColor
    }

    private func zoneDisplayLabel(_ zone: LeagueTableZone) -> String {
        let descriptor = "\(zone.key) \(zone.label) \(zone.type)".lowercased()
        if descriptor.contains("playoff") || descriptor.contains("play-off") {
            return descriptor.contains("releg") ? "Relegation play-off" : "Play-offs"
        }
        return zone.label
    }
}

private struct ZoneDashedLine: View {
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let y = proxy.size.height / 2
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: proxy.size.width, y: y))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 1)
        .accessibilityHidden(true)
    }
}

// Pulsing accent highlight for the row scrolled to via a cross-tab navigation
// (e.g. tapping a team's league position chip on a match detail screen).
// Unlike the one-shot fade used elsewhere, this pulses indefinitely — it only
// moves when a new navigation target is selected, or clears via backButton.
private struct HighlightedTableRowBackground: View {
    let isActive: Bool

    @State private var pulsing = false

    var body: some View {
        Rectangle()
            .fill(Color.accentColor.opacity(isActive ? (pulsing ? 0.22 : 0.08) : 0))
            .animation(
                isActive ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default,
                value: pulsing
            )
            .onAppear { pulsing = isActive }
            .onChange(of: isActive) { _, newValue in pulsing = newValue }
    }
}

private struct TableTeamLogo: View {
    let name: String

    var body: some View {
        Group {
            if let image = LogoResolver.shared.image(for: name) {
                Image(uiImage: image)
                    .resizable()
            } else {
                Image(systemName: "shield")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 18, height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityHidden(true)
    }
}

#Preview {
    TablesView()
        .environmentObject(PreferencesStore())
}
