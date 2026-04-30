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

    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var matchesStore: MatchesStore
    @EnvironmentObject private var fantasyViewModel: FantasyViewModel
    @AppStorage(AppGroupConfig.fantasyManagerEntryIDKey) private var fantasyManagerEntryID = ""
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var predictionDateKeys = FixturePredictionStore.storedDateKeys()
    @State private var activePredictionJob: PredictionJob?
    @State private var activePredictions: DailyFixturePredictions?
    @State private var predictionTask: Task<Void, Never>?
    @State private var predictorAvailabilityTask: Task<Void, Never>?
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var searchFilterWorkItem: DispatchWorkItem?
    @State private var groupedSideEffectsTask: Task<Void, Never>?
    @State private var predictionErrorMessage: String?
    @State private var predictableDateKeys: Set<String> = []
    @State private var isSearchVisible = false
    @State private var isSearchFieldFocused = false
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var filteredMatchDays: [MatchDay] = []
    @State private var indexedMatchDays: [IndexedMatchDay] = []
    @State private var reportedMissingLogoNames: Set<String> = []
    @State private var lastPredictorCandidateDateKeys: Set<String> = []
    @State private var didRunActivationForVisibleCycle = false
    @State private var navigationMatch: MatchNavigation?
    @State private var screenOpenedAt: Date?
    @State private var screenViewSentForActivation = false

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
        let days = isSearchFilteringActive ? filteredMatchDays : matchesStore.groupedMatches
        guard !preferences.showPostponedGames else { return days }
        return Self.filteringPostponed(days)
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

    private var predictionErrorPresented: Binding<Bool> {
        Binding(
            get: { predictionErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    predictionErrorMessage = nil
                }
            }
        )
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
                    if matchesStore.isLoading && matchesStore.groupedMatches.isEmpty {
                        VStack(spacing: 16) {
                            ProgressView()
                            Text(mode.loadingText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
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
                showFantasyBadge: nav.showFantasyBadge
            )
        }
    }

    var body: some View {
        NavigationStack {
            navigationStackContent
        }
        .onAppear {
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
            runActivationIfNeeded(logEvent: "isSelected")
            beginScreenViewTiming()
        }
        .onChange(of: matchesStore.isLoading) { _, isLoading in
            guard !isLoading else { return }
            sendTimedScreenView()
        }
        .onChange(of: preferences.snapshot) { _, _ in
            guard isSelected else { return }
            let snapshot = showAllMatches ? preferences.unfilteredSnapshot : preferences.snapshot
            NSLog("[MatchesView] snapshot_change mode=%@ showAllMatches=%d epl_pref=%d effective_snapshot=%@",
                  mode.rawValue, showAllMatches, preferences.englishPremierLeagueTeamsOnly, debugSnapshotSummary(snapshot))
            matchesStore.configure(with: snapshot, mode: mode)
            scheduleGroupedSideEffects(for: matchesStore.groupedMatches, immediate: false)
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
        .onChange(of: matchesStore.groupedMatches) { _, days in
            guard isSelected else { return }
            scheduleGroupedSideEffects(for: days, immediate: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: FixturePredictionStore.didChangeNotification)) { _ in
            guard isSelected else { return }
            predictionDateKeys = FixturePredictionStore.storedDateKeys()
            scheduleGroupedSideEffects(for: matchesStore.groupedMatches, immediate: false)
        }
        .onChange(of: searchText) { _, newValue in
            scheduleDebouncedSearch(for: newValue)
        }
        .onDisappear {
            matchesStore.setModeVisibility(mode, isVisible: false)
            isSearchFieldFocused = false
            predictionTask?.cancel()
            predictorAvailabilityTask?.cancel()
            searchDebounceTask?.cancel()
            searchFilterWorkItem?.cancel()
            groupedSideEffectsTask?.cancel()
        }
        .fullScreenCover(item: $activePredictionJob) { job in
            PredictionInterstitialView(displayDate: job.displayDate)
                .interactiveDismissDisabled()
        }
        .sheet(item: $activePredictions) { prediction in
            NavigationStack {
                DayPredictionsView(prediction: prediction)
            }
            .environmentObject(preferences)
            .environmentObject(fantasyViewModel)
        }
        .alert("Predictions Unavailable", isPresented: predictionErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(predictionErrorMessage ?? "Unable to generate predictions right now.")
        }
    }

    private func beginScreenViewTiming() {
        screenOpenedAt = Date()
        screenViewSentForActivation = false
        if !matchesStore.isLoading {
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
              matchesStore.groupedMatches.contains(where: { day in
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

            if mode == .results && matchesStore.isLoadingMoreMatches {
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
                reason: "pull_to_refresh"
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

            if mode == .fixtures && shouldShowPredictorButton(for: day) {
                predictorControls(for: day)
            }
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
                showFantasyBadge: mode == .fixtures
            )
        } label: {
            HStack(spacing: 0) {
                MatchesListRowLabel(
                    match: match,
                    isFixtureMode: mode == .fixtures,
                    highlightToday: day.isToday,
                    rowPreferences: matchRowPreferences,
                    fantasyContext: fantasyViewModel.matchRowContext
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

    private func shouldShowPredictorButton(for day: MatchDay) -> Bool {
        if predictionDateKeys.contains(day.dateKey) {
            return true
        }
        return predictableDateKeys.contains(day.dateKey)
    }

    private func predictorControls(for day: MatchDay) -> some View {
        HStack(spacing: 8) {
            predictorButton(for: day)
            #if DEBUG
            if preferences.showPredictionRedoButton && predictionDateKeys.contains(day.dateKey) {
                redoPredictorButton(for: day)
            }
            #endif
        }
    }

    private func predictorButton(for day: MatchDay) -> some View {
        let isRunning = predictionTask != nil
        let hasStoredPrediction = predictionDateKeys.contains(day.dateKey)
        return Button {
            handlePredictorTap(for: day)
        } label: {
            HStack(spacing: 6) {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: hasStoredPrediction ? "sparkles.rectangle.stack.fill" : "sparkles")
                        .font(.caption)
                }
                Text(hasStoredPrediction ? "View" : "Predict")
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color(.tertiarySystemBackground))
            )
        }
        .buttonStyle(.plain)
        .disabled(isRunning)
        .accessibilityLabel(hasStoredPrediction ? "View saved predictions for \(day.displayDate)" : "Predict fixtures for \(day.displayDate)")
    }

    #if DEBUG
    private func redoPredictorButton(for day: MatchDay) -> some View {
        let isRunning = predictionTask != nil
        return Button {
            handlePredictorTap(for: day, forceRegenerate: true)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                Text("Redo")
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color(.tertiarySystemBackground))
            )
        }
        .buttonStyle(.plain)
        .disabled(isRunning)
        .accessibilityLabel("Regenerate predictions for \(day.displayDate)")
    }
    #endif

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

                // Search toggle
                Button {
                    if isSearchVisible {
                        hideSearchAndClear()
                    } else {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSearchVisible = true
                        }
                        isSearchFieldFocused = true
                        rebuildSearchIndex(from: matchesStore.groupedMatches)
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

            if matchesStore.errorMessage != nil || (matchesStore.isLoading && matchesStore.groupedMatches.isEmpty) || matchesStore.lastUpdated != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = matchesStore.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    // Only show the loading indicator when there is no data yet (initial load).
                    // When cached/fresh data is already visible a background refresh should not
                    // disrupt the layout or replace the "Updated" timestamp with a spinner.
                    if matchesStore.isLoading && matchesStore.groupedMatches.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(mode.loadingText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else if let lastUpdated = matchesStore.lastUpdated {
                        let cachedSuffix = matchesStore.isUsingCache ? " (cached)" : ""
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
            refreshPredictorAvailability(days: days)
        }
    }

    private func runActivationIfNeeded(logEvent: String) {
        guard !didRunActivationForVisibleCycle else { return }
        didRunActivationForVisibleCycle = true
        matchesStore.setModeVisibility(mode, isVisible: true)
        let snapshot = showAllMatches ? preferences.unfilteredSnapshot : preferences.snapshot
        NSLog("[MatchesView] %@ mode=%@ selected=%d snapshot=%@", logEvent, mode.rawValue, isSelected, debugSnapshotSummary(snapshot))
        matchesStore.configure(with: snapshot, mode: mode)
        let days = matchesStore.groupedMatches
        scheduleGroupedSideEffects(for: days, immediate: false)
        predictionDateKeys = FixturePredictionStore.storedDateKeys()
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
                                match.tvChannels.joined(separator: " ")
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

    private func handlePredictorTap(for day: MatchDay, forceRegenerate: Bool = false) {
        guard predictionTask == nil else { return }

        if !forceRegenerate, let cached = FixturePredictionStore.prediction(for: day.dateKey) {
            activePredictions = cached
            return
        }

        guard forceRegenerate || predictableDateKeys.contains(day.dateKey) else {
            predictionErrorMessage = "No eligible fixtures can be predicted for this day."
            return
        }

        let dayMatches = day.leagues.flatMap(\.matches)
        guard !dayMatches.isEmpty else {
            predictionErrorMessage = "No fixtures found for this day."
            return
        }

        let job = PredictionJob(dateKey: day.dateKey, displayDate: day.displayDate, matches: dayMatches)
        activePredictionJob = job
        startPredictionTask(for: job)
    }

    private func startPredictionTask(for job: PredictionJob) {
        predictionTask?.cancel()
        let snapshot = showAllMatches ? preferences.unfilteredSnapshot : preferences.snapshot

        predictionTask = Task {
            let startedAt = Date()
            defer {
                Task { @MainActor in
                    predictionTask = nil
                }
            }

            do {
                let prediction = try await FixturePredictionGenerator.generate(
                    for: job,
                    apiBaseURL: snapshot.apiBaseURL
                )
                guard !Task.isCancelled else { return }

                let elapsed = Date().timeIntervalSince(startedAt)
                let remaining = max(0, 3.0 - elapsed)
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    FixturePredictionStore.save(prediction)
                    predictionDateKeys.insert(job.dateKey)
                    if activePredictionJob?.id == job.id {
                        activePredictionJob = nil
                    }
                    activePredictions = prediction
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }

                let elapsed = Date().timeIntervalSince(startedAt)
                let remaining = max(0, 3.0 - elapsed)
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    if activePredictionJob?.id == job.id {
                        activePredictionJob = nil
                    }
                    predictionErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func refreshPredictorAvailability(days: [MatchDay]) {
        guard mode == .fixtures else {
            predictableDateKeys = []
            return
        }

        let now = Date()
        let candidateDays = days.reduce(into: [String: [Match]]()) { partialResult, day in
            let upcoming = day.leagues
                .flatMap(\.matches)
                .filter { match in
                    guard let kickoff = match.dateTime else { return false }
                    return kickoff > now && !match.isPostponed
                }
            guard !upcoming.isEmpty else { return }
            partialResult[day.dateKey] = upcoming
        }

        guard !candidateDays.isEmpty else {
            lastPredictorCandidateDateKeys = []
            predictableDateKeys = []
            return
        }

        let candidateDateKeys = Set(candidateDays.keys)
        guard candidateDateKeys != lastPredictorCandidateDateKeys else { return }
        lastPredictorCandidateDateKeys = candidateDateKeys

        predictorAvailabilityTask?.cancel()
        let apiBaseURL = preferences.apiBaseURL
        predictorAvailabilityTask = Task {
            await TeamRankingSettingsCatalog.shared.ensureFresh(apiBaseURL: apiBaseURL)
            await TeamRankingsCatalog.shared.ensureFresh(apiBaseURL: apiBaseURL)

            guard !Task.isCancelled else { return }
            await MainActor.run {
                predictableDateKeys = Set(candidateDays.keys)
            }
        }
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
            rowPreferences: rowPreferences
        )
    }
}

private struct MatchNavigation: Identifiable, Hashable, Sendable {
    let match: Match
    let highlightToday: Bool
    let showFantasyBadge: Bool
    var id: String { match.id }
}

private struct PredictionJob: Identifiable, Sendable {
    let id = UUID()
    let dateKey: String
    let displayDate: String
    let matches: [Match]
}

private struct DailyFixturePredictions: Codable, Identifiable, Sendable {
    let dateKey: String
    let displayDate: String
    let generatedAt: Date
    let totalDayMatches: Int
    let skippedKickedOffCount: Int
    let skippedMissingEloCount: Int
    let skippedUnknownCount: Int
    let predictions: [PredictedFixture]

    var id: String {
        "\(dateKey)|\(generatedAt.timeIntervalSince1970)"
    }

    init(
        dateKey: String,
        displayDate: String,
        generatedAt: Date,
        totalDayMatches: Int,
        skippedKickedOffCount: Int,
        skippedMissingEloCount: Int,
        skippedUnknownCount: Int,
        predictions: [PredictedFixture]
    ) {
        self.dateKey = dateKey
        self.displayDate = displayDate
        self.generatedAt = generatedAt
        self.totalDayMatches = totalDayMatches
        self.skippedKickedOffCount = skippedKickedOffCount
        self.skippedMissingEloCount = skippedMissingEloCount
        self.skippedUnknownCount = skippedUnknownCount
        self.predictions = predictions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dateKey = try container.decode(String.self, forKey: .dateKey)
        displayDate = try container.decode(String.self, forKey: .displayDate)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        totalDayMatches = try container.decode(Int.self, forKey: .totalDayMatches)
        skippedKickedOffCount = try container.decode(Int.self, forKey: .skippedKickedOffCount)
        skippedMissingEloCount = try container.decode(Int.self, forKey: .skippedMissingEloCount)
        skippedUnknownCount = try container.decodeIfPresent(Int.self, forKey: .skippedUnknownCount) ?? 0
        predictions = try container.decode([PredictedFixture].self, forKey: .predictions)
    }
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
    let homeElo: Double?
    let awayElo: Double?
    let unavailableReason: String?
    let isPostponed: Bool

    var isPredicted: Bool {
        homeGoals != nil && awayGoals != nil && unavailableReason == nil && !isPostponed
    }

    var displayLeague: String {
        let baseLeague = league.trimmingCharacters(in: .whitespacesAndNewlines)
        if let leagueSubcategory, !leagueSubcategory.isEmpty {
            return "\(baseLeague): \(leagueSubcategory)"
        }
        return baseLeague
    }

    var displayHomeTeam: String {
        let trimmed = homeShortName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? homeTeam : trimmed
    }

    var displayAwayTeam: String {
        let trimmed = awayShortName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? awayTeam : trimmed
    }

    var asMatch: Match {
        Match(
            date: date,
            time: time,
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            homeShortName: homeShortName,
            awayShortName: awayShortName,
            league: league,
            leagueSubcategory: leagueSubcategory,
            tvChannels: [],
            homeScore: homeGoals,
            awayScore: awayGoals,
            scoreStatus: isPostponed ? "POSTPONED" : nil
        )
    }

    var statusLabelText: String {
        if isPostponed {
            return "Match postponed"
        }
        if isPredicted {
            return "Predicted"
        }
        return unavailableReason ?? "Unavailable"
    }

    var cardOpacity: Double {
        isPostponed ? 1.0 : (isPredicted ? 1.0 : 0.55)
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
        case homeElo
        case awayElo
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
        homeElo = try container.decodeIfPresent(Double.self, forKey: .homeElo)
        awayElo = try container.decodeIfPresent(Double.self, forKey: .awayElo)
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
        try container.encodeIfPresent(homeElo, forKey: .homeElo)
        try container.encodeIfPresent(awayElo, forKey: .awayElo)
        try container.encodeIfPresent(unavailableReason, forKey: .unavailableReason)
        try container.encode(isPostponed, forKey: .isPostponed)
    }
}

private struct PredictionLeagueSection: Identifiable {
    let id: String
    let league: String
    let fixtures: [PredictedFixture]
}

private struct FixturePredictionCachePayload: Codable {
    var entries: [String: DailyFixturePredictions]
}

enum FixturePredictionStore {
    private static let fileName = "fixture-predictions.json"
    static let didChangeNotification = Notification.Name("FixturePredictionStore.didChange")

    static func storedDateKeys() -> Set<String> {
        Set(loadCache().entries.keys)
    }

    fileprivate static func prediction(for dateKey: String) -> DailyFixturePredictions? {
        loadCache().entries[dateKey]
    }

    fileprivate static func save(_ prediction: DailyFixturePredictions) {
        var cache = loadCache()
        cache.entries[prediction.dateKey] = prediction
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
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(FixturePredictionCachePayload.self, from: data) else {
            return FixturePredictionCachePayload(entries: [:])
        }
        return payload
    }

    private static func persist(_ payload: FixturePredictionCachePayload) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
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
            return "Invalid API base URL for Elo lookup."
        }
    }
}

private enum FixturePredictionGenerator {
    static func generate(for job: PredictionJob, apiBaseURL: String) async throws -> DailyFixturePredictions {
        guard URL(string: apiBaseURL) != nil else {
            throw FixturePredictionError.invalidAPIBaseURL
        }

        let now = Date()
        let sortedMatches = job.matches.sorted { lhs, rhs in
            (lhs.dateTime ?? .distantFuture) < (rhs.dateTime ?? .distantFuture)
        }
        await TeamRankingSettingsCatalog.shared.ensureFresh(apiBaseURL: apiBaseURL)
        let settings = await TeamRankingSettingsCatalog.shared.settings()
        let cachedRankings = await TeamRankingsCatalog.shared.cachedEntries()
        let lookup = TeamRatingLookup(entries: cachedRankings, defaultPoints: settings.defaultElo)
        let uniqueTeamNames = Set(sortedMatches.flatMap { [$0.homeTeam, $0.awayTeam] })
        var ratingsByTeamName: [String: Double] = [:]
        ratingsByTeamName.reserveCapacity(uniqueTeamNames.count)
        for teamName in uniqueTeamNames {
            ratingsByTeamName[teamName] = lookup.resolvedRating(for: teamName)
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
                let matchTVChannels = match.tvChannels
                let kickoff = match.dateTime
                let isPostponed = match.isPostponed
                let isInProgress = match.isInProgress

                group.addTask {
                    let homeElo = ratingsByTeamName[matchHomeTeam]
                    let awayElo = ratingsByTeamName[matchAwayTeam]

                    let unavailableReason: String?
                    if kickoff == nil {
                        unavailableReason = "Kick-off time unavailable"
                    } else if isPostponed {
                        unavailableReason = "Match postponed"
                    } else if kickoff! <= now {
                        unavailableReason = isInProgress ? "Already in progress" : "Already kicked off"
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
                                homeElo: homeElo,
                                awayElo: awayElo,
                                unavailableReason: unavailableReason,
                                isPostponed: isPostponed
                            ),
                            skippedKickedOff: kickoff != nil && kickoff! <= now && !isPostponed,
                            skippedMissingElo: false,
                            skippedUnknown: kickoff == nil
                        )
                    }

                    let estimate = EloScorePredictor.predict(homeElo: homeElo!, awayElo: awayElo!)
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
                            homeElo: homeElo,
                            awayElo: awayElo,
                            unavailableReason: nil,
                            isPostponed: false
                        ),
                        skippedKickedOff: false,
                        skippedMissingElo: false,
                        skippedUnknown: false
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

        let orderedRows = computedRows.sorted { $0.index < $1.index }
        let predictions = orderedRows.map(\.fixture)
        let skippedKickedOffCount = orderedRows.reduce(0) { $0 + ($1.skippedKickedOff ? 1 : 0) }
        let skippedMissingEloCount = orderedRows.reduce(0) { $0 + ($1.skippedMissingElo ? 1 : 0) }
        let skippedUnknownCount = orderedRows.reduce(0) { $0 + ($1.skippedUnknown ? 1 : 0) }

        return DailyFixturePredictions(
            dateKey: job.dateKey,
            displayDate: job.displayDate,
            generatedAt: now,
            totalDayMatches: job.matches.count,
            skippedKickedOffCount: skippedKickedOffCount,
            skippedMissingEloCount: skippedMissingEloCount,
            skippedUnknownCount: skippedUnknownCount,
            predictions: predictions
        )
    }
}

private struct PredictionComputationResult: Sendable {
    let index: Int
    let fixture: PredictedFixture
    let skippedKickedOff: Bool
    let skippedMissingElo: Bool
    let skippedUnknown: Bool
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

private enum EloScorePredictor {
    private nonisolated static let homeAdvantageElo = 64.0
    private nonisolated static let baselineTotalGoals = 2.55
    private nonisolated static let maxGoalsForDistribution = 8

    nonisolated static func predict(homeElo: Double, awayElo: Double) -> ScorelineEstimate {
        let delta = (homeElo + homeAdvantageElo) - awayElo

        let totalGoals = clamp(
            baselineTotalGoals + Double.random(in: -0.20...0.30),
            min: 1.90,
            max: 3.60
        )

        let goalDiffSignal = tanh(delta / 280.0) * 1.20
        var lambdaHome = max(0.15, (totalGoals + goalDiffSignal) / 2)
        var lambdaAway = max(0.15, (totalGoals - goalDiffSignal) / 2)

        lambdaHome *= Double.random(in: 0.88...1.20)
        lambdaAway *= Double.random(in: 0.88...1.20)

        // Inject occasional volatility so underdogs still produce upset scorelines.
        if Double.random(in: 0...1) < 0.10 {
            let swing = Double.random(in: 0.12...0.42)
            if delta >= 0 {
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
        let (homeWin, draw, awayWin) = outcomeProbabilities(lambdaHome: lambdaHome, lambdaAway: lambdaAway)

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
        lambdaHome: Double,
        lambdaAway: Double
    ) -> (Double, Double, Double) {
        var home = 0.0
        var draw = 0.0
        var away = 0.0

        for homeGoals in 0...maxGoalsForDistribution {
            let homePMF = poissonPMF(k: homeGoals, lambda: lambdaHome)
            for awayGoals in 0...maxGoalsForDistribution {
                let probability = homePMF * poissonPMF(k: awayGoals, lambda: lambdaAway)
                if homeGoals > awayGoals {
                    home += probability
                } else if homeGoals == awayGoals {
                    draw += probability
                } else {
                    away += probability
                }
            }
        }

        let total = home + draw + away
        guard total > 0 else { return (0.33, 0.34, 0.33) }
        return (home / total, draw / total, away / total)
    }

    private nonisolated static func poissonPMF(k: Int, lambda: Double) -> Double {
        guard lambda > 0 else { return k == 0 ? 1 : 0 }
        var value = exp(-lambda)
        guard k > 0 else { return value }
        for i in 1...k {
            value *= lambda / Double(i)
        }
        return value
    }
}

private struct PredictionInterstitialView: View {
    let displayDate: String
    @State private var animate = false
    @State private var statusMessage = PredictionInterstitialMessages.random()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.15, blue: 0.27),
                    Color(red: 0.05, green: 0.28, blue: 0.38),
                    Color(red: 0.09, green: 0.20, blue: 0.48),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                        .frame(width: 210, height: 210)

                    Circle()
                        .trim(from: 0.10, to: 0.88)
                        .stroke(
                            AngularGradient(colors: [.white.opacity(0.2), .white, .white.opacity(0.2)], center: .center),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .frame(width: 170, height: 170)
                        .rotationEffect(.degrees(animate ? 360 : 0))
                        .animation(.linear(duration: 2.4).repeatForever(autoreverses: false), value: animate)

                    Circle()
                        .trim(from: 0.05, to: 0.45)
                        .stroke(
                            Color.white.opacity(0.70),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .frame(width: 140, height: 140)
                        .rotationEffect(.degrees(animate ? -360 : 0))
                        .animation(.linear(duration: 1.8).repeatForever(autoreverses: false), value: animate)

                    ForEach(0..<24, id: \.self) { index in
                        Circle()
                            .fill(.white.opacity(animate ? 0.95 : 0.35))
                            .frame(width: index.isMultiple(of: 3) ? 7 : 4, height: index.isMultiple(of: 3) ? 7 : 4)
                            .offset(y: -84)
                            .rotationEffect(.degrees(Double(index) * 15 + (animate ? 360 : 0)))
                            .animation(
                                .easeInOut(duration: 1.2)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.03),
                                value: animate
                            )
                    }

                    Image(systemName: "cpu.fill")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .white.opacity(0.45), radius: 10, x: 0, y: 0)
                }

                VStack(spacing: 8) {
                    Text(statusMessage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .padding(.top, 10)
                }

                ProgressView()
                    .tint(.white)
            }
            .padding(24)
        }
        .onAppear {
            animate = true
            statusMessage = PredictionInterstitialMessages.random()
        }
    }
}

private struct DayPredictionsView: View {
    let prediction: DailyFixturePredictions
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var fantasyViewModel: FantasyViewModel
    @State private var shareItems: [Any] = []
    @State private var isShareSheetPresented = false
    @State private var isLaunchingShareSheet = false
    @State private var cachedShareImage: UIImage?
    @State private var shareRenderTask: Task<Void, Never>?
    @State private var isPreparingShareImage = false
    @State private var pendingShareAfterRender = false

    private static let exportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var sections: [PredictionLeagueSection] {
        let grouped = Dictionary(grouping: prediction.predictions) { $0.displayLeague }
        return grouped.map { entry in
            let (league, fixtures) = entry
            let sorted = fixtures.sorted { lhs, rhs in
                let leftDate = MatchDateParser.parse(date: lhs.date, time: lhs.time) ?? .distantFuture
                let rightDate = MatchDateParser.parse(date: rhs.date, time: rhs.time) ?? .distantFuture
                if leftDate != rightDate {
                    return leftDate < rightDate
                }
                let homeCompare = lhs.homeTeam.localizedCaseInsensitiveCompare(rhs.homeTeam)
                if homeCompare != .orderedSame {
                    return homeCompare == .orderedAscending
                }
                return lhs.awayTeam.localizedCaseInsensitiveCompare(rhs.awayTeam) == .orderedAscending
            }
            return PredictionLeagueSection(
                id: "\(prediction.dateKey)|\(league)",
                league: league,
                fixtures: sorted
            )
        }
        .sorted { lhs, rhs in
            let lhsKickoff = lhs.fixtures.first.flatMap { MatchDateParser.parse(date: $0.date, time: $0.time) } ?? .distantFuture
            let rhsKickoff = rhs.fixtures.first.flatMap { MatchDateParser.parse(date: $0.date, time: $0.time) } ?? .distantFuture
            if lhsKickoff != rhsKickoff {
                return lhsKickoff < rhsKickoff
            }
            return lhs.league.localizedCaseInsensitiveCompare(rhs.league) == .orderedAscending
        }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.subheadline.weight(.semibold))
                        Text("Predictions for \(prediction.displayDate)")
                            .font(.subheadline.weight(.semibold))
                    }
                    Text("Generated \(Self.exportDateFormatter.string(from: prediction.generatedAt))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .textCase(nil)

            ForEach(sections) { section in
                Section {
                    Text(section.league)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 2, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)

                    ForEach(section.fixtures) { fixture in
                        PredictedMatchCard(fixture: fixture)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle("Predictions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if let image = cachedShareImage {
                        presentShareSheet(with: [image])
                        return
                    }

                    pendingShareAfterRender = true
                    prepareShareImageIfNeeded(force: false)
                } label: {
                    if isLaunchingShareSheet || (isPreparingShareImage && cachedShareImage == nil) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .disabled(
                    prediction.predictions.isEmpty
                        || isLaunchingShareSheet
                        || (isPreparingShareImage && cachedShareImage == nil)
                )
                .accessibilityLabel("Share predictions")
            }
        }
        .onAppear {
            prepareShareImageIfNeeded()
        }
        .onDisappear {
            shareRenderTask?.cancel()
            shareRenderTask = nil
            cachedShareImage = nil
            isLaunchingShareSheet = false
        }
        .sheet(isPresented: $isShareSheetPresented, onDismiss: {
            shareItems = []
            isLaunchingShareSheet = false
        }) {
            ShareSheet(activityItems: shareItems)
        }
    }

    private func presentShareSheet(with items: [Any]) {
        guard !items.isEmpty else { return }
        guard !isLaunchingShareSheet && !isShareSheetPresented else { return }
        isLaunchingShareSheet = true
        shareItems = items
        DispatchQueue.main.async {
            isShareSheetPresented = true
            isLaunchingShareSheet = false
        }
    }

    private func prepareShareImageIfNeeded(force: Bool = false) {
        guard !prediction.predictions.isEmpty else { return }
        if cachedShareImage != nil && !force { return }
        if isPreparingShareImage { return }

        shareRenderTask?.cancel()
        isPreparingShareImage = true
        let startedAt = CFAbsoluteTimeGetCurrent()
        let displayDate = prediction.displayDate
        let generated = Self.exportDateFormatter.string(from: prediction.generatedAt)
        let snapshotSections = sections

        shareRenderTask = Task { @MainActor in
            let rendered = PredictionShareImageRenderer.render(
                title: displayDate,
                generatedAtText: generated,
                sections: snapshotSections,
                preferences: preferences,
                fantasyViewModel: fantasyViewModel
            )
            guard !Task.isCancelled else { return }

            cachedShareImage = rendered
            isPreparingShareImage = false
            #if DEBUG
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            print("[PredictionsShare] Prepared image in \(elapsedMs)ms, success=\(rendered != nil)")
            #endif

            if pendingShareAfterRender {
                if let rendered {
                    presentShareSheet(with: [rendered])
                } else {
                    presentShareSheet(with: [shareText])
                }
                pendingShareAfterRender = false
            }
        }
    }

    private var shareText: String {
        var lines: [String] = []
        lines.append("Top Scores predictions")
        lines.append("\(prediction.displayDate)")
        lines.append("Generated \(Self.exportDateFormatter.string(from: prediction.generatedAt))")
        lines.append("")

        for section in sections {
            lines.append(section.league)
            for fixture in section.fixtures {
                if fixture.isPredicted {
                    let home = fixture.homeGoals ?? 0
                    let away = fixture.awayGoals ?? 0
                    lines.append("\(fixture.time)  \(fixture.displayHomeTeam) \(home)-\(away) \(fixture.displayAwayTeam)")
                } else if fixture.isPostponed {
                    lines.append("\(fixture.time)  \(fixture.displayHomeTeam) P-P \(fixture.displayAwayTeam)  [Match postponed]")
                } else {
                    lines.append("\(fixture.time)  \(fixture.displayHomeTeam) vs \(fixture.displayAwayTeam)  [\(fixture.statusLabelText)]")
                }
            }
            lines.append("")
        }

        lines.append("Note: Not real results. Yet.")
        return lines.joined(separator: "\n")
    }
}

private struct PredictedMatchCard: View {
    let fixture: PredictedFixture

    var body: some View {
        MatchRow(
            match: fixture.asMatch,
            highlightToday: false,
            showLeague: false,
            showBroadcastDetails: false,
            showFantasyBadge: false,
            centerFooterText: fixture.isPredicted ? nil : fixture.statusLabelText,
            centerFooterColor: fixture.isPredicted ? .accentColor : .secondary
        )
        .opacity(fixture.cardOpacity)
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.excludedActivityTypes = [.assignToContact, .addToReadingList]
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private enum PredictionShareImageRenderer {
    private static let viewportWidth: CGFloat = 360

    @MainActor
    static func render(
        title: String,
        generatedAtText: String,
        sections: [PredictionLeagueSection],
        preferences: PreferencesStore,
        fantasyViewModel: FantasyViewModel
    ) -> UIImage? {
        let fixtureCount = sections.reduce(0) { partial, section in
            partial + section.fixtures.count
        }
        let snapshot = PredictionShareSnapshotView(
            title: title,
            generatedAtText: generatedAtText,
            sections: sections
        )
            .environment(\.colorScheme, .dark)
            .environmentObject(preferences)
            .environmentObject(fantasyViewModel)
            .frame(width: viewportWidth, alignment: .topLeading)
            .background(Color.black)
            .fixedSize(horizontal: false, vertical: true)

        let renderer = ImageRenderer(content: snapshot)
        renderer.proposedSize = ProposedViewSize(width: viewportWidth, height: nil)
        renderer.scale = exportScale(forFixtureCount: fixtureCount)
        if #available(iOS 17.0, *) {
            renderer.isOpaque = true
        }
        return renderer.uiImage
    }

    private static func exportScale(forFixtureCount fixtureCount: Int) -> CGFloat {
        switch fixtureCount {
        case ...16:
            return 2.5
        case ...30:
            return 2.0
        default:
            return 1.5
        }
    }
}

private struct PredictionShareSnapshotView: View {
    let title: String
    let generatedAtText: String
    let sections: [PredictionLeagueSection]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.03, blue: 0.05),
                    Color(red: 0.07, green: 0.08, blue: 0.12),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        ShareAppIconView(size: 20)
                        Text("Top Scores Predictions")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    Text(title)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                    Text("Generated \(generatedAtText)")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.62))
                }

                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.league)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.82))

                        ForEach(section.fixtures) { fixture in
                            MatchRow(
                                match: fixture.asMatch,
                                highlightToday: false,
                                showLeague: false,
                                showBroadcastDetails: false,
                                showFantasyBadge: false,
                                centerFooterText: fixture.isPredicted ? nil : fixture.statusLabelText,
                                centerFooterColor: fixture.isPredicted ? .accentColor : .secondary,
                                isLargePresentation: true
                            )
                            .opacity(fixture.cardOpacity)
                        }
                    }
                }

                Text("Not real results. Yet.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.top, 2)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 14)
        }
    }
}

private struct ShareAppIconView: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let uiImage = appIconImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.accentColor)
                    .padding(3)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }

    private var appIconImage: UIImage? {
        guard
            let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
            let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
            let iconFiles = primary["CFBundleIconFiles"] as? [String],
            let iconName = iconFiles.last,
            let image = UIImage(named: iconName)
        else {
            return nil
        }
        return image
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
    MatchesView(mode: .fixtures)
        .environmentObject(PreferencesStore())
        .environmentObject(MatchesStore())
        .environmentObject(FantasyViewModel())
}
