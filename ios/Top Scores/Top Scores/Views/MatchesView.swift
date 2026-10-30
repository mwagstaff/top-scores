import Combine
import Observation
import os
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

    var loadingSubtitle: String {
        switch self {
        case .fixtures:
            return "Preparing matches for this date."
        case .results:
            return "Fetching the latest results."
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

    var emptyStateSystemImage: String {
        switch self {
        case .fixtures:
            return "calendar"
        case .results:
            return "tv"
        }
    }

    var emptyStateSubtitle: String {
        switch self {
        case .fixtures:
            return "There are no matching fixtures for this date."
        case .results:
            return "There are no results to show yet."
        }
    }

}

enum FixtureBrowsePageContentState: Equatable, Sendable {
    case loading
    case empty
    case fixtures

    static func resolve(groupedDayCount: Int?) -> Self {
        guard let groupedDayCount else { return .loading }
        return groupedDayCount == 0 ? .empty : .fixtures
    }
}

private struct FixtureMatchesLoadingPlaceholder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHighlighted = false

    var body: some View {
        VStack(spacing: 14) {
            FixtureLoadingLozenge(height: 176, rowCount: 2)
            FixtureLoadingLozenge(height: 226, rowCount: 3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 7)
        .opacity(reduceMotion ? 0.72 : (isHighlighted ? 0.88 : 0.50))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .onAppear {
            updateAnimation()
        }
        .onChange(of: reduceMotion) { _, _ in
            updateAnimation()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading fixtures for this date")
    }

    private func updateAnimation() {
        isHighlighted = false
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
            isHighlighted = true
        }
    }
}

private struct FixtureLoadingLozenge: View {
    let height: CGFloat
    let rowCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Circle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 29, height: 29)
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: 138, height: 13)
                Spacer()
                Circle()
                    .fill(Color.accentColor.opacity(0.42))
                    .frame(width: 6, height: 6)
            }
            .padding(.bottom, 14)

            ForEach(0..<rowCount, id: \.self) { index in
                Rectangle()
                    .fill(FootballVisualStyle.divider)
                    .frame(height: 1)

                HStack(spacing: 12) {
                    Circle()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 8) {
                        Capsule()
                            .fill(Color.white.opacity(0.13))
                            .frame(maxWidth: index.isMultiple(of: 2) ? 190 : 152)
                            .frame(height: 11)
                        Capsule()
                            .fill(Color.accentColor.opacity(0.16))
                            .frame(maxWidth: 220)
                            .frame(height: 9)
                    }
                    Spacer(minLength: 6)
                    Circle()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 34, height: 34)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(height: height)
        .background {
            FootballCardSurface(
                accentColor: Color.accentColor,
                accentOpacity: 0.06
            )
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
            .stroke(FootballVisualStyle.border, lineWidth: 1)
        }
        .accessibilityHidden(true)
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
            FootballSectionAccent.fantasy
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

@MainActor
final class FixturesViewCoordinator: ObservableObject {
    let browser = FixtureBrowserStore()

    @Published var expandedFixtureRegionID: String?
    @Published var fixturePickerDraftOptionIDs: Set<String>?
    @Published var fixturePickerBaselineOptionIDs: Set<String>?
    @Published var isFixtureFavouritesMenuExpanded = false
    @Published var isCustomOptionsPresented = false
    @Published var isTeamPickerPresented = false
    @Published var teamPickerDraftTeamIDs: Set<String> = []
    @Published private(set) var isSaveFixtureViewPromptVisible = false
    @Published private(set) var isCompetitionDockExpanded = false
    @Published private(set) var toastMessage: String?

    private var toastTask: Task<Void, Never>?
    private var dateSwipeNavigationReleaseTask: Task<Void, Never>?
    private var isDateSwipeSuppressingMatchNavigation = false

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
        !isFixtureFavouritesMenuExpanded && !isCustomOptionsPresented
    }

    var hasExpandedPanel: Bool {
        expandedFixtureRegionID != nil ||
        isFixtureFavouritesMenuExpanded || isCustomOptionsPresented
    }

    var allowsMatchNavigation: Bool {
        !isDateSwipeSuppressingMatchNavigation
    }

    func waitUntilDateSwipeFinishes() async -> Bool {
        while isDateSwipeSuppressingMatchNavigation {
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return !Task.isCancelled
    }

    func resetPresentation() {
        isCustomOptionsPresented = false
        isCompetitionDockExpanded = false
        expandedFixtureRegionID = nil
        fixturePickerDraftOptionIDs = nil
        fixturePickerBaselineOptionIDs = nil
        isFixtureFavouritesMenuExpanded = false
        isTeamPickerPresented = false
        clearDateSwipeInteraction()
        clearSaveFixtureViewPresentation()
    }

    func beginDateSwipeInteraction(failSafeNanoseconds: UInt64 = 10_000_000_000) {
        dateSwipeNavigationReleaseTask?.cancel()
        isDateSwipeSuppressingMatchNavigation = true
        dateSwipeNavigationReleaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: failSafeNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.isDateSwipeSuppressingMatchNavigation = false
            self.dateSwipeNavigationReleaseTask = nil
        }
    }

    func endDateSwipeInteraction(delayNanoseconds: UInt64 = 75_000_000) {
        guard isDateSwipeSuppressingMatchNavigation else { return }
        dateSwipeNavigationReleaseTask?.cancel()
        dateSwipeNavigationReleaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.isDateSwipeSuppressingMatchNavigation = false
            self.dateSwipeNavigationReleaseTask = nil
        }
    }

    private func clearDateSwipeInteraction() {
        dateSwipeNavigationReleaseTask?.cancel()
        dateSwipeNavigationReleaseTask = nil
        isDateSwipeSuppressingMatchNavigation = false
    }

    func toggleMatchFilters(reduceMotion: Bool) {
        isCustomOptionsPresented = false
        fixturePickerDraftOptionIDs = nil
        fixturePickerBaselineOptionIDs = nil
        withAnimation(reduceMotion ? nil : Self.competitionDockExpandAnimation) {
            expandedFixtureRegionID = nil
            isCompetitionDockExpanded = false
            isFixtureFavouritesMenuExpanded.toggle()
        }
    }

    func showCustomFixtureFilters(reduceMotion: Bool) {
        withAnimation(reduceMotion ? nil : Self.competitionDockExpandAnimation) {
            expandedFixtureRegionID = nil
            isFixtureFavouritesMenuExpanded = false
            isCompetitionDockExpanded = false
            isCustomOptionsPresented = true
        }
    }

    func collapseCompetitionDock(reduceMotion: Bool) {
        isCustomOptionsPresented = false
        fixturePickerDraftOptionIDs = nil
        fixturePickerBaselineOptionIDs = nil
        withAnimation(reduceMotion ? nil : Self.competitionDockCollapseAnimation) {
            expandedFixtureRegionID = nil
            isFixtureFavouritesMenuExpanded = false
            isCompetitionDockExpanded = false
        }
    }

    func presentSaveFixtureViewPrompt() {
        isSaveFixtureViewPromptVisible = true
    }

    func dismissSaveFixtureViewPrompt() {
        isSaveFixtureViewPromptVisible = false
    }

    func clearSaveFixtureViewPresentation() {
        isSaveFixtureViewPromptVisible = false
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
    @Environment(\.openURL) private var openURL
    @AppStorage(AppGroupConfig.fantasyManagerEntryIDKey) private var fantasyManagerEntryID = ""
    @State private var groupedSideEffectsTask: Task<Void, Never>?
    @State private var fixtureBrowseGroupingTask: Task<Void, Never>?
    @State private var fixtureBrowseGroupingRequestID = UUID()
    @State private var reportedMissingLogoNames: Set<String> = []
    @State private var didRunActivationForVisibleCycle = false
    @State private var navigationMatch: MatchNavigation?
    @State private var screenOpenedAt: Date?
    @State private var screenViewSentForActivation = false
    @State private var visibleGroupedDays: [MatchDay] = []
    @State private var visibleGroupedDaysSource: [MatchDay] = []
    @State private var fixtureBrowseGroupedDays: [MatchDay] = []
    @State private var fixtureBrowsePageGroupedDays: [String: [MatchDay]] = [:]
    @State private var fixtureBrowsePageRevisions: [String: UInt] = [:]
    @State private var fixtureBrowsePageSourceMatchesByDate: [String: [Match]] = [:]
    @State private var fixtureBrowseUnfilteredPageGroupedDays: [String: [MatchDay]] = [:]
    @State private var fixtureBrowseUnfilteredPageSourceMatchesByDate: [String: [Match]] = [:]
    @StateObject private var fixtureArtworkPreparation = FixtureArtworkPreparationState()
    @State private var expandedFixtureCompetitionKeys: Set<String> = []
    @State private var fixtureCompetitionMatchLimits: [String: Int] = [:]
    @State private var isFixtureDatePickerPresented = false
    @State private var fixtureDatePickerSelection = Date()
    @State private var fixtureDateCarouselState = FixtureDateCarouselState()
    @State private var subscribingCalendarFeed: PersonalCalendarFeed?
    @State private var calendarSubscriptionTask: Task<Void, Never>?
    @State private var pendingCalendarSubscriptionURL: URL?
    @State private var calendarSubscriptionErrorMessage = ""
    @State private var showsCalendarSubscriptionError = false
    @State private var isTVListingsPresented = false
    @State private var dateBeforeTVGuide: String?
    @State private var showsMatchDetails = false
    @State private var isTeamSearchPresented = false
    @State private var pendingTeamSearchDestination: TeamDetailsContext?
    @State private var navigationTeam: TeamDetailsContext?
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
        // Fixture-browser pages were already filtered before grouping. Repeating
        // the full match-tree filter here made every date selection allocate a
        // second copy of the page on the main actor.
        visibleGroupedDays = usesFixtureBrowser || preferences.showPostponedGames
            ? days
            : Self.filteringPostponed(days)
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
            .overlay(alignment: .bottomTrailing) {
                if mode == .fixtures && isSelected {
                    FixtureCompetitionDockView(
                        coordinator: fixturesCoordinator,
                        isTVListingsPresented: isTVListingsPresented,
                        canShowMatchDetails: canShowMatchDetails,
                        showsMatchDetails: $showsMatchDetails,
                        onToggleTVListings: toggleTVListings,
                        onSearch: presentTeamSearch,
                        onCalendar: presentFixtureDatePicker
                    )
                }
            }
        }
        .navigationDestination(item: $navigationMatch) { nav in
            MatchDetailView(
                match: nav.match,
                showFantasyBadge: nav.showFantasyBadge
            )
        }
        .navigationDestination(item: $navigationTeam) { context in
            TeamDetailsView(context: context)
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

    @ViewBuilder
    private func fixtureBrowsePageContent(for dateKey: String?) -> some View {
        if let dateKey {
            let days = fixtureBrowsePageGroupedDays[dateKey]
            switch FixtureBrowsePageContentState.resolve(groupedDayCount: days?.count) {
            case .loading:
                FixtureMatchesLoadingPlaceholder()
            case .empty:
                emptyState
            case .fixtures:
                fixtureMatchesScrollContent(days: days ?? [])
                    .refreshable {
                        await refreshMatchesManually()
                    }
            }
        } else {
            Color.clear
        }
    }

    private func fixtureDatePagedContent(containerWidth: CGFloat) -> some View {
        let previousDateKey = fixtureBrowser.adjacentDateKey(offset: -1)
        let nextDateKey = fixtureBrowser.adjacentDateKey(offset: 1)
        return FixtureDatePagingContainer(
            containerWidth: containerWidth,
            currentDateKey: fixtureBrowser.selectedDateKey,
            previousDateKey: previousDateKey,
            nextDateKey: nextDateKey,
            previousPageIsReady: previousDateKey.map { fixtureBrowsePageGroupedDays[$0] != nil } ?? false,
            nextPageIsReady: nextDateKey.map { fixtureBrowsePageGroupedDays[$0] != nil } ?? false,
            previousPageMatchCount: previousDateKey.flatMap { fixtureBrowser.cachedMatchesByDate[$0]?.count } ?? 0,
            nextPageMatchCount: nextDateKey.flatMap { fixtureBrowser.cachedMatchesByDate[$0]?.count } ?? 0,
            previousPageRevision: previousDateKey.flatMap { fixtureBrowsePageRevisions[$0] } ?? 0,
            currentPageRevision: fixtureBrowser.selectedDateKey.flatMap { fixtureBrowsePageRevisions[$0] } ?? 0,
            nextPageRevision: nextDateKey.flatMap { fixtureBrowsePageRevisions[$0] } ?? 0,
            isSwipeEnabled: fixturesCoordinator.isDateSwipeEnabled,
            reduceMotion: accessibilityReduceMotion,
            onSwipeProgressChanged: fixtureDateCarouselState.updateSwipeProgress,
            onSwipeSelectionSettled: fixtureDateCarouselState.settleOnSelection,
            onSelect: fixtureBrowser.selectDate,
            onSwipeInteractionChanged: { isActive in
                if isActive, let fixtureBrowseGroupingTask {
                    // Stop speculative sorting before it can compete with direct
                    // manipulation for CPU time. Selection restarts any needed work.
                    fixtureBrowseGroupingTask.cancel()
                    performanceDiagnosticLogAsync(
                        "[FixtureSwipe] cancelled speculative grouping at gesture begin"
                    )
                }
                fixtureBrowser.setDateSwipeInteractionActive(isActive)
                if isActive {
                    fixturesCoordinator.beginDateSwipeInteraction()
                } else {
                    fixturesCoordinator.endDateSwipeInteraction()
                }
            }
        ) { dateKey in
            fixtureBrowsePageContent(for: dateKey)
        }
    }

    private var presentedNavigationContent: some View {
        NavigationStack {
            navigationStackContent
                .accessibilityHidden(isTVListingsPresented)
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .environment(\.colorScheme, .dark)
        .alert("Unable to subscribe", isPresented: $showsCalendarSubscriptionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(calendarSubscriptionErrorMessage)
        }
        .crashBreadcrumb("fixture_date_picker", isPresented: isFixtureDatePickerPresented)
        .fullScreenCover(isPresented: $isFixtureDatePickerPresented, onDismiss: finishCalendarDismissal) {
            FixtureCalendarView(
                selection: $fixtureDatePickerSelection,
                dateRange: fixtureDatePickerRange,
                availableDateKeys: Set(fixtureBrowser.availableDays.map(\.date)),
                competitionsByDate: fixtureBrowser.calendarCompetitionSummariesByDate,
                contextTitle: preferences.fixtureViewMenuTitle,
                subscribingFeed: subscribingCalendarFeed,
                subscriptionError: calendarSubscriptionErrorMessage,
                onViewMatches: jumpToFixtureDatePickerSelection,
                onSubscribe: subscribeToPersonalCalendar,
                onLoadMonth: { try await fixtureBrowser.loadCalendarMonth(containing: $0) }
            )
            .environment(\.colorScheme, .dark)
        }
        .fullScreenCover(isPresented: $isTVListingsPresented, onDismiss: {
            fixtureBrowser.setTVListingsModeEnabled(false)
            if let dateBeforeTVGuide { fixtureBrowser.selectDate(dateBeforeTVGuide) }
            dateBeforeTVGuide = nil
        }) {
            FixtureTVGuideView(browser: fixtureBrowser, rowPreferences: matchRowPreferences,
                               fantasyContext: fantasyViewModel.matchRowContext)
                .environment(\.colorScheme, .dark)
        }
        .crashBreadcrumb("team_search", isPresented: isTeamSearchPresented)
        .sheet(isPresented: $isTeamSearchPresented, onDismiss: navigateToPendingTeam) {
            TeamSearchView(apiBaseURL: preferences.apiBaseURL) { context in
                pendingTeamSearchDestination = context
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var activationObservedContent: some View {
        presentedNavigationContent
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
                    fixturesCoordinator.resetPresentation()
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
        .onReceive(
            NotificationCenter.default.publisher(for: Notification.Name.NSCalendarDayChanged)
        ) { _ in
            guard mode == .fixtures else { return }
            fixtureBrowser.refreshToday()
        }
        .onChange(of: navigationMatch) { _, match in
            if match != nil {
                fixturesCoordinator.resetPresentation()
            }
        }
        .onChange(of: navigationTeam) { _, team in
            if team != nil {
                fixturesCoordinator.resetPresentation()
            }
        }
        .onChange(of: isTVListingsPresented) { _, isPresented in
            fixtureBrowser.setTVListingsModeEnabled(isPresented)
            if isPresented {
                fixturesCoordinator.resetPresentation()
                AppMetricsService.shared.fireScreenView(
                    screen: "tv_listings",
                    durationMs: nil,
                    apiBaseURL: preferences.apiBaseURL
                )
            }
        }
    }

    private var preferencesObservedContent: some View {
        activationObservedContent
        .onChange(of: viewState.isLoading) { _, isLoading in
            guard !isLoading else { return }
            sendTimedScreenView()
        }
        .onChange(of: preferences.snapshot) { _, _ in
            guard isSelected else { return }
            cancelFixtureBrowseGrouping()
            fixtureBrowsePageSourceMatchesByDate = [:]
            fixtureBrowsePageGroupedDays = [:]
            fixtureBrowsePageRevisions = [:]
            fixtureBrowseUnfilteredPageSourceMatchesByDate = [:]
            fixtureBrowseUnfilteredPageGroupedDays = [:]
            fixtureArtworkPreparation.reset()
            expandedFixtureCompetitionKeys.removeAll(keepingCapacity: true)
            fixtureCompetitionMatchLimits.removeAll(keepingCapacity: true)
            let snapshot = showAllMatches ? preferences.unfilteredSnapshot : preferences.snapshot
            #if DEBUG
            diagnosticLog("[MatchesView] snapshot_change mode=%@ showAllMatches=%d epl_pref=%d effective_snapshot=%@",
                  mode.rawValue, showAllMatches, preferences.englishPremierLeagueTeamsOnly, debugSnapshotSummary(snapshot))
            #endif
            if mode == .fixtures, fixtureBrowser.hasLoadedCalendar {
                // The fixture browser owns a selection-independent cache once
                // its calendar is ready. Keep MatchesStore's preferences in
                // sync without turning a carousel change into another fetch.
                matchesStore.prepareForPreferencesChange(
                    snapshot,
                    publishVisibleState: false
                )
                fixtureBrowser.configure(preferences: preferences.snapshot)
            } else {
                matchesStore.configure(with: snapshot, mode: mode)
                if mode == .fixtures {
                    fixtureBrowser.configure(preferences: preferences.snapshot)
                }
            }
            scheduleGroupedSideEffects(for: sourceGroupedDays, immediate: false)
        }
        .onChange(of: preferences.showAllMatches) { _, newValue in
            guard isSelected else { return }
            fixturesCoordinator.showToast(
                newValue ? "Viewing all matches (unfiltered)" : "Viewing preferred matches only"
            )
        }
    }

    var body: some View {
        preferencesObservedContent
        .onChange(of: viewState.groupedMatches) { _, days in
            if !usesFixtureBrowser {
                refreshVisibleGroupedDays(from: days)
            }
            guard isSelected else { return }
            scheduleGroupedSideEffects(for: days, immediate: false)
        }
        .onChange(of: fixtureBrowser.visibleMatches) { _, _ in
            guard fixturesCoordinator.allowsMatchNavigation else { return }
            rebuildFixtureBrowseGrouping()
        }
        .onReceive(fixtureBrowser.pageCache.$matchesByDate) { matchesByDate in
            scheduleFixtureBrowsePageGroupings(from: matchesByDate)
        }
        .onChange(of: viewState.teamRatingsRevision) { _, _ in
            scheduleFixtureBrowsePageGroupings(
                from: fixtureBrowser.cachedMatchesByDate,
                force: true
            )
        }
        .onChange(of: fixtureBrowser.hasLoadedCalendar) { _, _ in
            rebuildFixtureBrowseGrouping()
        }
        .onChange(of: fixtureBrowser.selectedDateKey) { _, dateKey in
            if let dateKey, dateKey > fixtureBrowser.todayDateKey {
                showsMatchDetails = false
            }
            handleFixtureBrowserDateChange(dateKey)
        }
        .onChange(of: preferences.showPostponedGames) { _, _ in
            refreshVisibleGroupedDays(from: sourceGroupedDays, force: true)
        }
        .onChange(of: preferences.showFACupEarlyRounds) { _, _ in
            refreshVisibleGroupedDays(from: sourceGroupedDays, force: true)
        }
        .onDisappear(perform: handleScreenDisappear)
    }

    private var scoresHeaderTitle: String {
        guard mode == .fixtures else { return "Results" }
        guard let selectedDateKey = fixtureBrowser.selectedDateKey else {
            return "Fixtures"
        }
        if isTVListingsPresented {
            return TVListingsTimeline.title(for: selectedDateKey)
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
        VStack(spacing: 0) {
            FootballHeroHeader(title: scoresHeaderTitle, subtitle: scoresHeaderSubtitle)
            if mode == .fixtures && !isTVListingsPresented {
                Text(preferences.fixtureViewMenuTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                    .accessibilityIdentifier("fixtureActiveView")
            }
        }
        .padding(.top, mode == .fixtures && dynamicTypeSize.isAccessibilitySize ? 8 : 0)
        .animation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.18), value: isTVListingsPresented)
        .overlay(alignment: .topLeading) {
            if mode == .fixtures,
               let targetDateKey = fixtureBrowser.currentDateJumpTargetKey {
                fixtureTodayButton(targetDateKey: targetDateKey)
                    .padding(.leading, 14)
            }
        }
    }

    private func fixtureTodayButton(targetDateKey: String) -> some View {
        let hint = targetDateKey == fixtureBrowser.todayDateKey
            ? "Moves to today"
            : "No matches today. Moves to \(Self.friendlyFixtureDateLabel(targetDateKey) ?? targetDateKey)"
        return Button {
            fixtureBrowser.selectDate(targetDateKey)
        } label: {
            VStack(spacing: 0) {
                FixtureCurrentDateIcon(dateKey: fixtureBrowser.todayDateKey)
                Text("Today")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Color.accentColor)
            .frame(width: 56, height: 44)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("fixtureCurrentDateJump-\(targetDateKey)")
        .accessibilityLabel("Return to today")
        .accessibilityHint(hint)
    }

    private var canShowMatchDetails: Bool {
        guard let selectedDateKey = fixtureBrowser.selectedDateKey else { return false }
        return selectedDateKey <= fixtureBrowser.todayDateKey
    }

    private var fixtureDatePickerRange: ClosedRange<Date> {
        let fallback = Calendar.current.startOfDay(for: Date())
        guard let firstDateKey = fixtureBrowser.availableDays.first?.date,
              let lastDateKey = fixtureBrowser.availableDays.last?.date,
              let firstDate = Self.fixtureDate(from: firstDateKey),
              let lastDate = Self.fixtureDate(from: lastDateKey) else {
            return fallback...fallback
        }
        return min(firstDate, lastDate, fallback)...max(firstDate, lastDate, fallback)
    }

    private var fixtureDatePickerSelectionKey: String {
        Self.fixtureDateKey(from: fixtureDatePickerSelection)
    }

    private var isFixtureDatePickerSelectionAvailable: Bool {
        fixtureBrowser.availableDays.contains { $0.date == fixtureDatePickerSelectionKey }
    }

    private func presentFixtureDatePicker() {
        calendarSubscriptionErrorMessage = ""
        if let selectedDateKey = fixtureBrowser.selectedDateKey,
           let selectedDate = Self.fixtureDate(from: selectedDateKey) {
            fixtureDatePickerSelection = selectedDate
        } else {
            fixtureDatePickerSelection = fixtureDatePickerRange.lowerBound
        }
        isFixtureDatePickerPresented = true
    }

    private func jumpToFixtureDatePickerSelection() {
        guard isFixtureDatePickerSelectionAvailable else { return }
        fixtureBrowser.selectDate(fixtureDatePickerSelectionKey)
        isFixtureDatePickerPresented = false
    }

    private func subscribeToPersonalCalendar(feed: PersonalCalendarFeed) {
        guard subscribingCalendarFeed == nil else { return }
        subscribingCalendarFeed = feed
        calendarSubscriptionErrorMessage = ""
        calendarSubscriptionTask = Task { @MainActor in
            do {
                let subscriptionURL = try await PersonalCalendarSubscriptionService.provision(
                    preferences: preferences.snapshot,
                    feed: feed
                )
                try Task.checkCancellation()
                pendingCalendarSubscriptionURL = subscriptionURL
                isFixtureDatePickerPresented = false
            } catch is CancellationError {
                subscribingCalendarFeed = nil
            } catch {
                subscribingCalendarFeed = nil
                calendarSubscriptionErrorMessage = error.localizedDescription
            }
        }
    }

    private func finishCalendarDismissal() {
        calendarSubscriptionTask?.cancel()
        calendarSubscriptionTask = nil
        subscribingCalendarFeed = nil
        // Wait for the actual dismissal so Calendar's confirmation is not lost
        // while a full-screen presentation is still animating away.
        guard let subscriptionURL = pendingCalendarSubscriptionURL else { return }
        pendingCalendarSubscriptionURL = nil
        openURL(subscriptionURL) { accepted in
            if !accepted {
                calendarSubscriptionErrorMessage = "Calendar could not open the subscription link. Please try again."
                showsCalendarSubscriptionError = true
            }
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
        if phase == .active {
            fixtureBrowser.refreshToday()
        }
        fixtureBrowser.setAutoRefreshEnabled(
            phase == .active,
            refreshImmediately: phase == .active
        )
    }

    private func toggleTVListings() {
        withAnimation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.20)) {
            if isTVListingsPresented {
                isTVListingsPresented = false
            } else {
                dateBeforeTVGuide = fixtureBrowser.selectedDateKey
                fixtureBrowser.showTVListingsToday()
                isTVListingsPresented = true
            }
        }
    }

    private func presentTeamSearch() {
        pendingTeamSearchDestination = nil
        isTeamSearchPresented = true
    }

    private func navigateToPendingTeam() {
        guard let destination = pendingTeamSearchDestination else { return }
        pendingTeamSearchDestination = nil
        navigationTeam = destination
    }

    private func handleScreenDisappear() {
        matchesStore.setModeVisibility(mode, isVisible: false)
        if mode == .fixtures && !isTVListingsPresented {
            fixtureBrowser.setAutoRefreshEnabled(false)
            matchesStore.setFixtureBrowserLiveRefreshActive(false)
        }
        fixturesCoordinator.resetPresentation()
        groupedSideEffectsTask?.cancel()
        cancelFixtureBrowseGrouping()
    }

    private func beginScreenViewTiming() {
        screenOpenedAt = Date()
        screenViewSentForActivation = false
        if !viewState.isLoading {
            sendTimedScreenView()
        }
    }

    private func sendTimedScreenView() {
        guard isSelected, screenOpenedAt != nil, !screenViewSentForActivation else { return }
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

    @ViewBuilder
    private var matchesList: some View {
        if usesFixtureBrowser {
            fixtureMatchesScrollContent(days: displayedMatchDays)
                .refreshable {
                    await refreshMatchesManually()
                }
        } else {
            matchesListContent(
                days: displayedMatchDays,
                includesResultsLoadingRow: true
            )
            .refreshable {
                await refreshMatchesManually()
            }
        }
    }

    private func fixtureMatchesScrollContent(days: [MatchDay]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                fixtureCompetitionCards(days: days)
            }
        }
        .background(Color.clear)
        .safeAreaPadding(.bottom, Self.fixtureDockContentClearance)
    }

    @ViewBuilder
    private func fixtureCompetitionCards(days: [MatchDay]) -> some View {
        ForEach(days) { day in
            ForEach(day.leagues) { league in
                competitionCardRow(for: league, day: day)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
            }
        }
    }

    private func refreshMatchesManually() async {
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
        AppMetricsService.shared.fireActivity(
            "manual_refresh",
            screen: mode.rawValue,
            durationMs: durationMs,
            apiBaseURL: preferences.apiBaseURL
        )
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
        let unfilteredLeague = unfilteredFixtureLeague(matching: league, on: day)
        let visibleMatchIDs = Set(league.matches.map(\.id))
        let filteredOutMatchCount = unfilteredLeague?.matches.reduce(into: 0) { count, match in
            if !visibleMatchIDs.contains(match.id) {
                count += 1
            }
        } ?? 0
        let expansionKey = fixtureCompetitionExpansionKey(for: league, on: day)
        let includesFilteredOutMatches = filteredOutMatchCount > 0 &&
            expandedFixtureCompetitionKeys.contains(expansionKey)
        let sourceLeague = includesFilteredOutMatches ? (unfilteredLeague ?? league) : league
        let matchLimit = FixtureCompetitionRenderWindow.displayedCount(
            totalCount: sourceLeague.matches.count,
            configuredLimit: fixtureCompetitionMatchLimits[expansionKey]
        )
        let displayedMatches = Array(sourceLeague.matches.prefix(matchLimit))
        let displayedLeague = displayedMatches.count == sourceLeague.matches.count
            ? sourceLeague
            : MatchLeague(
                id: sourceLeague.id,
                league: sourceLeague.league,
                matches: displayedMatches
            )
        let hiddenMatchCount = sourceLeague.matches.count - displayedMatches.count +
            (includesFilteredOutMatches ? 0 : filteredOutMatchCount)
        let canCollapse = includesFilteredOutMatches ||
            matchLimit > FixtureCompetitionRenderWindow.initialLimit
        let competitionName = displayedLeague.matches.first?.league ?? displayedLeague.league
        let competitionSubtitle = displayedLeague.matches.first?.leagueSubcategory?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let accentRole = CompetitionAccentRole.resolve(
            competitionID: displayedLeague.matches.first?.leagueId,
            competitionName: competitionName
        )
        let accentColor = accentRole.color
        let cardShape = RoundedRectangle(
            cornerRadius: FootballVisualStyle.cardCornerRadius,
            style: .continuous
        )

        let competitionID = displayedLeague.matches.first?.leagueId
        let canOpenTable = fixtureBrowser.competitions.first { entry in
            entry.stableID == competitionID || entry.allNames.contains {
                $0.caseInsensitiveCompare(competitionName) == .orderedSame
            }
        }?.supportsTable == true

        let heading = HStack(spacing: 11) {
            LeagueBadgeImage(
                competitionID: displayedLeague.matches.first?.leagueId,
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
            if canOpenTable {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FootballVisualStyle.mutedText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())

        return VStack(spacing: 0) {
            if canOpenTable {
                Button {
                    guard fixturesCoordinator.allowsMatchNavigation else {
                        diagnosticLogAsync(
                            "[FixtureSwipe] suppressed competition navigation during date swipe"
                        )
                        return
                    }
                    guard let competitionID else { return }
                    TablesNavigationCoordinator.shared.navigate(
                        leagueID: competitionID,
                        returnTitle: "Back to Scores"
                    )
                } label: {
                    heading
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(competitionName)
                .accessibilityHint("View competition on the Tables screen")
            } else {
                heading
            }

            Rectangle()
                .fill(FootballVisualStyle.divider)
                .frame(height: 0.5)
                .padding(.horizontal, 16)

            ForEach(Array(displayedLeague.matches.enumerated()), id: \.element.id) { index, match in
                let previousTime = index > 0 ? displayedLeague.matches[index - 1].time : nil
                if shouldShowKickoffDivider(currentTime: match.time, previousTime: previousTime) {
                    embeddedKickoffDivider(time: match.time)
                }

                matchButton(for: match, day: day)
                    .padding(.horizontal, 8)

                if index < displayedLeague.matches.count - 1 {
                    Rectangle()
                        .fill(FootballVisualStyle.divider)
                        .frame(height: 0.5)
                        .padding(.horizontal, 16)
                }
            }

            if hiddenMatchCount > 0 || canCollapse {
                Rectangle()
                    .fill(FootballVisualStyle.divider)
                    .frame(height: 0.5)
                    .padding(.horizontal, 16)

                fixtureCompetitionExpansionButton(
                    hiddenMatchCount: hiddenMatchCount,
                    displayedMatchCount: displayedMatches.count,
                    totalMatchCount: (unfilteredLeague ?? league).matches.count,
                    canCollapse: canCollapse,
                    expansionKey: expansionKey,
                    competitionName: competitionName
                )
            }
        }
        .background {
            FootballCardSurface(accentColor: accentColor.opacity(0.65))
        }
        .clipShape(cardShape)
        .background {
            // Shadow a simple, stable geometry instead of asking Core Animation to
            // derive a shadow mask from the card's entire changing view hierarchy.
            cardShape
                .fill(Color.black.opacity(0.01))
                .shadow(color: .black.opacity(0.24), radius: 16, y: 9)
        }
        .overlay {
            cardShape
                .stroke(
                    LinearGradient(
                        colors: [accentColor.opacity(0.32), FootballVisualStyle.border, FootballVisualStyle.border],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.6
                )
        }
        .modifier(CompetitionCardEntrance(isEnabled: mode == .results))
        .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .contain)
    }

    private func unfilteredFixtureLeague(
        matching league: MatchLeague,
        on day: MatchDay
    ) -> MatchLeague? {
        guard usesFixtureBrowser else { return nil }
        return fixtureBrowseUnfilteredPageGroupedDays[day.dateKey]?
            .first(where: { $0.dateKey == day.dateKey })?
            .leagues
            .first(where: { $0.id == league.id })
    }

    private func fixtureCompetitionExpansionKey(
        for league: MatchLeague,
        on day: MatchDay
    ) -> String {
        "\(day.dateKey)|\(league.id)"
    }

    private func fixtureCompetitionExpansionButton(
        hiddenMatchCount: Int,
        displayedMatchCount: Int,
        totalMatchCount: Int,
        canCollapse: Bool,
        expansionKey: String,
        competitionName: String
    ) -> some View {
        let revealCount = min(FixtureCompetitionRenderWindow.revealIncrement, hiddenMatchCount)
        let matchLabel = revealCount == 1 ? "match" : "matches"
        let title = hiddenMatchCount > 0
            ? "Show \(revealCount) more \(matchLabel)"
            : "Show fewer matches"

        return Button {
            if hiddenMatchCount > 0 {
                expandedFixtureCompetitionKeys.insert(expansionKey)
                fixtureCompetitionMatchLimits[expansionKey] = FixtureCompetitionRenderWindow.nextLimit(
                    displayedCount: displayedMatchCount,
                    totalCount: totalMatchCount
                )
            } else if canCollapse {
                expandedFixtureCompetitionKeys.remove(expansionKey)
                fixtureCompetitionMatchLimits.removeValue(forKey: expansionKey)
            }
        } label: {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 8)
                Image(systemName: hiddenMatchCount > 0 ? "chevron.down" : "chevron.up")
                    .font(.caption.weight(.bold))
                    .accessibilityHidden(true)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) in \(competitionName)")
        .accessibilityHint(
            hiddenMatchCount > 0
                ? "Reveals more matches without blocking date navigation"
                : "Returns to the first matches in this competition"
        )
    }

    @ViewBuilder
    private func matchButton(for match: Match, day: MatchDay) -> some View {
        let openMatch = {
            guard !match.isPostponed else { return }
            guard fixturesCoordinator.allowsMatchNavigation else {
                diagnosticLog("[MatchesView] suppressed match navigation during date swipe")
                return
            }
            navigationMatch = MatchNavigation(
                match: match,
                showFantasyBadge: mode == .fixtures
            )
        }
        let rowContent = HStack(spacing: 0) {
            MatchesListRowLabel(
                match: match,
                isFixtureMode: mode == .fixtures,
                showDetails: mode == .fixtures && showsMatchDetails && canShowMatchDetails && !isTVListingsPresented,
                apiBaseURL: preferences.apiBaseURL,
                rowPreferences: matchRowPreferences,
                fantasyContext: fantasyViewModel.matchRowContext
            )
            .equatable()
            FixtureMatchNavigationChevron(
                match: match,
                showFantasyBadge: mode == .fixtures,
                rowPreferences: matchRowPreferences,
                fantasyViewModel: fantasyViewModel
            )
        }
        Button(action: openMatch) { rowContent }
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

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: mode.emptyStateSystemImage)
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
        guard mode == .fixtures else { return viewState.isLoading }
        guard usesFixtureBrowser else { return viewState.isLoading }
        return fixtureBrowser.isLoadingSelectedDate || isSelectedFixturePagePreparing
    }

    private var isSelectedFixturePagePreparing: Bool {
        guard usesFixtureBrowser,
              let selectedDateKey = fixtureBrowser.selectedDateKey,
              !fixtureBrowser.visibleMatches.isEmpty else {
            return false
        }
        return fixtureBrowsePageGroupedDays[selectedDateKey] == nil ||
            visibleGroupedDays.isEmpty
    }

    private var nativeMatchesLoadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(.accentColor)
            Text(mode.loadingText)
                .font(.title3.weight(.semibold))
            Text(mode.loadingSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mode.loadingText). \(mode.loadingSubtitle)")
    }

    private var fixtureDateCarouselHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 74 : 62
    }

    private var fixtureDateBrowserControl: some View {
        return FixtureDateCarousel(
            state: fixtureDateCarouselState,
            availableDays: fixtureBrowser.availableDays,
            selectedDateKey: fixtureBrowser.selectedDateKey,
            todayDateKey: fixtureBrowser.todayDateKey,
            hasLoadedCalendar: fixtureBrowser.hasLoadedCalendar,
            errorMessage: fixtureBrowser.errorMessage,
            height: fixtureDateCarouselHeight,
            onSelect: fixtureBrowser.selectDate
        )
    }

    private static func friendlyFixtureDateLabel(_ dateKey: String) -> String? {
        guard let date = fixtureDate(from: dateKey) else { return nil }

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

    private static func fixtureDate(from dateKey: String) -> Date? {
        let parts = dateKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2])
        )
    }

    private static func fixtureDateKey(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return ""
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
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

private extension PreferencesStore {
    var fixtureViewMenuTitle: String {
        if fixtureAllMajorMatchesEnabled { return "Favourites" }
        if showAllMatches { return "All Competitions" }
        let optionIDs = Set(selectedFixtureViewOptionIDs)
        if optionIDs == Set([FixtureViewOptionID.topTeamsPreset]) { return "Top Teams" }
        if optionIDs.contains(FixtureViewOptionID.topTeamsPreset) { return "Top Teams + Custom" }
        if optionIDs == FixtureViewOptionID.premierLeagueMatchesPresetOptionIDs {
            return "Matches with Premier League teams"
        }
        return "Custom"
    }
}

struct FixtureCompetitionDockView: View {
    enum Content: String {
        case rail
        case teamPicker
    }

    @ObservedObject private var coordinator: FixturesViewCoordinator
    @ObservedObject private var fixtureBrowser: FixtureBrowserStore
    @ObservedObject private var topTeamsPresetStore = TopTeamsPresetStore.shared
    @EnvironmentObject private var preferences: PreferencesStore
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let content: Content
    private let isTVListingsPresented: Bool
    private let canShowMatchDetails: Bool
    @Binding private var showsMatchDetails: Bool
    private let onToggleTVListings: () -> Void
    private let onSearch: () -> Void
    private let onCalendar: () -> Void

    init(
        coordinator: FixturesViewCoordinator,
        content: Content = .rail,
        isTVListingsPresented: Bool = false,
        canShowMatchDetails: Bool = false,
        showsMatchDetails: Binding<Bool> = .constant(false),
        onToggleTVListings: @escaping () -> Void = {},
        onSearch: @escaping () -> Void = {},
        onCalendar: @escaping () -> Void = {}
    ) {
        self.coordinator = coordinator
        self.fixtureBrowser = coordinator.browser
        self.content = content
        self.isTVListingsPresented = isTVListingsPresented
        self.canShowMatchDetails = canShowMatchDetails
        self._showsMatchDetails = showsMatchDetails
        self.onToggleTVListings = onToggleTVListings
        self.onSearch = onSearch
        self.onCalendar = onCalendar
    }

    @ViewBuilder
    var body: some View {
        Group {
            switch content {
            case .rail:
                fixtureOptionsOverlay
                    .sheet(isPresented: $coordinator.isTeamPickerPresented) {
                        FixtureCompetitionDockView(coordinator: coordinator, content: .teamPicker)
                    }
                    .crashBreadcrumb("team_picker", isPresented: coordinator.isTeamPickerPresented)
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
    }

    private var fixtureOptionsOverlay: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                if coordinator.hasExpandedPanel {
                    Color.black.opacity(0.12)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            coordinator.collapseCompetitionDock(reduceMotion: accessibilityReduceMotion)
                        }
                        .accessibilityLabel("Dismiss match options")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("fixtureOptionsDismiss")
                }

                VStack(alignment: .trailing, spacing: 8) {
                    if coordinator.hasExpandedPanel {
                        fixtureCompetitionOverlayPanel
                            .frame(maxWidth: coordinator.isCustomOptionsPresented || dynamicTypeSize.isAccessibilitySize ? 420 : 320)
                            .frame(height: coordinator.isCustomOptionsPresented ? max(100, min(660, proxy.size.height - 90)) : nil)
                            .frame(maxHeight: max(100, proxy.size.height - 90), alignment: .bottom)
                            .padding(.horizontal, 16)
                    }
                    fixtureCompetitionAccessory
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .animation(accessibilityReduceMotion ? nil : FootballVisualStyle.easeOut, value: coordinator.hasExpandedPanel)
    }

    private var fixtureCompetitionAccessory: some View {
        VStack(spacing: 0) {
            if coordinator.isSaveFixtureViewPromptVisible && !coordinator.hasExpandedPanel {
                fixtureSaveFavouritesPrompt
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(fixtureSavePromptTransition)
            }
            fixtureCompetitionDock
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
        HStack(spacing: 8) {
            if coordinator.isCompetitionDockExpanded {
                fixtureCompetitionRail
                    .transition(expandedCompetitionDockTransition)
                    .accessibilityIdentifier("fixtureCompetitionDockExpanded")
            } else {
                Spacer(minLength: 0)
            }
            collapsedFixtureCompetitionDock
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
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

    private var collapsedFixtureCompetitionDock: some View {
        Button {
            coordinator.toggleMatchFilters(reduceMotion: accessibilityReduceMotion)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 50, height: 50)
                .modifier(FixtureOptionsGlass(cornerRadius: 25, interactive: true))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: 50, height: 50)
        .contentShape(.interaction, Circle())
        .accessibilityIdentifier("fixtureOptionsButton")
        .accessibilityLabel("Match options")
        .accessibilityValue(preferences.fixtureViewMenuTitle)
        .accessibilityHint(isFixtureFavouritesMenuExpanded ? "Closes match options" : "Choose a match view, TV listings, search or calendar")
    }

    @ViewBuilder
    private var fixtureCompetitionOverlayPanel: some View {
        if coordinator.isCustomOptionsPresented {
            FixtureCustomOptionsView(
                competitions: fixtureBrowser.competitions,
                apiBaseURL: preferences.apiBaseURL,
                selection: Binding(get: { fixturePickerDraftOptionIDs ?? fixturePickerInitialOptionIDs },
                                   set: { fixturePickerDraftOptionIDs = $0 }),
                onBack: {
                    coordinator.isCustomOptionsPresented = false
                    isFixtureFavouritesMenuExpanded = true
                },
                onClose: { coordinator.collapseCompetitionDock(reduceMotion: accessibilityReduceMotion) },
                onApply: {
                    let selection = fixturePickerDraftOptionIDs ?? fixturePickerInitialOptionIDs
                    coordinator.collapseCompetitionDock(reduceMotion: accessibilityReduceMotion)
                    applyCustomFixtureView(selection)
                }
            )
            .modifier(FixtureOptionsGlass(cornerRadius: 24))
        } else if isFixtureFavouritesMenuExpanded {
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
                            let isIncludedByTopTeams = includesTopTeamsPreset && region.id == "world"
                            Button {
                                toggleFixtureCompetitionPicker(for: region.id)
                            } label: {
                                FixtureRegionDockButton(
                                    systemSymbol: nil,
                                    regionID: region.id,
                                    isSelected: selectedCount > 0 || isIncludedByTopTeams,
                                    isExpanded: expandedFixtureRegionID == region.id
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(region.name)
                            .accessibilityValue(
                                isIncludedByTopTeams && selectedCount == 0
                                    ? "Included by Top teams"
                                    : selectedCount == 0
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
                                isSelected: includesTopTeamsPreset || !selectedFixtureTeamIDs.isEmpty,
                                isExpanded: isTeamPickerPresented,
                                systemSymbolSize: 30,
                                systemSymbolTint: Color(red: 0.18, green: 0.55, blue: 0.88),
                                showsPersistentBorder: true
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Teams")
                        .accessibilityValue(fixtureTeamSelectionAccessibilityValue)
                        .accessibilityHint("Choose individual teams to include")
                    }
                }
                .scrollIndicators(.hidden)
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
        ViewThatFits(in: .vertical) {
            fixtureOptionsMenuContent
            ScrollView {
                fixtureOptionsMenuContent
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .modifier(FixtureOptionsGlass(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fixtureOptionsMenu")
        .accessibilityAction(.escape) {
            coordinator.collapseCompetitionDock(reduceMotion: accessibilityReduceMotion)
        }
    }

    private var fixtureOptionsMenuContent: some View {
        VStack(spacing: 0) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 0) { fixtureOptionsShortcuts }
            } else {
                HStack(spacing: 0) { fixtureOptionsShortcuts }
                    .padding(.vertical, 8)
            }
            Divider().padding(.horizontal, 14)
            Text("MATCH VIEW")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 6)

            fixtureFavouritesActions

            Divider().padding(.horizontal, 14).padding(.vertical, 6)
            if canShowMatchDetails && !isTVListingsPresented {
                Toggle(isOn: $showsMatchDetails) {
                    Label("Show Details", systemImage: "list.bullet.rectangle")
                }
                .font(.subheadline)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .accessibilityIdentifier("fixtureShowDetails")
                Divider().padding(.horizontal, 14)
            }
            Button(action: saveCurrentFixtureViewAsFavourites) {
                HStack {
                    Text("Save View as Favourites")
                    Spacer(minLength: 8)
                    Image(systemName: "bookmark")
                }
                .font(.subheadline)
                .foregroundStyle(.primary)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(preferences.currentFixtureViewOptionIDs.isEmpty)
            .accessibilityIdentifier("fixtureSaveView")
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var fixtureOptionsShortcuts: some View {
        fixtureShortcut(
            isTVListingsPresented ? "Scores" : "TV Guide",
            symbol: isTVListingsPresented ? "soccerball" : "tv",
            identifier: "fixtureTVShortcut",
            action: onToggleTVListings
        )
        fixtureShortcut("Search", symbol: "magnifyingglass", identifier: "fixtureSearchShortcut", action: onSearch)
        fixtureShortcut("Calendar", symbol: "calendar", identifier: "fixtureCalendarShortcut", action: onCalendar)
            .disabled(fixtureBrowser.availableDays.isEmpty)
    }

    private func fixtureShortcut(_ title: String, symbol: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button {
            coordinator.collapseCompetitionDock(reduceMotion: accessibilityReduceMotion)
            action()
        } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    Label(title, systemImage: symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: symbol).font(.title2)
                        Text(title).font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .foregroundStyle(.primary)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title == "Search" ? "Search teams" : title)
    }

    private var fixtureFavouritesActions: some View {
        VStack(spacing: 0) {
            if preferences.hasSavedFavouriteFixtureView {
                fixtureFavouritesActionRow("Favourites", isSelected: preferences.fixtureAllMajorMatchesEnabled, action: selectFavourites)
            }
            fixtureFavouritesActionRow("Top Teams", isSelected: isTopTeamsPresetSelected, action: selectTopTeams)
            fixtureFavouritesActionRow("Matches with Premier League teams", isSelected: isPremierLeagueMatchesPresetSelected, action: selectPremierLeagueMatches)
            fixtureFavouritesActionRow("Show All", isSelected: preferences.showAllMatches, action: selectAllFixtureCompetitions)
            fixtureFavouritesActionRow(
                "Custom…",
                isSelected: preferences.fixtureViewMenuTitle == "Custom" || preferences.fixtureViewMenuTitle == "Top Teams + Custom",
                opensPicker: true,
                action: {
                    if fixturePickerDraftOptionIDs == nil { fixturePickerDraftOptionIDs = fixturePickerInitialOptionIDs }
                    coordinator.showCustomFixtureFilters(reduceMotion: accessibilityReduceMotion)
                }
            )
        }
        .padding(.horizontal, 6)
    }

    private var fixtureDockSeparator: some View {
        Rectangle()
            .fill(Color(.separator).opacity(0.7))
            .frame(width: 0.5, height: 28)
            .padding(.horizontal, 2)
            .accessibilityHidden(true)
    }

    private var isTopTeamsPresetSelected: Bool {
        !preferences.fixtureAllMajorMatchesEnabled &&
        !preferences.showAllMatches &&
        Set(preferences.selectedFixtureViewOptionIDs) == Set([FixtureViewOptionID.topTeamsPreset])
    }

    private var includesTopTeamsPreset: Bool {
        !preferences.fixtureAllMajorMatchesEnabled &&
        !preferences.showAllMatches &&
        Set(preferences.selectedFixtureViewOptionIDs).contains(FixtureViewOptionID.topTeamsPreset)
    }

    private var isPremierLeagueMatchesPresetSelected: Bool {
        !preferences.fixtureAllMajorMatchesEnabled &&
        !preferences.showAllMatches &&
        Set(preferences.selectedFixtureViewOptionIDs) ==
            FixtureViewOptionID.premierLeagueMatchesPresetOptionIDs
    }

    private func fixtureFavouritesActionRow(
        _ title: String,
        isSelected: Bool,
        opensPicker: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            if isTVListingsPresented { onToggleTVListings() }
            action()
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if isSelected {
                    Image(systemName: "checkmark").fontWeight(.semibold)
                }
                if opensPicker {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
            }
            .font(.subheadline)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .background(isSelected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                        let selectionState = fixtureViewOptionSelectionState(option.id)
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
                                FixturePickerCheckbox(selectionState: selectionState)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 58)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.title)
                        .accessibilityValue(selectionState.accessibilityValue)

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
                        let selectionState = fixtureViewOptionSelectionState(optionID)
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
                                FixturePickerCheckbox(selectionState: selectionState)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 54)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(competition.name)
                        .accessibilityValue(selectionState.accessibilityValue)

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
        let competitionCount = fixtureCompetitions(in: region).filter {
            fixtureViewOptionSelectionState(
                FixtureViewOptionID.competition($0.stableID)
            ) != .notSelected
        }.count
        let specialCount = FixtureViewSpecialOption.options(in: region.id)
            .filter { fixtureViewOptionSelectionState($0.id) != .notSelected }
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

    private func fixtureViewOptionSelectionState(
        _ optionID: String
    ) -> FixturePickerCheckbox.SelectionState {
        let optionIDs: Set<String>
        if let fixturePickerDraftOptionIDs {
            optionIDs = fixturePickerDraftOptionIDs
        } else {
            if preferences.snapshot.fixtureViewShowsAll { return .selected }
            optionIDs = effectiveFixtureViewOptionIDs
        }
        if optionIDs.contains(optionID) { return .selected }
        if optionIDs.contains(FixtureViewOptionID.topTeamsPreset),
           topTeamsPresetStore.preset.reflectedFixtureViewOptionIDs.contains(optionID) {
            return .includedByPreset
        }
        return .notSelected
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

    private var fixtureTeamSelectionAccessibilityValue: String {
        if includesTopTeamsPreset {
            return selectedFixtureTeamIDs.isEmpty
                ? "Teams included by Top teams"
                : "Teams included by Top teams plus \(selectedFixtureTeamIDs.count) additional"
        }
        return selectedFixtureTeamIDs.isEmpty
            ? "No teams selected"
            : "\(selectedFixtureTeamIDs.count) teams selected"
    }

    private func presentTeamPicker() {
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
        guard preferences.hasSavedFavouriteFixtureView else {
            selectTopTeams()
            return
        }
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
        preferences.performBatchUpdate {
            preferences.fixtureAllMajorMatchesEnabled = true
            preferences.competitionFilterEnabled = false
            preferences.englishPremierLeagueTeamsOnly = true
            preferences.majorUEFAClubGamesEnabled = true
            preferences.homeNationsFilterEnabled = true
            preferences.majorTournamentsFilterEnabled = true
            preferences.showAllMatches = false
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
        withAnimation(accessibilityReduceMotion ? nil : FootballVisualStyle.easeOut) {
            coordinator.clearSaveFixtureViewPresentation()
        }
        withAnimation(.easeOut(duration: 0.2)) {
            expandedFixtureRegionID = nil
            isFixtureFavouritesMenuExpanded = false
        }
        guard hasChanges else { return }
        preferences.performBatchUpdate {
            preferences.fixtureAllMajorMatchesEnabled = false
            preferences.competitionFilterEnabled = false
            preferences.englishPremierLeagueTeamsOnly = false
            preferences.majorUEFAClubGamesEnabled = false
            preferences.homeNationsFilterEnabled = false
            preferences.majorTournamentsFilterEnabled = false
            preferences.showAllMatches = true
        }
        fixtureBrowser.configure(
            preferences: preferences.snapshot,
            resetSelectedDate: true
        )
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
        preferences.hasSavedFavouriteFixtureView = true
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
        withAnimation(accessibilityReduceMotion ? nil : FootballVisualStyle.easeOut) {
            coordinator.clearSaveFixtureViewPresentation()
        }
        withAnimation(.easeOut(duration: 0.2)) {
            expandedFixtureRegionID = nil
            isFixtureFavouritesMenuExpanded = false
        }
        guard hasChanges else { return }
        applyCustomFixtureView(
            FixtureViewOptionID.premierLeagueMatchesPresetOptionIDs,
            shouldOfferSavePrompt: false
        )
        AppMetricsService.shared.fireActivity(
            "fixture_premier_league_matches_preset",
            screen: MatchesViewMode.fixtures.rawValue,
            apiBaseURL: preferences.apiBaseURL
        )
    }

    private func selectTopTeams() {
        let hasChanges = !isTopTeamsPresetSelected
        fixturePickerDraftOptionIDs = nil
        fixturePickerBaselineOptionIDs = nil
        withAnimation(accessibilityReduceMotion ? nil : FootballVisualStyle.easeOut) {
            coordinator.clearSaveFixtureViewPresentation()
        }
        withAnimation(.easeOut(duration: 0.2)) {
            expandedFixtureRegionID = nil
            isFixtureFavouritesMenuExpanded = false
        }
        guard hasChanges else { return }
        applyCustomFixtureView(
            Set([FixtureViewOptionID.topTeamsPreset]),
            shouldOfferSavePrompt: false
        )
        AppMetricsService.shared.fireActivity(
            "fixture_top_teams_preset",
            screen: MatchesViewMode.fixtures.rawValue,
            apiBaseURL: preferences.apiBaseURL
        )
    }

    private func applyCustomFixtureView(
        _ selectedIDs: Set<String>,
        shouldOfferSavePrompt: Bool = true
    ) {
        let selectedCompetitionIDs = Set(selectedIDs.compactMap(FixtureViewOptionID.competitionStableID))
        let selectedLeagues = fixtureBrowser.competitions
            .filter { selectedCompetitionIDs.contains($0.stableID) }
            .sorted { left, right in
                if left.weight != right.weight { return left.weight > right.weight }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
            .map(\.name)
        preferences.performBatchUpdate {
            preferences.selectedFixtureViewOptionIDs = selectedIDs.sorted()
            preferences.selectedLeagues = selectedLeagues
            preferences.fixtureAllMajorMatchesEnabled = false
            preferences.competitionFilterEnabled = true
            preferences.englishPremierLeagueTeamsOnly = false
            preferences.majorUEFAClubGamesEnabled = false
            preferences.homeNationsFilterEnabled = false
            preferences.majorTournamentsFilterEnabled = false
            preferences.showAllMatches = false
        }
        fixtureBrowser.configure(
            preferences: preferences.snapshot,
            resetSelectedDate: false
        )
        if shouldOfferSavePrompt {
            updateFixtureSavePrompt()
        } else {
            coordinator.clearSaveFixtureViewPresentation()
        }
    }
}

private extension MatchesView {
    private func handleFixtureBrowserDateChange(_ dateKey: String?) {
        guard mode == .fixtures, let dateKey else { return }
        // The page-cache publisher owns regrouping when match data changes. A date
        // selection only needs to switch to the already-grouped page; comparing the
        // complete match dictionary here made every swipe scale with the full season.
        if !fixturesCoordinator.allowsMatchNavigation {
            Task { @MainActor in
                guard await fixturesCoordinator.waitUntilDateSwipeFinishes(),
                      fixtureBrowser.selectedDateKey == dateKey else {
                    return
                }
                applyFixtureBrowseGrouping(for: dateKey)
                prewarmFixtureArtworkAroundSelection()
            }
        } else {
            applyFixtureBrowseGrouping(for: dateKey)
            prewarmFixtureArtworkAroundSelection()
        }
        if isTVListingsPresented,
           !TVListingsTimeline.isAvailable(for: dateKey) {
            isTVListingsPresented = false
        }
        diagnosticLog("[MatchesView] fixture_date_change date=%@", dateKey)
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
        if fixtureBrowser.cachedMatchesByDate != fixtureBrowsePageSourceMatchesByDate {
            scheduleFixtureBrowsePageGroupings(from: fixtureBrowser.cachedMatchesByDate)
        }
        guard let selectedDateKey = fixtureBrowser.selectedDateKey else { return }
        applyFixtureBrowseGrouping(for: selectedDateKey)
    }

    private func applyFixtureBrowseGrouping(for dateKey: String) {
        let groupedDays = fixtureBrowsePageGroupedDays[dateKey] ?? []
        let groupingChanged = groupedDays != fixtureBrowseGroupedDays
        if groupingChanged {
            fixtureBrowseGroupedDays = groupedDays
        }
        refreshVisibleGroupedDays(from: groupedDays)
        guard groupingChanged else { return }
        scheduleGroupedSideEffects(for: groupedDays, immediate: false)
    }

    private func scheduleFixtureBrowsePageGroupings(
        from matchesByDate: [String: [Match]],
        force: Bool = false
    ) {
        guard mode == .fixtures else { return }
        if force {
            // Keep displayed pages while rebuilding, but leave unfinished pages
            // dirty if a date swipe cancels background grouping.
            for dateKey in matchesByDate.keys {
                fixtureBrowsePageSourceMatchesByDate.removeValue(forKey: dateKey)
                fixtureBrowseUnfilteredPageSourceMatchesByDate.removeValue(forKey: dateKey)
            }
        }
        let removedDateKeys = Set(fixtureBrowsePageSourceMatchesByDate.keys)
            .subtracting(matchesByDate.keys)
        let changedDateKeys = Set(matchesByDate.compactMap { dateKey, matches in
            fixtureBrowsePageSourceMatchesByDate[dateKey] == matches ? nil : dateKey
        })
        guard !changedDateKeys.isEmpty || !removedDateKeys.isEmpty else { return }

        let filteredMatchesToGroup = Dictionary(uniqueKeysWithValues: changedDateKeys.compactMap {
            dateKey in
            matchesByDate[dateKey].map { (dateKey, $0) }
        })
        let unfilteredMatchesToGroup = Dictionary(uniqueKeysWithValues: changedDateKeys.map {
            ($0, fixtureBrowser.cachedUnfilteredMatches(for: $0))
        })
        let selectedDateKey = fixtureBrowser.selectedDateKey
        let adjacentDateKeys = selectedDateKey.map {
            Set(FixtureBrowsePrefetchPlanner.dateKeys(
                in: fixtureBrowser.availableDays,
                centeredOn: $0,
                radius: FixtureBrowsePrefetchPlanner.surroundingDateRadius
            ))
        } ?? []
        let workPlan = FixtureBrowseGroupingWorkPlan(
            changedDateKeys: changedDateKeys,
            selectedDateKey: selectedDateKey,
            priorityDateKeys: adjacentDateKeys
        )

        fixtureBrowseGroupingTask?.cancel()
        let requestID = UUID()
        fixtureBrowseGroupingRequestID = requestID
        let snapshot = preferences.snapshot
        fixtureBrowseGroupingTask = Task { @MainActor in
            var pendingRemovedDateKeys = removedDateKeys

            if !workPlan.immediateFilteredDateKeys.isEmpty {
                let selectedFilteredMatches = filteredMatchesToGroup.filter {
                    workPlan.immediateFilteredDateKeys.contains($0.key)
                }
                // Only the filtered page is needed to replace the loading state.
                // Grouping the much larger unfiltered page here made a cached
                // eight-match page wait behind 164 matches of background work.
                let result = await matchesStore.groupFixtureBrowsePages(
                    filteredMatchesByDate: selectedFilteredMatches,
                    unfilteredMatchesByDate: selectedFilteredMatches,
                    preferences: snapshot,
                    priority: .userInitiated
                )
                guard !Task.isCancelled,
                      fixtureBrowseGroupingRequestID == requestID,
                      let result else {
                    return
                }
                guard await fixturesCoordinator.waitUntilDateSwipeFinishes() else { return }
                applyFixtureBrowsePageGrouping(
                    result,
                    filteredDateKeys: workPlan.immediateFilteredDateKeys,
                    unfilteredDateKeys: [],
                    removedDateKeys: pendingRemovedDateKeys,
                    filteredMatchesByDate: selectedFilteredMatches,
                    unfilteredMatchesByDate: [:]
                )
                pendingRemovedDateKeys = []
                diagnosticLog(
                    "[MatchesView] fixture_page_grouping_complete priority=selected dates=%d matches=%d duration_ms=%d",
                    selectedFilteredMatches.count,
                    selectedFilteredMatches.values.reduce(0) { $0 + $1.count },
                    result.durationMilliseconds
                )
                if fixtureBrowser.selectedDateKey == selectedDateKey,
                   let selectedDateKey {
                    applyFixtureBrowseGrouping(for: selectedDateKey)
                }
            }

            if !workPlan.priorityFilteredDateKeys.isEmpty {
                let adjacentFilteredMatches = filteredMatchesToGroup.filter {
                    workPlan.priorityFilteredDateKeys.contains($0.key)
                }
                let result = await matchesStore.groupFixtureBrowsePages(
                    filteredMatchesByDate: adjacentFilteredMatches,
                    unfilteredMatchesByDate: adjacentFilteredMatches,
                    preferences: snapshot,
                    priority: .userInitiated
                )
                guard !Task.isCancelled,
                      fixtureBrowseGroupingRequestID == requestID,
                      let result else {
                    return
                }
                guard await fixturesCoordinator.waitUntilDateSwipeFinishes() else { return }
                applyFixtureBrowsePageGrouping(
                    result,
                    filteredDateKeys: workPlan.priorityFilteredDateKeys,
                    unfilteredDateKeys: [],
                    removedDateKeys: pendingRemovedDateKeys,
                    filteredMatchesByDate: adjacentFilteredMatches,
                    unfilteredMatchesByDate: [:]
                )
                pendingRemovedDateKeys = []
                diagnosticLog(
                    "[MatchesView] fixture_page_grouping_complete priority=adjacent dates=%d matches=%d duration_ms=%d",
                    adjacentFilteredMatches.count,
                    adjacentFilteredMatches.values.reduce(0) { $0 + $1.count },
                    result.durationMilliseconds
                )
            }

            if workPlan.hasDeferredWork {
                guard await InteractiveMotionGate.shared.waitUntilSustainedIdle(
                    operation: "fixture_browse_background_grouping",
                    quietPeriodMilliseconds: 1_000
                ) else { return }
                guard !Task.isCancelled,
                      fixtureBrowseGroupingRequestID == requestID else {
                    return
                }
                let backgroundFilteredMatches = filteredMatchesToGroup.filter {
                    workPlan.deferredFilteredDateKeys.contains($0.key)
                }
                let backgroundUnfilteredMatches = unfilteredMatchesToGroup.filter {
                    workPlan.deferredUnfilteredDateKeys.contains($0.key)
                }
                let result = await matchesStore.groupFixtureBrowsePages(
                    filteredMatchesByDate: backgroundFilteredMatches,
                    unfilteredMatchesByDate: backgroundUnfilteredMatches,
                    preferences: snapshot,
                    priority: .background
                )
                guard !Task.isCancelled,
                      fixtureBrowseGroupingRequestID == requestID,
                      let result else {
                    return
                }
                guard await fixturesCoordinator.waitUntilDateSwipeFinishes() else { return }
                applyFixtureBrowsePageGrouping(
                    result,
                    filteredDateKeys: workPlan.deferredFilteredDateKeys,
                    unfilteredDateKeys: workPlan.deferredUnfilteredDateKeys,
                    removedDateKeys: pendingRemovedDateKeys,
                    filteredMatchesByDate: backgroundFilteredMatches,
                    unfilteredMatchesByDate: backgroundUnfilteredMatches
                )
                pendingRemovedDateKeys = []
                if result.durationMilliseconds >= 50 {
                    diagnosticLog(
                        "[MatchesView] fixture_page_grouping_complete priority=background filtered_dates=%d filtered_matches=%d unfiltered_dates=%d unfiltered_matches=%d duration_ms=%d",
                        backgroundFilteredMatches.count,
                        backgroundFilteredMatches.values.reduce(0) { $0 + $1.count },
                        backgroundUnfilteredMatches.count,
                        backgroundUnfilteredMatches.values.reduce(0) { $0 + $1.count },
                        result.durationMilliseconds
                    )
                }
            }

            if !pendingRemovedDateKeys.isEmpty {
                applyFixtureBrowsePageGrouping(
                    FixtureBrowsePageGroupingResult(
                        filtered: [:],
                        unfiltered: [:],
                        durationMilliseconds: 0
                    ),
                    filteredDateKeys: [],
                    unfilteredDateKeys: [],
                    removedDateKeys: pendingRemovedDateKeys,
                    filteredMatchesByDate: [:],
                    unfilteredMatchesByDate: [:]
                )
            }

            if let selectedDateKey = fixtureBrowser.selectedDateKey {
                applyFixtureBrowseGrouping(for: selectedDateKey)
            }
            fixtureBrowseGroupingTask = nil
        }
    }

    private func applyFixtureBrowsePageGrouping(
        _ result: FixtureBrowsePageGroupingResult,
        filteredDateKeys: Set<String>,
        unfilteredDateKeys: Set<String>,
        removedDateKeys: Set<String>,
        filteredMatchesByDate: [String: [Match]],
        unfilteredMatchesByDate: [String: [Match]]
    ) {
        var nextFilteredSources = fixtureBrowsePageSourceMatchesByDate
        var nextUnfilteredSources = fixtureBrowseUnfilteredPageSourceMatchesByDate
        var nextFilteredPages = fixtureBrowsePageGroupedDays
        var nextUnfilteredPages = fixtureBrowseUnfilteredPageGroupedDays

        for dateKey in removedDateKeys {
            nextFilteredSources.removeValue(forKey: dateKey)
            nextUnfilteredSources.removeValue(forKey: dateKey)
            nextFilteredPages.removeValue(forKey: dateKey)
            nextUnfilteredPages.removeValue(forKey: dateKey)
        }
        for dateKey in filteredDateKeys {
            nextFilteredSources[dateKey] = filteredMatchesByDate[dateKey]
            if let grouped = result.filtered[dateKey] {
                nextFilteredPages[dateKey] = grouped
            } else {
                nextFilteredPages.removeValue(forKey: dateKey)
            }
        }
        for dateKey in unfilteredDateKeys {
            nextUnfilteredSources[dateKey] = unfilteredMatchesByDate[dateKey]
            if let grouped = result.unfiltered[dateKey] {
                nextUnfilteredPages[dateKey] = grouped
            } else {
                nextUnfilteredPages.removeValue(forKey: dateKey)
            }
        }

        fixtureBrowsePageSourceMatchesByDate = nextFilteredSources
        fixtureBrowseUnfilteredPageSourceMatchesByDate = nextUnfilteredSources
        if fixtureBrowsePageGroupedDays != nextFilteredPages {
            let changedPageKeys = Set(fixtureBrowsePageGroupedDays.keys)
                .union(nextFilteredPages.keys)
                .filter { fixtureBrowsePageGroupedDays[$0] != nextFilteredPages[$0] }
            for dateKey in changedPageKeys {
                fixtureBrowsePageRevisions[dateKey, default: 0] &+= 1
            }
            fixtureBrowsePageGroupedDays = nextFilteredPages
        }
        if fixtureBrowseUnfilteredPageGroupedDays != nextUnfilteredPages {
            fixtureBrowseUnfilteredPageGroupedDays = nextUnfilteredPages
        }
        prewarmFixtureArtworkAroundSelection()
    }

    private func prewarmFixtureArtworkAroundSelection() {
        guard let selectedDateKey = fixtureBrowser.selectedDateKey else { return }
        let candidateDateKeys = FixtureBrowsePrefetchPlanner.dateKeys(
            in: fixtureBrowser.availableDays,
            centeredOn: selectedDateKey,
            radius: 2
        )
        prewarmFixtureArtwork(for: candidateDateKeys)
    }

    private func prewarmFixtureArtwork(for candidateDateKeys: [String]) {
        let dateKeysToPrepare = candidateDateKeys.filter {
            fixtureBrowsePageSourceMatchesByDate[$0] != nil &&
                fixtureArtworkPreparation.markForPreparation($0)
        }
        guard !dateKeysToPrepare.isEmpty else { return }

        let matches = dateKeysToPrepare.flatMap {
            fixtureBrowsePageSourceMatchesByDate[$0] ?? []
        }
        LogoResolver.shared.prepareImagesForDisplay(for: matches)
        TvLogoResolver.shared.prepareImagesForDisplay(
            for: matches.flatMap(\.tvChannels).map(\.name)
        )
        CompetitionBadgeCache.shared.prepareImagesForDisplay(for: matches)
    }

    private func cancelFixtureBrowseGrouping() {
        fixtureBrowseGroupingTask?.cancel()
        fixtureBrowseGroupingTask = nil
        fixtureBrowseGroupingRequestID = UUID()
    }

    private func runActivationIfNeeded(logEvent: String) {
        guard !didRunActivationForVisibleCycle else { return }
        didRunActivationForVisibleCycle = true
        if mode == .fixtures {
            fixtureBrowser.refreshToday()
            matchesStore.setFixtureBrowserLiveRefreshActive(true)
        }
        matchesStore.setModeVisibility(mode, isVisible: true)
        let snapshot = showAllMatches ? preferences.unfilteredSnapshot : preferences.snapshot
        #if DEBUG
        diagnosticLog("[MatchesView] %@ mode=%@ selected=%d snapshot=%@", logEvent, mode.rawValue, isSelected, debugSnapshotSummary(snapshot))
        #endif
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
                diagnosticLog("Missing logo audit post failed error=%@", String(describing: error))
            }
        }
    }
}

enum FixtureCompetitionRenderWindow {
    static let initialLimit = 12
    static let revealIncrement = 20

    static func displayedCount(totalCount: Int, configuredLimit: Int?) -> Int {
        min(max(0, totalCount), max(0, configuredLimit ?? initialLimit))
    }

    static func nextLimit(displayedCount: Int, totalCount: Int) -> Int {
        min(max(0, totalCount), max(0, displayedCount) + revealIncrement)
    }
}

struct FixtureBrowseGroupingWorkPlan {
    let immediateFilteredDateKeys: Set<String>
    let priorityFilteredDateKeys: Set<String>
    let deferredFilteredDateKeys: Set<String>
    let deferredUnfilteredDateKeys: Set<String>

    init(
        changedDateKeys: Set<String>,
        selectedDateKey: String?,
        priorityDateKeys: Set<String>
    ) {
        if let selectedDateKey, changedDateKeys.contains(selectedDateKey) {
            immediateFilteredDateKeys = [selectedDateKey]
        } else {
            immediateFilteredDateKeys = []
        }
        priorityFilteredDateKeys = changedDateKeys
            .intersection(priorityDateKeys)
            .subtracting(immediateFilteredDateKeys)
        deferredFilteredDateKeys = changedDateKeys
            .subtracting(immediateFilteredDateKeys)
            .subtracting(priorityFilteredDateKeys)
        deferredUnfilteredDateKeys = changedDateKeys
    }

    var hasDeferredWork: Bool {
        !deferredFilteredDateKeys.isEmpty || !deferredUnfilteredDateKeys.isEmpty
    }
}

struct FixtureCompetitionRegion: Identifiable, Hashable {
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
    enum SelectionState: Equatable {
        case notSelected
        case includedByPreset
        case selected

        var accessibilityValue: String {
            switch self {
            case .notSelected: return "Not selected"
            case .includedByPreset: return "Included by Top teams"
            case .selected: return "Selected"
            }
        }
    }

    let selectionState: SelectionState

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(selectionState == .notSelected ? Color.clear : Color.accentColor)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(
                        selectionState == .notSelected
                            ? Color.secondary.opacity(0.8)
                            : Color.accentColor,
                        lineWidth: 1.5
                    )
            }
            .overlay {
                if selectionState != .notSelected {
                    Image(systemName: selectionState == .selected ? "checkmark" : "minus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
    }
}

struct FixtureViewSpecialOptionIcon: View {
    let option: FixtureViewSpecialOption
    let size: CGFloat

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
    var systemSymbolSize: CGFloat = 22
    var systemSymbolTint: Color?
    var showsPersistentBorder = false
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    isExpanded
                        ? Color.accentColor.opacity(0.18)
                        : isSelected ? Color.accentColor.opacity(0.08) : Color.clear
                )

            if let systemSymbol {
                Image(systemName: systemSymbol)
                    .font(.system(size: systemSymbolSize, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : systemSymbolTint ?? Color.primary)
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
            if systemSymbol != nil {
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
            color: isExpanded ? Color.accentColor.opacity(0.30) : .clear,
            radius: 8
        )
        .animation(accessibilityReduceMotion ? nil : FootballVisualStyle.easeOut, value: isExpanded)
        .animation(accessibilityReduceMotion ? nil : FootballVisualStyle.easeOut, value: isSelected)
        .contentShape(Circle())
    }
}

private struct FixtureOptionsGlass: ViewModifier {
    let cornerRadius: CGFloat
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(FootballVisualStyle.elevatedSurface, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(interactive), in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
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

struct FixtureRegionFlagIcon: View {
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

struct LeagueBadgeImage: View {
    let competitionID: String?
    let competitionName: String
    let size: CGFloat
    @State private var badgeCacheVersion = 0

    var body: some View {
        let _ = badgeCacheVersion
        Group {
            if let assetName = BundledCompetitionLogo.assetName(
                competitionID: competitionID,
                competitionName: competitionName
            ), let image = CompetitionBadgeCache.shared.bundledImage(assetName: assetName) {
                if assetName == "CompetitionLogo7" {
                    Image(uiImage: image.withRenderingMode(.alwaysTemplate))
                        .resizable()
                        .foregroundStyle(Color.white.opacity(0.94))
                        .scaledToFit()
                } else {
                    Image(uiImage: image)
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
    let isEnabled: Bool
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var hasAppeared = false

    func body(content: Content) -> some View {
        content
            .opacity(hasAppeared || !isEnabled ? 1 : 0)
            .offset(y: hasAppeared || !isEnabled || accessibilityReduceMotion ? 0 : 10)
            .onAppear {
                guard isEnabled, !hasAppeared else { return }
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

@MainActor
private final class FixtureArtworkPreparationState: ObservableObject {
    private var preparedDateKeys: Set<String> = []

    func markForPreparation(_ dateKey: String) -> Bool {
        preparedDateKeys.insert(dateKey).inserted
    }

    func reset() {
        preparedDateKeys.removeAll(keepingCapacity: true)
    }
}

private final class FixtureSwipeFrameMonitor: NSObject, ObservableObject {
    struct StallSample {
        let elapsedMilliseconds: Int
        let frameGapMilliseconds: Int
    }

    struct Summary {
        let maximumFrameGapMilliseconds: Int
        let estimatedDroppedFrames: Int
        let renderedFrameCount: Int
        let stallSamples: [StallSample]
    }

    private var displayLink: CADisplayLink?
    private var previousTimestamp: CFTimeInterval?
    private var maximumFrameGap: CFTimeInterval = 0
    private var estimatedDroppedFrames = 0
    private var startedAt: CFTimeInterval?
    private var renderedFrameCount = 0
    private var stallSamples: [StallSample] = []

    func start() {
        stopWithoutSummary()
        let displayLink = CADisplayLink(target: self, selector: #selector(frameDidRender(_:)))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
        startedAt = CACurrentMediaTime()
    }

    func stop() -> Summary {
        let summary = Summary(
            maximumFrameGapMilliseconds: Int((maximumFrameGap * 1_000).rounded()),
            estimatedDroppedFrames: estimatedDroppedFrames,
            renderedFrameCount: renderedFrameCount,
            stallSamples: stallSamples
        )
        stopWithoutSummary()
        return summary
    }

    @objc
    private func frameDidRender(_ displayLink: CADisplayLink) {
        defer { previousTimestamp = displayLink.timestamp }
        guard let previousTimestamp else { return }
        renderedFrameCount += 1
        let frameGap = displayLink.timestamp - previousTimestamp
        maximumFrameGap = max(maximumFrameGap, frameGap)
        let expectedFrameDuration = max(
            displayLink.targetTimestamp - displayLink.timestamp,
            1.0 / 120.0
        )
        estimatedDroppedFrames += max(0, Int((frameGap / expectedFrameDuration).rounded()) - 1)
        if frameGap >= max(expectedFrameDuration * 1.5, 0.025),
           stallSamples.count < 8,
           let startedAt {
            stallSamples.append(
                StallSample(
                    elapsedMilliseconds: Int(((displayLink.timestamp - startedAt) * 1_000).rounded()),
                    frameGapMilliseconds: Int((frameGap * 1_000).rounded())
                )
            )
        }
    }

    private func stopWithoutSummary() {
        displayLink?.invalidate()
        displayLink = nil
        previousTimestamp = nil
        maximumFrameGap = 0
        estimatedDroppedFrames = 0
        startedAt = nil
        renderedFrameCount = 0
        stallSamples.removeAll(keepingCapacity: true)
    }
}

/// Owns high-frequency drag state so a swipe doesn't invalidate the entire fixtures screen.
/// Adjacent pages stay mounted so the commit animation only translates prepared views;
/// data selection and its wider state updates wait until the destination reaches the viewport.
private struct StableFixtureDatePage<Content: View>: View, Equatable {
    let dateKey: String
    let revision: UInt
    let freezesContent: Bool
    let content: Content

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.freezesContent && rhs.freezesContent &&
            lhs.dateKey == rhs.dateKey && lhs.revision == rhs.revision
    }

    var body: some View {
        content
    }
}

private struct FixtureDatePageDescriptor: Identifiable {
    let dateKey: String?
    let slot: String
    let revision: UInt
    let isCurrent: Bool

    var id: String { dateKey ?? "empty:\(slot)" }
}

private struct FixtureDatePagingContainer<Content: View>: View {
    let containerWidth: CGFloat
    let currentDateKey: String?
    let previousDateKey: String?
    let nextDateKey: String?
    let previousPageIsReady: Bool
    let nextPageIsReady: Bool
    let previousPageMatchCount: Int
    let nextPageMatchCount: Int
    let previousPageRevision: UInt
    let currentPageRevision: UInt
    let nextPageRevision: UInt
    let isSwipeEnabled: Bool
    let reduceMotion: Bool
    let onSwipeProgressChanged: (CGFloat) -> Void
    let onSwipeSelectionSettled: (String) -> Void
    let onSelect: (String) -> Void
    let onSwipeInteractionChanged: (Bool) -> Void
    private let content: (String?) -> Content

    @StateObject private var frameMonitor = FixtureSwipeFrameMonitor()
    @State private var dragOffset: CGFloat = 0
    @State private var dragAxis: DragAxis?
    @State private var isCommittingSwipe = false
    @State private var commitUnlockTask: Task<Void, Never>?
    @State private var animationCompletionFallbackTask: Task<Void, Never>?
    @State private var swipeCommitID = UUID()
    @State private var isAwaitingAnimationCompletion = false
    @State private var isSuppressingMatchTaps = false
    @State private var swipeStartedAt: Date?
    @State private var swipeTargetDateKey: String?
    @State private var swipeDirection: Int?

    private enum DragAxis {
        case horizontal
        case vertical
    }

    init(
        containerWidth: CGFloat,
        currentDateKey: String?,
        previousDateKey: String?,
        nextDateKey: String?,
        previousPageIsReady: Bool,
        nextPageIsReady: Bool,
        previousPageMatchCount: Int,
        nextPageMatchCount: Int,
        previousPageRevision: UInt,
        currentPageRevision: UInt,
        nextPageRevision: UInt,
        isSwipeEnabled: Bool,
        reduceMotion: Bool,
        onSwipeProgressChanged: @escaping (CGFloat) -> Void,
        onSwipeSelectionSettled: @escaping (String) -> Void,
        onSelect: @escaping (String) -> Void,
        onSwipeInteractionChanged: @escaping (Bool) -> Void,
        @ViewBuilder content: @escaping (String?) -> Content
    ) {
        self.containerWidth = containerWidth
        self.currentDateKey = currentDateKey
        self.previousDateKey = previousDateKey
        self.nextDateKey = nextDateKey
        self.previousPageIsReady = previousPageIsReady
        self.nextPageIsReady = nextPageIsReady
        self.previousPageMatchCount = previousPageMatchCount
        self.nextPageMatchCount = nextPageMatchCount
        self.previousPageRevision = previousPageRevision
        self.currentPageRevision = currentPageRevision
        self.nextPageRevision = nextPageRevision
        self.isSwipeEnabled = isSwipeEnabled
        self.reduceMotion = reduceMotion
        self.onSwipeProgressChanged = onSwipeProgressChanged
        self.onSwipeSelectionSettled = onSwipeSelectionSettled
        self.onSelect = onSelect
        self.onSwipeInteractionChanged = onSwipeInteractionChanged
        self.content = content
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                ForEach(pageDescriptors) { descriptor in
                    page(for: descriptor)
                        .accessibilityHidden(!descriptor.isCurrent)
                }
            }
            .frame(width: containerWidth * 3)
            .offset(x: dragOffset)
        }
        .allowsHitTesting(!isSuppressingMatchTaps)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(FootballVisualStyle.pageBackground)
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(swipeGesture)
        .onChange(of: currentDateKey) { _, dateKey in
            if isCommittingSwipe, isAwaitingAnimationCompletion {
                performanceDiagnosticLogAsync(
                    "[FixtureSwipe] external_selection_recovered_pending_animation " +
                    "date=\(dateKey ?? "nil")"
                )
                resetTransition()
            } else if !isCommittingSwipe {
                resetTransition()
            }
        }
        .onChange(of: isSwipeEnabled) { _, enabled in
            if !enabled {
                resetTransition()
            }
        }
        .onDisappear {
            commitUnlockTask?.cancel()
            animationCompletionFallbackTask?.cancel()
            animationCompletionFallbackTask = nil
            isAwaitingAnimationCompletion = false
            swipeCommitID = UUID()
            logInterruptedSwipe(reason: "pager_disappeared")
            _ = frameMonitor.stop()
            onSwipeProgressChanged(0)
            performanceDiagnosticSetBreadcrumb(category: "fixture_swipe", value: nil)
            releaseMatchTapSuppression()
        }
    }

    private var canBeginSwipe: Bool {
        isSwipeEnabled && !isCommittingSwipe
    }

    private func page(
        for descriptor: FixtureDatePageDescriptor
    ) -> some View {
        StableFixtureDatePage(
            dateKey: descriptor.id,
            revision: descriptor.revision,
            freezesContent: isSuppressingMatchTaps || isCommittingSwipe,
            content: content(descriptor.dateKey)
        )
            .equatable()
            .frame(width: containerWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .environment(
                \.teamStadiumPhotoPrewarmingEnabled,
                false
            )
    }

    private var pageDescriptors: [FixtureDatePageDescriptor] {
        [
            FixtureDatePageDescriptor(
                dateKey: previousDateKey,
                slot: "previous",
                revision: previousPageRevision,
                isCurrent: false
            ),
            FixtureDatePageDescriptor(
                dateKey: currentDateKey,
                slot: "current",
                revision: currentPageRevision,
                isCurrent: true
            ),
            FixtureDatePageDescriptor(
                dateKey: nextDateKey,
                slot: "next",
                revision: nextPageRevision,
                isCurrent: false
            ),
        ]
    }

    private var datePageAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .timingCurve(0.22, 1, 0.36, 1, duration: 0.22)
                .logicallyComplete(after: 0.22)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard canBeginSwipe else { return }

                if dragAxis == nil {
                    let horizontalDistance = abs(value.translation.width)
                    let verticalDistance = abs(value.translation.height)
                    guard max(horizontalDistance, verticalDistance) >= 10 else { return }
                    let isHorizontal = FixtureBrowseSelectionResolver.hasHorizontalSwipeIntent(
                        translationWidth: value.translation.width,
                        translationHeight: value.translation.height
                    )
                    dragAxis = isHorizontal ? .horizontal : .vertical
                    if isHorizontal {
                        beginMatchTapSuppression()
                        beginSwipeDiagnostics(translationWidth: value.translation.width)
                    }
                }

                guard dragAxis == .horizontal else { return }
                let hasAdjacentDate = value.translation.width < 0
                    ? nextDateKey != nil
                    : previousDateKey != nil
                let maximumOffset = reduceMotion ? CGFloat(8) : containerWidth
                let resistance: CGFloat = hasAdjacentDate ? 1 : 0.08
                let nextDragOffset = min(
                    maximumOffset,
                    max(-maximumOffset, value.translation.width * resistance)
                )
                dragOffset = nextDragOffset
                onSwipeProgressChanged(nextDragOffset / containerWidth)
            }
            .onEnded { value in
                guard canBeginSwipe else { return }
                guard dragAxis == .horizontal else {
                    dragAxis = nil
                    releaseMatchTapSuppression()
                    return
                }
                guard
                      let direction = FixtureBrowseSelectionResolver.swipeDateOffset(
                        translationWidth: value.translation.width,
                        translationHeight: value.translation.height,
                        predictedEndTranslationWidth: value.predictedEndTranslation.width,
                        containerWidth: containerWidth
                      ),
                      direction == swipeDirection,
                      let targetDateKey = swipeTargetDateKey else {
                    cancelSwipe(reason: "threshold_or_missing_page")
                    dragAxis = nil
                    releaseMatchTapSuppression()
                    return
                }
                isCommittingSwipe = true
                dragAxis = nil
                completeSwipe(to: targetDateKey, direction: direction)
            }
    }

    private func cancelSwipe(reason: String) {
        logInterruptedSwipe(reason: reason)
        withAnimation(.easeOut(duration: reduceMotion ? 0.08 : 0.16)) {
            dragOffset = 0
            onSwipeProgressChanged(0)
        }
        performanceDiagnosticSetBreadcrumb(category: "fixture_swipe", value: nil)
    }

    private func beginMatchTapSuppression() {
        guard !isSuppressingMatchTaps else { return }
        isSuppressingMatchTaps = true
        InteractiveMotionGate.shared.begin()
        onSwipeInteractionChanged(true)
    }

    private func releaseMatchTapSuppression() {
        guard isSuppressingMatchTaps else { return }
        onSwipeInteractionChanged(false)
        InteractiveMotionGate.shared.end()
        isSuppressingMatchTaps = false
    }

    private func completeSwipe(to targetDateKey: String, direction: Int) {
        UISelectionFeedbackGenerator().selectionChanged()
        let interactionDurationMilliseconds = swipeStartedAt.map {
            Int(Date().timeIntervalSince($0) * 1000)
        } ?? 0
        performanceDiagnosticLogAsync(
            "[FixtureSwipe] commit source=\(currentDateKey ?? "nil") target=\(targetDateKey) " +
            "direction=\(direction > 0 ? "next" : "previous") " +
            "interaction_ms=\(interactionDurationMilliseconds) " +
            "ready=\(pageIsReady(direction: direction) ? 1 : 0) " +
            "matches=\(pageMatchCount(direction: direction))"
        )
        PerformanceSignposter.matches.emitEvent("FixtureSwipeCommit")
        performanceDiagnosticSetBreadcrumb(
            category: "fixture_swipe",
            value: "commit target=\(targetDateKey)"
        )
        let gestureFrameSummary = frameMonitor.stop()
        frameMonitor.start()
        performanceDiagnosticLogAsync(
            "[FixtureSwipe] gesture_frames target=\(targetDateKey) " +
            "max_frame_gap_ms=\(gestureFrameSummary.maximumFrameGapMilliseconds) " +
            "dropped_frames=\(gestureFrameSummary.estimatedDroppedFrames) " +
            frameDiagnostics(gestureFrameSummary)
        )
        clearSwipeDiagnostics()

        let transitionDurationMilliseconds = reduceMotion ? 0 : 220
        performanceDiagnosticSetBreadcrumb(
            category: "fixture_swipe",
            value: "animation target=\(targetDateKey)"
        )
        commitUnlockTask?.cancel()
        commitUnlockTask = nil
        animationCompletionFallbackTask?.cancel()
        animationCompletionFallbackTask = nil
        let commitID = UUID()
        swipeCommitID = commitID
        isAwaitingAnimationCompletion = true
        let animationStartedAt = ProcessInfo.processInfo.systemUptime

        let finishAnimation = {
            guard isCommittingSwipe,
                  swipeCommitID == commitID,
                  isAwaitingAnimationCompletion else {
                return
            }
            isAwaitingAnimationCompletion = false
            animationCompletionFallbackTask?.cancel()
            animationCompletionFallbackTask = nil
            let animationWaitMilliseconds = Int(
                ((ProcessInfo.processInfo.systemUptime - animationStartedAt) * 1_000).rounded()
            )
            let animationFrameSummary = frameMonitor.stop()
            performanceDiagnosticLogAsync(
                "[FixtureSwipe] animation_frames target=\(targetDateKey) " +
                "expected_ms=\(transitionDurationMilliseconds) elapsed_ms=\(animationWaitMilliseconds) " +
                "max_frame_gap_ms=\(animationFrameSummary.maximumFrameGapMilliseconds) " +
                "dropped_frames=\(animationFrameSummary.estimatedDroppedFrames) " +
                frameDiagnostics(animationFrameSummary)
            )
            frameMonitor.start()
            performanceDiagnosticSetBreadcrumb(
                category: "fixture_swipe",
                value: "selection target=\(targetDateKey)"
            )
            finishSwipeSelection(targetDateKey: targetDateKey, commitID: commitID)
        }

        if reduceMotion {
            dragOffset = -CGFloat(direction) * containerWidth
            onSwipeProgressChanged(-CGFloat(direction))
            finishAnimation()
        } else {
            // SwiftUI animation completions can be withheld if an animatable value is
            // replaced while the transaction is in flight. Guarantee that the pager
            // cannot remain permanently locked if that happens.
            animationCompletionFallbackTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled,
                      isCommittingSwipe,
                      swipeCommitID == commitID,
                      isAwaitingAnimationCompletion else {
                    return
                }
                let elapsedMilliseconds = Int(
                    ((ProcessInfo.processInfo.systemUptime - animationStartedAt) * 1_000).rounded()
                )
                performanceDiagnosticLogAsync(
                    "[FixtureSwipe] animation_completion_fallback target=\(targetDateKey) " +
                    "elapsed_ms=\(elapsedMilliseconds)"
                )
                finishAnimation()
            }
            // Complete from SwiftUI's animation transaction rather than a wall-clock
            // sleep. If the main run loop is briefly delayed, this avoids resetting
            // the carousel while its previous animation is still in flight.
            withAnimation(
                datePageAnimation,
                completionCriteria: .logicallyComplete
            ) {
                dragOffset = -CGFloat(direction) * containerWidth
                onSwipeProgressChanged(-CGFloat(direction))
            } completion: {
                finishAnimation()
            }
        }
    }

    private func finishSwipeSelection(targetDateKey: String, commitID: UUID) {
        guard isCommittingSwipe, swipeCommitID == commitID else { return }
        commitUnlockTask = Task { @MainActor in
            guard swipeCommitID == commitID else { return }
            let selectionStartedAt = ProcessInfo.processInfo.systemUptime
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                onSelect(targetDateKey)
                onSwipeSelectionSettled(targetDateKey)
                dragOffset = 0
            }
            let selectionDurationMilliseconds = Int(
                ((ProcessInfo.processInfo.systemUptime - selectionStartedAt) * 1_000).rounded()
            )
            performanceDiagnosticLogAsync(
                "[FixtureSwipe] selection target=\(targetDateKey) " +
                "duration_ms=\(selectionDurationMilliseconds)"
            )
            let selectionSettleStartedAt = ProcessInfo.processInfo.systemUptime
            await Task.yield()
            guard !Task.isCancelled, swipeCommitID == commitID else { return }
            let selectionSettleMilliseconds = Int(
                ((ProcessInfo.processInfo.systemUptime - selectionSettleStartedAt) * 1_000).rounded()
            )
            let selectionFrameSummary = frameMonitor.stop()
            performanceDiagnosticLogAsync(
                "[FixtureSwipe] selection_frames target=\(targetDateKey) " +
                "settle_ms=\(selectionSettleMilliseconds) " +
                "max_frame_gap_ms=\(selectionFrameSummary.maximumFrameGapMilliseconds) " +
                "dropped_frames=\(selectionFrameSummary.estimatedDroppedFrames) " +
                frameDiagnostics(selectionFrameSummary)
            )
            performanceDiagnosticLogAsync("[FixtureSwipe] complete target=\(targetDateKey)")
            performanceDiagnosticSetBreadcrumb(category: "fixture_swipe", value: nil)
            PerformanceSignposter.matches.emitEvent("FixtureSwipeComplete")
            releaseMatchTapSuppression()
            isCommittingSwipe = false
            commitUnlockTask = nil
        }
    }

    private func beginSwipeDiagnostics(translationWidth: CGFloat) {
        let direction = translationWidth < 0 ? 1 : -1
        let targetDateKey = direction > 0 ? nextDateKey : previousDateKey
        swipeStartedAt = Date()
        swipeTargetDateKey = targetDateKey
        swipeDirection = direction
        frameMonitor.start()
        PerformanceSignposter.matches.emitEvent("FixtureSwipeBegin")
        performanceDiagnosticLogAsync(
            "[FixtureSwipe] begin source=\(currentDateKey ?? "nil") " +
            "target=\(targetDateKey ?? "nil") direction=\(direction > 0 ? "next" : "previous") " +
            "ready=\(pageIsReady(direction: direction) ? 1 : 0) " +
            "matches=\(pageMatchCount(direction: direction)) width=\(Int(containerWidth))"
        )
        performanceDiagnosticSetBreadcrumb(
            category: "fixture_swipe",
            value: "drag target=\(targetDateKey ?? "nil")"
        )
    }

    private func logInterruptedSwipe(reason: String) {
        guard swipeStartedAt != nil else { return }
        let frameSummary = frameMonitor.stop()
        let durationMilliseconds = swipeStartedAt.map {
            Int(Date().timeIntervalSince($0) * 1000)
        } ?? 0
        performanceDiagnosticLogAsync(
            "[FixtureSwipe] cancel source=\(currentDateKey ?? "nil") " +
            "target=\(swipeTargetDateKeyForLog) reason=\(reason) " +
            "interaction_ms=\(durationMilliseconds) " +
            "max_frame_gap_ms=\(frameSummary.maximumFrameGapMilliseconds) " +
            "dropped_frames=\(frameSummary.estimatedDroppedFrames) " +
            frameDiagnostics(frameSummary)
        )
        PerformanceSignposter.matches.emitEvent("FixtureSwipeCancel")
        clearSwipeDiagnostics()
    }

    private var swipeTargetDateKeyForLog: String {
        swipeTargetDateKey ?? "nil"
    }

    private func frameDiagnostics(_ summary: FixtureSwipeFrameMonitor.Summary) -> String {
        let stalls = summary.stallSamples.map {
            "+\($0.elapsedMilliseconds):\($0.frameGapMilliseconds)"
        }.joined(separator: ",")
        return "rendered_frames=\(summary.renderedFrameCount) stalls=\(stalls.isEmpty ? "none" : stalls)"
    }

    private func pageIsReady(direction: Int) -> Bool {
        direction > 0 ? nextPageIsReady : previousPageIsReady
    }

    private func pageMatchCount(direction: Int) -> Int {
        direction > 0 ? nextPageMatchCount : previousPageMatchCount
    }

    private func clearSwipeDiagnostics() {
        swipeStartedAt = nil
        swipeTargetDateKey = nil
        swipeDirection = nil
    }

    private func resetTransition() {
        commitUnlockTask?.cancel()
        commitUnlockTask = nil
        animationCompletionFallbackTask?.cancel()
        animationCompletionFallbackTask = nil
        isAwaitingAnimationCompletion = false
        swipeCommitID = UUID()
        _ = frameMonitor.stop()
        onSwipeProgressChanged(0)
        performanceDiagnosticSetBreadcrumb(category: "fixture_swipe", value: nil)
        isCommittingSwipe = false
        dragAxis = nil
        clearSwipeDiagnostics()
        releaseMatchTapSuppression()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dragOffset = 0
        }
    }
}

@MainActor
@Observable
private final class FixtureDateCarouselState {
    var position = ScrollPosition(idType: String.self)
    private(set) var swipeProgress: CGFloat = 0
    private var centeredDateKey: String?

    func updateSwipeProgress(_ progress: CGFloat) {
        let clampedProgress = min(1, max(-1, progress))
        guard abs(swipeProgress - clampedProgress) > 0.0001 else { return }
        swipeProgress = clampedProgress
    }

    func settleOnSelection(_ dateKey: String) {
        centeredDateKey = dateKey
        position.scrollTo(id: dateKey, anchor: .center)
        swipeProgress = 0
    }

    func centerOnSelection(_ dateKey: String) {
        guard centeredDateKey != dateKey else { return }
        centeredDateKey = dateKey
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            position.scrollTo(id: dateKey, anchor: .center)
        }
    }
}

/// Isolates high-frequency swipe progress from the carousel's date/tile builder.
/// Only this transform modifier is invalidated as the user's finger moves.
private struct FixtureDateCarouselMotionModifier: ViewModifier {
    let state: FixtureDateCarouselState
    let dateTileStride: CGFloat

    func body(content: Content) -> some View {
        content.offset(x: state.swipeProgress * dateTileStride)
    }
}

private struct FixtureDateCarousel: View {
    let state: FixtureDateCarouselState
    let availableDays: [FixtureCalendarDay]
    let selectedDateKey: String?
    let todayDateKey: String
    let hasLoadedCalendar: Bool
    let errorMessage: String?
    let height: CGFloat
    let onSelect: (String) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        @Bindable var state = state

        Group {
            if availableDays.isEmpty {
                HStack(spacing: 8) {
                    if !hasLoadedCalendar && errorMessage == nil {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(
                        hasLoadedCalendar
                            ? "No match dates available"
                            : errorMessage == nil
                                ? "Loading match dates"
                                : "Match-date browsing unavailable"
                    )
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(height: height)
                .padding(.horizontal, 16)
            } else {
                ZStack {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 10) {
                            ForEach(availableDays) { day in
                                let selected = selectedDateKey == day.date
                                let presentation = FixtureDateCarouselLabelCache.shared.presentation(
                                    for: day.date
                                )
                                Button {
                                    onSelect(day.date)
                                } label: {
                                    FixtureDateCarouselTile(
                                        weekdayText: presentation.weekdayText,
                                        dayText: presentation.dayText,
                                        accessibilityDate: presentation.accessibilityDate,
                                        matchCount: day.matchCount,
                                        isSelected: selected,
                                        isToday: day.date == todayDateKey
                                    )
                                }
                                .id(day.date)
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("fixtureDate-\(day.date)")
                                .accessibilityAddTraits(selected ? .isSelected : [])
                            }
                        }
                        .scrollTargetLayout()
                        .modifier(
                            FixtureDateCarouselMotionModifier(
                                state: state,
                                dateTileStride: dateTileStride
                            )
                        )
                    }
                    // Symmetric margins keep the selected tile at the physical centre.
                    .contentMargins(
                        .horizontal,
                        12,
                        for: .scrollContent
                    )
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                    .scrollPosition($state.position, anchor: .center)
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
                    .frame(height: height)
                    .onChange(of: selectedDateKey, initial: true) { _, dateKey in
                        guard let dateKey else { return }
                        state.centerOnSelection(dateKey)
                    }
                }
                .frame(height: height)
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

    private var dateTileStride: CGFloat {
        (dynamicTypeSize.isAccessibilitySize ? 132 : 78) + 10
    }

}

private struct FixtureCurrentDateIcon: View {
    let dateKey: String

    private var dayText: String {
        let components = dateKey.split(separator: "-")
        guard let day = components.last.flatMap({ Int($0) }) else { return "–" }
        return String(day)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .stroke(Color.accentColor, lineWidth: 2)
                .frame(width: 25, height: 23)
                .offset(y: 1.5)

            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 23, height: 2)
                .offset(y: -5)

            HStack(spacing: 10) {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 2.5, height: 6)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 2.5, height: 6)
            }
            .offset(y: -10.5)

            Text(dayText)
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.accentColor)
                .offset(y: 3)
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}

@MainActor
private final class FixtureDateCarouselLabelCache {
    struct Presentation {
        let weekdayText: String
        let dayText: String
        let accessibilityDate: String
    }

    static let shared = FixtureDateCarouselLabelCache()

    private var presentationsByDateKey: [String: Presentation] = [:]
    private var formattingContext = ""

    private lazy var weekdayFormatter: DateFormatter = makeFormatter(format: "EEE")
    private lazy var dayFormatter: DateFormatter = {
        let formatter = makeFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()
    private lazy var accessibilityFormatter: DateFormatter = {
        let formatter = makeFormatter()
        formatter.dateStyle = .full
        return formatter
    }()

    func presentation(for dateKey: String) -> Presentation {
        refreshFormattingContextIfNeeded()
        if let cached = presentationsByDateKey[dateKey] {
            return cached
        }

        let date = Self.date(from: dateKey)
        let presentation = Presentation(
            weekdayText: date.map { weekdayFormatter.string(from: $0) } ?? "–",
            dayText: date.map { dayFormatter.string(from: $0) } ?? dateKey,
            accessibilityDate: date.map { accessibilityFormatter.string(from: $0) } ?? dateKey
        )
        presentationsByDateKey[dateKey] = presentation
        return presentation
    }

    private func refreshFormattingContextIfNeeded() {
        let nextContext = "\(Locale.current.identifier)|\(TimeZone.current.identifier)"
        guard formattingContext != nextContext else { return }
        formattingContext = nextContext
        presentationsByDateKey.removeAll(keepingCapacity: true)
        weekdayFormatter.locale = .current
        weekdayFormatter.timeZone = .current
        dayFormatter.locale = .current
        dayFormatter.timeZone = .current
        accessibilityFormatter.locale = .current
        accessibilityFormatter.timeZone = .current
    }

    private func makeFormatter(format: String? = nil) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }

    private static func date(from dateKey: String) -> Date? {
        let parts = dateKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2])
        )
    }
}

private struct FixtureDateCarouselTile: View {
    let weekdayText: String
    let dayText: String
    let accessibilityDate: String
    let matchCount: Int
    let isSelected: Bool
    let isToday: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 4) {
            Text(isToday ? "Today" : weekdayText)
                .font(.caption2.weight(isToday ? .heavy : .semibold))
                .textCase(.uppercase)
            Text(dayText)
                .font(
                    (dynamicTypeSize.isAccessibilitySize ? Font.caption : .subheadline)
                        .weight(isToday ? .heavy : (isSelected ? .bold : .medium))
                )
                .monospacedDigit()
        }
        .foregroundStyle(
            isToday
                ? Color.white
                : (isSelected ? Color.accentColor : FootballVisualStyle.mutedText.opacity(0.78))
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
}

struct MatchesListRowLabel: View, Equatable {
    let match: Match
    let isFixtureMode: Bool
    var showDetails: Bool = false
    var apiBaseURL: String = ""
    let rowPreferences: MatchRowPreferences
    let fantasyContext: FantasyMatchRowContext

    var body: some View {
        MatchRow(
            match: match,
            showTeamEvents: showDetails,
            apiBaseURL: apiBaseURL,
            showLeague: false,
            showWatchabilityRating: rowPreferences.showCompactFixtureStarRating,
            showFantasyBadge: isFixtureMode,
            showFantasyPlayerContributions: isFixtureMode,
            teamLogoScale: 1.518,
            showsFinishedInlineAggregateBrackets: true,
            layoutStyle: .compactFixture,
            presentationStyle: .embedded,
            fantasyContext: fantasyContext,
            rowPreferences: rowPreferences,
            prefersShortTeamNames: true
        )
    }
}

/// Observes fantasy state independently of the cached fixture page so a squad loaded
/// after the Scores screen appears can immediately update the navigation chevron.
private struct FixtureMatchNavigationChevron: View {
    let match: Match
    let showFantasyBadge: Bool
    let rowPreferences: MatchRowPreferences
    @ObservedObject var fantasyViewModel: FantasyViewModel

    private var showsFantasyParticipation: Bool {
        fantasyParticipationBadgeVisibility(
            for: match,
            showFantasyBadge: showFantasyBadge,
            layoutStyle: .compactFixture,
            rowPreferences: rowPreferences,
            fantasyContext: fantasyViewModel.matchRowContext
        )
    }

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(showsFantasyParticipation ? .semibold : .regular))
            .foregroundStyle(
                showsFantasyParticipation
                    ? FootballSectionAccent.fantasy
                    : Color(.tertiaryLabel)
            )
            .frame(width: 16)
    }
}

private struct MatchNavigation: Identifiable, Hashable, Sendable {
    let match: Match
    let showFantasyBadge: Bool
    var id: String { match.id }
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

private struct FixtureTVGuideView: View {
    @ObservedObject var browser: FixtureBrowserStore
    let rowPreferences: MatchRowPreferences
    let fantasyContext: FantasyMatchRowContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var swipeCoordinator = FixturesViewCoordinator()
    @State private var carouselState = FixtureDateCarouselState()
    @State private var navigationMatch: MatchNavigation?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                FixtureDateCarousel(
                    state: carouselState, availableDays: browser.availableDays,
                    selectedDateKey: browser.selectedDateKey, todayDateKey: browser.todayDateKey,
                    hasLoadedCalendar: browser.hasLoadedCalendar, errorMessage: browser.errorMessage,
                    height: dynamicTypeSize.isAccessibilitySize ? 74 : 62, onSelect: browser.selectDate
                )
                GeometryReader { geometry in
                    datePagedContent(width: geometry.size.width)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .background(FootballVisualStyle.pageBackground)
            .navigationTitle("TV Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("tvGuideClose")
                }
            }
            .navigationDestination(item: $navigationMatch) { nav in
                MatchDetailView(match: nav.match, showFantasyBadge: false)
            }
        }
        .onAppear { browser.setAutoRefreshEnabled(scenePhase == .active) }
        .onChange(of: scenePhase) { _, phase in
            browser.setAutoRefreshEnabled(phase == .active, refreshImmediately: phase == .active)
        }
    }

    private func datePagedContent(width: CGFloat) -> some View {
        let previous = browser.adjacentDateKey(offset: -1)
        let next = browser.adjacentDateKey(offset: 1)
        return FixtureDatePagingContainer(
            containerWidth: width,
            currentDateKey: browser.selectedDateKey,
            previousDateKey: previous, nextDateKey: next,
            previousPageIsReady: previous.map { browser.cachedMatchesByDate[$0] != nil } ?? false,
            nextPageIsReady: next.map { browser.cachedMatchesByDate[$0] != nil } ?? false,
            previousPageMatchCount: previous.map { browser.cachedUnfilteredMatches(for: $0).count } ?? 0,
            nextPageMatchCount: next.map { browser.cachedUnfilteredMatches(for: $0).count } ?? 0,
            previousPageRevision: 0, currentPageRevision: 0, nextPageRevision: 0,
            isSwipeEnabled: navigationMatch == nil,
            reduceMotion: reduceMotion,
            onSwipeProgressChanged: carouselState.updateSwipeProgress,
            onSwipeSelectionSettled: carouselState.settleOnSelection,
            onSelect: browser.selectDate,
            onSwipeInteractionChanged: { active in
                browser.setDateSwipeInteractionActive(active)
                if active { swipeCoordinator.beginDateSwipeInteraction() }
                else { swipeCoordinator.endDateSwipeInteraction() }
            }
        ) { date in
            if let date {
                let isCurrent = date == browser.selectedDateKey
                TVListingsView(
                    matches: isCurrent ? browser.selectedDateUnfilteredMatches : browser.cachedUnfilteredMatches(for: date),
                    selectedDateKey: date,
                    isLoading: isCurrent ? browser.isLoadingSelectedDate : browser.cachedMatchesByDate[date] == nil,
                    errorMessage: isCurrent ? browser.errorMessage : nil,
                    rowPreferences: rowPreferences, fantasyContext: fantasyContext,
                    onSelectMatch: { match in
                        guard swipeCoordinator.allowsMatchNavigation else { return }
                        navigationMatch = MatchNavigation(match: match, showFantasyBadge: false)
                    },
                    onRefresh: browser.refresh,
                    allowsWatchabilityPresentation: { swipeCoordinator.allowsMatchNavigation }
                )
            } else {
                ProgressView("Loading TV Guide").frame(maxHeight: .infinity)
            }
        }
    }

}
