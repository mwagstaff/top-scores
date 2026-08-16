import SwiftUI
import UIKit

enum MatchesViewMode: String, Sendable {
    case fixtures
    case results

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

}

struct MatchesView: View {
    let mode: MatchesViewMode
    var isSelected: Bool = true

    // Deliberately not observed: only this mode's view state should trigger
    // re-renders. Store access is for method calls (configure/refresh/etc).
    private let matchesStore: MatchesStore
    @ObservedObject private var viewState: MatchesModeViewState
    @StateObject private var fixtureBrowser = FixtureBrowserStore()

    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var fantasyViewModel: FantasyViewModel
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppGroupConfig.fantasyManagerEntryIDKey) private var fantasyManagerEntryID = ""
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var predictionIndex = FixturePredictionStore.allPredictions()
    @State private var pendingPredictionDateKeys: Set<String> = []
    @State private var attemptedPredictionDateKeys: Set<String> = []
    @State private var groupedSideEffectsTask: Task<Void, Never>?
    @State private var reportedMissingLogoNames: Set<String> = []
    @State private var didRunActivationForVisibleCycle = false
    @State private var navigationMatch: MatchNavigation?
    @State private var screenOpenedAt: Date?
    @State private var screenViewSentForActivation = false
    @State private var visibleGroupedDays: [MatchDay] = []
    @State private var visibleGroupedDaysSource: [MatchDay] = []
    @State private var fixtureBrowseGroupedDays: [MatchDay] = []
    @State private var fixtureBrowsePageGroupedDays: [String: [MatchDay]] = [:]
    @State private var fixtureBrowsePageSourceMatchesByDate: [String: [Match]] = [:]
    @State private var expandedFixtureRegionID: String?
    @State private var fixturePickerDraftOptionIDs: Set<String>?
    @State private var fixturePickerBaselineOptionIDs: Set<String>?
    @State private var isFixtureFavouritesMenuExpanded = false

    init(mode: MatchesViewMode, isSelected: Bool = true, store: MatchesStore) {
        self.mode = mode
        self.isSelected = isSelected
        self.matchesStore = store
        self.viewState = store.viewState(for: mode)
    }

    private static let fixtureDockContentClearance: CGFloat = 80

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

    private var usesFixtureBrowser: Bool {
        mode == .fixtures && fixtureBrowser.hasLoadedCalendar
    }

    private var sourceGroupedDays: [MatchDay] {
        usesFixtureBrowser ? fixtureBrowseGroupedDays : viewState.groupedMatches
    }

    private var displayedMatchDays: [MatchDay] {
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

    private var navigationStackContent: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if mode == .fixtures {
                    fixtureDateBrowserControl
                }
                if usesFixtureBrowser {
                    fixtureDatePagedContent(containerWidth: proxy.size.width)
                } else {
                    activeMatchesContent
                }
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
                showFantasyBadge: nav.showFantasyBadge,
                predictionDisplay: nav.predictionDisplay
            )
        }
    }

    @ViewBuilder
    private var activeMatchesContent: some View {
        Group {
            if displayedMatchDays.isEmpty && isMatchesUpdating {
                nativeMatchesLoadingState
            } else if displayedMatchDays.isEmpty {
                emptyState
            } else {
                matchesList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func fixtureDatePagedContent(containerWidth: CGFloat) -> some View {
        FixtureDatePagingContainer(
            containerWidth: containerWidth,
            currentDateKey: fixtureBrowser.selectedDateKey,
            previousDateKey: fixtureBrowser.adjacentDateKey(offset: -1),
            nextDateKey: fixtureBrowser.adjacentDateKey(offset: 1),
            isSwipeEnabled: expandedFixtureRegionID == nil &&
                !isFixtureFavouritesMenuExpanded,
            reduceMotion: accessibilityReduceMotion,
            onSelect: fixtureBrowser.selectDate
        ) {
            activeMatchesContent
        } adjacentContent: { dateKey in
            fixtureDatePage(for: dateKey)
        }
    }

    @ViewBuilder
    private func fixtureDatePage(for dateKey: String) -> some View {
        if let days = fixtureBrowsePageGroupedDays[dateKey], !days.isEmpty {
            matchesListContent(days: days)
        } else {
            nativeMatchesLoadingState
        }
    }

    var body: some View {
        NavigationStack {
            navigationStackContent
                .navigationTitle(scoresNavigationTitle)
                .navigationBarTitleDisplayMode(.inline)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if mode == .fixtures && navigationMatch == nil {
                fixtureCompetitionDock
            }
        }
        .onAppear {
            refreshVisibleGroupedDays(from: sourceGroupedDays)
            guard isSelected else { return }
            runActivationIfNeeded(logEvent: "onAppear")
            beginScreenViewTiming()
        }
        .onChange(of: isSelected) { _, selected in
            matchesStore.setModeVisibility(mode, isVisible: selected)
            guard selected else {
                if mode == .fixtures {
                    fixtureBrowser.setAutoRefreshEnabled(false)
                    matchesStore.setFixtureBrowserLiveRefreshActive(false)
                }
                didRunActivationForVisibleCycle = false
                screenOpenedAt = nil
                screenViewSentForActivation = false
                return
            }
            refreshVisibleGroupedDays(from: sourceGroupedDays)
            runActivationIfNeeded(logEvent: "isSelected")
            beginScreenViewTiming()
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhaseChange(phase)
        }
        .onChange(of: viewState.isLoading) { _, isLoading in
            guard !isLoading else { return }
            sendTimedScreenView()
        }
        .onChange(of: preferences.snapshot) { _, _ in
            guard isSelected else { return }
            fixtureBrowsePageSourceMatchesByDate = [:]
            fixtureBrowsePageGroupedDays = [:]
            let snapshot = showAllMatches ? preferences.unfilteredSnapshot : preferences.snapshot
            NSLog("[MatchesView] snapshot_change mode=%@ showAllMatches=%d epl_pref=%d effective_snapshot=%@",
                  mode.rawValue, showAllMatches, preferences.englishPremierLeagueTeamsOnly, debugSnapshotSummary(snapshot))
            matchesStore.configure(with: snapshot, mode: mode)
            if mode == .fixtures {
                fixtureBrowser.configure(preferences: preferences.snapshot)
            }
            scheduleGroupedSideEffects(for: sourceGroupedDays, immediate: false)
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
            if !usesFixtureBrowser {
                refreshVisibleGroupedDays(from: days)
            }
            // A refreshed fixture payload may now have markets for a day that was
            // previously unavailable. Keep retries tied to data refreshes, never
            // to a row appearing again while the list is being scrolled.
            attemptedPredictionDateKeys.removeAll()
            guard isSelected else { return }
            warmPredictionsForVisibleDays(days: days)
            scheduleGroupedSideEffects(for: days, immediate: false)
        }
        .onChange(of: fixtureBrowser.visibleMatches) { _, _ in
            rebuildFixtureBrowseGrouping()
        }
        .onChange(of: fixtureBrowser.cachedMatchesByDate) { _, matchesByDate in
            rebuildFixtureBrowsePageGroupings(from: matchesByDate)
        }
        .onChange(of: fixtureBrowser.hasLoadedCalendar) { _, _ in
            rebuildFixtureBrowseGrouping()
        }
        .onChange(of: fixtureBrowser.selectedDateKey) { _, dateKey in
            guard mode == .fixtures, let dateKey else { return }
            AppMetricsService.shared.fireActivity(
                "fixture_date_changed",
                screen: mode.rawValue,
                apiBaseURL: preferences.apiBaseURL
            )
            NSLog("[MatchesView] fixture_date_change date=%@", dateKey)
        }
        .onChange(of: preferences.showPostponedGames) { _, _ in
            refreshVisibleGroupedDays(from: sourceGroupedDays, force: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: FixturePredictionStore.didChangeNotification)) { _ in
            guard isSelected else { return }
            predictionIndex = FixturePredictionStore.allPredictions()
        }
        .onDisappear(perform: handleScreenDisappear)
    }

    private var scoresNavigationTitle: String {
        guard let selectedDateKey = fixtureBrowser.selectedDateKey,
              let dateLabel = Self.friendlyFixtureDateLabel(selectedDateKey) else {
            return "Scores"
        }

        let matches = fixtureBrowser.cachedMatchesByDate[selectedDateKey] ?? []
        return "\(Self.navigationTitlePrefix(for: matches)): \(dateLabel)"
    }

    private static func navigationTitlePrefix(for matches: [Match], now: Date = Date()) -> String {
        guard !matches.isEmpty else { return "Scores" }
        if matches.allSatisfy({ $0.isFinished }) {
            return "Results"
        }

        let hasKickedOff = matches.contains { match in
            guard !match.isPostponed else { return false }
            if match.isInProgress || match.isFinished || match.hasScore {
                return true
            }
            guard let kickoff = match.dateTime else { return false }
            return kickoff <= now
        }
        return hasKickedOff ? "Scores" : "Fixtures"
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        guard mode == .fixtures, isSelected else { return }
        fixtureBrowser.setAutoRefreshEnabled(
            phase == .active,
            refreshImmediately: phase == .active
        )
    }

    private func handleScreenDisappear() {
        matchesStore.setModeVisibility(mode, isVisible: false)
        if mode == .fixtures {
            fixtureBrowser.setAutoRefreshEnabled(false)
            matchesStore.setFixtureBrowserLiveRefreshActive(false)
        }
        expandedFixtureRegionID = nil
        fixturePickerDraftOptionIDs = nil
        fixturePickerBaselineOptionIDs = nil
        isFixtureFavouritesMenuExpanded = false
        groupedSideEffectsTask?.cancel()
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
        matchesListContent(
            days: displayedMatchDays,
            includesResultsLoadingRow: true
        )
        .refreshable {
            let refreshStart = Date()
            if mode == .fixtures {
                await fixtureBrowser.refresh()
            } else {
                let snapshot = showAllMatches ? preferences.unfilteredSnapshot : preferences.snapshot
                await matchesStore.refresh(
                    preferences: snapshot,
                    mode: mode,
                    force: true
                )
            }
            let durationMs = Int(Date().timeIntervalSince(refreshStart) * 1000)
            AppMetricsService.shared.fireActivity("manual_refresh", screen: mode.rawValue, durationMs: durationMs, apiBaseURL: preferences.apiBaseURL)
        }
    }

    private func matchesListContent(
        days: [MatchDay],
        includesResultsLoadingRow: Bool = false
    ) -> some View {
        List {
            ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                if usesFixtureBrowser {
                    Section {
                        compactLeagueRows(for: day)
                    }
                } else {
                    Section {
                        compactLeagueRows(for: day)
                    } header: {
                        sectionHeader(for: day, isFirst: index == 0)
                    }
                }
            }

            if includesResultsLoadingRow && mode == .results && viewState.isLoadingMoreMatches {
                loadingMoreMatchesRow
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, compactFixturesSpacing.minListRowHeight)
        .safeAreaPadding(
            .bottom,
            mode == .fixtures ? Self.fixtureDockContentClearance : 80
        )
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
                showFantasyBadge: mode == .fixtures,
                predictionDisplay: predictionDisplayState(for: match, dateKey: day.dateKey)
            )
        } label: {
            HStack(spacing: 0) {
                MatchesListRowLabel(
                    match: match,
                    isFixtureMode: mode == .fixtures,
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
            Text(mode.emptyStateTitle)
                .font(.title3)
            Text(mode.emptyStateSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isMatchesUpdating: Bool {
        mode == .fixtures
            ? (fixtureBrowser.isLoadingSelectedDate || viewState.isLoading)
            : viewState.isLoading
    }

    private var nativeMatchesLoadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text(mode.loadingText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(mode.loadingText)
    }

    private var fixtureDateBrowserControl: some View {
        Group {
            if fixtureBrowser.availableDays.isEmpty {
                HStack(spacing: 8) {
                    if !fixtureBrowser.hasLoadedCalendar && fixtureBrowser.errorMessage == nil {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(
                        fixtureBrowser.hasLoadedCalendar
                            ? "No match dates available"
                            : fixtureBrowser.errorMessage == nil
                                ? "Loading match dates"
                                : "Match-date browsing unavailable"
                    )
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 52)
                .padding(.horizontal, 16)
            } else {
                let jumpDirection = fixtureBrowser.nextMatchDateJumpDirection
                ZStack {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 6) {
                                ForEach(fixtureBrowser.availableDays) { day in
                                    let selected = fixtureBrowser.selectedDateKey == day.date
                                    Button {
                                        fixtureBrowser.selectDate(day.date)
                                    } label: {
                                        FixtureDateCarouselTile(
                                            dateKey: day.date,
                                            matchCount: fixtureMatchCount(for: day),
                                            isSelected: selected
                                        )
                                    }
                                    .id(day.date)
                                    .buttonStyle(.plain)
                                    .accessibilityAddTraits(selected ? .isSelected : [])
                                }
                            }
                            .scrollTargetLayout()
                            .padding(.leading, jumpDirection == .earlier ? 66 : 12)
                            .padding(.trailing, jumpDirection == .later ? 66 : 12)
                        }
                        .scrollIndicators(.hidden)
                        .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                        .mask {
                            HStack(spacing: 0) {
                                LinearGradient(
                                    colors: [.clear, .black],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: 10)
                                Rectangle().fill(.black)
                                LinearGradient(
                                    colors: [.black, .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: 10)
                            }
                        }
                        .frame(height: 56)
                        .onAppear {
                            if let selectedDateKey = fixtureBrowser.selectedDateKey {
                                proxy.scrollTo(selectedDateKey, anchor: .center)
                            }
                        }
                        .onChange(of: fixtureBrowser.selectedDateKey) { _, dateKey in
                            guard let dateKey else { return }
                            if accessibilityReduceMotion {
                                proxy.scrollTo(dateKey, anchor: .center)
                            } else {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(dateKey, anchor: .center)
                                }
                            }
                        }
                    }

                    if let direction = jumpDirection,
                       let targetDateKey = fixtureBrowser.nextMatchDateKey {
                        HStack(spacing: 0) {
                            if direction == .later { Spacer(minLength: 0) }
                            fixtureNextMatchButton(direction: direction, targetDateKey: targetDateKey)
                            if direction == .earlier { Spacer(minLength: 0) }
                        }
                    }
                }
                .frame(height: 56)
            }
        }
        .background(Color(.systemBackground).opacity(0.82))
    }

    private func fixtureNextMatchButton(
        direction: FixtureBrowseSelectionResolver.DateJumpDirection,
        targetDateKey: String
    ) -> some View {
        Button {
            fixtureBrowser.selectNextMatchDate()
        } label: {
            HStack(spacing: 3) {
                if direction == .earlier {
                    Image(systemName: "chevron.left")
                }
                Image(systemName: "soccerball")
                    .symbolRenderingMode(.hierarchical)
                if direction == .later {
                    Image(systemName: "chevron.right")
                }
            }
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 50, height: 42)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.8), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.leading, direction == .earlier ? 6 : 0)
        .padding(.trailing, direction == .later ? 6 : 0)
        .accessibilityLabel("Jump to next scheduled match")
        .accessibilityHint("Moves to \(fixtureJumpDateLabel(targetDateKey))")
    }

    private func fixtureJumpDateLabel(_ dateKey: String) -> String {
        Self.friendlyFixtureDateLabel(dateKey) ?? dateKey
    }

    private static func friendlyFixtureDateLabel(_ dateKey: String) -> String? {
        let parts = dateKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar.current.date(
                from: DateComponents(year: parts[0], month: parts[1], day: parts[2])
              ) else {
            return nil
        }

        let day = Calendar.current.component(.day, from: date)
        let formattedDate = date.formatted(
            .dateTime
                .weekday(.wide)
                .month(.wide)
                .day()
                .locale(Locale(identifier: "en_US"))
        )
        return "\(formattedDate)\(ordinalSuffix(for: day))"
    }

    private static func ordinalSuffix(for day: Int) -> String {
        if 11...13 ~= day % 100 {
            return "th"
        }

        switch day % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    private var fixtureCompetitionDock: some View {
        fixtureCompetitionRail
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) {
                if isFixtureFavouritesMenuExpanded {
                    fixtureFavouritesPanel
                        .padding(.horizontal, 12)
                        .offset(y: -70)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(2)
                } else if let region = expandedFixtureRegion {
                    fixtureCompetitionPanel(for: region)
                        .padding(.horizontal, 12)
                        .offset(y: -70)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(2)
                }
            }
            .animation(.easeOut(duration: 0.2), value: expandedFixtureRegionID)
            .animation(.easeOut(duration: 0.2), value: isFixtureFavouritesMenuExpanded)
            .zIndex(20)
    }

    private var fixtureCompetitionRail: some View {
        HStack(spacing: 6) {
            Button {
                fixturePickerDraftOptionIDs = nil
                fixturePickerBaselineOptionIDs = nil
                withAnimation(.easeOut(duration: 0.2)) {
                    expandedFixtureRegionID = nil
                    isFixtureFavouritesMenuExpanded.toggle()
                }
            } label: {
                FixtureRegionDockButton(
                    systemSymbol: isPremierLeagueMatchesPresetSelected ? nil : fixtureViewOptionsSymbol,
                    regionID: nil,
                    isSelected: preferences.fixtureAllMajorMatchesEnabled ||
                        preferences.showAllMatches ||
                        isPremierLeagueMatchesPresetSelected,
                    isExpanded: isFixtureFavouritesMenuExpanded,
                    showsFantasyPremierLeagueIcon: isPremierLeagueMatchesPresetSelected
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View options")
            .accessibilityValue(fixtureViewOptionsAccessibilityValue)
            .accessibilityHint("Shows fixture view options")

            Divider()
                .frame(height: 28)

            if fixtureBrowser.competitions.isEmpty {
                HStack(spacing: 8) {
                    if fixtureBrowser.errorMessage == nil {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                    Text(fixtureBrowser.errorMessage == nil ? "Loading" : "Unavailable")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 4) {
                        ForEach(availableFixtureRegions) { region in
                            let selectedCount = selectedCompetitionCount(in: region)
                            Button {
                                toggleFixtureCompetitionPicker(for: region.id)
                            } label: {
                                FixtureRegionDockButton(
                                    systemSymbol: nil,
                                    regionID: region.id,
                                    isSelected: selectedCount > 0,
                                    isExpanded: expandedFixtureRegionID == region.id
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(region.name)
                            .accessibilityValue(
                                selectedCount == 0
                                    ? "No competitions selected"
                                    : "\(selectedCount) competitions selected"
                            )
                            .accessibilityHint("Shows \(region.name) competitions")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(6)
        .frame(height: 58)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(.separator).opacity(0.45), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
    }

    private var fixtureFavouritesPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("View options")
                        .font(.headline)
                    Text("Choose which fixtures to show")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isFixtureFavouritesMenuExpanded = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close view options")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            fixturePredictionsActionRow
            Divider().padding(.leading, 58)
            fixtureFavouritesActionRow(
                title: "Show favourites",
                subtitle: "Use your saved competition view",
                icon: .system("star.fill"),
                isSelected: preferences.fixtureAllMajorMatchesEnabled,
                action: selectFavourites
            )
            Divider().padding(.leading, 58)
            fixtureFavouritesActionRow(
                title: "Show all",
                subtitle: "Include every competition",
                icon: .system("globe"),
                isSelected: preferences.showAllMatches,
                action: selectAllFixtureCompetitions
            )
            Divider().padding(.leading, 58)
            fixtureFavouritesActionRow(
                title: "Show Premier League teams",
                subtitle: "Show all matches involving Premier League teams",
                icon: .fantasyPremierLeague,
                isSelected: isPremierLeagueMatchesPresetSelected,
                action: selectPremierLeagueMatches
            )
            Divider().padding(.leading, 58)
            fixtureFavouritesActionRow(
                title: "Save current view as favourites",
                subtitle: "Replace your saved competition view",
                icon: .system("square.and.arrow.down"),
                isSelected: false,
                action: saveCurrentFixtureViewAsFavourites
            )
        }
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(.separator).opacity(0.55), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
    }

    private var fixturePredictionsActionRow: some View {
        Button {
            preferences.showPredictedScores.toggle()
            if preferences.showPredictedScores {
                warmPredictionsForVisibleDays(days: sourceGroupedDays)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show predictions")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("Display AI score predictions")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                FixturePickerCheckbox(isSelected: preferences.showPredictedScores)
            }
            .padding(.horizontal, 14)
            .frame(height: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show predictions")
        .accessibilityValue(preferences.showPredictedScores ? "Checked" : "Not checked")
        .accessibilityHint("Displays AI score predictions for matches")
    }

    private var fixtureViewOptionsSymbol: String {
        if preferences.fixtureAllMajorMatchesEnabled { return "star.fill" }
        if preferences.showAllMatches { return "globe" }
        return "slider.horizontal.3"
    }

    private var fixtureViewOptionsAccessibilityValue: String {
        if preferences.fixtureAllMajorMatchesEnabled { return "Favourites selected" }
        if preferences.showAllMatches { return "All competitions selected" }
        if isPremierLeagueMatchesPresetSelected { return "Premier League teams selected" }
        return "Custom view selected"
    }

    private var isPremierLeagueMatchesPresetSelected: Bool {
        !preferences.fixtureAllMajorMatchesEnabled &&
        !preferences.showAllMatches &&
        Set(preferences.selectedFixtureViewOptionIDs) ==
            FixtureViewOptionID.premierLeagueMatchesPresetOptionIDs
    }

    private enum FixtureFavouritesActionIcon {
        case system(String)
        case fantasyPremierLeague
    }

    private func fixtureFavouritesActionRow(
        title: String,
        subtitle: String,
        icon: FixtureFavouritesActionIcon,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                fixtureFavouritesActionIcon(icon, isSelected: isSelected)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }

    @ViewBuilder
    private func fixtureFavouritesActionIcon(
        _ icon: FixtureFavouritesActionIcon,
        isSelected: Bool
    ) -> some View {
        Group {
            switch icon {
            case .system(let name):
                Image(systemName: name)
                    .font(.system(size: 18, weight: .semibold))
            case .fantasyPremierLeague:
                FantasyLionIconView(size: 20)
            }
        }
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        .frame(width: 32, height: 32)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func fixtureCompetitionPanel(for region: FixtureCompetitionRegion) -> some View {
        let competitions = fixtureCompetitions(in: region)
        let specialOptions = FixtureViewSpecialOption.options(in: region.id)
        let listHeight = min(CGFloat(competitions.count + specialOptions.count) * 58, 348)

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                FixtureRegionFlagIcon(regionID: region.id, size: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(region.name)
                        .font(.headline)
                    Text("Select competitions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismissFixtureCompetitionPicker()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close competition picker")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(specialOptions) { option in
                        let selected = isFixturePickerOptionSelected(option.id)
                        Button {
                            toggleFixturePickerOption(option.id)
                        } label: {
                            HStack(spacing: 12) {
                                FixtureViewSpecialOptionIcon(option: option, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(option.subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1)
                                FixturePickerCheckbox(isSelected: selected)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 58)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.title)
                        .accessibilityValue(selected ? "Selected" : "Not selected")

                        if option.id != specialOptions.last?.id {
                            Divider()
                                .padding(.leading, 58)
                        }
                    }

                    if !specialOptions.isEmpty && !competitions.isEmpty {
                        Divider()
                    }

                    ForEach(competitions, id: \.stableID) { competition in
                        let optionID = FixtureViewOptionID.competition(competition.stableID)
                        let selected = isFixturePickerOptionSelected(optionID)
                        Button {
                            toggleFixturePickerOption(optionID)
                        } label: {
                            HStack(spacing: 12) {
                                CompetitionBadgeImage(
                                    competitionID: competition.stableID,
                                    size: 32
                                )
                                Text(competition.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(1)
                                FixturePickerCheckbox(isSelected: selected)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 54)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(competition.name)
                        .accessibilityValue(selected ? "Selected" : "Not selected")

                        if competition.stableID != competitions.last?.stableID {
                            Divider()
                                .padding(.leading, 58)
                        }
                    }
                }
            }
            .frame(height: listHeight)

            Divider()

            Button {
                commitFixtureCompetitionPicker()
            } label: {
                Text("Done")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .padding(10)
        }
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(.separator).opacity(0.55), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
    }

    private var expandedFixtureRegion: FixtureCompetitionRegion? {
        guard let expandedFixtureRegionID else { return nil }
        return availableFixtureRegions.first { $0.id == expandedFixtureRegionID }
    }

    private var availableFixtureRegions: [FixtureCompetitionRegion] {
        FixtureCompetitionRegion.all.filter { !fixtureCompetitions(in: $0).isEmpty }
    }

    private func fixtureCompetitions(in region: FixtureCompetitionRegion) -> [CompetitionCatalogEntry] {
        fixtureBrowser.competitions
            .filter { fixtureCompetitionRegionID(for: $0) == region.id }
            .sorted { left, right in
                if left.weight != right.weight { return left.weight > right.weight }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }

    private func selectedCompetitionCount(in region: FixtureCompetitionRegion) -> Int {
        let competitionCount = fixtureCompetitions(in: region).filter(isFixtureCompetitionSelected).count
        let specialCount = FixtureViewSpecialOption.options(in: region.id)
            .filter { isFixtureViewOptionSelected($0.id) }
            .count
        return competitionCount + specialCount
    }

    private func fixtureCompetitionRegionID(for competition: CompetitionCatalogEntry) -> String {
        if let region = competition.region?.trimmingCharacters(in: .whitespacesAndNewlines),
           !region.isEmpty {
            return region.lowercased()
        }

        let key = FixtureBrowseSelectionResolver.normalizedKey(competition.name)
        if key.contains("uefa") { return "europe" }
        if key.contains("fifa") || key.contains("international friendly") { return "world" }
        if key.contains("scottish") { return "scotland" }
        if key.contains("la liga") || key.contains("copa del rey") { return "spain" }
        if key.contains("bundesliga") { return "germany" }
        if key.contains("serie a") { return "italy" }
        if key.contains("ligue 1") { return "france" }
        return "england"
    }

    private func isFixtureCompetitionSelected(_ competition: CompetitionCatalogEntry) -> Bool {
        isFixtureViewOptionSelected(FixtureViewOptionID.competition(competition.stableID))
    }

    private func isFixtureViewOptionSelected(_ optionID: String) -> Bool {
        preferences.snapshot.fixtureViewShowsAll || effectiveFixtureViewOptionIDs.contains(optionID)
    }

    private func isFixturePickerOptionSelected(_ optionID: String) -> Bool {
        fixturePickerDraftOptionIDs?.contains(optionID) ?? isFixtureViewOptionSelected(optionID)
    }

    private var effectiveFixtureViewOptionIDs: Set<String> {
        if preferences.showAllMatches {
            return []
        }
        if preferences.fixtureAllMajorMatchesEnabled {
            return Set(preferences.favouriteFixtureViewOptionIDs)
        }
        if !preferences.selectedFixtureViewOptionIDs.isEmpty {
            return Set(preferences.selectedFixtureViewOptionIDs)
        }
        return Set(FixtureBrowseSelectionResolver.selectedCompetitionIDs(
            selectedLeagues: preferences.selectedLeagues,
            competitions: fixtureBrowser.competitions
        ).map(FixtureViewOptionID.competition))
    }

    private var fixturePickerInitialOptionIDs: Set<String> {
        guard preferences.snapshot.fixtureViewShowsAll else {
            return effectiveFixtureViewOptionIDs
        }
        return Set(fixtureBrowser.competitions.map {
            FixtureViewOptionID.competition($0.stableID)
        })
    }

    private func toggleFixtureCompetitionPicker(for regionID: String) {
        guard expandedFixtureRegionID != regionID else {
            dismissFixtureCompetitionPicker()
            return
        }

        let initialOptionIDs = fixturePickerInitialOptionIDs
        fixturePickerDraftOptionIDs = initialOptionIDs
        fixturePickerBaselineOptionIDs = initialOptionIDs
        withAnimation(.easeOut(duration: 0.2)) {
            isFixtureFavouritesMenuExpanded = false
            expandedFixtureRegionID = regionID
        }
    }

    private func dismissFixtureCompetitionPicker() {
        withAnimation(.easeOut(duration: 0.2)) {
            expandedFixtureRegionID = nil
        }
    }

    private func toggleFixturePickerOption(_ optionID: String) {
        let currentOptionIDs = fixturePickerDraftOptionIDs ?? fixturePickerInitialOptionIDs
        fixturePickerDraftOptionIDs = FixtureViewOptionID.toggling(
            optionID,
            in: currentOptionIDs
        )
    }

    private func commitFixtureCompetitionPicker() {
        let selectedIDs = fixturePickerDraftOptionIDs ?? fixturePickerInitialOptionIDs
        let baselineOptionIDs = fixturePickerBaselineOptionIDs ?? fixturePickerInitialOptionIDs
        let hasChanges = selectedIDs != baselineOptionIDs
        dismissFixtureCompetitionPicker()
        guard hasChanges else { return }

        guard !selectedIDs.isEmpty else {
            selectFavourites()
            return
        }

        applyCustomFixtureView(selectedIDs)
        AppMetricsService.shared.fireActivity(
            "fixture_competition_changed",
            screen: mode.rawValue,
            apiBaseURL: preferences.apiBaseURL
        )
    }

    private func selectFavourites() {
        fixturePickerDraftOptionIDs = nil
        fixturePickerBaselineOptionIDs = nil
        withAnimation(.easeOut(duration: 0.2)) {
            expandedFixtureRegionID = nil
            isFixtureFavouritesMenuExpanded = false
        }
        preferences.fixtureAllMajorMatchesEnabled = true
        preferences.competitionFilterEnabled = false
        preferences.englishPremierLeagueTeamsOnly = true
        preferences.majorUEFAClubGamesEnabled = true
        preferences.homeNationsFilterEnabled = true
        preferences.majorTournamentsFilterEnabled = true
        preferences.showAllMatches = false
        fixtureBrowser.configure(
            preferences: preferences.snapshot,
            resetSelectedDate: true
        )
        AppMetricsService.shared.fireActivity(
            "fixture_competition_favourites",
            screen: mode.rawValue,
            apiBaseURL: preferences.apiBaseURL
        )
    }

    private func selectAllFixtureCompetitions() {
        fixturePickerDraftOptionIDs = nil
        fixturePickerBaselineOptionIDs = nil
        withAnimation(.easeOut(duration: 0.2)) {
            expandedFixtureRegionID = nil
            isFixtureFavouritesMenuExpanded = false
        }
        preferences.fixtureAllMajorMatchesEnabled = false
        preferences.competitionFilterEnabled = false
        preferences.englishPremierLeagueTeamsOnly = false
        preferences.majorUEFAClubGamesEnabled = false
        preferences.homeNationsFilterEnabled = false
        preferences.majorTournamentsFilterEnabled = false
        preferences.showAllMatches = true
        fixtureBrowser.configure(
            preferences: preferences.snapshot,
            resetSelectedDate: true
        )
        AppMetricsService.shared.fireActivity(
            "fixture_competition_all",
            screen: mode.rawValue,
            apiBaseURL: preferences.apiBaseURL
        )
    }

    private func saveCurrentFixtureViewAsFavourites() {
        let optionIDs: [String]
        if preferences.showAllMatches {
            optionIDs = [FixtureViewOptionID.all]
        } else if preferences.fixtureAllMajorMatchesEnabled {
            optionIDs = preferences.favouriteFixtureViewOptionIDs
        } else {
            optionIDs = preferences.selectedFixtureViewOptionIDs
        }
        guard !optionIDs.isEmpty else { return }
        preferences.favouriteFixtureViewOptionIDs = optionIDs
        withAnimation(.easeOut(duration: 0.2)) {
            isFixtureFavouritesMenuExpanded = false
        }
        toastMessage = "Current view saved as favourites"
        withAnimation { showToast = true }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { showToast = false }
        }
        AppMetricsService.shared.fireActivity(
            "fixture_competition_favourites_saved",
            screen: mode.rawValue,
            apiBaseURL: preferences.apiBaseURL
        )
    }

    private func selectPremierLeagueMatches() {
        fixturePickerDraftOptionIDs = nil
        fixturePickerBaselineOptionIDs = nil
        withAnimation(.easeOut(duration: 0.2)) {
            expandedFixtureRegionID = nil
            isFixtureFavouritesMenuExpanded = false
        }
        applyCustomFixtureView(FixtureViewOptionID.premierLeagueMatchesPresetOptionIDs)
        AppMetricsService.shared.fireActivity(
            "fixture_premier_league_matches_preset",
            screen: mode.rawValue,
            apiBaseURL: preferences.apiBaseURL
        )
    }

    private func applyCustomFixtureView(_ selectedIDs: Set<String>) {
        preferences.selectedFixtureViewOptionIDs = selectedIDs.sorted()
        let selectedCompetitionIDs = Set(selectedIDs.compactMap(FixtureViewOptionID.competitionStableID))
        preferences.selectedLeagues = fixtureBrowser.competitions
            .filter { selectedCompetitionIDs.contains($0.stableID) }
            .sorted { left, right in
                if left.weight != right.weight { return left.weight > right.weight }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
            .map(\.name)
        preferences.fixtureAllMajorMatchesEnabled = false
        preferences.competitionFilterEnabled = true
        preferences.englishPremierLeagueTeamsOnly = false
        preferences.majorUEFAClubGamesEnabled = false
        preferences.homeNationsFilterEnabled = false
        preferences.majorTournamentsFilterEnabled = false
        preferences.showAllMatches = false
        fixtureBrowser.configure(
            preferences: preferences.snapshot,
            resetSelectedDate: true
        )
    }

    private func fixtureMatchCount(for day: FixtureCalendarDay) -> Int {
        day.matchCount
    }

    private func scheduleGroupedSideEffects(for days: [MatchDay], immediate: Bool) {
        groupedSideEffectsTask?.cancel()
        groupedSideEffectsTask = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: groupedSideEffectsDelayNanos)
            }
            guard !Task.isCancelled else { return }
            ensureFantasySquadLoadedIfNeeded()
            reportMissingTeamLogosIfNeeded(days: days)
        }
    }

    private func rebuildFixtureBrowseGrouping() {
        guard mode == .fixtures else { return }
        let pageGroupings = rebuildFixtureBrowsePageGroupings(
            from: fixtureBrowser.cachedMatchesByDate
        )
        let groupedDays = fixtureBrowser.selectedDateKey
            .flatMap { pageGroupings[$0] }
            ?? matchesStore.groupFixtureBrowseMatches(
                fixtureBrowser.visibleMatches,
                preferences: preferences.snapshot
            )
        let groupingChanged = groupedDays != fixtureBrowseGroupedDays
        if groupingChanged {
            fixtureBrowseGroupedDays = groupedDays
        }
        refreshVisibleGroupedDays(from: groupedDays)
        guard groupingChanged else { return }
        warmPredictionsForVisibleDays(days: groupedDays)
        scheduleGroupedSideEffects(for: groupedDays, immediate: false)
    }

    @discardableResult
    private func rebuildFixtureBrowsePageGroupings(
        from matchesByDate: [String: [Match]]
    ) -> [String: [MatchDay]] {
        guard mode == .fixtures else { return fixtureBrowsePageGroupedDays }
        guard matchesByDate != fixtureBrowsePageSourceMatchesByDate else {
            return fixtureBrowsePageGroupedDays
        }

        var groupedByDate = fixtureBrowsePageGroupedDays
        for removedDateKey in fixtureBrowsePageSourceMatchesByDate.keys
            where matchesByDate[removedDateKey] == nil {
            groupedByDate.removeValue(forKey: removedDateKey)
        }

        for (dateKey, matches) in matchesByDate {
            guard fixtureBrowsePageSourceMatchesByDate[dateKey] != matches else { continue }
            guard !matches.isEmpty else {
                groupedByDate.removeValue(forKey: dateKey)
                continue
            }
            let groupedDays = matchesStore.groupFixtureBrowseMatches(
                matches,
                preferences: preferences.snapshot
            )
            if groupedDays.isEmpty {
                groupedByDate.removeValue(forKey: dateKey)
            } else {
                groupedByDate[dateKey] = groupedDays
            }
        }

        fixtureBrowsePageSourceMatchesByDate = matchesByDate
        if groupedByDate != fixtureBrowsePageGroupedDays {
            fixtureBrowsePageGroupedDays = groupedByDate
        }
        return groupedByDate
    }

    private func runActivationIfNeeded(logEvent: String) {
        guard !didRunActivationForVisibleCycle else { return }
        didRunActivationForVisibleCycle = true
        matchesStore.setModeVisibility(mode, isVisible: true)
        if mode == .fixtures {
            matchesStore.setFixtureBrowserLiveRefreshActive(true)
        }
        let snapshot = showAllMatches ? preferences.unfilteredSnapshot : preferences.snapshot
        NSLog("[MatchesView] %@ mode=%@ selected=%d snapshot=%@", logEvent, mode.rawValue, isSelected, debugSnapshotSummary(snapshot))
        matchesStore.configure(with: snapshot, mode: mode)
        if mode == .fixtures {
            fixtureBrowser.configure(preferences: preferences.snapshot)
            fixtureBrowser.setAutoRefreshEnabled(
                scenePhase == .active,
                refreshImmediately: scenePhase == .active
            )
            rebuildFixtureBrowseGrouping()
        }
        let days = sourceGroupedDays
        predictionIndex = FixturePredictionStore.allPredictions()
        warmPredictionsForVisibleDays(days: days)
        scheduleGroupedSideEffects(for: days, immediate: false)
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

private struct FixtureCompetitionRegion: Identifiable, Hashable {
    let id: String
    let name: String

    static let all = [
        FixtureCompetitionRegion(id: "england", name: "England"),
        FixtureCompetitionRegion(id: "germany", name: "Germany"),
        FixtureCompetitionRegion(id: "spain", name: "Spain"),
        FixtureCompetitionRegion(id: "italy", name: "Italy"),
        FixtureCompetitionRegion(id: "france", name: "France"),
        FixtureCompetitionRegion(id: "europe", name: "Europe"),
        FixtureCompetitionRegion(id: "world", name: "World"),
        FixtureCompetitionRegion(id: "scotland", name: "Scotland"),
    ]
}

private struct FixturePickerCheckbox: View {
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isSelected ? Color.accentColor : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.8), lineWidth: 1.5)
            }
            .overlay {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
    }
}

private struct FixtureViewSpecialOptionIcon: View {
    let option: FixtureViewSpecialOption
    let size: CGFloat
    @State private var badgeCacheVersion = 0

    var body: some View {
        Group {
            if option.id == FixtureViewOptionID.premierLeagueTeams {
                CompetitionBadgeImage(competitionID: "premier-league", size: size)
            } else if let systemImage = option.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.58, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            } else if !option.logoTeamNames.isEmpty {
                HStack(spacing: option.logoTeamNames.count > 1 ? -6 : 0) {
                    ForEach(Array(option.logoTeamNames.prefix(2).enumerated()), id: \.offset) { _, teamName in
                        fixtureTeamLogo(teamName)
                    }
                }
            } else {
                Image(systemName: "shield")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: TeamBadgeCache.badgesUpdatedNotification)) { _ in
            badgeCacheVersion += 1
        }
    }

    @ViewBuilder
    private func fixtureTeamLogo(_ teamName: String) -> some View {
        if let image = LogoResolver.shared.image(for: teamName) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: option.logoTeamNames.count > 1 ? size * 0.68 : size, height: size)
        } else {
            Image(systemName: "shield")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: size * 0.72, height: size * 0.72)
        }
    }
}

private struct FixtureRegionDockButton: View {
    let systemSymbol: String?
    let regionID: String?
    let isSelected: Bool
    let isExpanded: Bool
    var showsFantasyPremierLeagueIcon = false

    var body: some View {
        ZStack {
            Circle()
                .fill(isExpanded ? Color.accentColor.opacity(0.16) : Color.clear)

            if showsFantasyPremierLeagueIcon {
                FantasyLionIconView(size: 24)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            } else if let systemSymbol {
                Image(systemName: systemSymbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            } else if let regionID {
                FixtureRegionFlagIcon(regionID: regionID, size: 30)
                    .padding(2)
                    .overlay {
                        Circle()
                            .stroke(
                                isSelected || isExpanded ? Color.accentColor : Color.clear,
                                lineWidth: isExpanded ? 2 : 1
                            )
                    }
            }
        }
        .frame(width: 44, height: 44)
        .overlay {
            if systemSymbol != nil || showsFantasyPremierLeagueIcon {
                Circle()
                    .stroke(isExpanded ? Color.accentColor : Color.clear, lineWidth: 1.5)
            }
        }
        .contentShape(Circle())
    }
}

private struct FixtureRegionFlagIcon: View {
    let regionID: String
    let size: CGFloat

    var body: some View {
        ZStack {
            switch regionID {
            case "england":
                Circle().fill(.white)
                Rectangle()
                    .fill(Color(red: 0.80, green: 0.08, blue: 0.13))
                    .frame(width: size * 0.20, height: size)
                Rectangle()
                    .fill(Color(red: 0.80, green: 0.08, blue: 0.13))
                    .frame(width: size, height: size * 0.20)
            case "germany":
                VStack(spacing: 0) {
                    Color.black
                    Color(red: 0.82, green: 0.04, blue: 0.10)
                    Color(red: 1.00, green: 0.78, blue: 0.06)
                }
            case "spain":
                VStack(spacing: 0) {
                    Color(red: 0.73, green: 0.05, blue: 0.09)
                    Color(red: 1.00, green: 0.78, blue: 0.05)
                        .frame(height: size * 0.50)
                    Color(red: 0.73, green: 0.05, blue: 0.09)
                }
            case "italy":
                HStack(spacing: 0) {
                    Color(red: 0.00, green: 0.57, blue: 0.28)
                    Color.white
                    Color(red: 0.81, green: 0.06, blue: 0.15)
                }
            case "france":
                HStack(spacing: 0) {
                    Color(red: 0.02, green: 0.24, blue: 0.57)
                    Color.white
                    Color(red: 0.85, green: 0.06, blue: 0.13)
                }
            case "europe":
                Circle().fill(Color(red: 0.00, green: 0.20, blue: 0.63))
                ForEach(0..<12, id: \.self) { index in
                    Circle()
                        .fill(Color(red: 1.00, green: 0.80, blue: 0.00))
                        .frame(width: size * 0.075, height: size * 0.075)
                        .offset(y: -size * 0.29)
                        .rotationEffect(.degrees(Double(index) * 30))
                }
            case "scotland":
                Circle().fill(Color(red: 0.00, green: 0.36, blue: 0.66))
                Rectangle()
                    .fill(.white)
                    .frame(width: size * 1.3, height: size * 0.16)
                    .rotationEffect(.degrees(38))
                Rectangle()
                    .fill(.white)
                    .frame(width: size * 1.3, height: size * 0.16)
                    .rotationEffect(.degrees(-38))
            default:
                Circle().fill(Color(red: 0.05, green: 0.48, blue: 0.77))
                Image(systemName: "globe.europe.africa.fill")
                    .font(.system(size: size * 0.68, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle().stroke(Color.white.opacity(0.28), lineWidth: 0.5)
        }
    }
}

private struct CompetitionBadgeImage: View {
    let competitionID: String
    let size: CGFloat
    @State private var badgeCacheVersion = 0

    var body: some View {
        Group {
            if let image = CompetitionBadgeCache.shared.image(for: competitionID) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "soccerball")
                    .font(.system(size: size * 0.7, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .onReceive(NotificationCenter.default.publisher(for: CompetitionBadgeCache.badgesUpdatedNotification)) { _ in
            badgeCacheVersion += 1
        }
    }
}

/// Owns high-frequency drag state so a swipe doesn't invalidate the entire fixtures screen.
private struct FixtureDatePagingContainer<CurrentContent: View, AdjacentContent: View>: View {
    let containerWidth: CGFloat
    let currentDateKey: String?
    let previousDateKey: String?
    let nextDateKey: String?
    let isSwipeEnabled: Bool
    let reduceMotion: Bool
    let onSelect: (String) -> Void
    private let currentContent: CurrentContent
    private let adjacentContent: (String) -> AdjacentContent

    @State private var dragOffset: CGFloat = 0
    @State private var dragAxis: DragAxis?
    @State private var transitionTask: Task<Void, Never>?

    private enum DragAxis {
        case horizontal
        case vertical
    }

    init(
        containerWidth: CGFloat,
        currentDateKey: String?,
        previousDateKey: String?,
        nextDateKey: String?,
        isSwipeEnabled: Bool,
        reduceMotion: Bool,
        onSelect: @escaping (String) -> Void,
        @ViewBuilder currentContent: () -> CurrentContent,
        @ViewBuilder adjacentContent: @escaping (String) -> AdjacentContent
    ) {
        self.containerWidth = containerWidth
        self.currentDateKey = currentDateKey
        self.previousDateKey = previousDateKey
        self.nextDateKey = nextDateKey
        self.isSwipeEnabled = isSwipeEnabled
        self.reduceMotion = reduceMotion
        self.onSelect = onSelect
        self.currentContent = currentContent()
        self.adjacentContent = adjacentContent
    }

    var body: some View {
        ZStack {
            if let adjacentDateKey {
                adjacentContent(adjacentDateKey)
                    .offset(x: incomingPageOffset)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }

            currentContent
                .offset(x: dragOffset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemBackground))
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(swipeGesture)
        .onChange(of: currentDateKey) { _, _ in
            resetTransition()
        }
        .onChange(of: isSwipeEnabled) { _, enabled in
            if !enabled {
                resetTransition()
            }
        }
        .onDisappear {
            transitionTask?.cancel()
        }
    }

    private var canBeginSwipe: Bool {
        isSwipeEnabled && transitionTask == nil
    }

    private var adjacentDateKey: String? {
        guard dragOffset != 0 else { return nil }
        return dragOffset < 0 ? nextDateKey : previousDateKey
    }

    private var incomingPageOffset: CGFloat {
        guard dragOffset != 0 else { return 0 }
        return (dragOffset < 0 ? containerWidth : -containerWidth) + dragOffset
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard canBeginSwipe else { return }

                if dragAxis == nil {
                    let horizontalDistance = abs(value.translation.width)
                    let verticalDistance = abs(value.translation.height)
                    guard max(horizontalDistance, verticalDistance) >= 10 else { return }
                    dragAxis = horizontalDistance > verticalDistance ? .horizontal : .vertical
                }

                guard dragAxis == .horizontal else { return }
                let hasAdjacentDate = value.translation.width < 0
                    ? nextDateKey != nil
                    : previousDateKey != nil
                let motionScale: CGFloat = reduceMotion ? 0.22 : 1
                dragOffset = value.translation.width * motionScale * (hasAdjacentDate ? 1 : 0.18)
            }
            .onEnded { value in
                defer { dragAxis = nil }
                guard canBeginSwipe,
                      dragAxis == .horizontal,
                      let direction = FixtureBrowseSelectionResolver.swipeDateOffset(
                        translationWidth: value.translation.width,
                        translationHeight: value.translation.height,
                        predictedEndTranslationWidth: value.predictedEndTranslation.width,
                        containerWidth: containerWidth
                      ),
                      let targetDateKey = direction > 0 ? nextDateKey : previousDateKey else {
                    cancelSwipe()
                    return
                }
                completeSwipe(to: targetDateKey, direction: direction)
            }
    }

    private func cancelSwipe() {
        withAnimation(.easeOut(duration: reduceMotion ? 0.08 : 0.16)) {
            dragOffset = 0
        }
    }

    private func completeSwipe(to targetDateKey: String, direction: Int) {
        UISelectionFeedbackGenerator().selectionChanged()
        guard !reduceMotion else {
            dragOffset = 0
            onSelect(targetDateKey)
            return
        }

        let destinationOffset = direction > 0 ? -containerWidth : containerWidth
        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.2)) {
            dragOffset = destinationOffset
        }

        transitionTask?.cancel()
        transitionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                onSelect(targetDateKey)
                dragOffset = 0
            }
            await Task.yield()
            transitionTask = nil
        }
    }

    private func resetTransition() {
        transitionTask?.cancel()
        transitionTask = nil
        dragAxis = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dragOffset = 0
        }
    }
}

private struct FixtureDateCarouselTile: View {
    let dateKey: String
    let matchCount: Int
    let isSelected: Bool

    private var date: Date? {
        Self.inputFormatter.date(from: dateKey)
    }

    private var accessibilityDate: String {
        date.map { Self.accessibilityFormatter.string(from: $0) } ?? dateKey
    }

    private var isToday: Bool {
        date.map { Calendar.autoupdatingCurrent.isDateInToday($0) } ?? false
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(isToday ? "Today" : (date.map { Self.weekdayFormatter.string(from: $0) } ?? "–"))
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
            Text(date.map { Self.dayFormatter.string(from: $0) } ?? dateKey)
                .font(.subheadline.weight(isSelected ? .semibold : .medium))
                .monospacedDigit()
        }
        .foregroundStyle(isSelected || isToday ? Color.accentColor : Color.secondary)
        .frame(width: 76, height: 50)
        .background {
            if isToday {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(isSelected ? 0.18 : 0.1))
            }
        }
        .overlay {
            if isToday {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.accentColor.opacity(isSelected ? 0.8 : 0.5), lineWidth: 1)
            }
        }
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(isSelected ? Color.accentColor : Color.clear)
                .frame(width: 46, height: 3)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDate)
        .accessibilityValue(
            "\(matchCount) \(matchCount == 1 ? "match" : "matches")" +
            (isToday ? ", today" : "") +
            (isSelected ? ", selected" : "")
        )
    }

    private static let inputFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = "EEE"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    private static let accessibilityFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateStyle = .full
        return formatter
    }()
}

private struct MatchesListRowLabel: View, Equatable {
    let match: Match
    let isFixtureMode: Bool
    let rowPreferences: MatchRowPreferences
    let fantasyContext: FantasyMatchRowContext
    let predictionDisplay: FixturePredictionDisplayState

    var body: some View {
        MatchRow(
            match: match,
            showLeague: false,
            showFantasyBadge: isFixtureMode,
            showFantasyPlayerContributions: isFixtureMode,
            teamLogoScale: 1.518,
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
