import Combine
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

enum CompetitionAccentRole: Equatable, Sendable {
    case premierLeague
    case laLiga
    case bundesliga
    case serieA
    case championsLeague
    case europaLeague
    case conferenceLeague
    case standard

    static func resolve(competitionID: String?, competitionName: String) -> CompetitionAccentRole {
        let key = [competitionID, competitionName]
            .compactMap { $0 }
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .filter(\.isLetter)

        if key.contains("premierleague") { return .premierLeague }
        if key.contains("laliga") || key.contains("spanishleague") { return .laLiga }
        if key.contains("bundesliga") { return .bundesliga }
        if key.contains("seriea") { return .serieA }
        if key.contains("championsleague") { return .championsLeague }
        if key.contains("europaleague") { return .europaLeague }
        if key.contains("conferenceleague") { return .conferenceLeague }
        return .standard
    }

    var color: Color {
        switch self {
        case .premierLeague:
            Color(red: 0.55, green: 0.38, blue: 0.94)
        case .laLiga, .bundesliga:
            Color(red: 0.91, green: 0.20, blue: 0.28)
        case .serieA:
            Color(red: 0.08, green: 0.57, blue: 0.93)
        case .championsLeague:
            Color(red: 0.24, green: 0.42, blue: 0.94)
        case .europaLeague:
            Color(red: 0.94, green: 0.43, blue: 0.12)
        case .conferenceLeague:
            Color(red: 0.25, green: 0.73, blue: 0.43)
        case .standard:
            Color.accentColor
        }
    }
}

struct FixtureCompetitionDockBoundsPreferenceKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?

    static func reduce(
        value: inout Anchor<CGRect>?,
        nextValue: () -> Anchor<CGRect>?
    ) {
        value = nextValue() ?? value
    }
}

@MainActor
final class FixturesViewCoordinator: ObservableObject {
    let browser = FixtureBrowserStore()

    @Published var expandedFixtureRegionID: String?
    @Published var fixturePickerDraftOptionIDs: Set<String>?
    @Published var fixturePickerBaselineOptionIDs: Set<String>?
    @Published var isFixtureFavouritesMenuExpanded = false
    @Published var isTeamPickerPresented = false
    @Published var teamPickerDraftTeamIDs: Set<String> = []
    @Published private(set) var isSaveFixtureViewPromptVisible = false
    @Published private(set) var isFixtureSaveRecoveryButtonVisible = false
    @Published var isDockEnabled = true
    @Published private(set) var isCompetitionDockExpanded = true
    @Published private(set) var isCompetitionDockIntroPending = false
    @Published private(set) var hasPresentedCompetitionDockIntro = false
    @Published private(set) var toastMessage: String?
    @Published private(set) var predictionWarmRequestToken = 0

    private var toastTask: Task<Void, Never>?
    private var competitionDockAutoCollapseTask: Task<Void, Never>?

    private static let competitionDockExpandAnimation = Animation.timingCurve(
        0.22,
        1,
        0.36,
        1,
        duration: 0.28
    )
    private static let competitionDockCollapseAnimation = Animation.timingCurve(
        0.22,
        1,
        0.36,
        1,
        duration: 0.38
    )

    var isDateSwipeEnabled: Bool {
        expandedFixtureRegionID == nil &&
        !isFixtureFavouritesMenuExpanded
    }

    var hasExpandedPanel: Bool {
        expandedFixtureRegionID != nil ||
        isFixtureFavouritesMenuExpanded
    }

    func resetPresentation() {
        competitionDockAutoCollapseTask?.cancel()
        competitionDockAutoCollapseTask = nil
        isCompetitionDockIntroPending = false
        isCompetitionDockExpanded = false
        expandedFixtureRegionID = nil
        fixturePickerDraftOptionIDs = nil
        fixturePickerBaselineOptionIDs = nil
        isFixtureFavouritesMenuExpanded = false
        isTeamPickerPresented = false
        clearSaveFixtureViewPresentation()
    }

    func prepareCompetitionDockForScoresEntry() {
        competitionDockAutoCollapseTask?.cancel()
        competitionDockAutoCollapseTask = nil

        guard !hasPresentedCompetitionDockIntro else {
            isCompetitionDockIntroPending = false
            isCompetitionDockExpanded = false
            return
        }

        hasPresentedCompetitionDockIntro = true
        isCompetitionDockIntroPending = true
        isCompetitionDockExpanded = true
    }

    func scheduleCompetitionDockAutoCollapse(
        reduceMotion: Bool,
        voiceOverRunning: Bool,
        delayNanoseconds: UInt64 = 1_750_000_000
    ) {
        guard isCompetitionDockIntroPending else { return }
        isCompetitionDockIntroPending = false
        competitionDockAutoCollapseTask?.cancel()

        guard !voiceOverRunning else { return }

        competitionDockAutoCollapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  self.isCompetitionDockExpanded,
                  !self.hasExpandedPanel,
                  !self.isTeamPickerPresented else {
                return
            }
            withAnimation(reduceMotion ? nil : Self.competitionDockCollapseAnimation) {
                self.isCompetitionDockExpanded = false
            }
            self.competitionDockAutoCollapseTask = nil
        }
    }

    func noteCompetitionDockInteraction() {
        isCompetitionDockIntroPending = false
        competitionDockAutoCollapseTask?.cancel()
        competitionDockAutoCollapseTask = nil
    }

    func expandCompetitionDock(reduceMotion: Bool) {
        noteCompetitionDockInteraction()
        withAnimation(reduceMotion ? nil : Self.competitionDockExpandAnimation) {
            isCompetitionDockExpanded = true
        }
    }

    func collapseCompetitionDock(reduceMotion: Bool) {
        noteCompetitionDockInteraction()
        fixturePickerDraftOptionIDs = nil
        fixturePickerBaselineOptionIDs = nil
        withAnimation(reduceMotion ? nil : Self.competitionDockCollapseAnimation) {
            expandedFixtureRegionID = nil
            isFixtureFavouritesMenuExpanded = false
            isCompetitionDockExpanded = false
        }
    }

    func presentSaveFixtureViewPrompt() {
        isFixtureSaveRecoveryButtonVisible = false
        isSaveFixtureViewPromptVisible = true
    }

    func dismissSaveFixtureViewPrompt() {
        isSaveFixtureViewPromptVisible = false
        isFixtureSaveRecoveryButtonVisible = true
    }

    func clearSaveFixtureViewPresentation() {
        isSaveFixtureViewPromptVisible = false
        isFixtureSaveRecoveryButtonVisible = false
    }

    func requestPredictionWarm() {
        predictionWarmRequestToken &+= 1
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        withAnimation {
            toastMessage = message
        }
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation {
                self?.toastMessage = nil
            }
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
    @ObservedObject private var fixturesCoordinator: FixturesViewCoordinator
    @ObservedObject private var fixtureBrowser: FixtureBrowserStore

    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var fantasyViewModel: FantasyViewModel
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppGroupConfig.fantasyManagerEntryIDKey) private var fantasyManagerEntryID = ""
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
    init(
        mode: MatchesViewMode,
        isSelected: Bool = true,
        store: MatchesStore,
        fixturesCoordinator: FixturesViewCoordinator
    ) {
        self.mode = mode
        self.isSelected = isSelected
        self.matchesStore = store
        self.viewState = store.viewState(for: mode)
        self.fixturesCoordinator = fixturesCoordinator
        self.fixtureBrowser = fixturesCoordinator.browser
    }

    private static let fixtureDockContentClearance: CGFloat = 80

    private struct CompactFixturesSpacingProfile {
        let dayHeaderTopFirst: CGFloat
        let dayHeaderTop: CGFloat
        let dayHeaderBottom: CGFloat
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
            ZStack(alignment: .top) {
                FootballVisualStyle.pageBackground
                    .ignoresSafeArea()

                FootballScreenBackdrop()

                VStack(spacing: 0) {
                    scoresHeroHeader

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
                .overlay(alignment: .top) {
                    if let toastMessage = fixturesCoordinator.toastMessage {
                        ToastView(message: toastMessage)
                            .padding(.top, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
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
            isSwipeEnabled: fixturesCoordinator.isDateSwipeEnabled,
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
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            fixturesCoordinator.isDockEnabled = navigationMatch == nil
            refreshVisibleGroupedDays(from: sourceGroupedDays)
            guard isSelected else { return }
            if mode == .fixtures {
                fixturesCoordinator.prepareCompetitionDockForScoresEntry()
            }
            runActivationIfNeeded(logEvent: "onAppear")
            beginScreenViewTiming()
        }
        .onChange(of: isSelected) { _, selected in
            matchesStore.setModeVisibility(mode, isVisible: selected)
            guard selected else {
                if mode == .fixtures {
                    fixtureBrowser.setAutoRefreshEnabled(false)
                    matchesStore.setFixtureBrowserLiveRefreshActive(false)
                    fixturesCoordinator.resetPresentation()
                }
                didRunActivationForVisibleCycle = false
                screenOpenedAt = nil
                screenViewSentForActivation = false
                return
            }
            if mode == .fixtures {
                fixturesCoordinator.prepareCompetitionDockForScoresEntry()
            }
            refreshVisibleGroupedDays(from: sourceGroupedDays)
            runActivationIfNeeded(logEvent: "isSelected")
            beginScreenViewTiming()
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhaseChange(phase)
        }
        .onChange(of: navigationMatch) { _, match in
            fixturesCoordinator.isDockEnabled = match == nil
            if match != nil {
                fixturesCoordinator.resetPresentation()
            }
        }
        .onChange(of: fixturesCoordinator.predictionWarmRequestToken) { _, _ in
            guard mode == .fixtures else { return }
            warmPredictionsForVisibleDays(days: sourceGroupedDays)
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
            fixturesCoordinator.showToast(
                newValue ? "Viewing all matches (unfiltered)" : "Viewing preferred matches only"
            )
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

    private var scoresHeaderTitle: String {
        guard mode == .fixtures else { return "Results" }
        guard let selectedDateKey = fixtureBrowser.selectedDateKey else {
            return "Fixtures"
        }
        let matches = fixtureBrowser.cachedMatchesByDate[selectedDateKey] ?? []
        return Self.navigationTitlePrefix(for: matches)
    }

    private var scoresHeaderSubtitle: String? {
        guard mode == .fixtures else { return nil }
        guard let selectedDateKey = fixtureBrowser.selectedDateKey else { return nil }
        return Self.friendlyFixtureDateLabel(selectedDateKey)
    }

    private var scoresHeroHeader: some View {
        FootballHeroHeader(title: scoresHeaderTitle, subtitle: scoresHeaderSubtitle)
        .animation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.18), value: fixtureBrowser.selectedDateKey)
        .overlay(alignment: .topTrailing) {
            if mode == .fixtures {
                fixtureHeaderActions
                    .padding(.trailing, 14)
            }
        }
    }

    private var fixtureHeaderActions: some View {
        HStack(spacing: 8) {
            if fixturesCoordinator.isFixtureSaveRecoveryButtonVisible {
                Button(action: restoreFixtureSavePrompt) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(0.20), in: Circle())
                        .overlay {
                            Circle()
                                .stroke(Color.accentColor.opacity(0.88), lineWidth: 1)
                        }
                        .shadow(color: Color.accentColor.opacity(0.42), radius: 9)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Save current Match View")
                .accessibilityHint("Shows the save favourites prompt again")
                .transition(fixtureRecoveryButtonTransition)
            }

            Button(action: togglePredictedScores) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(
                        preferences.showPredictedScores
                            ? Color.primary
                            : FootballVisualStyle.predictionAccent
                    )
                    .frame(width: 44, height: 44)
                    .background(
                        FootballVisualStyle.predictionAccent.opacity(
                            preferences.showPredictedScores ? 0.24 : 0.08
                        ),
                        in: Circle()
                    )
                    .overlay {
                        Circle()
                            .stroke(
                                FootballVisualStyle.predictionAccent.opacity(
                                    preferences.showPredictedScores ? 0.90 : 0.36
                                ),
                                lineWidth: 1
                            )
                    }
                    .shadow(
                        color: preferences.showPredictedScores
                            ? FootballVisualStyle.predictionAccent.opacity(0.28)
                            : .clear,
                        radius: 8
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Predicted scores")
            .accessibilityValue(preferences.showPredictedScores ? "On" : "Off")
            .accessibilityHint("Toggles AI score predictions")
        }
    }

    private var fixtureRecoveryButtonTransition: AnyTransition {
        accessibilityReduceMotion
            ? .opacity
            : .scale(scale: 0.74).combined(with: .opacity)
    }

    private func togglePredictedScores() {
        preferences.showPredictedScores.toggle()
        if preferences.showPredictedScores {
            fixturesCoordinator.requestPredictionWarm()
        }
        fixturesCoordinator.showToast(
            preferences.showPredictedScores
                ? "Showing predicted scores"
                : "Hiding predicted scores"
        )
        reconcileFixtureSavePrompt()
    }

    private func restoreFixtureSavePrompt() {
        let animation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.28)
        withAnimation(accessibilityReduceMotion ? nil : animation) {
            fixturesCoordinator.presentSaveFixtureViewPrompt()
        }
    }

    private func reconcileFixtureSavePrompt() {
        let animation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.32)
        withAnimation(accessibilityReduceMotion ? nil : animation) {
            if preferences.hasUnsavedFixtureViewChanges {
                fixturesCoordinator.presentSaveFixtureViewPrompt()
            } else {
                fixturesCoordinator.clearSaveFixtureViewPresentation()
            }
        }
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
        fixturesCoordinator.resetPresentation()
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
        .background(Color.clear)
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
        .background(FootballVisualStyle.pageBackground.opacity(0.92))
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
            competitionCardRow(for: league, day: day)
        }
    }

    private func shouldShowKickoffDivider(currentTime: String, previousTime: String?) -> Bool {
        mode == .fixtures &&
        preferences.showKickoffTimeDividers &&
        previousTime != nil &&
        previousTime != currentTime
    }

    private func embeddedKickoffDivider(time: String) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(FootballVisualStyle.divider)
            Text(time)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(FootballVisualStyle.mutedText.opacity(0.72))
                .monospacedDigit()
                .fixedSize()
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(FootballVisualStyle.divider)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private func competitionCardRow(for league: MatchLeague, day: MatchDay) -> some View {
        let competitionName = league.matches.first?.league ?? league.league
        let competitionSubtitle = league.matches.first?.leagueSubcategory?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let accentRole = CompetitionAccentRole.resolve(
            competitionID: league.matches.first?.leagueId,
            competitionName: competitionName
        )
        let accentColor = accentRole.color

        return VStack(spacing: 0) {
            HStack(spacing: 11) {
                LeagueBadgeImage(
                    competitionID: league.matches.first?.leagueId,
                    competitionName: competitionName,
                    size: 29
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(competitionName.uppercased())
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.white.opacity(0.94))

                    if let competitionSubtitle, !competitionSubtitle.isEmpty {
                        Text(competitionSubtitle.uppercased())
                            .font(.caption2.weight(.semibold))
                            .tracking(0.35)
                            .foregroundStyle(FootballVisualStyle.mutedText.opacity(0.80))
                    }
                }
                .lineLimit(2)

                Spacer(minLength: 8)

                Circle()
                    .fill(accentColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: accentColor.opacity(0.55), radius: 5)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Rectangle()
                .fill(FootballVisualStyle.divider)
                .frame(height: 0.5)
                .padding(.horizontal, 16)

            ForEach(Array(league.matches.enumerated()), id: \.element.id) { index, match in
                let previousTime = index > 0 ? league.matches[index - 1].time : nil
                if shouldShowKickoffDivider(currentTime: match.time, previousTime: previousTime) {
                    embeddedKickoffDivider(time: match.time)
                }

                matchButton(for: match, day: day)
                    .padding(.horizontal, 8)

                if index < league.matches.count - 1 {
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
        .clipShape(RoundedRectangle(cornerRadius: FootballVisualStyle.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FootballVisualStyle.cardCornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [accentColor.opacity(0.32), FootballVisualStyle.border, FootballVisualStyle.border],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.6
                )
        }
        .shadow(color: .black.opacity(0.24), radius: 16, y: 9)
        .modifier(CompetitionCardEntrance())
        .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func matchButton(for match: Match, day: MatchDay) -> some View {
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

    private var fixtureDateCarouselHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 74 : 62
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
                .frame(height: fixtureDateCarouselHeight)
                .padding(.horizontal, 16)
            } else {
                let jumpDirection = fixtureBrowser.nextMatchDateJumpDirection
                ZStack {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 10) {
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
                        .frame(height: fixtureDateCarouselHeight)
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
                .frame(height: fixtureDateCarouselHeight)
            }
        }
        .background(Color.clear)
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [.clear, FootballVisualStyle.divider, .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 0.5)
            .padding(.horizontal, 18)
        }
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
            .background {
                FixtureGlassSurface(cornerRadius: 12)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.66), lineWidth: 1)
            }
            .shadow(color: Color.accentColor.opacity(0.16), radius: 7)
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
}

struct FixtureCompetitionDockView: View {
    enum Content: String {
        case rail
        case panel
        case teamPicker
    }

    @ObservedObject private var coordinator: FixturesViewCoordinator
    @ObservedObject private var fixtureBrowser: FixtureBrowserStore
    @EnvironmentObject private var preferences: PreferencesStore
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let content: Content

    init(coordinator: FixturesViewCoordinator, content: Content = .rail) {
        self.coordinator = coordinator
        self.fixtureBrowser = coordinator.browser
        self.content = content
    }

    @ViewBuilder
    var body: some View {
        Group {
            switch content {
            case .rail:
                fixtureCompetitionAccessory
            case .panel:
                fixtureCompetitionOverlayPanel
            case .teamPicker:
                NavigationStack {
                    TeamSelectionView(
                        apiBaseURL: preferences.apiBaseURL,
                        selectedTeamIDs: $coordinator.teamPickerDraftTeamIDs,
                        onCancel: { coordinator.isTeamPickerPresented = false },
                        onDone: commitTeamPicker
                    )
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .environment(\.colorScheme, .dark)
        .task(id: competitionDockIntroTaskID) {
            guard content == .rail,
                  coordinator.isCompetitionDockIntroPending else {
                return
            }
            if !competitionDockContentIsReady {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
            }
            coordinator.scheduleCompetitionDockAutoCollapse(
                reduceMotion: accessibilityReduceMotion,
                voiceOverRunning: UIAccessibility.isVoiceOverRunning
            )
        }
    }

    private var competitionDockContentIsReady: Bool {
        !fixtureBrowser.competitions.isEmpty || fixtureBrowser.errorMessage != nil
    }

    private var competitionDockIntroTaskID: String {
        "\(content.rawValue)-\(coordinator.isCompetitionDockIntroPending)-\(competitionDockContentIsReady)"
    }

    private var fixtureCompetitionAccessory: some View {
        VStack(spacing: 0) {
            fixtureCompetitionDock
                .anchorPreference(
                    key: FixtureCompetitionDockBoundsPreferenceKey.self,
                    value: .bounds
                ) { bounds in
                    bounds
                }

            if coordinator.isSaveFixtureViewPromptVisible {
                fixtureSaveFavouritesPrompt
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(fixtureSavePromptTransition)
            }
        }
    }

    private var expandedFixtureRegionID: String? {
        get { coordinator.expandedFixtureRegionID }
        nonmutating set { coordinator.expandedFixtureRegionID = newValue }
    }

    private var fixturePickerDraftOptionIDs: Set<String>? {
        get { coordinator.fixturePickerDraftOptionIDs }
        nonmutating set { coordinator.fixturePickerDraftOptionIDs = newValue }
    }

    private var fixturePickerBaselineOptionIDs: Set<String>? {
        get { coordinator.fixturePickerBaselineOptionIDs }
        nonmutating set { coordinator.fixturePickerBaselineOptionIDs = newValue }
    }

    private var isFixtureFavouritesMenuExpanded: Bool {
        get { coordinator.isFixtureFavouritesMenuExpanded }
        nonmutating set { coordinator.isFixtureFavouritesMenuExpanded = newValue }
    }

    private var isTeamPickerPresented: Bool {
        get { coordinator.isTeamPickerPresented }
        nonmutating set { coordinator.isTeamPickerPresented = newValue }
    }

    private var teamPickerDraftTeamIDs: Set<String> {
        get { coordinator.teamPickerDraftTeamIDs }
        nonmutating set { coordinator.teamPickerDraftTeamIDs = newValue }
    }

    private var fixtureCompetitionDock: some View {
        ZStack(alignment: .leading) {
            if coordinator.isCompetitionDockExpanded {
                fixtureCompetitionRail
                    .transition(expandedCompetitionDockTransition)
                    .accessibilityIdentifier("fixtureCompetitionDockExpanded")
            } else {
                collapsedFixtureCompetitionDock
                    .transition(collapsedCompetitionDockTransition)
                    .accessibilityIdentifier("fixtureCompetitionDockCollapsed")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .animation(accessibilityReduceMotion ? nil : FootballVisualStyle.easeOut, value: expandedFixtureRegionID)
        .animation(accessibilityReduceMotion ? nil : FootballVisualStyle.easeOut, value: isFixtureFavouritesMenuExpanded)
        .zIndex(20)
    }

    private var expandedCompetitionDockTransition: AnyTransition {
        guard !accessibilityReduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .offset(x: -28).combined(with: .opacity),
            removal: .offset(x: -72).combined(with: .opacity)
        )
    }

    private var collapsedCompetitionDockTransition: AnyTransition {
        guard !accessibilityReduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .offset(x: -16).combined(with: .opacity),
            removal: .opacity
        )
    }

    private var collapsedFixtureCompetitionDock: some View {
        Button {
            coordinator.expandCompetitionDock(reduceMotion: accessibilityReduceMotion)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "globe")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .opacity(0.5)

                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.secondary)
                    .opacity(0.5)
            }
            .padding(.horizontal, 17)
            .frame(height: 58)
            .background {
                FixtureGlassSurface(cornerRadius: 29)
                    .opacity(0.5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 29, style: .continuous)
                    .stroke(Color(.separator).opacity(0.62), lineWidth: 0.5)
                    .opacity(0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 29, style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(
            .interaction,
            RoundedRectangle(cornerRadius: 29, style: .continuous)
        )
        .accessibilityLabel("Competition filters")
        .accessibilityValue(fixtureViewOptionsAccessibilityValue)
        .accessibilityHint("Expands country and competition filters")
    }

    @ViewBuilder
    private var fixtureCompetitionOverlayPanel: some View {
        if isFixtureFavouritesMenuExpanded {
            fixtureFavouritesPanel
                .transition(fixturePanelTransition)
        } else if let region = expandedFixtureRegion {
            fixtureCompetitionPanel(for: region)
                .transition(fixturePanelTransition)
        }
    }

    private var fixturePanelTransition: AnyTransition {
        accessibilityReduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    private var fixtureSavePromptTransition: AnyTransition {
        guard !accessibilityReduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        )
    }

    private var fixtureSaveFavouritesPrompt: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    fixtureSaveFavouritesPromptLabel
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        dismissFixtureSavePromptButton
                        saveFixtureViewButton
                    }
                }
            } else {
                HStack(spacing: 12) {
                    fixtureSaveFavouritesPromptLabel
                    Spacer(minLength: 4)
                    dismissFixtureSavePromptButton
                    saveFixtureViewButton
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 720)
        .background {
            FixtureGlassSurface(cornerRadius: 18)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(.separator).opacity(0.62), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.24), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
    }

    private var fixtureSaveFavouritesPromptLabel: some View {
        HStack(spacing: 11) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Save current view as favourites?")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Use this selection as your default match view.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dismissFixtureSavePromptButton: some View {
        Button(action: dismissFixtureSavePrompt) {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Color(.tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Keep existing favourites")
        .accessibilityHint("Dismisses without changing your saved match view")
    }

    private var saveFixtureViewButton: some View {
        Button(action: saveCurrentFixtureViewAsFavourites) {
            Image(systemName: "checkmark")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.primary)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.18), in: Circle())
                .overlay {
                    Circle()
                        .stroke(Color.accentColor.opacity(0.82), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Save as favourites")
        .accessibilityHint("Replaces your saved match view with this selection")
    }

    private var fixtureCompetitionRail: some View {
        HStack(spacing: 6) {
            Button {
                coordinator.noteCompetitionDockInteraction()
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
                    showsFantasyPremierLeagueIcon: isPremierLeagueMatchesPresetSelected,
                    usesPrimaryIconColor: true,
                    showsSelectionChrome: false
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Match filters")
            .accessibilityValue(fixtureViewOptionsAccessibilityValue)
            .accessibilityHint("Choose which matches to show")

            fixtureDockSeparator

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

                        fixtureDockSeparator

                        Button(action: presentTeamPicker) {
                            FixtureRegionDockButton(
                                systemSymbol: "shield.fill",
                                regionID: nil,
                                isSelected: selectedFixtureTeamIDs.count > 0,
                                isExpanded: isTeamPickerPresented,
                                systemSymbolSize: 30,
                                systemSymbolTint: Color(red: 0.18, green: 0.55, blue: 0.88),
                                showsPersistentBorder: true
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Teams")
                        .accessibilityValue(
                            selectedFixtureTeamIDs.isEmpty
                                ? "No teams selected"
                                : "\(selectedFixtureTeamIDs.count) teams selected"
                        )
                        .accessibilityHint("Choose individual teams to include")
                    }
                }
                .scrollIndicators(.hidden)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { _ in
                            coordinator.noteCompetitionDockInteraction()
                        }
                )
            }

            fixtureDockSeparator

            Button {
                coordinator.collapseCompetitionDock(reduceMotion: accessibilityReduceMotion)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Collapse competition filters")
            .accessibilityHint("Condenses the competition carousel")
        }
        .padding(6)
        .frame(height: 58)
        .background {
            FixtureGlassSurface(cornerRadius: 29)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 29, style: .continuous)
                .stroke(Color(.separator).opacity(0.62), lineWidth: 0.5)
        }
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
                    Text("Match filters")
                        .font(.headline)
                    Text("Choose which matches to show")
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
                .accessibilityLabel("Close match filters")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            fixtureFavouritesActionRow(
                title: "Show favourites",
                subtitle: "Use your saved match view",
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
        }
        .frame(maxWidth: 420)
        .background {
            FixtureGlassSurface(cornerRadius: 22)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(.separator).opacity(0.55), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
    }

    private var fixtureDockSeparator: some View {
        Rectangle()
            .fill(Color(.separator).opacity(0.7))
            .frame(width: 0.5, height: 28)
            .padding(.horizontal, 2)
            .accessibilityHidden(true)
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
        .background {
            FixtureGlassSurface(cornerRadius: 22)
        }
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

    private func dismissFixtureSavePrompt() {
        let animation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.22)
        withAnimation(accessibilityReduceMotion ? nil : animation) {
            coordinator.dismissSaveFixtureViewPrompt()
        }
    }

    private func updateFixtureSavePrompt() {
        let animation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.32)
        withAnimation(accessibilityReduceMotion ? nil : animation) {
            if preferences.hasUnsavedFixtureViewChanges {
                coordinator.presentSaveFixtureViewPrompt()
            } else {
                coordinator.clearSaveFixtureViewPresentation()
            }
        }
    }

    private func toggleFixtureCompetitionPicker(for regionID: String) {
        coordinator.noteCompetitionDockInteraction()
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

    private var selectedFixtureTeamIDs: Set<String> {
        Set(effectiveFixtureViewOptionIDs.compactMap(FixtureViewOptionID.teamStableID))
    }

    private func presentTeamPicker() {
        coordinator.noteCompetitionDockInteraction()
        teamPickerDraftTeamIDs = selectedFixtureTeamIDs
        withAnimation(.easeOut(duration: 0.2)) {
            expandedFixtureRegionID = nil
            isFixtureFavouritesMenuExpanded = false
        }
        isTeamPickerPresented = true
    }

    private func commitTeamPicker() {
        let initialOptionIDs = fixturePickerInitialOptionIDs
        let updatedOptionIDs = FixtureViewOptionID.replacingTeams(
            in: initialOptionIDs,
            with: teamPickerDraftTeamIDs
        )
        isTeamPickerPresented = false
        guard updatedOptionIDs != initialOptionIDs else { return }
        guard !updatedOptionIDs.isEmpty else {
            selectFavourites()
            return
        }
        applyCustomFixtureView(updatedOptionIDs)
        AppMetricsService.shared.fireActivity(
            "fixture_teams_changed",
            screen: MatchesViewMode.fixtures.rawValue,
            apiBaseURL: preferences.apiBaseURL
        )
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
            screen: MatchesViewMode.fixtures.rawValue,
            apiBaseURL: preferences.apiBaseURL
        )
    }

    private func selectFavourites() {
        fixturePickerDraftOptionIDs = nil
        fixturePickerBaselineOptionIDs = nil
        withAnimation(accessibilityReduceMotion ? nil : FootballVisualStyle.easeOut) {
            coordinator.clearSaveFixtureViewPresentation()
        }
        withAnimation(.easeOut(duration: 0.2)) {
            expandedFixtureRegionID = nil
            isFixtureFavouritesMenuExpanded = false
        }
        activateFavouriteFixtureView()
        AppMetricsService.shared.fireActivity(
            "fixture_competition_favourites",
            screen: MatchesViewMode.fixtures.rawValue,
            apiBaseURL: preferences.apiBaseURL
        )
    }

    private func activateFavouriteFixtureView() {
        preferences.fixtureAllMajorMatchesEnabled = true
        preferences.competitionFilterEnabled = false
        preferences.englishPremierLeagueTeamsOnly = true
        preferences.majorUEFAClubGamesEnabled = true
        preferences.homeNationsFilterEnabled = true
        preferences.majorTournamentsFilterEnabled = true
        preferences.showAllMatches = false
        preferences.showPredictedScores = preferences.favouriteShowPredictedScores
        if preferences.showPredictedScores {
            coordinator.requestPredictionWarm()
        }
        fixtureBrowser.configure(
            preferences: preferences.snapshot,
            resetSelectedDate: true
        )
    }

    private func selectAllFixtureCompetitions() {
        let hasChanges = !preferences.showAllMatches
        fixturePickerDraftOptionIDs = nil
        fixturePickerBaselineOptionIDs = nil
        withAnimation(.easeOut(duration: 0.2)) {
            expandedFixtureRegionID = nil
            isFixtureFavouritesMenuExpanded = false
        }
        guard hasChanges else { return }
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
        updateFixtureSavePrompt()
        AppMetricsService.shared.fireActivity(
            "fixture_competition_all",
            screen: MatchesViewMode.fixtures.rawValue,
            apiBaseURL: preferences.apiBaseURL
        )
    }

    private func saveCurrentFixtureViewAsFavourites() {
        let optionIDs = preferences.currentFixtureViewOptionIDs.sorted()
        guard !optionIDs.isEmpty else { return }
        preferences.favouriteFixtureViewOptionIDs = optionIDs
        preferences.favouriteShowPredictedScores = preferences.showPredictedScores
        activateFavouriteFixtureView()
        withAnimation(accessibilityReduceMotion ? nil : FootballVisualStyle.easeOut) {
            coordinator.clearSaveFixtureViewPresentation()
        }
        withAnimation(.easeOut(duration: 0.2)) {
            isFixtureFavouritesMenuExpanded = false
        }
        coordinator.showToast("Current view saved as favourites")
        AppMetricsService.shared.fireActivity(
            "fixture_competition_favourites_saved",
            screen: MatchesViewMode.fixtures.rawValue,
            apiBaseURL: preferences.apiBaseURL
        )
    }

    private func selectPremierLeagueMatches() {
        let hasChanges = !isPremierLeagueMatchesPresetSelected
        fixturePickerDraftOptionIDs = nil
        fixturePickerBaselineOptionIDs = nil
        withAnimation(.easeOut(duration: 0.2)) {
            expandedFixtureRegionID = nil
            isFixtureFavouritesMenuExpanded = false
        }
        guard hasChanges else { return }
        applyCustomFixtureView(FixtureViewOptionID.premierLeagueMatchesPresetOptionIDs)
        AppMetricsService.shared.fireActivity(
            "fixture_premier_league_matches_preset",
            screen: MatchesViewMode.fixtures.rawValue,
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
        updateFixtureSavePrompt()
    }
}

private extension MatchesView {

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
    var usesPrimaryIconColor = false
    var showsSelectionChrome = true
    var systemSymbolSize: CGFloat = 22
    var systemSymbolTint: Color?
    var showsPersistentBorder = false
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    showsSelectionChrome
                        ? isExpanded
                            ? Color.accentColor.opacity(0.18)
                            : isSelected
                                ? Color.accentColor.opacity(0.08)
                                : Color.clear
                        : Color.clear
                )

            if showsFantasyPremierLeagueIcon {
                FantasyLionIconView(size: 24)
                    .foregroundStyle(
                        usesPrimaryIconColor
                            ? Color.primary
                            : isSelected ? Color.accentColor : Color.primary
                    )
            } else if let systemSymbol {
                Image(systemName: systemSymbol)
                    .font(.system(size: systemSymbolSize, weight: .semibold))
                    .foregroundStyle(
                        usesPrimaryIconColor
                            ? Color.primary
                            : isSelected ? Color.accentColor : systemSymbolTint ?? Color.primary
                    )
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
            if showsSelectionChrome && (systemSymbol != nil || showsFantasyPremierLeagueIcon) {
                Circle()
                    .stroke(
                        isExpanded
                            ? Color.accentColor.opacity(0.88)
                            : isSelected
                                ? Color.accentColor.opacity(0.34)
                                : showsPersistentBorder
                                    ? (systemSymbolTint ?? Color.accentColor).opacity(0.82)
                                    : Color.clear,
                        lineWidth: isExpanded ? 1.5 : showsPersistentBorder ? 1 : 0.8
                    )
            }
        }
        .shadow(
            color: showsSelectionChrome && isExpanded ? Color.accentColor.opacity(0.30) : .clear,
            radius: 8
        )
        .animation(accessibilityReduceMotion ? nil : FootballVisualStyle.easeOut, value: isExpanded)
        .animation(accessibilityReduceMotion ? nil : FootballVisualStyle.easeOut, value: isSelected)
        .contentShape(Circle())
    }
}

private struct FixtureGlassSurface: View {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency

    var body: some View {
        ZStack {
            if accessibilityReduceTransparency {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(FootballVisualStyle.elevatedSurface)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(FootballVisualStyle.elevatedSurface.opacity(0.68))
            }

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.045), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
        }
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

private struct LeagueBadgeImage: View {
    let competitionID: String?
    let competitionName: String
    let size: CGFloat
    @State private var badgeCacheVersion = 0

    var body: some View {
        let _ = badgeCacheVersion
        Group {
            if let image = CompetitionBadgeCache.shared.image(
                competitionID: competitionID,
                competitionName: competitionName
            ) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: competitionName.localizedCaseInsensitiveContains("cup") ? "trophy.fill" : "soccerball")
                    .font(.system(size: size * 0.68, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.82))
            }
        }
        .frame(width: size, height: size)
        .onReceive(NotificationCenter.default.publisher(for: CompetitionBadgeCache.badgesUpdatedNotification)) { _ in
            badgeCacheVersion &+= 1
        }
        .accessibilityHidden(true)
    }
}

private struct CompetitionCardEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var hasAppeared = false

    func body(content: Content) -> some View {
        content
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared || accessibilityReduceMotion ? 0 : 10)
            .onAppear {
                guard !hasAppeared else { return }
                if accessibilityReduceMotion {
                    hasAppeared = true
                } else {
                    withAnimation(FootballVisualStyle.easeOut) {
                        hasAppeared = true
                    }
                }
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
        .background(FootballVisualStyle.pageBackground)
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
        VStack(spacing: 4) {
            Text(isToday ? "Today" : (date.map { Self.weekdayFormatter.string(from: $0) } ?? "–"))
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
            Text(date.map { Self.dayFormatter.string(from: $0) } ?? dateKey)
                .font(
                    (dynamicTypeSize.isAccessibilitySize ? Font.caption : .subheadline)
                        .weight(isSelected ? .bold : .medium)
                )
                .monospacedDigit()
        }
        .foregroundStyle(
            isSelected
                ? Color.white.opacity(0.96)
                : isToday
                    ? Color.accentColor.opacity(0.84)
                    : FootballVisualStyle.mutedText.opacity(0.78)
        )
        .frame(
            width: dynamicTypeSize.isAccessibilitySize ? 132 : 78,
            height: dynamicTypeSize.isAccessibilitySize ? 72 : 54
        )
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(isSelected ? Color.accentColor : Color.clear)
                .frame(width: 44, height: 3)
                .shadow(color: isSelected ? Color.accentColor.opacity(0.70) : .clear, radius: 5)
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
            presentationStyle: .embedded,
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
    let fixturesCoordinator = FixturesViewCoordinator()
    return MatchesView(
        mode: .fixtures,
        store: store,
        fixturesCoordinator: fixturesCoordinator
    )
        .environmentObject(PreferencesStore())
        .environmentObject(store)
        .environmentObject(FantasyViewModel())
}
