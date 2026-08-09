import SwiftUI
import UIKit

enum MatchesViewMode: String, Sendable {
    case fixtures
    case results

    var title: String {
        switch self {
        case .fixtures:
            return "Fixtures"
        case .results:
            return "Results"
        }
    }

    var headingIconName: String {
        switch self {
        case .fixtures:
            return "calendar"
        case .results:
            return "clock.arrow.circlepath"
        }
    }

    var loadingText: String {
        switch self {
        case .fixtures:
            return "Loading fixtures"
        case .results:
            return "Loading results"
        }
    }

    var loadingServerText: String {
        switch self {
        case .fixtures:
            return "Loading fixtures from server"
        case .results:
            return "Loading results from server"
        }
    }

    var loadingServerSubtitle: String {
        switch self {
        case .fixtures:
            return "Fetching latest fixture data..."
        case .results:
            return "Fetching latest results data..."
        }
    }

    var refreshAccessibilityLabel: String {
        switch self {
        case .fixtures:
            return "Refresh fixtures"
        case .results:
            return "Refresh results"
        }
    }

    var emptyStateTitle: String {
        switch self {
        case .fixtures:
            return "No fixtures to show"
        case .results:
            return "No results to show"
        }
    }

    var emptyStateSubtitle: String {
        switch self {
        case .fixtures:
            return "Fixtures appear here..."
        case .results:
            return "Results appear here..."
        }
    }

    var refreshProgressText: String {
        switch self {
        case .fixtures:
            return "Refreshing fixtures"
        case .results:
            return "Refreshing results"
        }
    }
}

struct MatchesView: View {
    let mode: MatchesViewMode
    var isSelected: Bool = true

    // Deliberately not observed: only this mode's view state should trigger
    // re-renders. Store access is for method calls (configure/refresh/etc).
    private let matchesStore: MatchesStore
    @ObservedObject private var viewState: MatchesModeViewState

    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var fantasyViewModel: FantasyViewModel
    @AppStorage(AppGroupConfig.fantasyManagerEntryIDKey) private var fantasyManagerEntryID = ""
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var predictionIndex = FixturePredictionStore.allPredictions()
    @State private var pendingPredictionDateKeys: Set<String> = []
    @State private var attemptedPredictionDateKeys: Set<String> = []
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var searchFilterWorkItem: DispatchWorkItem?
    @State private var groupedSideEffectsTask: Task<Void, Never>?
    @State private var isSearchVisible = false
    @State private var isSearchFieldFocused = false
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var filteredMatchDays: [MatchDay] = []
    @State private var indexedMatchDays: [IndexedMatchDay] = []
    @State private var reportedMissingLogoNames: Set<String> = []
    @State private var didRunActivationForVisibleCycle = false
    @State private var navigationMatch: MatchNavigation?
    @State private var screenOpenedAt: Date?
    @State private var screenViewSentForActivation = false
    @State private var visibleGroupedDays: [MatchDay] = []
    @State private var visibleGroupedDaysSource: [MatchDay] = []

    init(mode: MatchesViewMode, isSelected: Bool = true, store: MatchesStore) {
        self.mode = mode
        self.isSelected = isSelected
        self.matchesStore = store
        self.viewState = store.viewState(for: mode)
    }

    private static let minimumSearchCharacters = 3
    private static let searchDebounceNanoseconds: UInt64 = 250_000_000
    private static let searchFilterQueue = DispatchQueue(label: "TopScores.match-search", qos: .userInitiated)

    private struct CompactFixturesSpacingProfile {
        let dayHeaderTopFirst: CGFloat
        let dayHeaderTop: CGFloat
        let dayHeaderBottom: CGFloat
        let leagueHeadingTop: CGFloat
        let leagueHeadingBottom: CGFloat
        let rowTop: CGFloat
        let rowBottom: CGFloat
        let minListRowHeight: CGFloat
    }

    private let groupedSideEffectsDelayNanos: UInt64 = 1_500_000_000

    private var showAllMatches: Bool {
        preferences.showAllMatches
    }

    private var matchRowPreferences: MatchRowPreferences {
        MatchRowPreferences(
            preferences: preferences,
            hasFantasyManagerEntry: !fantasyManagerEntryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private var compactFixturesSpacing: CompactFixturesSpacingProfile {
        CompactFixturesSpacingProfile(
            dayHeaderTopFirst: 6,
            dayHeaderTop: 10,
            dayHeaderBottom: 2,
            leagueHeadingTop: 3,
            leagueHeadingBottom: 2,
            rowTop: 2,
            rowBottom: 5,
            minListRowHeight: 24
        )
    }

    private var compactDayHeaderFont: Font {
        .headline
    }

    private var normalizedDebouncedQuery: String {
        Self.normalizedSearchText(debouncedSearchText)
    }

    private var normalizedLiveQuery: String {
        Self.normalizedSearchText(searchText)
    }

    private var isSearchFilteringActive: Bool {
        normalizedDebouncedQuery.count >= Self.minimumSearchCharacters
    }

    private var displayedMatchDays: [MatchDay] {
        if isSearchFilteringActive {
            guard !preferences.showPostponedGames else { return filteredMatchDays }
            return Self.filteringPostponed(filteredMatchDays)
        }
        // Postponed filtering over the full dataset is cached in visibleGroupedDays
        // so it doesn't run on every body evaluation.
        return visibleGroupedDays
    }

    private func refreshVisibleGroupedDays(from days: [MatchDay], force: Bool = false) {
        // Identical-storage arrays compare in O(1), so unchanged data is a no-op.
        if !force && days == visibleGroupedDaysSource { return }
        visibleGroupedDaysSource = days
        visibleGroupedDays = preferences.showPostponedGames ? days : Self.filteringPostponed(days)
    }

    private static func filteringPostponed(_ days: [MatchDay]) -> [MatchDay] {
        days.compactMap { day in
            let filteredLeagues = day.leagues.compactMap { league -> MatchLeague? in
                let filteredMatches = league.matches.filter { !$0.isPostponed }
                guard !filteredMatches.isEmpty else { return nil }
                return MatchLeague(id: league.id, league: league.league, matches: filteredMatches)
            }
            guard !filteredLeagues.isEmpty else { return nil }
            return MatchDay(
                id: day.id,
                dateKey: day.dateKey,
                displayDate: day.displayDate,
                isToday: day.isToday,
                isTomorrow: day.isTomorrow,
                leagues: filteredLeagues
            )
        }
    }

    private let refreshFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var navigationStackContent: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                headerView
                Group {
                    if viewState.groupedMatches.isEmpty && viewState.isLoading {
                        ServerLoadingStateView(mode: mode)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if displayedMatchDays.isEmpty {
                        emptyState
                    } else {
                        matchesList
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .background(Color(.systemBackground))
            .overlay(alignment: .top) {
                if showToast {
                    ToastView(message: toastMessage)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .navigationDestination(item: $navigationMatch) { nav in
            MatchDetailView(
                match: nav.match,
                highlightToday: nav.highlightToday,
                showFantasyBadge: nav.showFantasyBadge,
                predictionDisplay: nav.predictionDisplay
            )
        }
    }

    var body: some View {
        NavigationStack {
            navigationStackContent
        }
        .onAppear {
            refreshVisibleGroupedDays(from: viewState.groupedMatches)
            guard isSelected else { return }
            runActivationIfNeeded(logEvent: "onAppear")
            beginScreenViewTiming()
        }
        .onChange(of: isSelected) { _, selected in
            matchesStore.setModeVisibility(mode, isVisible: selected)
            guard selected else {
                isSearchFieldFocused = false
                didRunActivationForVisibleCycle = false
                screenOpenedAt = nil
                screenViewSentForActivation = false
                return
            }
            refreshVisibleGroupedDays(from: viewState.groupedMatches)
            runActivationIfNeeded(logEvent: "isSelected")
            beginScreenViewTiming()
        }
        .onChange(of: viewState.isLoading) { _, isLoading in
            guard !isLoading else { return }
            sendTimedScreenView()
        }
        .onChange(of: preferences.snapshot) { _, _ in
            guard isSelected else { return }
            let snapshot = showAllMatches ? preferences.unfilteredSnapshot : preferences.snapshot
            NSLog("[MatchesView] snapshot_change mode=%@ showAllMatches=%d epl_pref=%d effective_snapshot=%@",
                  mode.rawValue, showAllMatches, preferences.englishPremierLeagueTeamsOnly, debugSnapshotSummary(snapshot))
            matchesStore.configure(with: snapshot, mode: mode)
            scheduleGroupedSideEffects(for: viewState.groupedMatches, immediate: false)
        }
        .onChange(of: preferences.showAllMatches) { _, newValue in
            guard isSelected else { return }
            let snapshot = newValue ? preferences.unfilteredSnapshot : preferences.snapshot
            NSLog("[MatchesView] showAllMatches_change mode=%@ value=%d snapshot=%@", mode.rawValue, newValue, debugSnapshotSummary(snapshot))
            matchesStore.configure(with: snapshot, mode: mode)
            toastMessage = newValue ? "Viewing all matches (unfiltered)" : "Viewing preferred matches only"
            withAnimation {
                showToast = true
            }
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                withAnimation {
                    showToast = false
                }
            }
        }
        .onChange(of: viewState.groupedMatches) { _, days in
            refreshVisibleGroupedDays(from: days)
            // A refreshed fixture payload may now have markets for a day that was
            // previously unavailable. Keep retries tied to data refreshes, never
            // to a row appearing again while the list is being scrolled.
            attemptedPredictionDateKeys.removeAll()
            guard isSelected else { return }
            warmPredictionsForVisibleDays(days: days)
            scheduleGroupedSideEffects(for: days, immediate: false)
        }
        .onChange(of: preferences.showPostponedGames) { _, _ in
            refreshVisibleGroupedDays(from: viewState.groupedMatches, force: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: FixturePredictionStore.didChangeNotification)) { _ in
            guard isSelected else { return }
            predictionIndex = FixturePredictionStore.allPredictions()
        }
        .onChange(of: searchText) { _, newValue in
            scheduleDebouncedSearch(for: newValue)
        }
        .onDisappear {
            matchesStore.setModeVisibility(mode, isVisible: false)
            isSearchFieldFocused = false
            searchDebounceTask?.cancel()
            searchFilterWorkItem?.cancel()
            groupedSideEffectsTask?.cancel()
        }
    }

    private func beginScreenViewTiming() {
        screenOpenedAt = Date()
        screenViewSentForActivation = false
        if !viewState.isLoading {
            sendTimedScreenView()
        }
    }

    private func sendTimedScreenView() {
        guard !screenViewSentForActivation else { return }
        screenViewSentForActivation = true
        let durationMs = screenOpenedAt.map { Int(Date().timeIntervalSince($0) * 1000) }
        screenOpenedAt = nil
        AppMetricsService.shared.fireScreenView(screen: mode.rawValue, durationMs: durationMs, apiBaseURL: preferences.apiBaseURL)
    }

    private func ensureFantasySquadLoadedIfNeeded() {
        guard mode == .fixtures,
              preferences.showsFantasyDataInFixtures,
              !fantasyManagerEntryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              fantasyViewModel.data == nil,
              !fantasyViewModel.isLoading,
              !fantasyViewModel.isRefreshing,
              viewState.groupedMatches.contains(where: { day in
                  day.leagues.contains(where: { league in
                      league.matches.contains(where: {
                          $0.league.trimmingCharacters(in: .whitespacesAndNewlines)
                              .localizedCaseInsensitiveCompare("Premier League") == .orderedSame
                      })
                  })
              })
        else {
            return
        }

        Task {
            await fantasyViewModel.refresh(
                managerEntryID: fantasyManagerEntryID,
                apiBaseURL: preferences.apiBaseURL,
                rivalManagers: [],
                trackedLeagues: []
            )
        }
    }

    private func debugSnapshotSummary(_ snapshot: PreferencesSnapshot) -> String {
        "competition=\(snapshot.competitionFilterEnabled) epl=\(snapshot.englishPremierLeagueTeamsOnly) " +
        "major_uefa=\(snapshot.majorUEFAClubGamesEnabled) " +
        "home_nations=\(snapshot.homeNationsFilterEnabled) major=\(snapshot.majorTournamentsFilterEnabled) " +
        "channels=\(snapshot.channelFilterEnabled) show_all=\(snapshot.showAllMatches)"
    }

    private var matchesList: some View {
        List {
            ForEach(Array(displayedMatchDays.enumerated()), id: \.element.id) { index, day in
                Section {
                    compactLeagueRows(for: day)
                } header: {
                    sectionHeader(for: day, isFirst: index == 0)
                }
            }

            if mode == .results && viewState.isLoadingMoreMatches {
                loadingMoreMatchesRow
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, compactFixturesSpacing.minListRowHeight)
        .safeAreaPadding(.bottom, 80)
        .refreshable {
            let refreshStart = Date()
            let snapshot = showAllMatches ? preferences.unfilteredSnapshot : preferences.snapshot
            matchesStore.queueRefresh(
                preferences: snapshot,
                mode: mode,
                reason: "pull_to_refresh",
                force: true
            )
            await Task.yield()
            let durationMs = Int(Date().timeIntervalSince(refreshStart) * 1000)
            AppMetricsService.shared.fireActivity("manual_refresh", screen: mode.rawValue, durationMs: durationMs, apiBaseURL: preferences.apiBaseURL)
        }
    }

    private var loadingMoreMatchesRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(.accentColor)
            Text("Loading more matches...")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
    }

    private func sectionHeader(for day: MatchDay, isFirst: Bool) -> some View {
        HStack(spacing: 12) {
            Text(day.displayDate)
                .font(compactDayHeaderFont)
                .fontWeight(.semibold)

            Spacer()
        }
        .padding(.top, isFirst ? compactFixturesSpacing.dayHeaderTopFirst : compactFixturesSpacing.dayHeaderTop)
        .padding(.bottom, compactFixturesSpacing.dayHeaderBottom)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(.separator).opacity(0.35))
                .frame(height: 0.5)
        }
        .textCase(nil)
    }

    @ViewBuilder
    private func compactLeagueRows(for day: MatchDay) -> some View {
        ForEach(day.leagues) { league in
            leagueHeadingDividerRow(for: league)

            ForEach(Array(league.matches.enumerated()), id: \.element.id) { index, match in
                let prevTime: String? = index > 0 ? league.matches[index - 1].time : nil
                if shouldShowKickoffDivider(currentTime: match.time, previousTime: prevTime) {
                    kickoffDividerRow(time: match.time)
                }
                matchRow(for: match, day: day)
            }
        }
    }

    private func shouldShowKickoffDivider(currentTime: String, previousTime: String?) -> Bool {
        mode == .fixtures &&
        preferences.showKickoffTimeDividers &&
        previousTime != nil &&
        previousTime != currentTime
    }

    private func leagueHeadingDividerRow(for league: MatchLeague) -> some View {
        Text(league.league)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary.opacity(0.95))
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(
                EdgeInsets(
                    top: compactFixturesSpacing.leagueHeadingTop + 2,
                    leading: 16,
                    bottom: compactFixturesSpacing.leagueHeadingBottom,
                    trailing: 16
                )
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private func kickoffDividerRow(time: String) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(.white.opacity(0.08))
            Text(time)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary.opacity(0.55))
                .monospacedDigit()
                .fixedSize()
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(.white.opacity(0.08))
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 2, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private func matchRow(for match: Match, day: MatchDay) -> some View {
        let showFPLChevron = fantasyParticipationBadgeVisibility(
            for: match,
            showFantasyBadge: mode == .fixtures,
            layoutStyle: .compactFixture,
            rowPreferences: matchRowPreferences,
            fantasyContext: fantasyViewModel.matchRowContext
        )
        Button {
            navigationMatch = MatchNavigation(
                match: match,
                highlightToday: day.isToday,
                showFantasyBadge: mode == .fixtures,
                predictionDisplay: predictionDisplayState(for: match, dateKey: day.dateKey)
            )
        } label: {
            HStack(spacing: 0) {
                MatchesListRowLabel(
                    match: match,
                    isFixtureMode: mode == .fixtures,
                    highlightToday: day.isToday,
                    rowPreferences: matchRowPreferences,
                    fantasyContext: fantasyViewModel.matchRowContext,
                    predictionDisplay: predictionDisplayState(for: match, dateKey: day.dateKey)
                )
                .equatable()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(showFPLChevron ? .semibold : .regular))
                    .foregroundStyle(showFPLChevron
                        ? Color(red: 0.95, green: 0.20, blue: 0.66)
                        : Color(.tertiaryLabel))
                    .frame(width: 16)
            }
        }
        .disabled(match.isPostponed)
        .buttonStyle(.plain)
        .onAppear {
            guard mode == .results else { return }
            let snapshot = showAllMatches ? preferences.unfilteredSnapshot : preferences.snapshot
            Task {
                await matchesStore.prefetchIfNeeded(
                    currentMatch: match,
                    preferences: snapshot,
                    mode: mode
                )
            }
        }
        .listRowInsets(
            EdgeInsets(
                top: compactFixturesSpacing.rowTop,
                leading: 16,
                bottom: compactFixturesSpacing.rowBottom,
                trailing: 0
            )
        )
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func matchDebugFooterText(for match: Match) -> String? {
        return matchesStore.teamRatingDebugText(for: match)
    }

    /// Resolves what a row's trailing prediction chip should show. Predictions are
    /// precomputed in the background (see `warmPredictionsForVisibleDays`), so by the
    /// time a row scrolls into view its prediction is normally already in `predictionIndex`;
    /// `.pending` only appears for the brief window where a newly-loaded day is still warming up.
    private func predictionDisplayState(for match: Match, dateKey: String) -> FixturePredictionDisplayState {
        guard preferences.showPredictedScores else { return .hidden }
        if let stored = predictionIndex[match.id], stored.isPredicted {
            return .available(
                homeGoals: stored.homeGoals ?? 0,
                awayGoals: stored.awayGoals ?? 0,
                homeWinProbability: stored.homeWinProbability ?? 0,
                drawProbability: stored.drawProbability ?? 0,
                awayWinProbability: stored.awayWinProbability ?? 0
            )
        }
        guard mode == .fixtures, !match.isPostponed, let kickoff = match.dateTime, kickoff > Date() else {
            return .hidden
        }
        return pendingPredictionDateKeys.contains(dateKey) ? .pending : .hidden
    }

    /// Precomputes and freezes predictions for any visible day that has upcoming,
    /// not-yet-predicted fixtures. Idempotent per match: a match that already has a
    /// stored prediction is never recomputed, so once frozen it stays comparable
    /// against the eventual real result.
    private func warmPredictionsForVisibleDays(days: [MatchDay]) {
        guard mode == .fixtures else { return }
        let now = Date()
        var newlyQueued: [(dateKey: String, displayDate: String, matches: [Match])] = []
        for day in days {
            guard !pendingPredictionDateKeys.contains(day.dateKey),
                  !attemptedPredictionDateKeys.contains(day.dateKey)
            else { continue }
            let matches = day.leagues.flatMap(\.matches)
            let needsPrediction = matches.contains { match in
                guard let kickoff = match.dateTime, kickoff > now, !match.isPostponed else { return false }
                if let stored = predictionIndex[match.id], stored.isPredicted { return false }
                return true
            }
            guard needsPrediction else { continue }
            newlyQueued.append((day.dateKey, day.displayDate, matches))
        }
        guard !newlyQueued.isEmpty else { return }
        pendingPredictionDateKeys.formUnion(newlyQueued.map(\.dateKey))

        let apiBaseURL = preferences.apiBaseURL
        let existingSnapshot = predictionIndex
        Task {
            for (dateKey, displayDate, matches) in newlyQueued {
                guard !Task.isCancelled else { return }
                let job = PredictionJob(dateKey: dateKey, displayDate: displayDate, matches: matches)
                let fixtures = try? await FixturePredictionGenerator.generate(
                    for: job,
                    apiBaseURL: apiBaseURL,
                    existingPredictions: existingSnapshot
                )
                await MainActor.run {
                    if let fixtures {
                        FixturePredictionStore.save(fixtures)
                        for fixture in fixtures where fixture.isPredicted {
                            predictionIndex[fixture.id] = fixture
                        }
                    }
                    pendingPredictionDateKeys.remove(dateKey)
                    attemptedPredictionDateKeys.insert(dateKey)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tv")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(isSearchFilteringActive ? "No matches found" : mode.emptyStateTitle)
                .font(.title3)
            Text(isSearchFilteringActive ? "Try a different search term." : mode.emptyStateSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerView: some View {
        TopLevelScreenHeader(screenTitle: mode.title) {
            Image(systemName: mode.headingIconName)
                .font(.system(size: 24, weight: .semibold))
        } accessory: {
            HStack(spacing: 8) {
                // EPL / All-competitions filter toggle
                Button {
                    let enabling = !preferences.englishPremierLeagueTeamsOnly
                    NSLog("[MatchesView] epl_toggle mode=%@ enabling=%d showAllMatches=%d", mode.rawValue, enabling, preferences.showAllMatches)
                    preferences.englishPremierLeagueTeamsOnly = enabling
                    if enabling && preferences.showAllMatches {
                        // showAllMatches forces unfilteredSnapshot, overriding all filters.
                        // Clear it so the actual snapshot (including EPL filter) is used.
                        preferences.showAllMatches = false
                    }
                } label: {
                    FantasyLionIconView(size: 28)
                        .foregroundStyle(preferences.englishPremierLeagueTeamsOnly ? Color.accentColor : Color.primary)
                        .padding(8)
                        .background(Circle().fill(
                            preferences.englishPremierLeagueTeamsOnly
                                ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                                : AnyShapeStyle(.ultraThinMaterial)
                        ))
                }
                .accessibilityLabel(preferences.englishPremierLeagueTeamsOnly ? "Premier League teams only – tap for all competitions" : "All competitions – tap for Premier League teams only")

                // Predicted scores toggle
                Button {
                    preferences.showPredictedScores.toggle()
                    if preferences.showPredictedScores {
                        warmPredictionsForVisibleDays(days: viewState.groupedMatches)
                    }
                } label: {
                    Image(systemName: preferences.showPredictedScores ? "sparkles.rectangle.stack.fill" : "sparkles")
                        .font(.title3)
                        .padding(10)
                        .background(Circle().fill(
                            preferences.showPredictedScores
                                ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                                : AnyShapeStyle(.ultraThinMaterial)
                        ))
                        .foregroundStyle(preferences.showPredictedScores ? Color.accentColor : Color.primary)
                }
                .accessibilityLabel(preferences.showPredictedScores ? "Hide predicted scores" : "Show predicted scores")

                // Search toggle
                Button {
                    if isSearchVisible {
                        hideSearchAndClear()
                    } else {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSearchVisible = true
                        }
                        isSearchFieldFocused = true
                        rebuildSearchIndex(from: viewState.groupedMatches)
                        AppMetricsService.shared.fireActivity("search_activated", screen: mode.rawValue, apiBaseURL: preferences.apiBaseURL)
                    }
                } label: {
                    Image(systemName: isSearchVisible ? "magnifyingglass.circle.fill" : "magnifyingglass")
                        .font(.title3)
                        .padding(10)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .accessibilityLabel(isSearchVisible ? "Hide search and clear text" : "Show match search")
            }
        } detail: {
            if isSearchVisible {
                MatchSearchBar(
                    text: $searchText,
                    isFocused: $isSearchFieldFocused,
                    placeholder: "Search teams, leagues or channels"
                )
                    .frame(height: 44)
                    .transition(.move(edge: .top).combined(with: .opacity))

                if !normalizedLiveQuery.isEmpty, normalizedLiveQuery.count < Self.minimumSearchCharacters {
                    Text("Type at least \(Self.minimumSearchCharacters) characters to search.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if viewState.errorMessage != nil || (viewState.groupedMatches.isEmpty && viewState.isLoading) || viewState.lastUpdated != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = viewState.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    // Only show the loading indicator when there is no data yet (initial load).
                    // When cached/fresh data is already visible a background refresh should not
                    // disrupt the layout or replace the "Updated" timestamp with a spinner.
                    if viewState.groupedMatches.isEmpty && viewState.isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(mode.loadingServerText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else if let lastUpdated = viewState.lastUpdated {
                        let cachedSuffix = viewState.isUsingCache ? " (cached)" : ""
                        Text("Updated \(refreshFormatter.string(from: lastUpdated))\(cachedSuffix)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func hideSearchAndClear() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        searchFilterWorkItem?.cancel()
        searchFilterWorkItem = nil
        searchText = ""
        debouncedSearchText = ""
        filteredMatchDays = []
        isSearchFieldFocused = false
        withAnimation(.easeInOut(duration: 0.2)) {
            isSearchVisible = false
        }
    }

    private func scheduleDebouncedSearch(for rawText: String) {
        searchDebounceTask?.cancel()
        searchFilterWorkItem?.cancel()
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            debouncedSearchText = ""
            filteredMatchDays = []
            return
        }

        searchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: Self.searchDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            debouncedSearchText = trimmed
            applySearchFilter()
        }
    }

    private func scheduleGroupedSideEffects(for days: [MatchDay], immediate: Bool) {
        groupedSideEffectsTask?.cancel()
        groupedSideEffectsTask = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: groupedSideEffectsDelayNanos)
            }
            guard !Task.isCancelled else { return }
            rebuildSearchIndex(from: days)
            ensureFantasySquadLoadedIfNeeded()
            reportMissingTeamLogosIfNeeded(days: days)
        }
    }

    private func runActivationIfNeeded(logEvent: String) {
        guard !didRunActivationForVisibleCycle else { return }
        didRunActivationForVisibleCycle = true
        matchesStore.setModeVisibility(mode, isVisible: true)
        let snapshot = showAllMatches ? preferences.unfilteredSnapshot : preferences.snapshot
        NSLog("[MatchesView] %@ mode=%@ selected=%d snapshot=%@", logEvent, mode.rawValue, isSelected, debugSnapshotSummary(snapshot))
        matchesStore.configure(with: snapshot, mode: mode)
        let days = viewState.groupedMatches
        predictionIndex = FixturePredictionStore.allPredictions()
        warmPredictionsForVisibleDays(days: days)
        scheduleGroupedSideEffects(for: days, immediate: false)
    }

    private func rebuildSearchIndex(from days: [MatchDay]) {
        guard isSearchVisible || isSearchFilteringActive else {
            indexedMatchDays = []
            filteredMatchDays = []
            return
        }

        indexedMatchDays = days.map { day in
            let indexedLeagues = day.leagues.map { league in
                let indexedMatches = league.matches.map { match in
                    IndexedMatch(
                        match: match,
                        searchText: Self.normalizedSearchText(
                            [
                                match.homeTeam,
                                match.awayTeam,
                                match.displayLeague,
                                match.time,
                                match.tvChannels.map(\.name).joined(separator: " ")
                            ].joined(separator: " ")
                        )
                    )
                }
                return IndexedMatchLeague(id: league.id, league: league.league, matches: indexedMatches)
            }
            return IndexedMatchDay(
                id: day.id,
                dateKey: day.dateKey,
                displayDate: day.displayDate,
                isToday: day.isToday,
                isTomorrow: day.isTomorrow,
                leagues: indexedLeagues
            )
        }

        applySearchFilter()
    }

    private func applySearchFilter() {
        let query = normalizedDebouncedQuery
        guard query.count >= Self.minimumSearchCharacters else {
            searchFilterWorkItem?.cancel()
            searchFilterWorkItem = nil
            filteredMatchDays = []
            return
        }

        searchFilterWorkItem?.cancel()
        let scheduledQuery = query
        let indexedDays = indexedMatchDays
        let workItem = DispatchWorkItem {
            let result = Self.filterDays(indexedDays, query: scheduledQuery)
            DispatchQueue.main.async {
                guard scheduledQuery == self.normalizedDebouncedQuery else { return }
                self.filteredMatchDays = result
            }
        }
        searchFilterWorkItem = workItem
        Self.searchFilterQueue.async(execute: workItem)
    }

    private static func normalizedSearchText(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func filterDays(_ indexedDays: [IndexedMatchDay], query: String) -> [MatchDay] {
        var result: [MatchDay] = []
        result.reserveCapacity(indexedDays.count)

        for day in indexedDays {
            var dayLeagues: [MatchLeague] = []
            dayLeagues.reserveCapacity(day.leagues.count)

            for league in day.leagues {
                var leagueMatches: [Match] = []
                leagueMatches.reserveCapacity(league.matches.count)

                for indexedMatch in league.matches where indexedMatch.searchText.contains(query) {
                    leagueMatches.append(indexedMatch.match)
                }

                if !leagueMatches.isEmpty {
                    dayLeagues.append(MatchLeague(id: league.id, league: league.league, matches: leagueMatches))
                }
            }

            if !dayLeagues.isEmpty {
                result.append(
                    MatchDay(
                        id: day.id,
                        dateKey: day.dateKey,
                        displayDate: day.displayDate,
                        isToday: day.isToday,
                        isTomorrow: day.isTomorrow,
                        leagues: dayLeagues
                    )
                )
            }
        }

        return result
    }

    private func reportMissingTeamLogosIfNeeded(days: [MatchDay]) {
        let teamEntries = days
            .flatMap(\.leagues)
            .flatMap(\.matches)
            .flatMap {
                [
                    ($0.homeTeam, [$0.homeShortName].compactMap { $0 }),
                    ($0.awayTeam, [$0.awayShortName].compactMap { $0 }),
                ]
            }

        let missingTeamNames = Set(LogoResolver.shared.missingTeamNames(in: teamEntries))
            .subtracting(reportedMissingLogoNames)
        guard !missingTeamNames.isEmpty else { return }
        guard let baseURL = URL(string: preferences.apiBaseURL) else { return }
        reportedMissingLogoNames.formUnion(missingTeamNames)

        Task {
            let client = APIClient(baseURL: baseURL)
            do {
                try await client.reportMissingTeamLogos(Array(missingTeamNames))
            } catch {
                NSLog("Missing logo audit post failed error=%@", String(describing: error))
            }
        }
    }
}

private struct IndexedMatchDay {
    let id: String
    let dateKey: String
    let displayDate: String
    let isToday: Bool
    let isTomorrow: Bool
    let leagues: [IndexedMatchLeague]
}

private struct IndexedMatchLeague {
    let id: String
    let league: String
    let matches: [IndexedMatch]
}

private struct IndexedMatch {
    let match: Match
    let searchText: String
}

private struct MatchSearchBar: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    func makeUIView(context: Context) -> UISearchBar {
        let searchBar = UISearchBar(frame: .zero)
        searchBar.searchBarStyle = .minimal
        searchBar.placeholder = placeholder
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.returnKeyType = .search
        searchBar.delegate = context.coordinator
        return searchBar
    }

    func updateUIView(_ searchBar: UISearchBar, context: Context) {
        if searchBar.text != text {
            searchBar.text = text
        }
        context.coordinator.updateFocus(for: searchBar, shouldFocus: isFocused)
    }

    final class Coordinator: NSObject, UISearchBarDelegate {
        private var text: Binding<String>
        private var isFocused: Binding<Bool>

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
        }

        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
            text.wrappedValue = searchText
        }

        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            if !isFocused.wrappedValue {
                isFocused.wrappedValue = true
            }
        }

        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
            if isFocused.wrappedValue {
                isFocused.wrappedValue = false
            }
        }

        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            isFocused.wrappedValue = false
        }

        func updateFocus(for searchBar: UISearchBar, shouldFocus: Bool) {
            if shouldFocus {
                guard !searchBar.isFirstResponder else { return }
                guard searchBar.window != nil else {
                    DispatchQueue.main.async { [weak searchBar] in
                        guard let searchBar else { return }
                        self.updateFocus(for: searchBar, shouldFocus: shouldFocus)
                    }
                    return
                }
                searchBar.becomeFirstResponder()
            } else if searchBar.isFirstResponder {
                searchBar.resignFirstResponder()
            }
        }
    }
}

private struct MatchesListRowLabel: View, Equatable {
    let match: Match
    let isFixtureMode: Bool
    let highlightToday: Bool
    let rowPreferences: MatchRowPreferences
    let fantasyContext: FantasyMatchRowContext
    let predictionDisplay: FixturePredictionDisplayState

    var body: some View {
        MatchRow(
            match: match,
            highlightToday: highlightToday,
            showLeague: false,
            showFantasyBadge: isFixtureMode,
            showFantasyPlayerContributions: isFixtureMode,
            teamLogoScale: 1.1,
            showsFinishedInlineAggregateBrackets: true,
            layoutStyle: .compactFixture,
            fantasyContext: fantasyContext,
            rowPreferences: rowPreferences,
            predictionDisplay: predictionDisplay
        )
    }
}

private struct MatchNavigation: Identifiable, Hashable, Sendable {
    let match: Match
    let highlightToday: Bool
    let showFantasyBadge: Bool
    let predictionDisplay: FixturePredictionDisplayState
    var id: String { match.id }
}

private struct PredictionJob: Identifiable, Sendable {
    let id = UUID()
    let dateKey: String
    let displayDate: String
    let matches: [Match]
}

private struct PredictedFixture: Codable, Identifiable, Sendable {
    let id: String
    let date: String
    let time: String
    let league: String
    let leagueSubcategory: String?
    let homeTeam: String
    let awayTeam: String
    let homeShortName: String?
    let awayShortName: String?
    let tvChannels: [String]
    let homeGoals: Int?
    let awayGoals: Int?
    let expectedHomeGoals: Double?
    let expectedAwayGoals: Double?
    let homeWinProbability: Double?
    let drawProbability: Double?
    let awayWinProbability: Double?
    let unavailableReason: String?
    let isPostponed: Bool

    var isPredicted: Bool {
        homeGoals != nil && awayGoals != nil && unavailableReason == nil && !isPostponed
    }
}

extension PredictedFixture {
    private enum CodingKeys: String, CodingKey {
        case id
        case date
        case time
        case league
        case leagueSubcategory
        case homeTeam
        case awayTeam
        case homeShortName
        case awayShortName
        case tvChannels
        case homeGoals
        case awayGoals
        case expectedHomeGoals
        case expectedAwayGoals
        case homeWinProbability
        case drawProbability
        case awayWinProbability
        case unavailableReason
        case isPostponed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        date = try container.decode(String.self, forKey: .date)
        time = try container.decode(String.self, forKey: .time)
        league = try container.decode(String.self, forKey: .league)
        leagueSubcategory = try container.decodeIfPresent(String.self, forKey: .leagueSubcategory)
        homeTeam = try container.decode(String.self, forKey: .homeTeam)
        awayTeam = try container.decode(String.self, forKey: .awayTeam)
        homeShortName = try container.decodeIfPresent(String.self, forKey: .homeShortName)
        awayShortName = try container.decodeIfPresent(String.self, forKey: .awayShortName)
        tvChannels = try container.decodeIfPresent([String].self, forKey: .tvChannels) ?? []
        homeGoals = try container.decodeIfPresent(Int.self, forKey: .homeGoals)
        awayGoals = try container.decodeIfPresent(Int.self, forKey: .awayGoals)
        expectedHomeGoals = try container.decodeIfPresent(Double.self, forKey: .expectedHomeGoals)
        expectedAwayGoals = try container.decodeIfPresent(Double.self, forKey: .expectedAwayGoals)
        homeWinProbability = try container.decodeIfPresent(Double.self, forKey: .homeWinProbability)
        drawProbability = try container.decodeIfPresent(Double.self, forKey: .drawProbability)
        awayWinProbability = try container.decodeIfPresent(Double.self, forKey: .awayWinProbability)
        unavailableReason = try container.decodeIfPresent(String.self, forKey: .unavailableReason)
        isPostponed = try container.decodeIfPresent(Bool.self, forKey: .isPostponed) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(date, forKey: .date)
        try container.encode(time, forKey: .time)
        try container.encode(league, forKey: .league)
        try container.encodeIfPresent(leagueSubcategory, forKey: .leagueSubcategory)
        try container.encode(homeTeam, forKey: .homeTeam)
        try container.encode(awayTeam, forKey: .awayTeam)
        try container.encodeIfPresent(homeShortName, forKey: .homeShortName)
        try container.encodeIfPresent(awayShortName, forKey: .awayShortName)
        try container.encode(tvChannels, forKey: .tvChannels)
        try container.encodeIfPresent(homeGoals, forKey: .homeGoals)
        try container.encodeIfPresent(awayGoals, forKey: .awayGoals)
        try container.encodeIfPresent(expectedHomeGoals, forKey: .expectedHomeGoals)
        try container.encodeIfPresent(expectedAwayGoals, forKey: .expectedAwayGoals)
        try container.encodeIfPresent(homeWinProbability, forKey: .homeWinProbability)
        try container.encodeIfPresent(drawProbability, forKey: .drawProbability)
        try container.encodeIfPresent(awayWinProbability, forKey: .awayWinProbability)
        try container.encodeIfPresent(unavailableReason, forKey: .unavailableReason)
        try container.encode(isPostponed, forKey: .isPostponed)
    }
}

private struct FixturePredictionCachePayload: Codable {
    // Keyed by match id. Entries are written once (when a prediction is first
    // computed for an upcoming fixture) and never overwritten, so a finished
    // match's prediction stays available to compare against the real result.
    var entries: [String: PredictedFixture]
}

enum FixturePredictionStore {
    private static let fileName = "fixture-predictions.json"
    static let didChangeNotification = Notification.Name("FixturePredictionStore.didChange")

    fileprivate static func allPredictions() -> [String: PredictedFixture] {
        loadCache().entries
    }

    /// Persists newly-computed predictions. Only successfully-predicted fixtures
    /// are stored; matches that couldn't be predicted (no markets yet, postponed,
    /// etc.) are left out so they're retried on a future warm-up pass.
    fileprivate static func save(_ fixtures: [PredictedFixture]) {
        let predicted = fixtures.filter(\.isPredicted)
        guard !predicted.isEmpty else { return }
        var cache = loadCache()
        for fixture in predicted {
            cache.entries[fixture.id] = fixture
        }
        persist(cache)
    }

    static func clearAll() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: cacheURL)
        notifyDidChange()
    }

    private static func loadCache() -> FixturePredictionCachePayload {
        guard let data = try? Data(contentsOf: cacheURL) else {
            return FixturePredictionCachePayload(entries: [:])
        }
        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(FixturePredictionCachePayload.self, from: data) else {
            return FixturePredictionCachePayload(entries: [:])
        }
        return payload
    }

    private static func persist(_ payload: FixturePredictionCachePayload) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: cacheURL, options: [.atomic])
        notifyDidChange()
    }

    private static func notifyDidChange() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    private static var cacheURL: URL {
        let fileManager = FileManager.default
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = baseURL.appendingPathComponent("TopScores", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }
}

private enum FixturePredictionError: LocalizedError {
    case invalidAPIBaseURL

    var errorDescription: String? {
        switch self {
        case .invalidAPIBaseURL:
            return "Invalid API base URL for predictions lookup."
        }
    }
}

private enum FixturePredictionGenerator {
    /// - Parameter existingPredictions: Previously-frozen predictions keyed by match id.
    ///   Matches already present here are reused verbatim rather than recomputed, since
    ///   `MarketsScorePredictor` samples randomly and re-running it would silently change
    ///   a prediction that's supposed to be a fixed, comparable-later snapshot.
    static func generate(
        for job: PredictionJob,
        apiBaseURL: String,
        existingPredictions: [String: PredictedFixture]
    ) async throws -> [PredictedFixture] {
        guard URL(string: apiBaseURL) != nil else {
            throw FixturePredictionError.invalidAPIBaseURL
        }

        let now = Date()
        let sortedMatches = job.matches.sorted { lhs, rhs in
            (lhs.dateTime ?? .distantFuture) < (rhs.dateTime ?? .distantFuture)
        }
        await PredictionsCatalog.shared.ensureFresh(apiBaseURL: apiBaseURL)
        let leagues = await PredictionsCatalog.shared.cachedLeagues()
        var marketsByEventID: [String: PredictionMarkets] = [:]
        var marketsByTeamsAndDate: [String: PredictionMarkets] = [:]
        for fixture in leagues.flatMap(\.fixtures) {
            guard let markets = fixture.markets else { continue }
            marketsByEventID[fixture.eventID] = markets
            if let date = fixture.date {
                marketsByTeamsAndDate[joinKey(home: fixture.homeTeam, away: fixture.awayTeam, date: date)] = markets
            }
        }

        let computedRows = await withTaskGroup(of: PredictionComputationResult.self) { group in
            for (index, match) in sortedMatches.enumerated() {
                let matchID = match.id
                let matchDate = match.date
                let matchTime = match.time
                let matchLeague = match.league
                let matchLeagueSubcategory = match.leagueSubcategory
                let matchHomeTeam = match.homeTeam
                let matchAwayTeam = match.awayTeam
                let matchHomeShortName = match.homeShortName
                let matchAwayShortName = match.awayShortName
                let matchTVChannels = match.tvChannels.map(\.name)
                let kickoff = match.dateTime
                let isPostponed = match.isPostponed
                let isInProgress = match.isInProgress
                let markets = match.matchDetailsID.flatMap { marketsByEventID[$0] }
                    ?? marketsByTeamsAndDate[joinKey(home: matchHomeTeam, away: matchAwayTeam, date: matchDate)]

                if let frozen = existingPredictions[matchID], frozen.isPredicted {
                    group.addTask {
                        PredictionComputationResult(index: index, fixture: frozen)
                    }
                    continue
                }

                group.addTask {
                    let unavailableReason: String?
                    if kickoff == nil {
                        unavailableReason = "Kick-off time unavailable"
                    } else if isPostponed {
                        unavailableReason = "Match postponed"
                    } else if kickoff! <= now {
                        unavailableReason = isInProgress ? "Already in progress" : "Already kicked off"
                    } else if markets == nil {
                        unavailableReason = "Prediction unavailable"
                    } else {
                        unavailableReason = nil
                    }

                    if let unavailableReason {
                        return PredictionComputationResult(
                            index: index,
                            fixture: PredictedFixture(
                                id: matchID,
                                date: matchDate,
                                time: matchTime,
                                league: matchLeague,
                                leagueSubcategory: matchLeagueSubcategory,
                                homeTeam: matchHomeTeam,
                                awayTeam: matchAwayTeam,
                                homeShortName: matchHomeShortName,
                                awayShortName: matchAwayShortName,
                                tvChannels: matchTVChannels,
                                homeGoals: nil,
                                awayGoals: nil,
                                expectedHomeGoals: nil,
                                expectedAwayGoals: nil,
                                homeWinProbability: nil,
                                drawProbability: nil,
                                awayWinProbability: nil,
                                unavailableReason: unavailableReason,
                                isPostponed: isPostponed
                            )
                        )
                    }

                    let estimate = MarketsScorePredictor.predict(markets: markets!)
                    return PredictionComputationResult(
                        index: index,
                        fixture: PredictedFixture(
                            id: matchID,
                            date: matchDate,
                            time: matchTime,
                            league: matchLeague,
                            leagueSubcategory: matchLeagueSubcategory,
                            homeTeam: matchHomeTeam,
                            awayTeam: matchAwayTeam,
                            homeShortName: matchHomeShortName,
                            awayShortName: matchAwayShortName,
                            tvChannels: matchTVChannels,
                            homeGoals: estimate.homeGoals,
                            awayGoals: estimate.awayGoals,
                            expectedHomeGoals: estimate.expectedHomeGoals,
                            expectedAwayGoals: estimate.expectedAwayGoals,
                            homeWinProbability: estimate.homeWinProbability,
                            drawProbability: estimate.drawProbability,
                            awayWinProbability: estimate.awayWinProbability,
                            unavailableReason: nil,
                            isPostponed: false
                        )
                    )
                }
            }

            var results: [PredictionComputationResult] = []
            results.reserveCapacity(sortedMatches.count)
            for await row in group {
                results.append(row)
            }
            return results
        }

        return computedRows.sorted { $0.index < $1.index }.map(\.fixture)
    }

    private nonisolated static func joinKey(home: String, away: String, date: String) -> String {
        "\(normalizedTeamKey(home))|\(normalizedTeamKey(away))|\(date)"
    }

    private nonisolated static func normalizedTeamKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private struct PredictionComputationResult: Sendable {
    let index: Int
    let fixture: PredictedFixture
}

private struct ScorelineEstimate: Sendable {
    let homeGoals: Int
    let awayGoals: Int
    let expectedHomeGoals: Double
    let expectedAwayGoals: Double
    let homeWinProbability: Double
    let drawProbability: Double
    let awayWinProbability: Double
}

private enum MarketsScorePredictor {
    // Used only when BSD's expected_goals market is missing for a fixture that
    // otherwise has markets data (e.g. btts/over_under present, expected_goals not).
    private nonisolated static let fallbackExpectedGoals = 1.275

    nonisolated static func predict(markets: PredictionMarkets) -> ScorelineEstimate {
        let baseHome = max(0.15, markets.expectedGoals?.home ?? fallbackExpectedGoals)
        let baseAway = max(0.15, markets.expectedGoals?.away ?? fallbackExpectedGoals)

        var lambdaHome = baseHome * Double.random(in: 0.88...1.20)
        var lambdaAway = baseAway * Double.random(in: 0.88...1.20)

        // Inject occasional volatility so underdogs still produce upset scorelines.
        if Double.random(in: 0...1) < 0.10 {
            let swing = Double.random(in: 0.12...0.42)
            if baseHome >= baseAway {
                lambdaHome *= (1 - swing)
                lambdaAway *= (1 + swing)
            } else {
                lambdaHome *= (1 + swing)
                lambdaAway *= (1 - swing)
            }
        }

        lambdaHome = clamp(lambdaHome, min: 0.12, max: 4.80)
        lambdaAway = clamp(lambdaAway, min: 0.12, max: 4.80)

        let homeGoals = samplePoisson(lambda: lambdaHome)
        let awayGoals = samplePoisson(lambda: lambdaAway)
        // Win/draw/away probabilities come straight from BSD's own match_result
        // market rather than being recomputed from the sampled Poisson means.
        let (homeWin, draw, awayWin) = outcomeProbabilities(from: markets.matchResult)

        return ScorelineEstimate(
            homeGoals: homeGoals,
            awayGoals: awayGoals,
            expectedHomeGoals: lambdaHome,
            expectedAwayGoals: lambdaAway,
            homeWinProbability: homeWin,
            drawProbability: draw,
            awayWinProbability: awayWin
        )
    }

    private nonisolated static func clamp(_ value: Double, min lower: Double, max upper: Double) -> Double {
        Swift.max(lower, Swift.min(value, upper))
    }

    private nonisolated static func samplePoisson(lambda: Double) -> Int {
        guard lambda > 0 else { return 0 }
        let threshold = exp(-lambda)
        var product = 1.0
        var count = 0

        repeat {
            count += 1
            product *= Double.random(in: 0..<1)
        } while product > threshold

        return max(0, count - 1)
    }

    private nonisolated static func outcomeProbabilities(
        from matchResult: MatchResultMarket?
    ) -> (Double, Double, Double) {
        guard let matchResult else { return (0.33, 0.34, 0.33) }
        let home = max(0, matchResult.probHome) / 100
        let draw = max(0, matchResult.probDraw) / 100
        let away = max(0, matchResult.probAway) / 100

        let total = home + draw + away
        guard total > 0 else { return (0.33, 0.34, 0.33) }
        return (home / total, draw / total, away / total)
    }
}

private struct ServerLoadingStateView: View {
    let mode: MatchesViewMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animateSpinner = false

    var body: some View {
        VStack(spacing: 18) {
            LiquidServerSpinner(isAnimating: animateSpinner && !reduceMotion)

            VStack(spacing: 5) {
                Text(mode.loadingServerText)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text(mode.loadingServerSubtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .background {
            loadingBackground
        }
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 26, x: 0, y: 18)
        .padding(.horizontal, 32)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(mode.loadingServerText)
        .onAppear {
            animateSpinner = true
        }
        .onDisappear {
            animateSpinner = false
        }
    }

    @ViewBuilder
    private var loadingBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        if #available(iOS 26.0, *) {
            shape
                .fill(.clear)
                .glassEffect(.regular, in: shape)
        } else {
            shape
                .fill(.ultraThinMaterial)
        }
    }
}

private struct LiquidServerSpinner: View {
    let isAnimating: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.accentColor.opacity(0.24),
                            Color.accentColor.opacity(0.04),
                            .clear,
                        ],
                        center: .center,
                        startRadius: 2,
                        endRadius: 46
                    )
                )
                .frame(width: 82, height: 82)

            Circle()
                .stroke(.white.opacity(0.16), lineWidth: 1)
                .frame(width: 68, height: 68)

            Circle()
                .trim(from: 0.08, to: 0.76)
                .stroke(
                    AngularGradient(
                        colors: [
                            Color.accentColor.opacity(0.15),
                            Color.accentColor,
                            .white.opacity(0.92),
                            Color.accentColor.opacity(0.18),
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .frame(width: 58, height: 58)
                .rotationEffect(.degrees(isAnimating ? 360 : 0))
                .animation(.linear(duration: 1.15).repeatForever(autoreverses: false), value: isAnimating)

            Circle()
                .trim(from: 0.0, to: 0.32)
                .stroke(
                    .white.opacity(0.72),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .frame(width: 42, height: 42)
                .rotationEffect(.degrees(isAnimating ? -360 : 0))
                .animation(.linear(duration: 1.65).repeatForever(autoreverses: false), value: isAnimating)

            Image(systemName: "arrow.down.to.line.compact")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white, Color.accentColor)
                .symbolRenderingMode(.palette)
                .shadow(color: Color.accentColor.opacity(0.55), radius: 10, x: 0, y: 0)
        }
        .frame(width: 92, height: 92)
    }
}

private struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.8))
            )
            .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
    }
}

#Preview {
    let store = MatchesStore()
    return MatchesView(mode: .fixtures, store: store)
        .environmentObject(PreferencesStore())
        .environmentObject(store)
        .environmentObject(FantasyViewModel())
}
