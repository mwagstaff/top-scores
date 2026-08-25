import SwiftUI
import os
import UIKit
import Combine
import UniformTypeIdentifiers
import ImageIO

struct FantasyView: View {
    private static let currentInitialSetupVersion = 1
    private static let teamManagementURL = URL(string: "https://fantasy.premierleague.com/my-team")

    private struct PendingFantasyRefreshRequest: Equatable {
        let force: Bool
        let rivalManagers: [FantasyRivalManager]
        let trackedLeagues: [FantasyTrackedLeague]
    }

    private struct PendingSharedFantasyImport {
        enum Source {
            case queue
            case legacy
        }

        let payload: FantasySharedImportPayload
        let source: Source
    }

    let isSelected: Bool

    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var fantasyViewModel: FantasyViewModel
    @AppStorage(StorageKeys.managerEntryID) private var managerEntryID = ""
    @AppStorage(StorageKeys.rivalManagersJSON) private var rivalManagersJSON = "[]"
    @AppStorage(StorageKeys.trackedLeaguesJSON) private var trackedLeaguesJSON = "[]"
    @AppStorage(StorageKeys.initialSetupVersion) private var initialSetupVersion = 0
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var managerCaptureStatusMessage = "Waiting for shared Fantasy entry URL. Open your Points page in Safari/Chrome and share it to Top Scores."
    @State private var shareImportStatusMessage: String?
    @State private var shareImportStatusIsError = false
    @State private var sharedEntryPollingDeadline: Date?
    @State private var lastProcessedSharedEntryUpdatedAt: TimeInterval = 0
    @State private var lastProcessedSharedEntryURL = ""
    @State private var nextSharedEntryRetryAt: Date = .distantPast
    @State private var isProcessingSharedEntryImport = false
    @State private var rivalManagers: [FantasyRivalManager] = []
    @State private var trackedLeagues: [FantasyTrackedLeague] = []
    @State private var isRunningInitialSetup = false
    @State private var initialSetupErrorMessage: String?
    @State private var setupRivalCandidates: [FantasySetupRivalCandidate] = []
    @State private var selectedSetupRivalEntryIDs: Set<Int> = []
    @State private var setupRivalSearchText = ""
    @State private var leagueIDLoadingDetails: Set<Int> = []
    @State private var showAddRivalSheet = false
    @State private var addSheetMode: FantasyIDAddMode = .rival
    @State private var rivalEntryInput = ""
    @State private var managerEntryInput = ""
    @State private var pendingRivalProfile: FantasyEntryProfile?
    @State private var pendingLeagueStanding: FantasyTrackedLeagueStanding?
    @State private var rivalValidationErrorMessage: String?
    @State private var leagueValidationErrorMessage: String?
    @State private var managerValidationErrorMessage: String?
    @State private var isValidatingManager = false
    @State private var isValidatingRival = false
    @State private var isValidatingLeague = false
    @State private var selectedRivalSquad: FantasyRivalSquad?
    @State private var selectedLeagueStanding: FantasyTrackedLeagueStanding?
    @State private var selectedLeagueMemberSquad: FantasyRivalSquad?
    @State private var selectedLeagueMemberPlayerSelection: FantasySelectedPlayerSelection?
    @State private var selectedLeagueMemberScoreBreakdown: FantasyScoreBreakdownSelection?
    @State private var leagueMemberEntryIDLoading: Int?
    @State private var leagueMemberLoadErrorMessage = ""
    @State private var showLeagueMemberLoadError = false
    @State private var leagueMemberLoadTask: Task<Void, Never>?
    @State private var selectedPlayerSelection: FantasySelectedPlayerSelection?
    @State private var pendingPlayerSelectionAfterRivalDismiss: FantasySelectedPlayerSelection?
    @State private var pendingScoreBreakdownAfterRivalDismiss: FantasyScoreBreakdownSelection?
    @State private var selectedScoreBreakdown: FantasyScoreBreakdownSelection?
    @State private var showReviewShareSheet = false
    @State private var shareRemovedEntryIDs: Set<Int> = []
    @State private var queuedShareItems: [Any] = []
    @State private var activeSharePayload: FantasySharePayload?
    @State private var isPreparingShareImage = false
    @State private var isLaunchingShareFlow = false
    @State private var showDeleteRivalConfirmation = false
    @State private var rivalEntryIDPendingDeletion: Int?
    @State private var rivalTeamNamePendingDeletion = ""
    @State private var rivalsScoreMode: RivalsScoreMode = .currentGameweek
    @State private var teamViewMode: FantasyTeamViewMode = .current
    @State private var showFantasySignIn = false
    @State private var shouldPresentFantasySignInAfterDisconnect = false
    @State private var fantasyPitchDetailMode: FantasyPitchPlayerDetailMode = .opponent
    @State private var expectedPointsMetricGameweekID: Int?
    @FocusState private var isRivalEntryInputFocused: Bool
    @State private var lastObservedClipboardChangeCount = UIPasteboard.general.changeCount
    @State private var pendingFantasyRefreshRequest: PendingFantasyRefreshRequest?
    @State private var inFlightFantasyRefreshRequest: PendingFantasyRefreshRequest?
    @State private var fantasyRefreshTask: Task<Void, Never>?
    @State private var fantasyScoreRefreshTask: Task<Void, Never>?
    @State private var lastStartedFantasyRefreshRequest: PendingFantasyRefreshRequest?
    @State private var lastStartedFantasyRefreshAt: Date?
    @State private var lastStartedFantasyScoreRefreshAt: Date?
    @State private var hasLoadedFantasyStorageState = false
    @State private var screenOpenedAt: Date?
    @State private var screenViewSentForActivation = false
    private let fantasyRefreshTimer = Timer.publish(every: 30.0, on: .main, in: .common).autoconnect()
    var body: some View {
        lifecycleBoundView
    }

    private var baseNavigationView: some View {
        NavigationStack {
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    FootballVisualStyle.pageBackground
                        .ignoresSafeArea()

                    FootballScreenBackdrop()

                    VStack(spacing: 0) {
                        if !usesInitialSetupNavigation {
                            FootballHeroHeader(
                                title: "FPL",
                                subtitle: fplHeaderSubtitle,
                                subtitleLink: currentManagerEntryID == nil ? nil : Self.teamManagementURL
                            )
                        }

                        Group {
                            if managerEntryID.isEmpty {
                                setupFlowView
                            } else if initialSetupVersion < Self.currentInitialSetupVersion {
                                initialSetupFlowView
                            } else {
                                linkedFantasyView
                            }
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                }
            }
            .navigationTitle(usesInitialSetupNavigation ? "Choose rivals" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(usesInitialSetupNavigation ? .visible : .hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .environment(\.colorScheme, .dark)
    }

    private var usesInitialSetupNavigation: Bool {
        !managerEntryID.isEmpty && initialSetupVersion < Self.currentInitialSetupVersion
    }

    private var fplHeaderSubtitle: String? {
        guard let teamName = fantasyViewModel.myProfile?.name
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !teamName.isEmpty else {
            return "Fantasy Premier League"
        }
        return teamName
    }

    private var modalPresentationView: some View {
        baseNavigationView
            .overlay {
                ZStack {
                    if isLaunchingShareFlow {
                        shareLoadingOverlay
                    }
                }
            }
            .sheet(isPresented: $showAddRivalSheet) {
                addRivalSheet
            }
            .sheet(isPresented: $showFantasySignIn) {
                FantasySignInView { entryID in
                    completeFantasySignIn(entryID)
                }
            }
            .sheet(item: $selectedRivalSquad) { rival in
                rivalDetailSheet(rival)
                    .presentationDragIndicator(.visible)
            }
            .sheet(
                item: $selectedLeagueStanding,
                onDismiss: resetLeagueDetailPresentation
            ) { league in
                leagueDetailSheet(league)
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $selectedScoreBreakdown) { breakdown in
                scoreBreakdownSheet(breakdown)
                    .presentationDragIndicator(.visible)
            }
            .alert("Delete rival?", isPresented: $showDeleteRivalConfirmation) {
                Button("Cancel", role: .cancel) {
                    rivalEntryIDPendingDeletion = nil
                    rivalTeamNamePendingDeletion = ""
                }
                Button("Delete", role: .destructive) {
                    guard let entryID = rivalEntryIDPendingDeletion else { return }
                    removeRival(entryID: entryID)
                    selectedRivalSquad = nil
                    rivalEntryIDPendingDeletion = nil
                    rivalTeamNamePendingDeletion = ""
                    setShareImportStatus("Rival removed from table.", isError: false)
                }
            } message: {
                if rivalTeamNamePendingDeletion.isEmpty {
                    Text("This rival will be removed from your table.")
                } else {
                    Text("Remove \(rivalTeamNamePendingDeletion) from your rivals table?")
                }
            }
            .sheet(item: $selectedPlayerSelection) { selection in
                FantasyPlayerDetailsSheet(
                    selection: selection,
                    apiBaseURL: preferences.apiBaseURL,
                    fantasyViewModel: fantasyViewModel
                )
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showReviewShareSheet, onDismiss: {
                shareRemovedEntryIDs = []
                isPreparingShareImage = false
                if !queuedShareItems.isEmpty {
                    let items = queuedShareItems
                    queuedShareItems = []
                    DispatchQueue.main.async {
                        presentShareSheet(with: items)
                    }
                } else {
                    isLaunchingShareFlow = false
                }
            }) {
                reviewAndShareSheet
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $activeSharePayload, onDismiss: {
                activeSharePayload = nil
            }) {
                FantasyShareSheet(activityItems: $0.items)
            }
    }

    private var lifecycleBoundView: some View {
        modalPresentationView
            .onAppear {
                let storedRivals = loadRivalManagersFromStorage()
                let storedLeagues = loadTrackedLeaguesFromStorage()
                hasLoadedFantasyStorageState = true
                syncManagerEntryIDToSharedDefaults()
                if managerEntryID.isEmpty {
                    managerCaptureStatusMessage = "Waiting for shared Fantasy entry URL. Open your Points page in Safari/Chrome and share it to Top Scores."
                } else {
                    migrateLegacyInitialSetupIfNeeded()
                    if initialSetupVersion < Self.currentInitialSetupVersion {
                        beginInitialSetup()
                    } else {
                        triggerFantasyRefresh(
                            force: fantasyViewModel.data == nil,
                            rivalManagers: storedRivals,
                            trackedLeagues: storedLeagues
                        )
                    }
                }
                armSharedEntryPolling()
                consumeSharedFantasyEntryURLIfNeeded()
                beginScreenViewTiming()
            }
            .onChange(of: isSelected) { _, selected in
                guard selected else {
                    fantasyRefreshTask?.cancel()
                    fantasyRefreshTask = nil
                    fantasyScoreRefreshTask?.cancel()
                    fantasyScoreRefreshTask = nil
                    inFlightFantasyRefreshRequest = nil
                    pendingFantasyRefreshRequest = nil
                    fantasyViewModel.cancelBackgroundRefreshWork()
                    screenOpenedAt = nil
                    screenViewSentForActivation = false
                    return
                }
                if isFantasySetupReadyForRefresh {
                    triggerFantasyRefresh(
                        force: fantasyViewModel.data == nil,
                        rivalManagers: rivalManagers,
                        trackedLeagues: trackedLeagues
                    )
                } else if !managerEntryID.isEmpty, initialSetupVersion < Self.currentInitialSetupVersion {
                    beginInitialSetup()
                }
                if shouldPresentFantasySignInAfterDisconnect, managerEntryID.isEmpty {
                    shouldPresentFantasySignInAfterDisconnect = false
                    showFantasySignIn = true
                }
                armSharedEntryPolling()
                consumeSharedFantasyEntryURLIfNeeded()
                beginScreenViewTiming()
            }
            .onChange(of: scenePhase) { _, newValue in
                guard newValue == .active else {
                    fantasyRefreshTask?.cancel()
                    fantasyRefreshTask = nil
                    fantasyScoreRefreshTask?.cancel()
                    fantasyScoreRefreshTask = nil
                    inFlightFantasyRefreshRequest = nil
                    pendingFantasyRefreshRequest = nil
                    fantasyViewModel.cancelBackgroundRefreshWork()
                    return
                }
                if isSelected, isFantasySetupReadyForRefresh {
                    triggerFantasyRefresh(
                        force: false,
                        rivalManagers: rivalManagers,
                        trackedLeagues: trackedLeagues
                    )
                } else if isSelected, !managerEntryID.isEmpty, initialSetupVersion < Self.currentInitialSetupVersion {
                    beginInitialSetup()
                }
                if showAddRivalSheet {
                    autoPopulateAddSheetIDFromClipboard(forceRead: true)
                }
                armSharedEntryPolling()
                consumeSharedFantasyEntryURLIfNeeded()
            }
            .onChange(of: showAddRivalSheet) { _, isPresented in
                guard isPresented else { return }
                autoPopulateAddSheetIDFromClipboard(forceRead: true)
            }
            .onChange(of: isRivalEntryInputFocused) { _, isFocused in
                guard showAddRivalSheet, isFocused else { return }
                autoPopulateAddSheetIDFromClipboard(forceRead: true)
            }
            .onChange(of: managerEntryID) { previousValue, newValue in
                syncManagerEntryIDToSharedDefaults()
                if newValue.isEmpty {
                    pendingFantasyRefreshRequest = nil
                    fantasyViewModel.reset()
                    managerCaptureStatusMessage = "Waiting for shared Fantasy entry URL. Open your Points page in Safari/Chrome and share it to Top Scores."
                    managerValidationErrorMessage = nil
                    initialSetupVersion = 0
                    initialSetupErrorMessage = nil
                    setupRivalCandidates = []
                    selectedSetupRivalEntryIDs = []
                    setupRivalSearchText = ""
                    isRunningInitialSetup = false
                    if !previousValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        shouldPresentFantasySignInAfterDisconnect = !isSelected
                        if isSelected {
                            showFantasySignIn = true
                        }
                    }
                } else {
                    managerValidationErrorMessage = nil
                    guard hasLoadedFantasyStorageState else { return }
                    if initialSetupVersion < Self.currentInitialSetupVersion {
                        beginInitialSetup()
                    } else {
                        triggerFantasyRefresh(force: true)
                    }
                }
            }
            .onChange(of: fantasyViewModel.authenticatedEntryID) { _, newEntryID in
                guard let newEntryID, newEntryID > 0 else { return }
                let resolvedValue = String(newEntryID)
                guard managerEntryID != resolvedValue else { return }
                managerEntryID = resolvedValue
            }
            .onChange(of: selectedRivalSquad) { _, newValue in
                guard newValue == nil else { return }
                if let pendingPlayerSelection = pendingPlayerSelectionAfterRivalDismiss {
                    pendingPlayerSelectionAfterRivalDismiss = nil
                    DispatchQueue.main.async {
                        selectedPlayerSelection = pendingPlayerSelection
                    }
                    return
                }
                if let pendingScoreBreakdown = pendingScoreBreakdownAfterRivalDismiss {
                    pendingScoreBreakdownAfterRivalDismiss = nil
                    DispatchQueue.main.async {
                        selectedScoreBreakdown = pendingScoreBreakdown
                    }
                }
            }
            .onChange(of: preferences.apiBaseURL) { _, _ in
                guard isFantasySetupReadyForRefresh else { return }
                triggerFantasyRefresh(
                    force: true,
                    rivalManagers: rivalManagers,
                    trackedLeagues: trackedLeagues
                )
            }
            .onChange(of: fantasyViewModel.isLoading) { _, isLoading in
                if !isLoading {
                    drainPendingFantasyRefreshIfNeeded()
                    sendTimedScreenView()
                }
            }
            .onChange(of: fantasyViewModel.isRefreshing) { _, isRefreshing in
                if !isRefreshing {
                    drainPendingFantasyRefreshIfNeeded()
                }
            }
            .onChange(of: rivalManagersJSON) { _, _ in
                let storedRivals = loadRivalManagersFromStorage()
                guard isFantasySetupReadyForRefresh else { return }
                triggerFantasyRefresh(
                    force: true,
                    rivalManagers: storedRivals,
                    trackedLeagues: trackedLeagues
                )
            }
            .onChange(of: trackedLeaguesJSON) { _, _ in
                let storedLeagues = loadTrackedLeaguesFromStorage()
                guard isFantasySetupReadyForRefresh else { return }
                triggerFantasyRefresh(
                    force: true,
                    rivalManagers: rivalManagers,
                    trackedLeagues: storedLeagues
                )
            }
            .onReceive(fantasyRefreshTimer) { _ in
                guard isSelected,
                      scenePhase == .active,
                      isFantasySetupReadyForRefresh else { return }
                triggerFantasyScoreRefresh()
            }
            .task(id: sharedEntryPollingDeadline) {
                await pollForSharedFantasyEntry()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
                guard showAddRivalSheet else { return }
                autoPopulateAddSheetIDFromClipboard(forceRead: false)
            }
    }

    private var setupFlowView: some View {
        Form {
            setupSection
            managerEntryInputSection
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    private var initialSetupFlowView: some View {
        Group {
            if isRunningInitialSetup {
                initialSetupLoadingView
            } else if !setupRivalCandidates.isEmpty {
                chooseRivalsSetupView
            } else {
                initialSetupRecoveryView
            }
        }
    }

    private var isFantasySetupReadyForRefresh: Bool {
        !managerEntryID.isEmpty && initialSetupVersion >= Self.currentInitialSetupVersion
    }

    private var filteredSetupRivalCandidates: [FantasySetupRivalCandidate] {
        let trimmedQuery = setupRivalSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return setupRivalCandidates }

        let normalizedQuery = normalizedSetupSearchValue(trimmedQuery)
        return setupRivalCandidates.filter { candidate in
            normalizedSetupSearchValue(candidate.managerName).contains(normalizedQuery)
            || normalizedSetupSearchValue(candidate.teamName).contains(normalizedQuery)
        }
    }

    private var managerDigitsInput: String {
        managerEntryInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isManagerSubmitEnabled: Bool {
        let input = managerDigitsInput
        return input.count >= 3 && input.allSatisfy(\.isNumber) && !isValidatingManager
    }

    private var rivalDigitsInput: String {
        rivalEntryInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isRivalSubmitEnabled: Bool {
        let input = rivalDigitsInput
        return input.count >= 3 && input.allSatisfy(\.isNumber) && !isValidatingRival
    }

    private var isLeagueSubmitEnabled: Bool {
        let input = rivalDigitsInput
        return input.count >= 3 && input.allSatisfy(\.isNumber) && !isValidatingLeague
    }

    private var isAddSheetSubmitEnabled: Bool {
        switch addSheetMode {
        case .rival:
            return isRivalSubmitEnabled
        case .league:
            return isLeagueSubmitEnabled
        }
    }

    private var activeAddSheetErrorMessage: String? {
        switch addSheetMode {
        case .rival:
            return rivalValidationErrorMessage
        case .league:
            return leagueValidationErrorMessage
        }
    }

    private var currentManagerEntryID: Int? {
        let trimmed = managerEntryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let entryID = Int(trimmed), entryID > 0 else { return nil }
        return entryID
    }

    private var linkedFantasyView: some View {
        ScrollView {
            VStack(spacing: 12) {
                if fantasyViewModel.isRefreshing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Refreshing Fantasy score...")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 2)
                }

                if fantasyViewModel.data != nil || fantasyViewModel.previousTeamData != nil {
                    teamModePicker

                    if let shareImportStatusMessage {
                        shareImportStatusCard(
                            message: shareImportStatusMessage,
                            isError: shareImportStatusIsError
                        )
                    }

                    switch teamViewMode {
                    case .current:
                        if let data = fantasyViewModel.data {
                            let displayData = data
                            FantasyTransferDeadlineLabel(
                                gameweekID: data.deadlineGameweekID,
                                deadlineTime: data.deadlineTime
                            )
                            pitchSection(
                                displayData,
                                playerSelectionEnabled: true,
                                detailMode: $fantasyPitchDetailMode,
                                expectedPoints: fantasyViewModel.currentSquadProjectedGameweekPoints,
                                teamValue: data.currentTeamValueMillions,
                                isExpectedPointsLoading: fantasyViewModel.currentSquadProjectedGameweekPoints == nil,
                                showsPoints: false
                            )
                            benchSection(
                                displayData,
                                playerSelectionEnabled: true,
                                detailMode: fantasyPitchDetailMode,
                                showsPoints: false
                            )
                        }
                    case .previous:
                        if let data = fantasyViewModel.previousTeamData {
                            pitchSection(
                                data,
                                playerSelectionEnabled: true,
                                detailMode: $fantasyPitchDetailMode,
                                teamValue: data.currentTeamValueMillions,
                                finalPointsMetricTitle: "Final score"
                            )
                            benchSection(
                                data,
                                playerSelectionEnabled: true,
                                detailMode: fantasyPitchDetailMode
                            )
                            eventLegendSection(data)
                            if data.isEstimatedScore {
                                scoreCalculationSection(data)
                            }
                            rivalsSection
                            summaryStatsSection(data)
                        } else {
                            noPreviousTeamCard
                        }
                    }

                    if !playerCreatedLeagues.isEmpty {
                        yourLeaguesSection
                    }

                    if isShowingProvisionalPointsMetric {
                        provisionalPointsInfoCard
                    }
                } else if fantasyViewModel.isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Loading Fantasy score...")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                    .hidden()
                }

                if let errorMessage = fantasyViewModel.errorMessage {
                    errorCard(errorMessage)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(Color.clear)
        .refreshable {
            await fantasyViewModel.refresh(
                managerEntryID: managerEntryID,
                apiBaseURL: preferences.apiBaseURL,
                rivalManagers: rivalManagers,
                trackedLeagues: trackedLeagues
            )
        }
    }

    private var teamModePicker: some View {
        Picker("Team view", selection: $teamViewMode) {
            Text("Current team").tag(FantasyTeamViewMode.current)
            Text(previousTeamPickerTitle).tag(FantasyTeamViewMode.previous)
        }
        .pickerStyle(.segmented)
        .accessibilityHint("Switch between your latest squad and your most recently completed gameweek.")
    }

    private var previousTeamPickerTitle: String {
        guard let data = fantasyViewModel.previousTeamData,
              data.scorePhase == .final else {
            return fantasyPreviousTeamPickerTitle(finalScore: nil)
        }
        return fantasyPreviousTeamPickerTitle(finalScore: data.resolvedCurrentScore)
    }

    private var noPreviousTeamCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No previous team yet", systemImage: "clock.arrow.circlepath")
                .font(.headline)
            Text("Your previous team and points will appear after the first gameweek of the season is complete.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var playerCreatedLeagues: [FantasyEntryClassicLeague] {
        (fantasyViewModel.myProfile?.leagues?.classic ?? [])
            .filter(\.isPlayerCreated)
    }

    private var isShowingProvisionalPointsMetric: Bool {
        guard teamViewMode == .current,
              let data = fantasyViewModel.data,
              data.scorePhase == .provisional else {
            return false
        }
        return expectedPointsMetricGameweekID != data.gameweekID
    }

    private var provisionalPointsInfoCard: some View {
        Label {
            Text(
                "Provisional scores can change. They become final only after every gameweek match finishes and FPL completes its final calculations, including bonus points."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.accentColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private var yourLeaguesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your leagues")
                    .font(.title3.weight(.bold))

                Spacer(minLength: 12)

                Button {
                    openFantasyLeagues()
                } label: {
                    Label("View all on FPL", systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityHint("Opens your leagues in Fantasy Premier League")
            }

            HStack {
                Text("League")
                Spacer()
                Text("Your rank")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)

            VStack(spacing: 0) {
                ForEach(Array(playerCreatedLeagues.enumerated()), id: \.element.id) { index, league in
                    Button {
                        openPlayerLeague(league)
                    } label: {
                        playerLeagueRow(league)
                    }
                    .buttonStyle(.plain)
                    .disabled(leagueIDLoadingDetails.contains(league.id))
                    .accessibilityHint("Opens the league table")

                    if index < playerCreatedLeagues.count - 1 {
                        Divider()
                            .padding(.leading, 52)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.accentColor.opacity(0.14), lineWidth: 1)
        )
    }

    private func playerLeagueRow(_ league: FantasyEntryClassicLeague) -> some View {
        let rank = league.resolvedEntryRank
        let trend = LeagueRankTrend.resolve(
            currentRank: rank,
            lastRank: league.resolvedEntryLastRank
        )
        let isLoading = leagueIDLoadingDetails.contains(league.id)

        return HStack(spacing: 12) {
            Text(leagueInitial(for: league))
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.82))
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(league.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(leagueMemberCountText(league))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let rank {
                HStack(spacing: 5) {
                    Text("\(rank)")
                        .font(.title3.monospacedDigit().weight(.bold))
                    leagueTrendIcon(currentRank: rank, lastRank: league.resolvedEntryLastRank)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(leagueRankAccessibilityLabel(league, rank: rank, trend: trend))
            } else {
                Text("—")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Rank unavailable")
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private func leagueInitial(for league: FantasyEntryClassicLeague) -> String {
        league.name.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init) ?? "L"
    }

    private func leagueMemberCountText(_ league: FantasyEntryClassicLeague) -> String {
        guard let memberCount = league.resolvedMemberCount else { return "Private league" }
        return "\(memberCount) \(memberCount == 1 ? "member" : "members")"
    }

    private func leagueRankAccessibilityLabel(
        _ league: FantasyEntryClassicLeague,
        rank: Int,
        trend: LeagueRankTrend
    ) -> String {
        let movement: String
        switch trend {
        case .up:
            movement = "up"
        case .down:
            movement = "down"
        case .equal:
            movement = "unchanged"
        case .unavailable:
            movement = "trend unavailable"
        }
        return "\(league.name), rank \(rank), \(movement)"
    }

    private var leaguesNudgeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Leagues", systemImage: "trophy.fill")
                .font(.headline)
            Text("Track the leagues that matter to you. Add one or more leagues to see your rank here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                prepareLeagueEntrySheet()
            } label: {
                Label("Add a league", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var setupSection: some View {
        Section("Connect your Fantasy Premier League account") {
            Text("Sign in on the official Fantasy Premier League page and Top Scores will identify your manager account automatically.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                showFantasySignIn = true
            } label: {
                Label("Sign in to FPL", systemImage: "person.crop.circle.badge.checkmark")
            }
        }
    }

    private var managerEntryInputSection: some View {
        Section("Or enter your manager ID manually") {
            TextField("Enter manager ID", text: $managerEntryInput)
                .keyboardType(.numberPad)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .onChange(of: managerEntryInput) { _, newValue in
                    let digitsOnly = newValue.filter(\.isNumber)
                    if digitsOnly != newValue {
                        managerEntryInput = digitsOnly
                    }
                }

            Button {
                Task {
                    await validateManagerEntryInput()
                }
            } label: {
                if isValidatingManager {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Submitting...")
                    }
                } else {
                    Text("Submit")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isManagerSubmitEnabled)
        }
    }

    private var initialSetupLoadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Setting up your Fantasy account...")
                .font(.headline)
            Text("Importing your leagues and finding nearby rivals from your private leagues.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Color.clear)
    }

    private var initialSetupRecoveryView: some View {
        VStack(spacing: 14) {
            Text("Choose rivals")
                .font(.headline)
            Text(initialSetupErrorMessage ?? "We couldn't finish setup yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Try again") {
                beginInitialSetup(force: true)
            }
            .buttonStyle(.borderedProminent)

            Button("Skip for now") {
                completeInitialSetup(with: [])
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Color.clear)
    }

    private var chooseRivalsSetupView: some View {
        List {
            Section {
                Text("Please choose your closest rivals...")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                ForEach(filteredSetupRivalCandidates) { candidate in
                    Button {
                        toggleSetupRivalSelection(candidate.entryID)
                    } label: {
                        setupRivalRow(candidate)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                HStack(spacing: 8) {
                    Text("")
                        .frame(width: 24, alignment: .leading)
                    Text("Team")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Total")
                        .frame(width: 52, alignment: .trailing)
                    Text("GW")
                        .frame(width: 40, alignment: .trailing)
                }
            } footer: {
                if filteredSetupRivalCandidates.isEmpty {
                    Text("No rivals match your search.")
                } else {
                    Text("Select any number of rivals, or skip this step.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .searchable(
            text: $setupRivalSearchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search player or team"
        )
        .safeAreaInset(edge: .bottom) {
            Button {
                completeInitialSetup(with: setupRivalCandidates.filter { selectedSetupRivalEntryIDs.contains($0.entryID) })
            } label: {
                Text(selectedSetupRivalEntryIDs.isEmpty ? "Continue" : "Add \(selectedSetupRivalEntryIDs.count) Rivals")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(.ultraThinMaterial)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Skip") {
                    completeInitialSetup(with: [])
                }
            }
        }
    }

    private func setupRivalRow(_ candidate: FantasySetupRivalCandidate) -> some View {
        let isSelected = selectedSetupRivalEntryIDs.contains(candidate.entryID)

        return HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 24, alignment: .leading)

            HStack(spacing: 8) {
                managerBadgeImage(urlString: candidate.clubBadgeSrc, fallbackTeamName: candidate.teamName)
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.managerName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(candidate.teamName)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(candidate.totalPoints)")
                .font(.body.monospacedDigit().weight(.semibold))
                .frame(width: 52, alignment: .trailing)
                .foregroundStyle(.primary)

            Text("\(candidate.eventPoints)")
                .font(.body.monospacedDigit().weight(.semibold))
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(.primary)
        }
        .contentShape(Rectangle())
    }

    private func shareImportStatusCard(message: String, isError: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.orange : Color.green)
                .padding(.top, 2)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                shareImportStatusMessage = nil
                shareImportStatusIsError = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill(Color(.tertiarySystemGroupedBackground))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss message")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func scoreSummaryCard(
        _ data: FantasySquadDisplayData,
        showRivalPills: Bool = true,
        showsActiveChipMessage: Bool = false,
        projectedGameweekPoints: Double? = nil,
        isExpectedPointsLoading: Bool = false,
        scoreTapEnabled: Bool = true,
        scoreTapAction: (() -> Void)? = nil,
        moreRivalsTapAction: (() -> Void)? = nil
    ) -> some View {
        let displayedScore = data.resolvedCurrentScoreDisplay
        let rivalPills = data.hasStartedFixturesInGameweek ? rivalScorePills() : []
        let visibleRivalPills = Array(rivalPills.prefix(3))
        let hiddenRivalCount = max(0, rivalPills.count - visibleRivalPills.count)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(data.gameweekTitle)
                        .font(.headline)
                    if isExpectedPointsLoading {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Calculating xP for this gameweek")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else if let projectedGameweekPoints {
                        Text(
                            "xP: \(fantasyExpectedPointsText(projectedGameweekPoints)) (expected total points for gameweek)"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    if showRivalPills && !visibleRivalPills.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(visibleRivalPills) { pill in
                                Button {
                                    openRivalFromScorePill(entryID: pill.entryID)
                                } label: {
                                    HStack(spacing: 0) {
                                        Text(pill.initials)
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 4)
                                            .background(rivalInitialsColor(for: pill.initials))

                                        Text(pill.displayedScore)
                                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                                            .monospacedDigit()
                                            .foregroundStyle(.primary)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 4)
                                            .background(Color(.tertiarySystemGroupedBackground))
                                    }
                                    .clipShape(Capsule(style: .continuous))
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }

                            if hiddenRivalCount > 0, let moreRivalsTapAction {
                                Button {
                                    moreRivalsTapAction()
                                } label: {
                                    Text("+\(hiddenRivalCount)")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                        .underline()
                                        .padding(.horizontal, 4)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Show \(hiddenRivalCount) more rivals")
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)

                if scoreTapEnabled {
                    Button {
                        if let scoreTapAction {
                            scoreTapAction()
                        } else {
                            openScoreBreakdown(for: data)
                        }
                    } label: {
                        FantasyScoreLozenge(
                            displayedScore: displayedScore,
                            isLive: data.hasActiveFixtures
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    FantasyScoreLozenge(
                        displayedScore: displayedScore,
                        isLive: data.hasActiveFixtures
                    )
                }
            }

            if showsActiveChipMessage, let chipSummary = data.activeChipSummaryText {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                    Text(chipSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func rivalScorePills() -> [FantasyRivalScorePill] {
        fantasyViewModel.rivalSquads
            .map { rival in
                FantasyRivalScorePill(
                    entryID: rival.entryID,
                    initials: initials(for: rival.managerName),
                    score: rival.currentScore,
                    showsAsterisk: rival.squad.hasActiveChip
                )
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return lhs.initials.localizedCaseInsensitiveCompare(rhs.initials) == .orderedAscending
            }
    }

    private func initials(for managerName: String) -> String {
        let words = managerName
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }

        if words.isEmpty {
            return "R"
        }

        if words.count == 1 {
            let hyphenParts = words[0]
                .split(separator: "-")
                .map(String.init)
                .filter { !$0.isEmpty }
            if hyphenParts.count >= 2 {
                let combined = hyphenParts
                    .prefix(3)
                    .compactMap { $0.first }
                    .map(String.init)
                    .joined()
                    .uppercased()
                if !combined.isEmpty {
                    return String(combined.prefix(3))
                }
            }
            return String(words[0].prefix(2)).uppercased()
        }

        let firstInitial = words.first?.first.map(String.init) ?? "R"
        let surname = words.last ?? ""
        let surnameParts = surname
            .split(separator: "-")
            .map(String.init)
            .filter { !$0.isEmpty }

        let suffix: String
        if surnameParts.count >= 2 {
            suffix = surnameParts
                .prefix(2)
                .compactMap { $0.first }
                .map(String.init)
                .joined()
        } else {
            suffix = surname.first.map(String.init) ?? ""
        }

        let raw = (firstInitial + suffix).uppercased()
        return String(raw.prefix(3))
    }

    private func rivalInitialsColor(for initials: String) -> Color {
        let normalized = initials
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        guard !normalized.isEmpty else {
            return .blue
        }

        var hash = 0
        for scalar in normalized.unicodeScalars {
            hash = (hash * 31 + Int(scalar.value)) % 360
        }
        let hue = Double(hash) / 360.0
        return Color(hue: hue, saturation: 0.72, brightness: 0.78)
    }

    private func openRivalFromScorePill(entryID: Int) {
        guard let rival = fantasyViewModel.rivalSquads.first(where: { $0.entryID == entryID }) else {
            return
        }
        selectedRivalSquad = rival
    }

    private func openScoreBreakdown(
        for data: FantasySquadDisplayData,
        teamNameOverride: String? = nil
    ) {
        let teamName = {
            if let teamNameOverride {
                let trimmed = teamNameOverride.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
            let ownTeamName = fantasyViewModel.myProfile?.name
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ownTeamName.isEmpty ? "My Team" : ownTeamName
        }()
        let selection = FantasyScoreBreakdownSelection(teamName: teamName, squad: data)

        if selectedLeagueMemberSquad != nil {
            selectedLeagueMemberScoreBreakdown = selection
            return
        }

        if selectedRivalSquad != nil {
            pendingScoreBreakdownAfterRivalDismiss = selection
            selectedRivalSquad = nil
            return
        }

        selectedScoreBreakdown = selection
    }

    private func scoreBreakdownSheet(
        _ breakdown: FantasyScoreBreakdownSelection,
        closeAction: (() -> Void)? = nil
    ) -> some View {
        let rows = scoreBreakdownRows(for: breakdown.squad)
        let maxAbsTotal = max(rows.map { abs($0.totalPoints) }.max() ?? 1, 1)

        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(breakdown.teamName)
                            .font(.headline)
                        Text("\(breakdown.squad.gameweekTitle) score breakdown")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Total: \(breakdown.squad.resolvedCurrentScore)")
                            .font(.title3.monospacedDigit().weight(.bold))
                    }

                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                FantasyPlayerProfileImage(url: row.profileImageURL, size: 18)
                                Text(row.playerName)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text("\(row.totalPoints)")
                                    .font(.subheadline.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(scoreColor(points: row.totalPoints))
                            }

                            scoreBar(
                                points: row.totalPoints,
                                maxAbsValue: maxAbsTotal,
                                barHeight: 9
                            )

                            if !row.components.isEmpty {
                                let componentMax = max(row.components.map { abs($0.points) }.max() ?? 1, 1)
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(row.components) { component in
                                        HStack(spacing: 8) {
                                            Text(component.title)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .frame(width: 140, alignment: .leading)

                                            scoreBar(
                                                points: component.points,
                                                maxAbsValue: componentMax,
                                                barHeight: 7
                                            )

                                            Text("\(component.points)")
                                                .font(.caption.monospacedDigit().weight(.semibold))
                                                .foregroundStyle(scoreColor(points: component.points))
                                                .frame(width: 28, alignment: .trailing)
                                        }
                                    }
                                }
                                .padding(.leading, 10)
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(.secondarySystemGroupedBackground))
                        )
                    }
                }
                .padding(14)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Score Breakdown")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let closeAction {
                            closeAction()
                        } else {
                            selectedScoreBreakdown = nil
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }

    private func scoreBar(points: Int, maxAbsValue: Int, barHeight: CGFloat) -> some View {
        let magnitude = CGFloat(abs(points))
        let denominator = CGFloat(max(maxAbsValue, 1))
        let progress = max(0.0, min(1.0, magnitude / denominator))

        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.10))
                Capsule(style: .continuous)
                    .fill(scoreColor(points: points).opacity(0.88))
                    .frame(width: max(4, proxy.size.width * progress))
            }
        }
        .frame(height: barHeight)
    }

    private func scoreColor(points: Int) -> Color {
        if points > 0 { return .green }
        if points < 0 { return .red }
        return .secondary
    }

    private func scoreBreakdownRows(for squad: FantasySquadDisplayData) -> [FantasyScoreBreakdownRow] {
        squad.starters
            .sorted { $0.pickPosition < $1.pickPosition }
            .map { player in
                FantasyScoreBreakdownRow(
                    elementID: player.elementID,
                    playerName: player.displayName,
                    profileImageURL: player.profileImageURL,
                    totalPoints: player.appliedPoints,
                    components: scoreBreakdownComponents(for: player)
                )
            }
    }

    private func scoreBreakdownComponents(for player: FantasyDisplayPlayer) -> [FantasyScoreBreakdownComponent] {
        let multiplier = max(player.multiplier, 1)
        let appearance = (player.minutesPlayed <= 0 ? 0 : (player.minutesPlayed > 60 ? 2 : 1)) * multiplier
        let goalPointsPerGoal: Int = {
            switch player.positionType {
            case .goalkeeper:
                return 10
            case .defender:
                return 6
            case .midfielder:
                return 5
            case .forward:
                return 4
            }
        }()
        let goals = player.goalsScored * goalPointsPerGoal * multiplier
        let assists = player.assists * 3 * multiplier
        let cards = ((player.yellowCards * -1) + (player.redCards * -3)) * multiplier

        let known = appearance + goals + assists + cards
        let residual = player.appliedPoints - known

        let ordered: [(String, Int)] = [
            ("Appearance", appearance),
            ("Goals", goals),
            ("Assists", assists),
            ("Cards", cards),
            ("Defensive/other", residual)
        ]

        let components = ordered.compactMap { title, points -> FantasyScoreBreakdownComponent? in
            guard points != 0 else { return nil }
            return FantasyScoreBreakdownComponent(title: title, points: points)
        }
        if components.isEmpty {
            return [FantasyScoreBreakdownComponent(title: "No points", points: 0)]
        }
        return components
    }

    private func summaryStatsSection(_ data: FantasySquadDisplayData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gameweek stats")
                .font(.headline)

            HStack(spacing: 8) {
                summaryPill(title: "GW Rank", value: formatNumber(data.rank))
                summaryPill(title: "Overall", value: formatNumber(data.overallRank))
                summaryPill(title: "Bench", value: formatNumber(data.pointsOnBench))
                summaryPill(title: "Transfers", value: formatTransfersValue(data.transfersCost))
            }
        }
    }

    private var leagueTableEntries: [FantasyLeagueTableEntry] {
        guard let mySquad = fantasyViewModel.previousTeamData else { return [] }

        let entryID = Int(managerEntryID.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        let profile = fantasyViewModel.myProfile

        let myTeamName = {
            let trimmed = profile?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "My Team" : trimmed
        }()

        let myManagerName = {
            let first = profile?.playerFirstName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let last = profile?.playerLastName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let combined = [first, last]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return combined.isEmpty ? "You" : combined
        }()

        var rows: [FantasyLeagueTableEntry] = [
            FantasyLeagueTableEntry(
                entryID: entryID,
                teamName: myTeamName,
                managerName: myManagerName,
                currentGameweekScore: mySquad.resolvedCurrentScore,
                allGameweeksScore: profile?.summaryOverallPoints,
                projectedGameweekPoints: fantasyViewModel.currentSquadProjectedGameweekPoints,
                isExpectedPointsLoading: false,
                hasActiveChipInCurrentGameweek: mySquad.hasActiveChip,
                squad: mySquad,
                clubBadgeSrc: profile?.clubBadgeSrc,
                isUser: true
            )
        ]

        let rivalSquadsByEntryID = Dictionary(
            uniqueKeysWithValues: fantasyViewModel.rivalSquads.map { ($0.entryID, $0) }
        )
        rows.append(contentsOf: rivalManagers.map { rival in
            let rivalSquad = rivalSquadsByEntryID[rival.entryID]
            return FantasyLeagueTableEntry(
                entryID: rival.entryID,
                teamName: rival.teamName,
                managerName: rival.managerDisplayName,
                currentGameweekScore: rivalSquad?.currentScore,
                allGameweeksScore: rivalSquad?.allGameweeksPoints ?? rival.overallPoints,
                projectedGameweekPoints: rivalSquad?.projectedGameweekPoints,
                isExpectedPointsLoading: rivalSquad?.isExpectedPointsLoading ?? false,
                hasActiveChipInCurrentGameweek: rivalSquad?.squad.hasActiveChip ?? false,
                squad: rivalSquad?.squad,
                clubBadgeSrc: rivalSquad?.clubBadgeSrc ?? rival.clubBadgeSrc,
                isUser: false
            )
        })

        return rows.sorted { lhs, rhs in
            let lhsScore = lhs.scoreValue(for: rivalsScoreMode) ?? Int.min
            let rhsScore = rhs.scoreValue(for: rivalsScoreMode) ?? Int.min
            if lhsScore != rhsScore {
                return lhsScore > rhsScore
            }
            let lhsName = lhs.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
            let rhsName = rhs.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
            if lhsName.localizedCaseInsensitiveCompare(rhsName) != .orderedSame {
                return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
            }
            return lhs.entryID < rhs.entryID
        }
    }

    private var reviewShareEntries: [FantasyLeagueTableEntry] {
        leagueTableEntries.filter { !shareRemovedEntryIDs.contains($0.entryID) }
    }

    private var rivalsSection: some View {
        let rankedEntries = leagueTableEntries
        let hasRivals = rankedEntries.count > 1

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Rivals")
                    .font(.headline)
                Spacer(minLength: 0)
            }

            Text("Share one or more rival's Fantasy Points page to Top Scores from Safari/Chrome to add them to your Rivals list.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Picker("Score scope", selection: $rivalsScoreMode) {
                ForEach(RivalsScoreMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if rankedEntries.count <= 1 {
                Text("Add rival manager IDs to compare live scores.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("#")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 26, alignment: .trailing)
                    Text("Team")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("xP")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 48, alignment: .trailing)
                    Text(rivalsScoreMode == .currentGameweek ? "GW" : "Total")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 44, alignment: .trailing)
                    Color.clear
                        .frame(width: 16)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .foregroundStyle(.secondary)

                Rectangle()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(height: 1)

                ForEach(Array(rankedEntries.enumerated()), id: \.element.id) { index, entry in
                    if entry.canOpenDetails {
                        Button {
                            openLeagueTableEntry(entry)
                        } label: {
                            rivalTableRow(rank: index + 1, entry: entry, scoreMode: rivalsScoreMode)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if !entry.isUser {
                                Button(role: .destructive) {
                                    removeRival(entryID: entry.entryID)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    } else {
                        rivalTableRow(rank: index + 1, entry: entry, scoreMode: rivalsScoreMode)
                            .contextMenu {
                                if !entry.isUser {
                                    Button(role: .destructive) {
                                        removeRival(entryID: entry.entryID)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                            }
                    }

                    if index < rankedEntries.count - 1 {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.22))
                            .frame(height: 1)
                    }
                }
            }
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if hasRivals {
                HStack(spacing: 10) {
                    Button {
                        prepareReviewShareSheet()
                    } label: {
                        Label("Review and share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(rankedEntries.count < 2)

                    Button {
                        prepareRivalEntrySheet()
                    } label: {
                        Label("Add rival", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Button {
                    prepareRivalEntrySheet()
                } label: {
                    Label("Add rival", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var playerLeaguesSection: some View {
        leagueSectionCard(
            title: "Player Leagues",
            leagues: fantasyViewModel.trackedLeagueStandings.filter { $0.leagueType == "x" },
            emptyState: "No player-created leagues found.",
            showsAddButton: true
        )
    }

    private var gameLeaguesSection: some View {
        leagueSectionCard(
            title: "Game Leagues",
            leagues: fantasyViewModel.trackedLeagueStandings.filter { $0.leagueType != "x" },
            emptyState: "No game-managed leagues found."
        )
    }

    private func leagueSectionCard(
        title: String,
        leagues: [FantasyTrackedLeagueStanding],
        emptyState: String,
        showsAddButton: Bool = false
    ) -> some View {
        let hasConfiguredLeagues = !trackedLeagues.isEmpty

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer(minLength: 0)
            }

            if !hasConfiguredLeagues {
                Text(emptyState)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if leagues.isEmpty {
                if fantasyViewModel.isLoading || fantasyViewModel.isRefreshing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading league standings...")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                } else {
                    Text(emptyState)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(leagues) { league in
                        Button {
                            openLeagueSummary(league)
                        } label: {
                            leagueSummaryRow(league)
                        }
                        .buttonStyle(.plain)
                        .disabled(leagueIDLoadingDetails.contains(league.leagueID))
                    }
                }
            }

            if showsAddButton {
                Button {
                    prepareLeagueEntrySheet()
                } label: {
                    Label("Add league", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func leagueSummaryRow(_ league: FantasyTrackedLeagueStanding) -> some View {
        let trend = LeagueRankTrend.resolve(currentRank: league.myRank, lastRank: league.myLastRank)
        let isLoadingDetails = leagueIDLoadingDetails.contains(league.leagueID)
        let showsChevron = league.canOpenDetails || league.leagueType == "x"

        return HStack(spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(league.leagueName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let rank = league.myRank {
                        Text("Your rank: \(rank)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Your rank: Unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let rank = league.myRank {
                    HStack(spacing: 4) {
                        Text("\(rank)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                        leagueTrendIcon(currentRank: rank, lastRank: league.myLastRank)
                    }
                } else {
                    Text("-")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.thinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(leagueTrendOutlineColor(for: trend), lineWidth: 1)
            )

            Group {
                if isLoadingDetails {
                    ProgressView()
                        .controlSize(.small)
                } else if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.8))
                }
            }
            .frame(width: 16, alignment: .center)
        }
    }

    private func rivalTableRow(
        rank: Int,
        entry: FantasyLeagueTableEntry,
        scoreMode: RivalsScoreMode
    ) -> some View {
        let isLoadingDetails = entry.isLoadingDetails
        let showsChevron = entry.canOpenDetails

        return HStack(spacing: 8) {
            Text("\(rank)")
                .font(.body.monospacedDigit())
                .frame(width: 26, alignment: .trailing)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                managerBadgeImage(urlString: entry.clubBadgeSrc, fallbackTeamName: entry.teamName)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.teamName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(Color.primary)
                    Text(entry.isUser ? "\(entry.managerName) (You)" : entry.managerName)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if entry.showsExpectedPointsLoadingIndicator {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    fantasyExpectedPointsPill(
                        text: entry.projectedGameweekPointsDisplay,
                        value: entry.projectedGameweekPoints
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(width: 48, alignment: .trailing)

            Group {
                if entry.showsScoreLoadingIndicator(for: scoreMode) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    Text(entry.scoreDisplay(for: scoreMode))
                        .font(.body.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(width: 44, alignment: .trailing)

            Group {
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(isLoadingDetails ? 0.35 : 0.8))
                } else {
                    Color.clear
                }
            }
            .frame(width: 16, alignment: .center)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .opacity(isLoadingDetails ? 0.58 : 1)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(entry.isUser ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(entry.isUser ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.2), value: isLoadingDetails)
    }

    private func fantasyExpectedPointsPill(text: String, value: Double?) -> some View {
        let color = fantasyExpectedPointsPillColor(value)

        return Text(text)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(value == nil ? Color.secondary : fantasyExpectedPointsPillForegroundColor(value))
            .frame(minWidth: 40, alignment: .center)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.opacity(value == nil ? 0.20 : 0.92))
            )
    }

    private func fantasyExpectedPointsPillColor(_ value: Double?) -> Color {
        guard let value else { return Color.gray }
        switch value {
        case ..<2.0:
            return Color.red
        case ..<4.0:
            return Color.orange
        case ..<6.0:
            return Color.yellow
        default:
            return Color.green
        }
    }

    private func fantasyExpectedPointsPillForegroundColor(_ value: Double?) -> Color {
        guard let value else { return Color.secondary }
        return value >= 4.0 ? Color.black.opacity(0.82) : Color.white
    }

    private func leagueDetailSheet(_ league: FantasyTrackedLeagueStanding) -> some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("Your rank")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(league.myRank.map(String.init) ?? "-")
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                        }

                        if league.standings.isEmpty {
                            Text("League standings are unavailable right now. Please try again shortly.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color(.secondarySystemGroupedBackground))
                                )
                        } else {
                            LazyVStack(spacing: 0) {
                                HStack(spacing: 8) {
                                    Text("#")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(width: 30, alignment: .trailing)
                                    Text("Team")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text("GW")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(width: 44, alignment: .trailing)
                                    Text("Total")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(width: 56, alignment: .trailing)
                                    Text("")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(width: 36, alignment: .trailing)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .foregroundStyle(.secondary)

                                Rectangle()
                                    .fill(Color.secondary.opacity(0.22))
                                    .frame(height: 1)

                                ForEach(Array(league.standings.enumerated()), id: \.element.id) { index, row in
                                    Button {
                                        openLeagueMemberSquad(row)
                                    } label: {
                                        leagueStandingRow(
                                            row,
                                            isCurrentUser: row.entry == league.myEntryID,
                                            isLoading: leagueMemberEntryIDLoading == row.entry
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(leagueMemberEntryIDLoading != nil)
                                    .accessibilityHint("Opens this manager's latest team and score")
                                    .id(row.entry)
                                    if index < league.standings.count - 1 {
                                        Rectangle()
                                            .fill(Color.secondary.opacity(0.22))
                                            .frame(height: 1)
                                    }
                                }
                            }
                            .background(.thinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    .padding(14)
                }
                .onAppear {
                    scrollToCurrentLeagueEntry(proxy: proxy, league: league)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(league.leagueName)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        selectedLeagueStanding = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("Close")
                }
            }
            .navigationDestination(item: $selectedLeagueMemberSquad) { rival in
                rivalSquadDetailView(
                    rival,
                    showsDeleteButton: false,
                    closeAction: nil
                )
            }
        }
        .alert("Team unavailable", isPresented: $showLeagueMemberLoadError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(leagueMemberLoadErrorMessage)
        }
        .sheet(item: $selectedLeagueMemberPlayerSelection) { selection in
            FantasyPlayerDetailsSheet(
                selection: selection,
                apiBaseURL: preferences.apiBaseURL,
                fantasyViewModel: fantasyViewModel
            )
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedLeagueMemberScoreBreakdown) { breakdown in
            scoreBreakdownSheet(
                breakdown,
                closeAction: { selectedLeagueMemberScoreBreakdown = nil }
            )
            .presentationDragIndicator(.visible)
        }
    }

    private func resetLeagueDetailPresentation() {
        leagueMemberLoadTask?.cancel()
        leagueMemberLoadTask = nil
        leagueMemberEntryIDLoading = nil
        selectedLeagueMemberSquad = nil
        selectedLeagueMemberPlayerSelection = nil
        selectedLeagueMemberScoreBreakdown = nil
    }

    private func scrollToCurrentLeagueEntry(
        proxy: ScrollViewProxy,
        league: FantasyTrackedLeagueStanding
    ) {
        guard league.standings.contains(where: { $0.entry == league.myEntryID }) else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(league.myEntryID, anchor: .center)
        }
    }

    private func leagueStandingRow(
        _ row: FantasyClassicLeagueStandingEntry,
        isCurrentUser: Bool,
        isLoading: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Text("\(row.rank)")
                .font(.body.monospacedDigit())
                .frame(width: 30, alignment: .trailing)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                leagueBadgeImage(urlString: row.clubBadgeSrc, teamName: row.entryName)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(row.entryName)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        if isCurrentUser {
                            Text("You")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.14), in: Capsule())
                        }
                    }
                    Text(row.playerName)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(row.eventTotal)")
                .font(.body.monospacedDigit().weight(.semibold))
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(.primary)

            Text("\(row.total)")
                .font(.body.monospacedDigit().weight(.semibold))
                .frame(width: 56, alignment: .trailing)
                .foregroundStyle(.primary)

            HStack(spacing: 4) {
                leagueTrendIcon(currentRank: row.rank, lastRank: row.lastRank)
                    .frame(width: 20, alignment: .trailing)

                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrentUser ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isCurrentUser ? Color.accentColor.opacity(0.65) : Color.clear, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func managerBadgeImage(urlString: String?, fallbackTeamName: String?) -> some View {
        if let urlString,
           let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 20, height: 20)
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                case .failure:
                    managerFallbackBadge(teamName: fallbackTeamName)
                @unknown default:
                    managerFallbackBadge(teamName: fallbackTeamName)
                }
            }
        } else {
            managerFallbackBadge(teamName: fallbackTeamName)
        }
    }

    @ViewBuilder
    private func managerFallbackBadge(teamName: String?) -> some View {
        if let teamName,
           let logo = LogoResolver.shared.image(for: teamName) {
            Image(uiImage: logo)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: "shield")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        }
    }

    @ViewBuilder
    private func leagueTrendIcon(currentRank: Int, lastRank: Int?) -> some View {
        switch LeagueRankTrend.resolve(currentRank: currentRank, lastRank: lastRank) {
        case .up:
            Image(systemName: "arrow.up")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        case .down:
            Image(systemName: "arrow.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
        case .equal:
            Image(systemName: "equal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.gray)
        case .unavailable:
            Image(systemName: "minus")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.gray)
        }
    }

    private func leagueTrendOutlineColor(for trend: LeagueRankTrend) -> Color {
        switch trend {
        case .up:
            return .green.opacity(0.7)
        case .down:
            return .red.opacity(0.7)
        case .equal:
            return .gray.opacity(0.6)
        case .unavailable:
            return .gray.opacity(0.35)
        }
    }

    @ViewBuilder
    private func leagueBadgeImage(urlString: String?, teamName: String) -> some View {
        if let urlString,
           let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    Circle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 30, height: 30)
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                case .failure:
                    leagueInitialsBadge(teamName: teamName)
                @unknown default:
                    leagueInitialsBadge(teamName: teamName)
                }
            }
        } else {
            leagueInitialsBadge(teamName: teamName)
        }
    }

    private func leagueInitialsBadge(teamName: String) -> some View {
        Text(FantasyLeagueBadgeInitials.make(from: teamName))
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Color.accentColor.opacity(0.82), in: Circle())
            .accessibilityHidden(true)
    }

    private var reviewAndShareSheet: some View {
        let rankedEntries = leagueTableEntries
        let includedEntries = reviewShareEntries

        return NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose the teams to include in your shared league table.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if includedEntries.count < 2 {
                    Text("Keep at least 2 entries selected to share.")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(spacing: 0) {
                    ForEach(Array(rankedEntries.enumerated()), id: \.element.id) { index, entry in
                        reviewShareEntryRow(rank: index + 1, entry: entry)

                        if index < rankedEntries.count - 1 {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.2))
                                .frame(height: 1)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )

                Spacer(minLength: 0)
            }
            .padding(14)
            .navigationTitle("Review and Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        showReviewShareSheet = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        shareLeagueTable()
                    } label: {
                        if isPreparingShareImage {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    .disabled(isPreparingShareImage || includedEntries.count < 2)
                    .accessibilityLabel("Share table")
                }
            }
            .background(Color(.systemGroupedBackground))
        }
    }

    private func reviewShareEntryRow(rank: Int, entry: FantasyLeagueTableEntry) -> some View {
        let isIncluded = !shareRemovedEntryIDs.contains(entry.entryID)
        let canRemove = !entry.isUser && isIncluded && reviewShareEntries.count > 2

        return HStack(spacing: 8) {
            Text("\(rank)")
                .font(.body.monospacedDigit())
                .frame(width: 26, alignment: .trailing)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                managerBadgeImage(urlString: entry.clubBadgeSrc, fallbackTeamName: entry.teamName)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.teamName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(Color.primary)
                    Text(entry.isUser ? "\(entry.managerName) (You)" : entry.managerName)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isIncluded ? 1.0 : 0.5)

            Text(entry.scoreDisplay(for: rivalsScoreMode))
                .font(.body.monospacedDigit().weight(.semibold))
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(isIncluded ? Color.primary : Color.secondary)

            if entry.isUser {
                Text("You")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .center)
            } else {
                Button {
                    toggleShareInclusion(for: entry)
                } label: {
                    Image(systemName: isIncluded ? "minus.circle.fill" : "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(
                            isIncluded
                            ? (canRemove ? Color.red : Color.gray)
                            : Color.blue
                        )
                }
                .buttonStyle(.plain)
                .disabled(isIncluded && !canRemove)
                .frame(width: 32, alignment: .center)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private var addRivalSheet: some View {
        NavigationStack {
            Form {
                Section("Tip") {
                    Text(addSheetMode.tipText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button {
                        openFantasyWebsiteInBrowser()
                    } label: {
                        Label("Open fantasy.premierleague.com", systemImage: "globe")
                    }
                }

                Section(addSheetMode.idSectionTitle) {
                    Text(addSheetMode.manualEntryHelpText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    TextField(addSheetMode.idPlaceholder, text: $rivalEntryInput)
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .focused($isRivalEntryInputFocused)
                        .onChange(of: rivalEntryInput) { _, newValue in
                            let digitsOnly = newValue.filter(\.isNumber)
                            if digitsOnly != newValue {
                                rivalEntryInput = digitsOnly
                            }
                        }

                    Button {
                        Task {
                            await validateAddSheetInput()
                        }
                    } label: {
                        if addSheetMode == .rival && isValidatingRival {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Validating...")
                            }
                        } else if addSheetMode == .league && isValidatingLeague {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Validating...")
                            }
                        } else {
                            Text("Submit")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isAddSheetSubmitEnabled)
                }

                if let validationErrorMessage = activeAddSheetErrorMessage {
                    Section {
                        Text(validationErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if addSheetMode == .rival, let pendingRivalProfile {
                    Section("Confirm manager") {
                        Text("Team: \(pendingRivalProfile.name)")
                        Text("Manager: \(pendingRivalProfile.playerFirstName) \(pendingRivalProfile.playerLastName)")
                        Button("Add rival manager") {
                            addPendingRivalProfile()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if addSheetMode == .league, let pendingLeagueStanding {
                    Section("Confirm league") {
                        Text("League: \(pendingLeagueStanding.leagueName)")
                        if let rank = pendingLeagueStanding.myRank {
                            Text("Your rank: \(rank)")
                        } else {
                            Text("Your rank: Unavailable")
                        }
                        Button("Add league") {
                            addPendingLeagueStanding()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle(addSheetMode.sheetTitle)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        showAddRivalSheet = false
                    }
                }
            }
            .onAppear {
                autoPopulateAddSheetIDFromClipboard(forceRead: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    isRivalEntryInputFocused = true
                }
            }
            .onDisappear {
                isRivalEntryInputFocused = false
            }
        }
    }

    private func rivalDetailSheet(_ rival: FantasyRivalSquad) -> some View {
        NavigationStack {
            rivalSquadDetailView(
                rival,
                showsDeleteButton: true,
                closeAction: { selectedRivalSquad = nil }
            )
        }
    }

    private func rivalSquadDetailView(
        _ rival: FantasyRivalSquad,
        showsDeleteButton: Bool,
        closeAction: (() -> Void)?
    ) -> some View {
        let displayData = rival.squad.applyingExpectedPoints(rival.expectedPointsSection)

        return ScrollView {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rival.managerName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                pitchSection(
                    displayData,
                    playerSelectionEnabled: true,
                    detailMode: $fantasyPitchDetailMode,
                    expectedPoints: rival.projectedGameweekPoints,
                    teamValue: displayData.currentTeamValueMillions,
                    isExpectedPointsLoading: rival.isExpectedPointsLoading
                )
                benchSection(
                    displayData,
                    playerSelectionEnabled: true,
                    detailMode: fantasyPitchDetailMode
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(rival.teamName)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if showsDeleteButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) {
                        rivalEntryIDPendingDeletion = rival.entryID
                        rivalTeamNamePendingDeletion = rival.teamName
                        showDeleteRivalConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("Delete rival")
                }
            }
            if let closeAction {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        closeAction()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }

    private func pitchSection(
        _ data: FantasySquadDisplayData,
        playerSelectionEnabled: Bool,
        detailMode: Binding<FantasyPitchPlayerDetailMode>,
        expectedPoints: Double? = nil,
        teamValue: Double? = nil,
        isExpectedPointsLoading: Bool = false,
        showsPoints: Bool = true,
        finalPointsMetricTitle: String = "Final Points"
    ) -> some View {
        let pointsMetricTitle: String
        let pointsMetricValue: Double?
        let pointsMetricDisplayValue: String?
        let pointsMetricTint: Color
        let pointsMetricIsLoading: Bool
        let canTogglePointsMetric = data.scorePhase == .provisional &&
            (expectedPoints != nil || isExpectedPointsLoading)
        let showsExpectedPointsMetric = data.scorePhase == .expected ||
            (canTogglePointsMetric && expectedPointsMetricGameweekID == data.gameweekID)
        let pointsMetricFooter = !showsExpectedPointsMetric && data.scorePhase != .expected
            ? "GW average: \(data.gameweekAverageScore.map(String.init) ?? "—")"
            : nil
        if showsExpectedPointsMetric {
            pointsMetricTitle = "Expected Points (xP)"
            pointsMetricValue = expectedPoints
            pointsMetricDisplayValue = expectedPoints.map { "\(fantasyExpectedPointsText($0)) xP" }
            pointsMetricTint = Color(red: 0.70, green: 0.28, blue: 0.96)
            pointsMetricIsLoading = isExpectedPointsLoading
        } else if data.scorePhase == .provisional {
            pointsMetricTitle = "Provisional Points"
            pointsMetricValue = Double(data.resolvedCurrentScore)
            pointsMetricDisplayValue = "\(data.resolvedCurrentScore)"
            pointsMetricTint = gameweekPerformanceTint(
                score: data.resolvedCurrentScore,
                average: data.gameweekAverageScore
            )
            pointsMetricIsLoading = false
        } else {
            pointsMetricTitle = finalPointsMetricTitle
            pointsMetricValue = Double(data.resolvedCurrentScore)
            pointsMetricDisplayValue = "\(data.resolvedCurrentScore)"
            pointsMetricTint = Color(red: 0.20, green: 0.55, blue: 1.0)
            pointsMetricIsLoading = false
        }

        return VStack(alignment: .leading, spacing: 10) {

            ZStack(alignment: .bottomTrailing) {
                FantasyPitchBackground()

                VStack(spacing: 8) {
                    positionRow(
                        data.goalkeepers,
                        gameweekID: data.gameweekID,
                        playerSelectionEnabled: playerSelectionEnabled,
                        detailMode: detailMode.wrappedValue,
                        scorePhase: data.scorePhase,
                        showsPoints: showsPoints
                    )
                    positionRow(
                        data.defenders,
                        gameweekID: data.gameweekID,
                        playerSelectionEnabled: playerSelectionEnabled,
                        detailMode: detailMode.wrappedValue,
                        scorePhase: data.scorePhase,
                        showsPoints: showsPoints
                    )
                    positionRow(
                        data.midfielders,
                        gameweekID: data.gameweekID,
                        playerSelectionEnabled: playerSelectionEnabled,
                        detailMode: detailMode.wrappedValue,
                        scorePhase: data.scorePhase,
                        showsPoints: showsPoints
                    )
                    positionRow(
                        data.forwards,
                        gameweekID: data.gameweekID,
                        playerSelectionEnabled: playerSelectionEnabled,
                        detailMode: detailMode.wrappedValue,
                        scorePhase: data.scorePhase,
                        showsPoints: showsPoints
                    )
                }
                .padding(.horizontal, 6)
                .padding(.top, 14)
                .padding(.bottom, 50)

                if let teamValue {
                    HStack(alignment: .top, spacing: 8) {
                        if canTogglePointsMetric {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    expectedPointsMetricGameweekID = showsExpectedPointsMetric
                                        ? nil
                                        : data.gameweekID
                                }
                            } label: {
                                pitchSummaryMetric(
                                    title: pointsMetricTitle,
                                    value: pointsMetricValue,
                                    displayValue: pointsMetricDisplayValue,
                                    target: 50,
                                    tint: pointsMetricTint,
                                    isLoading: pointsMetricIsLoading,
                                    footer: pointsMetricFooter
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(
                                showsExpectedPointsMetric
                                    ? "Shows provisional points"
                                    : "Shows expected points"
                            )
                        } else {
                            pitchSummaryMetric(
                                title: pointsMetricTitle,
                                value: pointsMetricValue,
                                displayValue: pointsMetricDisplayValue,
                                target: 50,
                                tint: pointsMetricTint,
                                isLoading: pointsMetricIsLoading,
                                footer: pointsMetricFooter
                            )
                            .allowsHitTesting(false)
                        }

                        Spacer(minLength: 44)

                        pitchSummaryMetric(
                            title: "Team Value",
                            value: teamValue,
                            displayValue: "£\(teamValue.formatted(.number.precision(.fractionLength(1))))m",
                            target: 100,
                            tint: Color(red: 0.12, green: 0.73, blue: 0.25),
                            isLoading: false
                        )
                        .allowsHitTesting(false)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }

                FantasyPitchDetailToggleButton(mode: detailMode)
                    .padding(.bottom, 10)
                    .padding(.leading, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                if data.hasActiveFixtures {
                    FantasyPitchLivePill()
                        .padding(.bottom, 12)
                        .padding(.trailing, 12)
                }
            }
            .frame(height: 576)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.34), radius: 16, x: 0, y: 9)
        }
    }

    private func pitchSummaryMetric(
        title: String,
        value: Double?,
        displayValue: String?,
        target: Double,
        tint: Color,
        isLoading: Bool,
        footer: String? = nil
    ) -> some View {
        let cardShape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        return VStack(spacing: 4) {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                FantasyTeamSummaryRing(
                    ratio: value.map { max($0 / target, 0) },
                    centerText: displayValue,
                    tint: tint,
                    isLoading: isLoading,
                    diameter: 52,
                    lineWidth: 5
                )
            }
            .padding(.vertical, 9)
            .frame(width: 92)
            .background {
                cardShape
                    .fill(.thinMaterial)
                    .overlay {
                        cardShape
                            .fill(Color(red: 0.025, green: 0.14, blue: 0.095).opacity(0.22))
                    }
            }
            .overlay {
                cardShape
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.30),
                                tint.opacity(0.20),
                                Color.white.opacity(0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: Color.black.opacity(0.22), radius: 7, x: 0, y: 3)

            if let footer {
                Text(footer)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.76))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
        .frame(width: 92)
        .accessibilityElement(children: .combine)
    }

    private func gameweekPerformanceTint(score: Int, average: Int?) -> Color {
        guard let average else {
            return Color(red: 0.95, green: 0.62, blue: 0.16)
        }

        switch score - average {
        case ...(-3):
            return Color(red: 0.92, green: 0.23, blue: 0.20)
        case 3...:
            return Color(red: 0.24, green: 0.76, blue: 0.30)
        default:
            return Color(red: 0.95, green: 0.62, blue: 0.16)
        }
    }

    private func positionRow(
        _ players: [FantasyDisplayPlayer],
        gameweekID: Int,
        playerSelectionEnabled: Bool,
        detailMode: FantasyPitchPlayerDetailMode,
        scorePhase: FantasySquadDisplayData.ScorePhase,
        showsPoints: Bool = true
    ) -> some View {
        GeometryReader { proxy in
            let count = max(players.count, 1)
            let spacing = FantasyPitchLayout.playerSpacing(
                for: players.count,
                availableWidth: proxy.size.width
            )
            let availableWidth = proxy.size.width - (CGFloat(count - 1) * spacing)
            let cardWidth = FantasyPitchLayout.playerCardWidth(
                for: count,
                availableWidth: availableWidth
            )

            HStack(spacing: spacing) {
                ForEach(players) { player in
                    selectablePlayerCard(
                        player: player,
                        width: cardWidth,
                        gameweekID: gameweekID,
                        playerSelectionEnabled: playerSelectionEnabled,
                        detailMode: detailMode,
                        scorePhase: scorePhase,
                        showsPoints: showsPoints
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 122)
    }

    private func benchSection(
        _ data: FantasySquadDisplayData,
        playerSelectionEnabled: Bool,
        detailMode: FantasyPitchPlayerDetailMode,
        showsPoints: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bench")
                .font(.headline)

            GeometryReader { proxy in
                let count = max(data.bench.count, 1)
                let spacing = FantasyPitchLayout.benchSpacing(
                    for: data.bench.count,
                    availableWidth: proxy.size.width
                )
                let availableWidth = proxy.size.width - (CGFloat(count - 1) * spacing)
                let cardWidth = FantasyPitchLayout.benchCardWidth(
                    for: count,
                    availableWidth: availableWidth
                )

                HStack(spacing: spacing) {
                    ForEach(data.bench) { player in
                        selectablePlayerCard(
                            player: player,
                            width: cardWidth,
                            gameweekID: data.gameweekID,
                            playerSelectionEnabled: playerSelectionEnabled,
                            detailMode: detailMode,
                            scorePhase: data.scorePhase,
                            showsPoints: showsPoints
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 128)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.065, green: 0.08, blue: 0.075), Color(red: 0.035, green: 0.045, blue: 0.042)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.09), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private func selectablePlayerCard(
        player: FantasyDisplayPlayer,
        width: CGFloat,
        gameweekID: Int,
        playerSelectionEnabled: Bool,
        detailMode: FantasyPitchPlayerDetailMode,
        scorePhase: FantasySquadDisplayData.ScorePhase,
        showsPoints: Bool = true
    ) -> some View {
        if playerSelectionEnabled {
            Button {
                openPlayerDetails(player: player, gameweekID: gameweekID)
            } label: {
                FantasyPlayerCard(
                    player: player,
                    width: width,
                    detailMode: detailMode,
                    scorePhase: scorePhase,
                    showsPoints: showsPoints
                )
            }
            .buttonStyle(.plain)
        } else {
            FantasyPlayerCard(
                player: player,
                width: width,
                detailMode: detailMode,
                scorePhase: scorePhase,
                showsPoints: showsPoints
            )
        }
    }

    @ViewBuilder
    private func eventLegendSection(_ data: FantasySquadDisplayData) -> some View {
        let goalLine = legendLine(
            emoji: "⚽️",
            title: "Goals scored",
            players: legendPlayers(data.allPlayers, value: \.goalsScored)
        )
        let assistLine = legendLine(
            emoji: "🅰️",
            title: "Assists",
            players: legendPlayers(data.allPlayers, value: \.assists)
        )
        let yellowLine = legendLine(
            emoji: "🟨",
            title: "Yellow cards",
            players: legendPlayers(data.allPlayers, value: \.yellowCards)
        )
        let redLine = legendLine(
            emoji: "🟥",
            title: "Red cards",
            players: legendPlayers(data.allPlayers, value: \.redCards)
        )

        let lines = [goalLine, assistLine, yellowLine, redLine].compactMap { $0 }

        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Legend")
                    .font(.headline)

                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }

    private func scoreCalculationSection(_ data: FantasySquadDisplayData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("* Score calculation")
                .font(.headline)

            if data.scoreCalculationRulesApplied.isEmpty {
                Text("Score is estimated based on player stats, and is subject to change")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(data.scoreCalculationRulesApplied, id: \.self) { rule in
                    Text("• \(rule)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func legendLine(emoji: String, title: String, players: [String]) -> String? {
        guard !players.isEmpty else { return nil }
        return "\(emoji) \(title) (\(players.joined(separator: ", ")))"
    }

    private func legendPlayers(
        _ players: [FantasyDisplayPlayer],
        value: KeyPath<FantasyDisplayPlayer, Int>
    ) -> [String] {
        players
            .filter { $0[keyPath: value] > 0 }
            .map { "\($0.displayName) x\($0[keyPath: value])" }
    }

    private func summaryPill(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.tertiarySystemGroupedBackground))
        )
    }

    private func errorCard(_ message: String) -> some View {
        Group {
            if fantasyViewModel.requiresAuthentication {
                fantasySignInCard
            } else if fantasyViewModel.isShowingGameUpdatingState {
                gameUpdatingCard
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Fantasy data unavailable")
                        .font(.headline)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("Retry now") {
                        triggerFantasyRefresh(force: true)
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
            }
        }
    }

    private var fantasySignInCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Sign in to load your current team", systemImage: "person.crop.circle.badge.checkmark")
                .font(.headline)
            Text("The current-team API is private. Sign in securely on the official Fantasy Premier League page to continue.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("Sign in to FPL") {
                showFantasySignIn = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var gameUpdatingCard: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))

                Circle()
                    .stroke(Color.accentColor.opacity(0.20), lineWidth: 1)

                TimelineView(.animation) { context in
                    let cycleDuration = 1.6
                    let phase = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
                    let pulse = phase < 0.5 ? phase * 2.0 : (1.0 - phase) * 2.0
                    let opacity = 0.74 + (0.26 * pulse)

                    FantasyLionIconView(size: 42, scale: 0.94)
                        .foregroundStyle(Color.accentColor)
                        .opacity(opacity)
                        .frame(width: 42, height: 42)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                }
                .frame(width: 42, height: 42)
                .transaction { transaction in
                    transaction.animation = nil
                }
            }
            .frame(width: 76, height: 76)

            VStack(spacing: 8) {
                Text("FPL is updating right now")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text("The official Fantasy Premier League game is being updated, so your squad and scores will return shortly. Stay tuned...")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("Check again") {
                triggerFantasyRefresh(force: true)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.accentColor.opacity(0.12), lineWidth: 1)
        )
    }

    private var shareLoadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                Text("Preparing share sheet...")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.15), value: isLaunchingShareFlow)
    }

    private func beginScreenViewTiming() {
        screenOpenedAt = Date()
        screenViewSentForActivation = false
        let isIdle = !fantasyViewModel.isLoading && !fantasyViewModel.isRefreshing
        if isIdle {
            sendTimedScreenView()
        }
    }

    private func sendTimedScreenView() {
        guard !screenViewSentForActivation else { return }
        screenViewSentForActivation = true
        let durationMs = screenOpenedAt.map { Int(Date().timeIntervalSince($0) * 1000) }
        screenOpenedAt = nil
        AppMetricsService.shared.fireScreenView(screen: "fantasy", durationMs: durationMs, apiBaseURL: preferences.apiBaseURL)
    }

    private func triggerFantasyRefresh(
        force: Bool,
        rivalManagers rivalManagersOverride: [FantasyRivalManager]? = nil,
        trackedLeagues trackedLeaguesOverride: [FantasyTrackedLeague]? = nil
    ) {
        guard isFantasySetupReadyForRefresh else { return }
        guard isSelected else { return }
        guard scenePhase == .active else { return }
        guard hasLoadedFantasyStorageState || rivalManagersOverride != nil || trackedLeaguesOverride != nil else { return }

        let rivalManagersSnapshot = rivalManagersOverride ?? rivalManagers
        let trackedLeaguesSnapshot = trackedLeaguesOverride ?? trackedLeagues
        let request = PendingFantasyRefreshRequest(
            force: force,
            rivalManagers: rivalManagersSnapshot,
            trackedLeagues: trackedLeaguesSnapshot
        )
        if !force,
           let lastStartedFantasyRefreshRequest,
           let lastStartedFantasyRefreshAt,
           lastStartedFantasyRefreshRequest == request,
           Date().timeIntervalSince(lastStartedFantasyRefreshAt) < fantasyAutomaticRefreshMinimumInterval {
            return
        }

        if fantasyRefreshTask != nil || fantasyViewModel.isLoading || fantasyViewModel.isRefreshing {
            if inFlightFantasyRefreshRequest != request {
                pendingFantasyRefreshRequest = request
            }
            PerformanceSignposter.fantasy.emitEvent("FantasyRefreshQueued")
            #if DEBUG
            diagnosticPrint(
                "[FantasyUI] queue_refresh force=\(force) rivals=\(rivalManagersSnapshot.count) leagues=\(trackedLeaguesSnapshot.count)"
            )
            #endif
            return
        }

        PerformanceSignposter.fantasy.emitEvent("FantasyRefreshTriggered")
        #if DEBUG
        diagnosticPrint(
            "[FantasyUI] trigger_refresh force=\(force) rivals=\(rivalManagersSnapshot.count) leagues=\(trackedLeaguesSnapshot.count)"
        )
        #endif

        inFlightFantasyRefreshRequest = request
        lastStartedFantasyRefreshRequest = request
        lastStartedFantasyRefreshAt = Date()
        let task = Task {
            await fantasyViewModel.refresh(
                managerEntryID: managerEntryID,
                apiBaseURL: preferences.apiBaseURL,
                rivalManagers: rivalManagersSnapshot,
                trackedLeagues: trackedLeaguesSnapshot
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                fantasyRefreshTask = nil
                inFlightFantasyRefreshRequest = nil
                drainPendingFantasyRefreshIfNeeded()
            }
        }
        fantasyRefreshTask = task
    }

    private func triggerFantasyScoreRefresh(force: Bool = false) {
        guard isFantasySetupReadyForRefresh,
              isSelected,
              scenePhase == .active,
              fantasyViewModel.data != nil,
              fantasyScoreRefreshTask == nil,
              fantasyRefreshTask == nil,
              !fantasyViewModel.isLoading,
              !fantasyViewModel.isRefreshing else {
            return
        }

        if !force,
           let lastStartedFantasyScoreRefreshAt,
           Date().timeIntervalSince(lastStartedFantasyScoreRefreshAt) <
                fantasyViewModel.automaticScoreRefreshMinimumInterval {
            return
        }

        lastStartedFantasyScoreRefreshAt = Date()
        let task = Task {
            let becameFinal = await fantasyViewModel.refreshCurrentScores()
            guard !Task.isCancelled else { return }
            fantasyScoreRefreshTask = nil
            if becameFinal {
                triggerFantasyRefresh(
                    force: true,
                    rivalManagers: rivalManagers,
                    trackedLeagues: trackedLeagues
                )
            }
        }
        fantasyScoreRefreshTask = task
    }

    private func migrateLegacyInitialSetupIfNeeded() {
        guard !managerEntryID.isEmpty else { return }
        guard initialSetupVersion < Self.currentInitialSetupVersion else { return }
        initialSetupVersion = Self.currentInitialSetupVersion
    }

    private func beginInitialSetup(force: Bool = false) {
        guard !managerEntryID.isEmpty else { return }
        guard isSelected else { return }
        guard scenePhase == .active else { return }
        if isRunningInitialSetup && !force {
            return
        }
        if initialSetupVersion >= Self.currentInitialSetupVersion && !force {
            return
        }

        isRunningInitialSetup = true
        initialSetupErrorMessage = nil
        setupRivalCandidates = []
        selectedSetupRivalEntryIDs = []
        setupRivalSearchText = ""

        Task {
            do {
                let payload = try await fantasyViewModel.prepareInitialSetup(managerEntryID: managerEntryID)
                await MainActor.run {
                    trackedLeagues = payload.trackedLeagues
                    persistTrackedLeaguesToStorage(payload.trackedLeagues)
                    managerCaptureStatusMessage = "Fantasy account linked successfully."

                    if payload.rivalCandidates.isEmpty {
                        completeInitialSetup(with: [])
                    } else {
                        setupRivalCandidates = payload.rivalCandidates
                        isRunningInitialSetup = false
                    }
                }
            } catch {
                await MainActor.run {
                    isRunningInitialSetup = false
                    initialSetupErrorMessage = error.localizedDescription
                    setShareImportStatus("Could not finish Fantasy setup yet.", isError: true)
                }
            }
        }
    }

    private func completeInitialSetup(with selectedCandidates: [FantasySetupRivalCandidate]) {
        let selectedRivals = selectedCandidates.map { candidate in
            let managerName = splitManagerName(candidate.managerName)
            return FantasyRivalManager(
                entryID: candidate.entryID,
                teamName: candidate.teamName,
                managerFirstName: managerName.firstName,
                managerLastName: managerName.lastName,
                overallPoints: candidate.totalPoints,
                clubBadgeSrc: candidate.clubBadgeSrc
            )
        }
        rivalManagers = selectedRivals
        persistRivalManagersToStorage(selectedRivals)
        initialSetupVersion = Self.currentInitialSetupVersion
        setupRivalCandidates = []
        selectedSetupRivalEntryIDs = []
        setupRivalSearchText = ""
        isRunningInitialSetup = false
        initialSetupErrorMessage = nil

        if selectedRivals.isEmpty {
            setShareImportStatus("Fantasy setup complete. Leagues imported.", isError: false)
        } else {
            setShareImportStatus(
                "Fantasy setup complete. Added \(selectedRivals.count) rivals and imported your leagues.",
                isError: false
            )
        }
        triggerFantasyRefresh(force: true, rivalManagers: selectedRivals, trackedLeagues: trackedLeagues)
    }

    private func splitManagerName(_ fullName: String) -> (firstName: String, lastName: String) {
        let components = fullName
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard let first = components.first else {
            return ("", "")
        }
        let last = components.dropFirst().joined(separator: " ")
        return (first, last)
    }

    private func toggleSetupRivalSelection(_ entryID: Int) {
        if selectedSetupRivalEntryIDs.contains(entryID) {
            selectedSetupRivalEntryIDs.remove(entryID)
        } else {
            selectedSetupRivalEntryIDs.insert(entryID)
        }
    }

    private func normalizedSetupSearchValue(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func drainPendingFantasyRefreshIfNeeded() {
        guard let pendingRequest = pendingFantasyRefreshRequest else { return }
        guard fantasyRefreshTask == nil else { return }
        guard !fantasyViewModel.isLoading, !fantasyViewModel.isRefreshing else { return }

        self.pendingFantasyRefreshRequest = nil
        triggerFantasyRefresh(
            force: pendingRequest.force,
            rivalManagers: pendingRequest.rivalManagers,
            trackedLeagues: pendingRequest.trackedLeagues
        )
    }

    private var fantasyAutomaticRefreshMinimumInterval: TimeInterval {
        fantasyViewModel.data?.hasActiveFixtures == true ? 30 : 15 * 60
    }

    private func prepareRivalEntrySheet() {
        addSheetMode = .rival
        rivalEntryInput = ""
        rivalValidationErrorMessage = nil
        leagueValidationErrorMessage = nil
        pendingRivalProfile = nil
        pendingLeagueStanding = nil
        isValidatingRival = false
        isValidatingLeague = false
        showAddRivalSheet = true
    }

    private func prepareLeagueEntrySheet() {
        addSheetMode = .league
        rivalEntryInput = ""
        rivalValidationErrorMessage = nil
        leagueValidationErrorMessage = nil
        pendingRivalProfile = nil
        pendingLeagueStanding = nil
        isValidatingRival = false
        isValidatingLeague = false
        showAddRivalSheet = true
    }

    private func validateAddSheetInput() async {
        switch addSheetMode {
        case .rival:
            await validateRivalEntryInput()
        case .league:
            await validateLeagueIDInput()
        }
    }

    private func autoPopulateAddSheetIDFromClipboard(forceRead: Bool) {
        guard showAddRivalSheet else { return }
        let pasteboard = UIPasteboard.general
        let changeCount = pasteboard.changeCount
        guard forceRead || changeCount != lastObservedClipboardChangeCount else { return }
        lastObservedClipboardChangeCount = changeCount

        guard let extractedID = extractFantasyIDFromPasteboard(pasteboard),
              extractedID.count >= 3 else {
            return
        }
        guard rivalEntryInput != extractedID else { return }

        rivalEntryInput = extractedID
        pendingRivalProfile = nil
        pendingLeagueStanding = nil
        rivalValidationErrorMessage = nil
        leagueValidationErrorMessage = nil
    }

    private func extractFantasyIDFromPasteboard(_ pasteboard: UIPasteboard) -> String? {
        if let rawString = pasteboard.string,
           let extracted = extractFantasyID(from: rawString) {
            return extracted
        }

        if let url = pasteboard.url,
           let extracted = extractFantasyID(from: url.absoluteString) {
            return extracted
        }

        return nil
    }

    private func extractFantasyID(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let target = FantasySharedURLParser.parse(from: trimmed) {
            switch target {
            case .manager(let id), .league(let id):
                return id
            }
        }

        guard trimmed.range(of: #"^\d{3,}$"#, options: .regularExpression) != nil else {
            return nil
        }

        return trimmed
    }

    private func validateManagerEntryInput() async {
        managerValidationErrorMessage = nil

        let trimmed = managerDigitsInput
        guard !trimmed.isEmpty else {
            managerValidationErrorMessage = "Enter a manager ID to continue."
            return
        }
        guard trimmed.allSatisfy(\.isNumber) else {
            managerValidationErrorMessage = "Manager ID must contain numbers only."
            return
        }
        guard trimmed.count >= 3 else {
            managerValidationErrorMessage = "Enter at least 3 digits."
            return
        }
        guard let entryID = Int(trimmed), entryID > 0 else {
            managerValidationErrorMessage = "Manager ID is invalid."
            return
        }

        isValidatingManager = true
        defer { isValidatingManager = false }

        do {
            let profile = try await fantasyViewModel.validateRivalEntryID(String(entryID))
            managerEntryID = String(profile.id)
            managerEntryInput = ""
            managerValidationErrorMessage = nil
            managerCaptureStatusMessage = "Fantasy account linked successfully."
            setShareImportStatus("Fantasy account linked: \(profile.name)", isError: false)
        } catch {
            managerValidationErrorMessage = error.localizedDescription
        }
    }

    private func validateRivalEntryInput() async {
        rivalValidationErrorMessage = nil
        pendingRivalProfile = nil
        pendingLeagueStanding = nil

        let trimmed = rivalEntryInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            rivalValidationErrorMessage = "Enter a manager ID to continue."
            return
        }
        guard trimmed.allSatisfy(\.isNumber) else {
            rivalValidationErrorMessage = "Manager ID must contain numbers only."
            return
        }
        guard let entryID = Int(trimmed), entryID > 0 else {
            rivalValidationErrorMessage = "Manager ID is invalid."
            return
        }
        if entryID == Int(managerEntryID) {
            rivalValidationErrorMessage = "That is your own manager ID. Add a different manager."
            return
        }

        if rivalManagers.contains(where: { $0.entryID == entryID }) {
            rivalValidationErrorMessage = "That manager is already in your rivals list."
            return
        }

        isValidatingRival = true
        defer { isValidatingRival = false }

        do {
            let profile = try await fantasyViewModel.validateRivalEntryID(trimmed)
            pendingRivalProfile = profile
            rivalEntryInput = String(profile.id)
        } catch {
            rivalValidationErrorMessage = error.localizedDescription
        }
    }

    private func validateLeagueIDInput() async {
        leagueValidationErrorMessage = nil
        pendingLeagueStanding = nil
        pendingRivalProfile = nil

        let trimmed = rivalEntryInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            leagueValidationErrorMessage = "Enter a league ID to continue."
            return
        }
        guard trimmed.allSatisfy(\.isNumber) else {
            leagueValidationErrorMessage = "League ID must contain numbers only."
            return
        }
        guard let leagueID = Int(trimmed), leagueID > 0 else {
            leagueValidationErrorMessage = "League ID is invalid."
            return
        }

        if trackedLeagues.contains(where: { $0.leagueID == leagueID }) {
            leagueValidationErrorMessage = "That league is already in your leagues list."
            return
        }

        isValidatingLeague = true
        defer { isValidatingLeague = false }

        do {
            let standing = try await fantasyViewModel.validateLeagueID(trimmed, managerEntryID: managerEntryID)
            pendingLeagueStanding = standing
            rivalEntryInput = String(standing.leagueID)
        } catch {
            leagueValidationErrorMessage = error.localizedDescription
        }
    }

    private func addPendingRivalProfile() {
        guard let pendingRivalProfile else { return }
        let rival = FantasyRivalManager(
            entryID: pendingRivalProfile.id,
            teamName: pendingRivalProfile.name,
            managerFirstName: pendingRivalProfile.playerFirstName,
            managerLastName: pendingRivalProfile.playerLastName,
            overallPoints: pendingRivalProfile.summaryOverallPoints,
            clubBadgeSrc: pendingRivalProfile.clubBadgeSrc
        )
        guard !rivalManagers.contains(where: { $0.entryID == rival.entryID }) else {
            return
        }

        var updatedRivals = rivalManagers
        updatedRivals.append(rival)
        updatedRivals.sort { lhs, rhs in
            let left = lhs.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
            let right = rhs.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
            if left.localizedCaseInsensitiveCompare(right) != .orderedSame {
                return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
            }
            return lhs.entryID < rhs.entryID
        }
        rivalManagers = updatedRivals
        persistRivalManagersToStorage(updatedRivals)
        showAddRivalSheet = false
        triggerFantasyRefresh(force: true, rivalManagers: updatedRivals)
    }

    private func addPendingLeagueStanding() {
        guard let pendingLeagueStanding else { return }
        let league = FantasyTrackedLeague(leagueID: pendingLeagueStanding.leagueID)
        guard !trackedLeagues.contains(where: { $0.leagueID == league.leagueID }) else { return }

        var updatedLeagues = trackedLeagues
        updatedLeagues.append(league)
        updatedLeagues.sort { $0.leagueID < $1.leagueID }
        trackedLeagues = updatedLeagues
        persistTrackedLeaguesToStorage(updatedLeagues)
        showAddRivalSheet = false
        triggerFantasyRefresh(force: true, trackedLeagues: updatedLeagues)
    }

    private func removeRival(entryID: Int) {
        let updatedRivals = rivalManagers.filter { $0.entryID != entryID }
        rivalManagers = updatedRivals
        persistRivalManagersToStorage(updatedRivals)
        triggerFantasyRefresh(force: true, rivalManagers: updatedRivals)
    }

    private func openLeagueSummary(_ league: FantasyTrackedLeagueStanding) {
        if league.canOpenDetails {
            selectedLeagueStanding = league
            return
        }

        guard league.leagueType == "x" else {
            selectedLeagueStanding = league
            return
        }
        guard let currentManagerEntryID else { return }
        guard !leagueIDLoadingDetails.contains(league.leagueID) else { return }

        leagueIDLoadingDetails.insert(league.leagueID)
        Task {
            do {
                let detailedLeague = try await fantasyViewModel.loadLeagueStandingDetails(
                    leagueID: league.leagueID,
                    managerEntryID: String(currentManagerEntryID)
                )
                await MainActor.run {
                    selectedLeagueStanding = detailedLeague
                    leagueIDLoadingDetails.remove(league.leagueID)
                }
            } catch {
                await MainActor.run {
                    selectedLeagueStanding = league
                    leagueIDLoadingDetails.remove(league.leagueID)
                }
            }
        }
    }

    private func openPlayerLeague(_ league: FantasyEntryClassicLeague) {
        if let loadedLeague = fantasyViewModel.trackedLeagueStandings.first(where: {
            $0.leagueID == league.id
        }) {
            openLeagueSummary(loadedLeague)
            return
        }

        guard let currentManagerEntryID else { return }
        openLeagueSummary(
            FantasyTrackedLeagueStanding(
                leagueID: league.id,
                leagueName: league.name,
                myEntryID: currentManagerEntryID,
                myRank: league.resolvedEntryRank,
                myLastRank: league.resolvedEntryLastRank,
                myEventTotal: nil,
                myOverallTotal: league.resolvedTotalPoints,
                myEntryName: fantasyViewModel.myProfile?.name,
                standings: [],
                leagueType: league.leagueType,
                rankCount: league.resolvedMemberCount
            )
        )
    }

    private func openLeagueMemberSquad(_ member: FantasyClassicLeagueStandingEntry) {
        guard leagueMemberEntryIDLoading == nil else { return }

        leagueMemberLoadTask?.cancel()
        leagueMemberEntryIDLoading = member.entry
        leagueMemberLoadErrorMessage = ""
        leagueMemberLoadTask = Task {
            defer {
                if leagueMemberEntryIDLoading == member.entry {
                    leagueMemberEntryIDLoading = nil
                }
            }

            do {
                let squad = try await fantasyViewModel.loadLeagueMemberSquad(member)
                try Task.checkCancellation()
                selectedLeagueMemberSquad = squad
            } catch is CancellationError {
                return
            } catch let urlError as URLError where urlError.code == .cancelled {
                return
            } catch {
                let message = error.localizedDescription
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                leagueMemberLoadErrorMessage = message.contains("not public yet")
                    ? message
                    : "\(member.entryName)'s latest team is unavailable right now. Please try again shortly."
                showLeagueMemberLoadError = true
            }
        }
    }

    private func openLeagueTableEntry(_ entry: FantasyLeagueTableEntry) {
        guard let squad = entry.squad else { return }
        let rivalExpectedPointsSection = fantasyViewModel.rivalSquads
            .first(where: { $0.entryID == entry.entryID })?
            .expectedPointsSection
        selectedRivalSquad = FantasyRivalSquad(
            entryID: entry.entryID,
            teamName: entry.teamName,
            managerName: entry.managerName,
            clubBadgeSrc: entry.clubBadgeSrc,
            squad: squad,
            allGameweeksPoints: entry.allGameweeksScore,
            projectedGameweekPoints: entry.projectedGameweekPoints,
            expectedPointsSection: rivalExpectedPointsSection,
            isExpectedPointsLoading: entry.isExpectedPointsLoading
        )
    }

    private func openPlayerDetails(player: FantasyDisplayPlayer, gameweekID: Int) {
        let selection = FantasySelectedPlayerSelection(
            player: player,
            gameweekID: gameweekID
        )

        if selectedLeagueMemberSquad != nil {
            selectedLeagueMemberPlayerSelection = selection
            return
        }

        if selectedRivalSquad != nil {
            pendingPlayerSelectionAfterRivalDismiss = selection
            selectedRivalSquad = nil
            return
        }

        selectedPlayerSelection = selection
    }

    private func prepareReviewShareSheet() {
        shareRemovedEntryIDs = []
        isPreparingShareImage = false
        showReviewShareSheet = true
    }

    private func toggleShareInclusion(for entry: FantasyLeagueTableEntry) {
        guard !entry.isUser else { return }

        if shareRemovedEntryIDs.contains(entry.entryID) {
            shareRemovedEntryIDs.remove(entry.entryID)
            return
        }

        guard reviewShareEntries.count > 2 else { return }
        shareRemovedEntryIDs.insert(entry.entryID)
    }

    private func shareLeagueTable() {
        let includedEntries = reviewShareEntries
        guard includedEntries.count >= 2 else { return }
        guard let squad = fantasyViewModel.data else { return }
        let hasEstimatedScores = includedEntries.contains { entry in
            entry.squad?.isEstimatedScore == true
        }

        isPreparingShareImage = true
        isLaunchingShareFlow = true

        Task { @MainActor in
            let image = FantasyLeagueShareImageRenderer.render(
                gameweekTitle: squad.gameweekTitle,
                rows: includedEntries,
                scoreMode: rivalsScoreMode,
                showEstimatedFooter: hasEstimatedScores
            )
            isPreparingShareImage = false

            if let image {
                #if DEBUG
                diagnosticPrint("[FantasyShare] rendered image size=\(Int(image.size.width))x\(Int(image.size.height)) scale=\(image.scale)")
                #endif
                queuedShareItems = [FantasyImageShareItemSource(image: image)]
                showReviewShareSheet = false
            } else {
                #if DEBUG
                diagnosticPrint("[FantasyShare] render returned nil")
                #endif
                isLaunchingShareFlow = false
            }
        }
    }

    private func presentShareSheet(with items: [Any]) {
        guard activeSharePayload == nil else { return }
        #if DEBUG
        let typeDescriptions = items.map { String(describing: type(of: $0)) }.joined(separator: ",")
        diagnosticPrint("[FantasyShare] presenting share sheet items=\(items.count) types=[\(typeDescriptions)]")
        #endif
        activeSharePayload = FantasySharePayload(items: items)
        isLaunchingShareFlow = false
    }

    private func instructionStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number).")
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(text)
        }
        .font(.subheadline)
    }

    private func openFantasyWebsiteInBrowser() {
        guard let url = URL(string: "https://fantasy.premierleague.com/") else { return }
        armSharedEntryPolling()
        openURL(url)
    }

    private func completeFantasySignIn(_ entryID: Int?) {
        if let entryID, entryID > 0 {
            managerEntryID = String(entryID)
            managerCaptureStatusMessage = "Successfully connected your account. Finalising setup..."
            return
        }

        guard !managerEntryID.isEmpty else { return }
        triggerFantasyRefresh(force: true)
    }

    private func openFantasyLeagues() {
        guard let url = URL(string: "https://fantasy.premierleague.com/leagues/cups") else { return }
        openURL(url)
    }

    private func applyCapturedManagerID(_ capturedID: String) {
        guard capturedID.allSatisfy(\.isNumber), !capturedID.isEmpty else {
            managerCaptureStatusMessage = "Shared URL did not include a valid manager ID. Share the Points page URL."
            return
        }

        managerEntryID = capturedID
        managerCaptureStatusMessage = "Successfully connected your account. Finalising setup..."
    }

    private func consumeSharedFantasyEntryURLIfNeeded() {
        guard !isProcessingSharedEntryImport else { return }
        guard Date() >= nextSharedEntryRetryAt else { return }
        guard let defaults = UserDefaults(suiteName: AppGroupConfig.identifier) else { return }
        guard let pendingImport = nextPendingSharedFantasyImport(from: defaults) else { return }

        let trimmed = pendingImport.payload.trimmedRawURL
        guard !trimmed.isEmpty else {
            discardSharedFantasyImport(pendingImport, from: defaults)
            return
        }

        let sharedUpdatedAt = pendingImport.payload.updatedAt
        if pendingImport.source == .legacy,
           sharedUpdatedAt > 0,
           sharedUpdatedAt <= lastProcessedSharedEntryUpdatedAt {
            return
        }
        if pendingImport.source == .legacy,
           sharedUpdatedAt <= 0,
           trimmed == lastProcessedSharedEntryURL {
            return
        }

        guard let parsedTarget = FantasySharedURLParser.parse(from: trimmed) else {
            managerCaptureStatusMessage = "Received a shared link, but it did not contain a valid Fantasy entry or league URL."
            setShareImportStatus(
                "Received a shared link, but it did not contain a valid Fantasy entry or league URL.",
                isError: true
            )
            markSharedEntryAsProcessed(updatedAt: sharedUpdatedAt, rawURL: trimmed)
            discardSharedFantasyImport(pendingImport, from: defaults)
            consumeSharedFantasyEntryURLIfNeeded()
            return
        }

        if managerEntryID.isEmpty {
            switch parsedTarget {
            case .manager(let parsedID):
                applyCapturedManagerID(parsedID)
                setShareImportStatus("Fantasy Premier League account linked successfully!", isError: false)
            case .league:
                managerCaptureStatusMessage = "Link your own Fantasy manager account first by sharing your Points page URL."
                setShareImportStatus(
                    "Link your own Fantasy manager account first by sharing your Points page URL.",
                    isError: true
                )
            }
            markSharedEntryAsProcessed(updatedAt: sharedUpdatedAt, rawURL: trimmed)
            discardSharedFantasyImport(pendingImport, from: defaults)
            consumeSharedFantasyEntryURLIfNeeded()
            return
        }

        if showAddRivalSheet {
            showAddRivalSheet = false
        }

        isProcessingSharedEntryImport = true
        Task {
            let handled: Bool
            switch parsedTarget {
            case .manager(let parsedID):
                handled = await addRivalFromSharedEntryID(parsedID)
            case .league(let leagueID):
                handled = await addLeagueFromSharedLeagueID(leagueID)
            }
            await MainActor.run {
                if handled {
                    markSharedEntryAsProcessed(updatedAt: sharedUpdatedAt, rawURL: trimmed)
                    discardSharedFantasyImport(pendingImport, from: defaults)
                } else {
                    nextSharedEntryRetryAt = Date().addingTimeInterval(3)
                }
                isProcessingSharedEntryImport = false
                if handled {
                    consumeSharedFantasyEntryURLIfNeeded()
                }
            }
        }
    }

    @MainActor
    private func addRivalFromSharedEntryID(_ capturedID: String) async -> Bool {
        guard let entryID = Int(capturedID), entryID > 0 else {
            managerCaptureStatusMessage = "Shared URL did not contain a valid manager ID."
            setShareImportStatus("Shared URL did not contain a valid manager ID.", isError: true)
            return true
        }

        guard entryID != Int(managerEntryID) else {
            managerCaptureStatusMessage = "Shared entry ID \(capturedID) is already your linked manager ID."
            setShareImportStatus(
                "Shared entry ID \(capturedID) is already your linked manager ID.",
                isError: true
            )
            return true
        }

        guard !rivalManagers.contains(where: { $0.entryID == entryID }) else {
            managerCaptureStatusMessage = "Shared rival \(capturedID) is already in your rivals list."
            setShareImportStatus("Rival \(capturedID) is already in your rivals list.", isError: false)
            return true
        }

        do {
            let profile = try await fantasyViewModel.validateRivalEntryID(capturedID)
            let rival = FantasyRivalManager(
                entryID: profile.id,
                teamName: profile.name,
                managerFirstName: profile.playerFirstName,
                managerLastName: profile.playerLastName,
                overallPoints: profile.summaryOverallPoints,
                clubBadgeSrc: profile.clubBadgeSrc
            )
            guard !rivalManagers.contains(where: { $0.entryID == rival.entryID }) else {
                setShareImportStatus("Rival \(capturedID) is already in your rivals list.", isError: false)
                return true
            }
            var updatedRivals = rivalManagers
            updatedRivals.append(rival)
            updatedRivals.sort { lhs, rhs in
                let left = lhs.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
                let right = rhs.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
                if left.localizedCaseInsensitiveCompare(right) != .orderedSame {
                    return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
                }
                return lhs.entryID < rhs.entryID
            }
            rivalManagers = updatedRivals

            let managerNameParts = [
                profile.playerFirstName.trimmingCharacters(in: .whitespacesAndNewlines),
                profile.playerLastName.trimmingCharacters(in: .whitespacesAndNewlines)
            ].filter { !$0.isEmpty }
            let managerName = managerNameParts.joined(separator: " ")
            let rivalDisplayName = managerName.isEmpty ? profile.name : "\(profile.name) (\(managerName))"

            persistRivalManagersToStorage(updatedRivals)
            managerCaptureStatusMessage = "Rival added from shared URL: \(rivalDisplayName)."
            setShareImportStatus("Rival added: \(rivalDisplayName)", isError: false)
            rivalEntryInput = ""
            pendingRivalProfile = nil
            rivalValidationErrorMessage = nil
            showAddRivalSheet = false
            triggerFantasyRefresh(force: true, rivalManagers: updatedRivals)
            return true
        } catch {
            if let fantasyError = error as? FantasyPublicAPIError,
               case .gameUpdating = fantasyError {
                managerCaptureStatusMessage = "Fantasy Premier League is temporarily updating. We'll retry adding this rival shortly."
                setShareImportStatus(
                    "Fantasy Premier League is temporarily updating. We'll retry adding this rival shortly.",
                    isError: true
                )
                return false
            }
            managerCaptureStatusMessage = "Could not add shared rival ID \(capturedID): \(error.localizedDescription)"
            setShareImportStatus(
                "Could not add rival \(capturedID) yet. Retrying shortly.",
                isError: true
            )
            if case FantasyPublicAPIError.badStatus(let code, _, _) = error,
               code == 400 || code == 404 {
                return true
            }
            return false
        }
    }

    @MainActor
    private func addLeagueFromSharedLeagueID(_ capturedID: String) async -> Bool {
        guard let leagueID = Int(capturedID), leagueID > 0 else {
            setShareImportStatus("Shared URL did not contain a valid league ID.", isError: true)
            return true
        }

        guard !trackedLeagues.contains(where: { $0.leagueID == leagueID }) else {
            setShareImportStatus("League \(capturedID) is already in your leagues list.", isError: false)
            return true
        }

        do {
            let standing = try await fantasyViewModel.validateLeagueID(capturedID, managerEntryID: managerEntryID)
            var updatedLeagues = trackedLeagues
            updatedLeagues.append(FantasyTrackedLeague(leagueID: standing.leagueID))
            updatedLeagues.sort { $0.leagueID < $1.leagueID }
            trackedLeagues = updatedLeagues
            persistTrackedLeaguesToStorage(updatedLeagues)
            managerCaptureStatusMessage = "League added from shared URL: \(standing.leagueName)."
            if let rank = standing.myRank {
                setShareImportStatus("League added: \(standing.leagueName) (Rank \(rank))", isError: false)
            } else {
                setShareImportStatus("League added: \(standing.leagueName)", isError: false)
            }
            showAddRivalSheet = false
            triggerFantasyRefresh(force: true, trackedLeagues: updatedLeagues)
            return true
        } catch {
            if let fantasyError = error as? FantasyPublicAPIError,
               case .gameUpdating = fantasyError {
                setShareImportStatus(
                    "Fantasy Premier League is temporarily updating. We'll retry adding this league shortly.",
                    isError: true
                )
                return false
            }
            setShareImportStatus(
                "Could not add league \(capturedID) yet. Retrying shortly.",
                isError: true
            )
            if case FantasyPublicAPIError.badStatus(let code, _, _) = error,
               code == 400 || code == 404 {
                return true
            }
            return false
        }
    }

    private func nextPendingSharedFantasyImport(from defaults: UserDefaults) -> PendingSharedFantasyImport? {
        let queuedPayloads = FantasySharedImportStore.loadQueue(from: defaults)
        if let firstQueuedPayload = queuedPayloads.first {
            return PendingSharedFantasyImport(payload: firstQueuedPayload, source: .queue)
        }

        guard let legacyPayload = FantasySharedImportStore.loadLegacyPayload(from: defaults) else {
            return nil
        }
        return PendingSharedFantasyImport(payload: legacyPayload, source: .legacy)
    }

    private func discardSharedFantasyImport(_ pendingImport: PendingSharedFantasyImport, from defaults: UserDefaults) {
        switch pendingImport.source {
        case .queue:
            var queuedPayloads = FantasySharedImportStore.loadQueue(from: defaults)
            if let matchingIndex = queuedPayloads.firstIndex(of: pendingImport.payload) {
                queuedPayloads.remove(at: matchingIndex)
            } else if !queuedPayloads.isEmpty {
                queuedPayloads.removeFirst()
            }
            FantasySharedImportStore.saveQueue(queuedPayloads, to: defaults)
        case .legacy:
            FantasySharedImportStore.saveLegacyPayload(nil, to: defaults)
        }
    }

    private func markSharedEntryAsProcessed(updatedAt: TimeInterval, rawURL: String) {
        if updatedAt > 0 {
            lastProcessedSharedEntryUpdatedAt = updatedAt
        }
        lastProcessedSharedEntryURL = rawURL
    }

    private func armSharedEntryPolling() {
        sharedEntryPollingDeadline = Date().addingTimeInterval(12)
    }

    @MainActor
    private func pollForSharedFantasyEntry() async {
        guard let deadline = sharedEntryPollingDeadline else { return }

        while !Task.isCancelled, Date() <= deadline {
            guard isSelected, scenePhase == .active else { return }
            consumeSharedFantasyEntryURLIfNeeded()
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }

        if sharedEntryPollingDeadline == deadline {
            sharedEntryPollingDeadline = nil
        }
    }

    private func setShareImportStatus(_ message: String, isError: Bool) {
        shareImportStatusMessage = message
        shareImportStatusIsError = isError
    }

    private func syncManagerEntryIDToSharedDefaults() {
        guard let defaults = UserDefaults(suiteName: AppGroupConfig.identifier) else { return }
        let trimmed = managerEntryID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: AppGroupConfig.fantasyManagerEntryIDKey)
        } else {
            defaults.set(trimmed, forKey: AppGroupConfig.fantasyManagerEntryIDKey)
        }
        defaults.synchronize()
    }

    @discardableResult
    private func loadRivalManagersFromStorage() -> [FantasyRivalManager] {
        guard let data = rivalManagersJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([FantasyRivalManager].self, from: data) else {
            rivalManagers = []
            return []
        }
        rivalManagers = decoded
        return decoded
    }

    @discardableResult
    private func loadTrackedLeaguesFromStorage() -> [FantasyTrackedLeague] {
        guard let data = trackedLeaguesJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([FantasyTrackedLeague].self, from: data) else {
            trackedLeagues = []
            return []
        }
        trackedLeagues = decoded
        return decoded
    }

    private func persistRivalManagersToStorage(_ managers: [FantasyRivalManager]? = nil) {
        let managersToPersist = managers ?? rivalManagers
        guard let data = try? JSONEncoder().encode(managersToPersist),
              let encoded = String(data: data, encoding: .utf8) else {
            rivalManagersJSON = "[]"
            return
        }
        rivalManagersJSON = encoded
    }

    private func persistTrackedLeaguesToStorage(_ leagues: [FantasyTrackedLeague]? = nil) {
        let leaguesToPersist = leagues ?? trackedLeagues
        guard let data = try? JSONEncoder().encode(leaguesToPersist),
              let encoded = String(data: data, encoding: .utf8) else {
            trackedLeaguesJSON = "[]"
            return
        }
        trackedLeaguesJSON = encoded
    }

    private func formatNumber(_ value: Int?) -> String {
        guard let value else { return "-" }
        return Self.integerFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func formatTransfersValue(_ value: Int?) -> String {
        guard let value else { return "-" }
        if value > 0 {
            return "-\(value)"
        }
        return "\(value)"
    }

    private enum StorageKeys {
        static let managerEntryID = "fantasy.managerEntryID"
        static let rivalManagersJSON = "fantasy.rivalManagersJSON"
        static let trackedLeaguesJSON = "fantasy.trackedLeaguesJSON"
        static let initialSetupVersion = "fantasy.initialSetupVersion"
    }

    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}

private struct FantasyPitchBackground: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.055, green: 0.27, blue: 0.17),
                        Color(red: 0.025, green: 0.19, blue: 0.115),
                        Color(red: 0.035, green: 0.235, blue: 0.145)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                HStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { index in
                        Rectangle()
                            .fill(index.isMultiple(of: 2) ? Color.white.opacity(0.022) : Color.black.opacity(0.035))
                    }
                }

                RadialGradient(
                    colors: [Color.white.opacity(0.055), Color.clear],
                    center: .top,
                    startRadius: 0,
                    endRadius: proxy.size.height * 0.78
                )

                Path { path in
                    let width = proxy.size.width
                    let height = proxy.size.height
                    let inset: CGFloat = 14

                    let pitchRect = CGRect(
                        x: inset,
                        y: inset,
                        width: width - (inset * 2),
                        height: height - (inset * 2)
                    )

                    path.addRoundedRect(in: pitchRect, cornerSize: CGSize(width: 8, height: 8))

                    let halfwayY = pitchRect.midY
                    path.move(to: CGPoint(x: pitchRect.minX, y: halfwayY))
                    path.addLine(to: CGPoint(x: pitchRect.maxX, y: halfwayY))

                    let centerCircleRadius: CGFloat = min(58, width * 0.16)
                    path.addEllipse(
                        in: CGRect(
                            x: pitchRect.midX - centerCircleRadius,
                            y: halfwayY - centerCircleRadius,
                            width: centerCircleRadius * 2,
                            height: centerCircleRadius * 2
                        )
                    )

                    let penaltyWidth = pitchRect.width * 0.52
                    let penaltyDepth = pitchRect.height * 0.17
                    path.addRect(
                        CGRect(
                            x: pitchRect.midX - (penaltyWidth / 2),
                            y: pitchRect.minY,
                            width: penaltyWidth,
                            height: penaltyDepth
                        )
                    )
                    path.addRect(
                        CGRect(
                            x: pitchRect.midX - (penaltyWidth / 2),
                            y: pitchRect.maxY - penaltyDepth,
                            width: penaltyWidth,
                            height: penaltyDepth
                        )
                    )

                    let sixYardWidth = penaltyWidth * 0.48
                    let sixYardDepth = penaltyDepth * 0.46
                    path.addRect(
                        CGRect(
                            x: pitchRect.midX - (sixYardWidth / 2),
                            y: pitchRect.minY,
                            width: sixYardWidth,
                            height: sixYardDepth
                        )
                    )
                    path.addRect(
                        CGRect(
                            x: pitchRect.midX - (sixYardWidth / 2),
                            y: pitchRect.maxY - sixYardDepth,
                            width: sixYardWidth,
                            height: sixYardDepth
                        )
                    )
                }
                .stroke(Color(red: 0.77, green: 0.87, blue: 0.80).opacity(0.46), lineWidth: 1.35)

                LinearGradient(
                    colors: [Color.black.opacity(0.24), Color.clear, Color.black.opacity(0.28)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .allowsHitTesting(false)
            }
        }
    }
}

private enum FantasyPitchPlayerDetailMode {
    case opponent
    case price
    case difficulty
    case ownershipPercent
    case ownershipCount
    case form
    case pointsPerMatch
    case totalPoints
    case averageMinutes

    var buttonLabel: String {
        switch self {
        case .opponent: return "Opposition"
        case .price: return "Price"
        case .difficulty: return "Difficulty"
        case .ownershipPercent: return "Ownership %"
        case .ownershipCount: return "Ownership #"
        case .form: return "Form"
        case .pointsPerMatch: return "Pts / match"
        case .totalPoints: return "Total pts"
        case .averageMinutes: return "Avg. mins"
        }
    }

    var systemImageName: String {
        switch self {
        case .opponent:
            return "figure.soccer"
        case .price:
            return "sterlingsign.circle.fill"
        case .difficulty:
            return "circle.hexagongrid.fill"
        case .ownershipPercent, .ownershipCount:
            return "person.2.fill"
        case .form:
            return "chart.line.uptrend.xyaxis"
        case .pointsPerMatch, .totalPoints:
            return "number.circle.fill"
        case .averageMinutes:
            return "clock.fill"
        }
    }

    var accessibilityLabel: String {
        "Showing \(buttonLabel.lowercased())."
    }
}

private enum FantasyPitchLayout {
    static func playerSpacing(for playerCount: Int, availableWidth: CGFloat) -> CGFloat {
        guard playerCount > 1 else { return 0 }

        let preferredSpacing: CGFloat
        switch playerCount {
        case 2:
            preferredSpacing = 26
        case 3:
            preferredSpacing = 18
        case 4:
            preferredSpacing = 12
        default:
            preferredSpacing = 3
        }

        let minimumCardWidth: CGFloat = 44
        let maximumSpacing = max(
            3,
            (availableWidth - (CGFloat(playerCount) * minimumCardWidth)) / CGFloat(playerCount - 1)
        )
        return min(preferredSpacing, maximumSpacing)
    }

    static func playerCardWidth(for playerCount: Int, availableWidth: CGFloat) -> CGFloat {
        min(72, max(44, floor(availableWidth / CGFloat(max(playerCount, 1)))))
    }

    static func benchSpacing(for playerCount: Int, availableWidth: CGFloat) -> CGFloat {
        guard playerCount > 1 else { return 0 }
        let preferredSpacing: CGFloat = playerCount < 4 ? 18 : 12
        let minimumCardWidth: CGFloat = 48
        let maximumSpacing = max(
            6,
            (availableWidth - (CGFloat(playerCount) * minimumCardWidth)) / CGFloat(playerCount - 1)
        )
        return min(preferredSpacing, maximumSpacing)
    }

    static func benchCardWidth(for playerCount: Int, availableWidth: CGFloat) -> CGFloat {
        min(82, max(48, floor(availableWidth / CGFloat(max(playerCount, 1)))))
    }
}

private struct FantasyPitchDetailToggleButton: View {
    @Binding var mode: FantasyPitchPlayerDetailMode

    var body: some View {
        Menu {
            Button("Opposition", systemImage: "figure.soccer") { mode = .opponent }
            Button("Price", systemImage: "sterlingsign.circle.fill") { mode = .price }
            Button("Difficulty", systemImage: "circle.hexagongrid.fill") { mode = .difficulty }
            Button("Ownership %", systemImage: "person.2.fill") { mode = .ownershipPercent }
            Button("Ownership #", systemImage: "person.2.fill") { mode = .ownershipCount }
            Button("Form", systemImage: "chart.line.uptrend.xyaxis") { mode = .form }
            Button("Pts / match", systemImage: "number.circle.fill") { mode = .pointsPerMatch }
            Button("Total pts", systemImage: "number.circle.fill") { mode = .totalPoints }
            Button("Avg. mins", systemImage: "clock.fill") { mode = .averageMinutes }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: mode.systemImageName)
                    .font(.system(size: 10, weight: .semibold))
                Text(mode.buttonLabel)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .foregroundStyle(Color.white.opacity(0.94))
            .background(Color(red: 0.025, green: 0.045, blue: 0.04).opacity(0.9), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.22), radius: 5, x: 0, y: 2)
        }
        .accessibilityLabel(mode.accessibilityLabel)
    }
}

private struct FantasyPitchLivePill: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            livePill(pulse: fantasyLivePulseIntensity(at: context.date, reduceMotion: reduceMotion))
        }
    }

    private func livePill(pulse: Double) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.white)
                .frame(width: 7, height: 7)
                .opacity(1 - (0.7 * pulse))

            Text("Live")
                .font(.system(size: 12, weight: .bold, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            ZStack {
                Capsule(style: .continuous)
                    .fill(Color.red.opacity(0.92))
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.13 * pulse))
            }
        )
        .overlay {
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.68 - (0.46 * pulse)), lineWidth: 1)
        }
        .shadow(color: Color.red.opacity(0.38), radius: 10)
        .accessibilityLabel("Live Fantasy matches")
    }
}

private struct FantasyPlayerLiveScorePill: View {
    let points: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            liveScorePill(pulse: fantasyLivePulseIntensity(at: context.date, reduceMotion: reduceMotion))
        }
    }

    private func liveScorePill(pulse: Double) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.white)
                .frame(width: 5, height: 5)
                .opacity(1 - (0.7 * pulse))

            Text("\(points)")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2.5)
        .foregroundStyle(.white)
        .background(
            ZStack {
                Capsule(style: .continuous)
                    .fill(Color.red.opacity(0.92))
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.13 * pulse))
            }
        )
        .overlay {
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.68 - (0.44 * pulse)), lineWidth: 0.85)
        }
        .shadow(color: Color.red.opacity(0.34), radius: 6)
        .accessibilityLabel("Live, \(points) points")
    }
}

private func fantasyLivePulseIntensity(at date: Date, reduceMotion: Bool) -> Double {
    guard !reduceMotion else { return 0 }
    let cycleDuration = 1.44
    let cyclePosition = date.timeIntervalSinceReferenceDate
        .truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
    return (1 - cos(cyclePosition * 2 * .pi)) / 2
}

private struct FantasyPlayerCard: View {
    let player: FantasyDisplayPlayer
    let width: CGFloat
    let detailMode: FantasyPitchPlayerDetailMode
    let scorePhase: FantasySquadDisplayData.ScorePhase
    let showsPoints: Bool
    @ObservedObject private var teamColorCatalog = TeamColorCatalog.shared

    init(
        player: FantasyDisplayPlayer,
        width: CGFloat,
        detailMode: FantasyPitchPlayerDetailMode,
        scorePhase: FantasySquadDisplayData.ScorePhase,
        showsPoints: Bool = true
    ) {
        self.player = player
        self.width = width
        self.detailMode = detailMode
        self.scorePhase = scorePhase
        self.showsPoints = showsPoints
    }

    private var scoreState: FantasyDisplayPlayer.GameweekScoreState {
        player.gameweekScoreState
    }

    private enum ScorePresentation {
        case expected(Double)
        case live(Int)
        case provisional(Int)
        case confirmed(Int)
        case pending
        case expectedUnavailable
        case noFixture

        var accessibilityDescription: String {
            switch self {
            case .expected(let points):
                return "\(fantasyExpectedPointsText(points)) expected points"
            case .live(let points):
                return "\(points) live points"
            case .provisional(let points):
                return "\(points) provisional points"
            case .confirmed(let points):
                return "\(points) confirmed points"
            case .pending:
                return "has not played yet"
            case .expectedUnavailable:
                return "calculating expected points"
            case .noFixture:
                return "no fixture this gameweek"
            }
        }
    }

    private var scorePresentation: ScorePresentation {
        switch scorePhase {
        case .expected:
            switch scoreState {
            case .live:
                return .live(player.displayPoints)
            case .upcoming:
                if let playerExpectedPoints {
                    return .expected(playerExpectedPoints)
                }
                return .expectedUnavailable
            case .completed:
                return .confirmed(player.displayPoints)
            case .noFixture:
                return .noFixture
            }
        case .provisional:
            guard player.hasAnyFixtureThisGameweek else { return .noFixture }
            guard player.hasStartedFixtureThisGameweek else { return .pending }
            return player.hasActiveFixtureThisGameweek
                ? .live(player.displayPoints)
                : .provisional(player.displayPoints)
        case .final:
            guard player.hasAnyFixtureThisGameweek else { return .noFixture }
            guard player.hasStartedFixtureThisGameweek else { return .pending }
            return .confirmed(player.displayPoints)
        }
    }

    private var clubAccentColor: Color {
        teamColorCatalog.lineupColors(
            for: player.teamName,
            opponentTeamName: nil,
            isAway: false
        ).background
    }

    private var primaryTextColor: Color {
        player.isUnavailable ? Color.white.opacity(0.48) : Color.white.opacity(0.96)
    }

    private var secondaryTextColor: Color {
        player.isUnavailable ? Color.white.opacity(0.36) : Color.white.opacity(0.66)
    }

    private var accessibilityLabelText: String {
        let fixtureDifficultyText = player.fixtureDifficulty.map { ", fixture difficulty \($0)" } ?? ""
        return "\(player.displayName), \(secondaryDisplayText)\(fixtureDifficultyText), \(scorePresentation.accessibilityDescription), \(scoreState.accessibilityDescription)"
    }

    private var hasEventStats: Bool {
        player.goalsScored > 0 || player.assists > 0 || player.yellowCards > 0 || player.redCards > 0
    }

    private var opponentDisplayText: String {
        let trimmed = player.upcomingOpponentDisplay?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "No game" : trimmed
    }

    private var secondaryDisplayText: String {
        switch detailMode {
        case .opponent:
            return opponentDisplayText
        case .price:
            return String(format: "£%.1fm", player.nowCostMillions)
        case .difficulty:
            return ""
        case .ownershipPercent:
            guard let ownershipPercent = player.ownershipPercent else { return "-" }
            return String(format: "%.1f%%", ownershipPercent)
        case .ownershipCount:
            return abbreviatedManagerCount(player.ownershipCount)
        case .form:
            return player.form ?? "-"
        case .pointsPerMatch:
            return player.hasStartedCurrentSeason ? (player.pointsPerMatch ?? "0.0") : "0.0"
        case .totalPoints:
            return player.hasStartedCurrentSeason ? (player.totalPoints.map(String.init) ?? "0") : "0"
        case .averageMinutes:
            guard player.hasStartedCurrentSeason, let averageMinutes = player.averageMinutes else { return "0.0" }
            return String(format: "%.1f", averageMinutes)
        }
    }

    private var playerExpectedPoints: Double? {
        player.expectedPointsThisGameweek
    }

    var body: some View {
        let profileImageSize = max(42, min(width * 0.88, 62))
        let cornerRadius = max(9, width * 0.15)

        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                LinearGradient(
                    colors: [
                        clubAccentColor.opacity(player.isUnavailable ? 0.20 : 0.48),
                        Color(red: 0.025, green: 0.11, blue: 0.075).opacity(0.96)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                playerPortrait(size: profileImageSize)

                if player.isUnavailable || player.hasFutureAvailabilityIssue {
                    VStack(alignment: .leading, spacing: 3) {
                        if player.isUnavailable {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.orange)
                        }
                        if player.hasFutureAvailabilityIssue {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.blue)
                        }
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                if hasEventStats {
                    HStack(spacing: 3) {
                        if player.goalsScored > 0 {
                            eventStatBadge(symbol: "soccerball", color: .white, count: player.goalsScored)
                        }
                        if player.assists > 0 {
                            eventEmojiBadge(emoji: "🅰️", color: .mint, count: player.assists)
                        }
                        if player.yellowCards > 0 {
                            cardStatBadge(fill: Color.yellow, count: player.yellowCards, textColor: .black)
                        }
                        if player.redCards > 0 {
                            cardStatBadge(fill: Color.red, count: player.redCards, textColor: .white)
                        }
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }

                VStack(alignment: .trailing, spacing: 3) {
                    if player.isCaptain {
                        badge(text: "C", color: .yellow)
                    }
                    if player.isViceCaptain {
                        badge(text: "V", color: .cyan)
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .frame(width: width, height: 64)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(clubAccentColor.opacity(player.isUnavailable ? 0.22 : 0.82))
                    .frame(height: 2)
            }

            VStack(spacing: 2) {
                Text(player.displayName)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .foregroundStyle(primaryTextColor)

                if detailMode == .opponent {
                    Text(opponentDisplayText)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .foregroundStyle(opponentDifficultyTextColor)
                        .padding(.vertical, 2.5)
                        .frame(width: max(0, width - 12))
                        .background(
                            Capsule(style: .continuous)
                                .fill(opponentDifficultyColor)
                        )
                } else if detailMode == .difficulty {
                    difficultyDots
                } else {
                    Text(secondaryDisplayText)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                        .foregroundStyle(secondaryTextColor)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 5)
            .frame(width: width)
            .background(Color(red: 0.02, green: 0.035, blue: 0.031).opacity(0.96))

            scoreStatusPill(scorePresentation)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(width: width)
                .background(Color(red: 0.02, green: 0.035, blue: 0.031).opacity(0.96))
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [clubAccentColor.opacity(0.82), Color.white.opacity(0.18), clubAccentColor.opacity(0.36)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.15
                )
        }
        .opacity(player.isUnavailable ? 0.72 : 1)
        .shadow(
            color: Color.black.opacity(0.36),
            radius: 5,
            x: 0,
            y: 3
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText)
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .heavy, design: .rounded))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.95))
            )
            .foregroundStyle(.black.opacity(0.8))
    }

    private var opponentDifficultyColor: Color {
        guard opponentDisplayText != "No game", let difficulty = player.fixtureDifficulty else {
            return Color.white.opacity(0.10)
        }
        return fixtureDifficultyColor(difficulty).opacity(0.92)
    }

    private var opponentDifficultyTextColor: Color {
        guard let difficulty = player.fixtureDifficulty else {
            return Color.white.opacity(0.58)
        }
        return difficulty <= 3 ? Color.black.opacity(0.82) : Color.white
    }

    private var difficultyDots: some View {
        HStack(spacing: 3) {
            ForEach(Array(player.nextFiveFixtureDifficulties.prefix(5).enumerated()), id: \.offset) { _, difficulty in
                Circle()
                    .fill(difficulty.map(fixtureDifficultyColor) ?? Color.white.opacity(0.18))
                    .frame(width: 7, height: 7)
            }
            ForEach(0..<max(0, 5 - player.nextFiveFixtureDifficulties.count), id: \.self) { _ in
                Circle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 7, height: 7)
            }
        }
        .frame(height: 14)
        .accessibilityLabel(difficultyDotsAccessibilityLabel)
    }

    private var difficultyDotsAccessibilityLabel: String {
        let values = player.nextFiveFixtureDifficulties.prefix(5).map { difficulty in
            difficulty.map { "difficulty \($0)" } ?? "difficulty unavailable"
        }
        return values.isEmpty ? "No upcoming fixture difficulties" : values.joined(separator: ", ")
    }

    private func abbreviatedManagerCount(_ count: Int?) -> String {
        guard let count else { return "-" }
        if count >= 1_000_000 {
            return String(format: "%.2fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return String(count)
    }

    @ViewBuilder
    private func scoreStatusPill(_ presentation: ScorePresentation) -> some View {
        switch presentation {
        case .expected(let expectedPoints):
            statusPill(
                score: "\(fantasyExpectedPointsText(expectedPoints)) xP",
                label: nil,
                primaryColor: Color(red: 0.75, green: 0.30, blue: 0.96),
                fillColor: Color(red: 0.27, green: 0.055, blue: 0.37)
            )
        case .live(let points):
            FantasyPlayerLiveScorePill(points: points)
        case .provisional(let points):
            statusPill(
                score: "\(points)",
                label: nil,
                primaryColor: fantasyProvisionalPointsTint(points),
                fillColor: fantasyProvisionalPointsTint(points).opacity(0.31)
            )
        case .confirmed(let points):
            statusPill(
                score: "\(points)",
                label: "confirmed",
                primaryColor: Color(red: 0.20, green: 0.55, blue: 1.0),
                fillColor: Color(red: 0.035, green: 0.17, blue: 0.34)
            )
        case .pending:
            statusPill(
                score: "–",
                label: nil,
                primaryColor: Color.white.opacity(0.48),
                fillColor: Color.white.opacity(0.07)
            )
        case .expectedUnavailable:
            loadingExpectedPointsPill
        case .noFixture:
            statusPill(
                score: "No game",
                label: nil,
                primaryColor: Color.white.opacity(0.35),
                fillColor: Color.white.opacity(0.06)
            )
        }
    }

    private func statusPill(
        score: String,
        label: String?,
        primaryColor: Color,
        fillColor: Color
    ) -> some View {
        HStack(spacing: 0) {
            Text(score)
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .foregroundStyle(Color.white.opacity(0.96))
                .frame(maxWidth: .infinity)
                .padding(.leading, label == nil ? 0 : 5)

            if let label {
                Text(label)
                    .font(.system(size: label == "confirmed" ? 7.5 : 8.5, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                    .foregroundStyle(Color.white.opacity(0.96))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(primaryColor.opacity(0.88), in: Capsule(style: .continuous))
                    .padding(.trailing, 2)
            }
        }
        .padding(.vertical, 2.5)
        .background(fillColor, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(primaryColor.opacity(0.92), lineWidth: 0.85)
        )
    }

    private var loadingExpectedPointsPill: some View {
        let purple = Color(red: 0.75, green: 0.30, blue: 0.96)

        return HStack(spacing: 4) {
            ProgressView()
                .controlSize(.mini)
                .tint(.white.opacity(0.92))

            Text("xP")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.96))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2.5)
        .background(Color(red: 0.27, green: 0.055, blue: 0.37).opacity(0.48), in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(purple.opacity(0.85), lineWidth: 0.85)
        )
        .accessibilityLabel("Calculating expected points")
    }

    private func fixtureDifficultyColor(_ difficulty: Int) -> Color {
        switch difficulty {
        case ...1: return Color.green
        case 2: return Color(red: 0.29, green: 0.71, blue: 0.27)
        case 3: return Color(red: 0.95, green: 0.68, blue: 0.16)
        case 4: return Color(red: 0.91, green: 0.37, blue: 0.15)
        default: return Color(red: 0.78, green: 0.16, blue: 0.14)
        }
    }

    @ViewBuilder
    private func playerPortrait(size: CGFloat) -> some View {
        if let url = player.profileImageURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(width: size, height: size)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.top, 2)
                } else if case .failure = phase {
                    missingPlayerPortrait
                } else {
                    missingPlayerPortrait
                        .opacity(0.72)
                }
            }
        } else {
            missingPlayerPortrait
        }
    }

    private var missingPlayerPortrait: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: player.isUnavailable
                    ? [Color(red: 0.055, green: 0.06, blue: 0.062), Color.black.opacity(0.88)]
                    : [clubAccentColor.opacity(0.38), Color(red: 0.03, green: 0.08, blue: 0.13)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            GeometryReader { proxy in
                HStack(spacing: proxy.size.width * 0.12) {
                    ForEach(0..<4, id: \.self) { _ in
                        Rectangle()
                            .fill(Color.white.opacity(player.isUnavailable ? 0.018 : 0.05))
                            .frame(width: proxy.size.width * 0.08)
                            .rotationEffect(.degrees(-28))
                    }
                }
                .frame(width: proxy.size.width * 1.3, height: proxy.size.height)
                .offset(x: -proxy.size.width * 0.18)
            }
            .clipped()

            Image(systemName: "person.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.white.opacity(player.isUnavailable ? 0.16 : 0.46))
                .frame(width: min(width * 0.62, 46), height: min(width * 0.62, 46))
                .padding(.bottom, 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func eventStatBadge(symbol: String, color: Color, count: Int) -> some View {
        HStack(spacing: 1) {
            ForEach(0..<max(1, count), id: \.self) { _ in
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.38))
        )
        .foregroundStyle(color)
    }

    private func eventEmojiBadge(emoji: String, color: Color, count: Int) -> some View {
        HStack(spacing: 1) {
            ForEach(0..<max(1, count), id: \.self) { _ in
                Text(emoji)
                    .font(.system(size: 10))
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.38))
        )
        .foregroundStyle(color)
    }

    private func cardStatBadge(fill: Color, count: Int, textColor: Color) -> some View {
        HStack(spacing: 1) {
            ForEach(0..<max(1, count), id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(fill)
                    .frame(width: 7, height: 9)
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.34))
        )
        .foregroundStyle(textColor)
    }
}

func fantasyPreviousTeamPickerTitle(finalScore: Int?) -> String {
    guard let finalScore else { return "Previous team" }
    return "Previous team (\(finalScore))"
}

private enum FantasyTeamViewMode: Hashable {
    case current
    case previous
}

private enum RivalsScoreMode: String, CaseIterable {
    case currentGameweek
    case allGameweeks

    var title: String {
        switch self {
        case .currentGameweek:
            return "Current gameweek"
        case .allGameweeks:
            return "All gameweeks"
        }
    }
}

enum LeagueRankTrend: Equatable {
    case up
    case down
    case equal
    case unavailable

    nonisolated static func resolve(currentRank: Int?, lastRank: Int?) -> Self {
        guard let currentRank, currentRank > 0,
              let lastRank, lastRank > 0 else {
            return .unavailable
        }
        if currentRank < lastRank {
            return .up
        }
        if currentRank > lastRank {
            return .down
        }
        return .equal
    }
}

private enum FantasyIDAddMode {
    case rival
    case league

    var sheetTitle: String {
        switch self {
        case .rival:
            return "Add Rivals"
        case .league:
            return "Add Leagues"
        }
    }

    var idSectionTitle: String {
        switch self {
        case .rival:
            return "Manager ID"
        case .league:
            return "League ID"
        }
    }

    var idPlaceholder: String {
        switch self {
        case .rival:
            return "Enter manager ID"
        case .league:
            return "Enter league ID"
        }
    }

    var manualEntryHelpText: String {
        switch self {
        case .rival:
            return "Alternatively, if you know their ID, please enter it here..."
        case .league:
            return "Alternatively, if you know the league ID, please enter it here..."
        }
    }

    var tipText: String {
        switch self {
        case .rival:
            return "For the fastest flow, open a rival's Points page in Safari/Chrome and share it to Top Scores. It will auto-validate when you return to the app."
        case .league:
            return "For the fastest flow, open a Fantasy league page in Safari/Chrome and share it to Top Scores. It will auto-validate when you return to the app."
        }
    }
}

private struct FantasyLeagueTableEntry: Identifiable, Hashable {
    let entryID: Int
    let teamName: String
    let managerName: String
    let currentGameweekScore: Int?
    let allGameweeksScore: Int?
    let projectedGameweekPoints: Double?
    let isExpectedPointsLoading: Bool
    let hasActiveChipInCurrentGameweek: Bool
    let squad: FantasySquadDisplayData?
    let clubBadgeSrc: String?
    let isUser: Bool

    var id: Int {
        entryID
    }

    var canOpenDetails: Bool {
        !isUser && squad != nil
    }

    var isLoadingDetails: Bool {
        !isUser && squad == nil
    }

    func scoreValue(for mode: RivalsScoreMode) -> Int? {
        switch mode {
        case .currentGameweek:
            return currentGameweekScore
        case .allGameweeks:
            return allGameweeksScore
        }
    }

    func scoreDisplay(for mode: RivalsScoreMode) -> String {
        guard let score = scoreValue(for: mode) else { return "-" }
        if mode == .currentGameweek, hasActiveChipInCurrentGameweek {
            return "\(score)*"
        }
        return "\(score)"
    }

    var projectedGameweekPointsDisplay: String {
        guard let projectedGameweekPoints else { return "-" }
        return fantasyExpectedPointsText(projectedGameweekPoints)
    }

    func showsScoreLoadingIndicator(for mode: RivalsScoreMode) -> Bool {
        isLoadingDetails && scoreValue(for: mode) == nil
    }

    var showsExpectedPointsLoadingIndicator: Bool {
        isExpectedPointsLoading || (isLoadingDetails && projectedGameweekPoints == nil)
    }
}

private struct FantasyRivalScorePill: Identifiable, Hashable {
    let entryID: Int
    let initials: String
    let score: Int
    let showsAsterisk: Bool

    var id: Int {
        entryID
    }

    var displayedScore: String {
        "\(score)\(showsAsterisk ? "*" : "")"
    }
}

private func fantasyExpectedPointsText(_ value: Double) -> String {
    String(format: "%.1f", value)
}

func fantasyProvisionalPointsTint(_ points: Int) -> Color {
    switch points {
    case ...2:
        return Color(red: 0.92, green: 0.23, blue: 0.20)
    case 3...5:
        return Color(red: 0.95, green: 0.62, blue: 0.16)
    case 6...:
        return Color(red: 0.24, green: 0.76, blue: 0.30)
    default:
        return Color(red: 0.92, green: 0.23, blue: 0.20)
    }
}

private func fantasyScoreHeatmapColor(_ points: Int) -> Color {
    switch points {
    case ..<1:
        return Color(red: 0.78, green: 0.16, blue: 0.14)
    case 1...2:
        return Color(red: 0.91, green: 0.37, blue: 0.15)
    case 3...4:
        return Color(red: 0.95, green: 0.68, blue: 0.16)
    case 5...7:
        return Color(red: 0.29, green: 0.71, blue: 0.27)
    default:
        return Color.green
    }
}

private enum AssistantManagerPortraitCatalog {
    static let assetNames = [
        "AssistantManagerPortrait01",
        "AssistantManagerPortrait02",
        "AssistantManagerPortrait03",
        "AssistantManagerPortrait04",
        "AssistantManagerPortrait05",
        "AssistantManagerPortrait06",
        "AssistantManagerPortrait07",
        "AssistantManagerPortrait08",
        "AssistantManagerPortrait09",
        "AssistantManagerPortrait10",
        "AssistantManagerPortrait11",
        "AssistantManagerPortrait12",
        "AssistantManagerPortrait13",
        "AssistantManagerPortrait14"
    ]

    static func randomAssetName() -> String {
        assetNames.randomElement() ?? assetNames[0]
    }
}

private enum AssistantManagerPortraitSize {
    case small
    case large

    var frame: CGSize {
        switch self {
        case .small:
            return CGSize(width: 74, height: 74)
        case .large:
            return CGSize(width: 132, height: 182)
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .small: return 18
        case .large: return 24
        }
    }

    var imageScale: CGFloat {
        switch self {
        case .small: return 1.55
        case .large: return 1.0
        }
    }

    var scaleAnchor: UnitPoint {
        switch self {
        case .small: return .top
        case .large: return .center
        }
    }

    var verticalOffset: CGFloat {
        switch self {
        case .small: return -18
        case .large: return 0
        }
    }
}

private struct AssistantManagerPortraitView: View {
    let size: AssistantManagerPortraitSize
    let assetName: String

    private var borderColor: Color {
        return Color.green.opacity(0.75)
    }

    var body: some View {
        let frame = size.frame

        ZStack {
            Image(assetName)
                .resizable()
                .scaledToFill()
                .frame(width: frame.width, height: frame.height)
                .scaleEffect(size.imageScale, anchor: size.scaleAnchor)
                .offset(y: size.verticalOffset)
                .clipped()
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                .stroke(borderColor, lineWidth: 2)
        )
        .shadow(color: borderColor.opacity(0.20), radius: 6, x: 0, y: 3)
    }
}

private struct AssistantManagerSpeechBubbleView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Matt's words of wisdom...")
                .font(.headline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(.systemBackground))
                )

            Triangle()
                .fill(Color(.systemBackground))
                .frame(width: 18, height: 12)
                .rotationEffect(.degrees(180))
                .offset(x: 20, y: -1)
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct FantasyScoreLozenge: View {
    let displayedScore: String
    let isLive: Bool

    @State private var isPulsing = false

    private var gradient: LinearGradient {
        if isLive {
            return LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.20, blue: 0.66),
                    Color(red: 1.0, green: 0.29, blue: 0.29),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }

        return LinearGradient(
            colors: [Color.cyan, Color.blue],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(gradient)

            Text(displayedScore)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(.label))
                .padding(.horizontal, 12)
        }
        .frame(width: 94, height: 62)
        .overlay {
            if isLive {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.red.opacity(isPulsing ? 0.45 : 0.9), lineWidth: 1)
                    .scaleEffect(isPulsing ? 1.04 : 1.0)
            }
        }
        .shadow(color: isLive ? Color.red.opacity(isPulsing ? 0.28 : 0.12) : .clear, radius: 8)
        .animation(
            isLive ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
            value: isPulsing
        )
        .onAppear {
            isPulsing = isLive
        }
        .onChange(of: isLive) { _, newValue in
            isPulsing = newValue
        }
    }
}

private struct FantasyTeamSummaryRing: View {
    let ratio: Double?
    let centerText: String?
    let tint: Color
    let isLoading: Bool
    var diameter: CGFloat = 96
    var lineWidth: CGFloat = 9

    private var baseProgress: Double {
        min(max(ratio ?? 0, 0), 1)
    }

    private var overflowProgress: Double {
        min(max((ratio ?? 0) - 1, 0), 1)
    }

    private var centerFontSize: CGFloat {
        if diameter <= 60 {
            return (centerText?.count ?? 0) > 6 ? 8.5 : 10.5
        }
        return (centerText?.count ?? 0) > 6 ? 16 : 21
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: lineWidth))

            Circle()
                .trim(from: 0, to: baseProgress)
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            if overflowProgress > 0 {
                Circle()
                    .trim(from: 0, to: overflowProgress)
                    .stroke(
                        tint.opacity(0.72),
                        style: StrokeStyle(lineWidth: max(2, lineWidth / 3), lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .scaleEffect(1.16)
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(tint)
            } else {
                Text(centerText ?? "—")
                    .font(.system(size: centerFontSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, diameter <= 60 ? 4 : 8)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(centerText ?? "Calculating value")
    }
}

private struct FantasyTransferDeadlineLabel: View {
    let gameweekID: Int?
    let deadlineTime: String?

    var body: some View {
        if let deadline = Self.parseDeadline(deadlineTime) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let text = Self.displayText(deadline: deadline, gameweekID: gameweekID, now: context.date)
                let isUrgent = Self.isUrgent(deadline: deadline, now: context.date)

                Group {
                    if isUrgent {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.orange)
                            Text(text)
                        }
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.orange.opacity(0.16))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                        )
                    } else {
                        Text(text)
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private static func displayText(deadline: Date, gameweekID: Int?, now: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let weekday = weekdayFormatter.string(from: deadline)
        let day = calendar.component(.day, from: deadline)
        let time = timeFormatter.string(from: deadline)
        let prefix = prefixText(
            gameweekID: gameweekID,
            weekday: weekday,
            day: day,
            time: time
        )

        let remainingInterval = deadline.timeIntervalSince(now)
        guard remainingInterval > 0 else {
            return prefix
        }

        if remainingInterval >= 24 * 60 * 60 {
            let remainingDays = max(1, Int(floor(remainingInterval / (24 * 60 * 60))))
            let dayLabel = remainingDays == 1 ? "day" : "days"
            return "\(prefix) (\(remainingDays) \(dayLabel))"
        }

        let remainingSeconds = Int(remainingInterval)
        let hours = remainingSeconds / 3600
        let minutes = (remainingSeconds % 3600) / 60
        let seconds = remainingSeconds % 60
        return "\(prefix) (\(String(format: "%02d:%02d:%02d", hours, minutes, seconds)))"
    }

    private static func prefixText(gameweekID: Int?, weekday: String, day: Int, time: String) -> String {
        if let gameweekID {
            return "GW \(gameweekID) deadline: \(weekday) \(day)\(ordinalSuffix(for: day)), \(time)"
        }
        return "Deadline: \(weekday) \(day)\(ordinalSuffix(for: day)), \(time)"
    }

    private static func isUrgent(deadline: Date, now: Date) -> Bool {
        let remainingSeconds = deadline.timeIntervalSince(now)
        return remainingSeconds > 0 && remainingSeconds < 24 * 60 * 60
    }

    private static func parseDeadline(_ rawValue: String?) -> Date? {
        let trimmed = (rawValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let date = deadlineFormatterWithFractionalSeconds.date(from: trimmed) {
            return date
        }
        return deadlineFormatter.date(from: trimmed)
    }

    private static func ordinalSuffix(for day: Int) -> String {
        let remainder100 = day % 100
        if remainder100 >= 11 && remainder100 <= 13 {
            return "th"
        }

        switch day % 10 {
        case 1:
            return "st"
        case 2:
            return "nd"
        case 3:
            return "rd"
        default:
            return "th"
        }
    }

    private static let deadlineFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let deadlineFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

struct FantasySelectedPlayerSelection: Identifiable {
    let player: FantasyDisplayPlayer
    let gameweekID: Int
    let seasonKey: String?

    init(
        player: FantasyDisplayPlayer,
        gameweekID: Int,
        seasonKey: String? = nil
    ) {
        self.player = player
        self.gameweekID = gameweekID
        self.seasonKey = seasonKey
    }

    var id: String {
        "\(seasonKey ?? "current")-\(player.elementID)-\(gameweekID)-\(player.pickPosition)"
    }
}

@MainActor
private final class FantasyPlayerProfileImageLoader: ObservableObject {
    private static let imageCache = NSCache<NSString, UIImage>()

    @Published private(set) var image: UIImage?

    private var requestedURL: URL?
    private var requestedMaximumPixelSize = 0

    func load(url: URL?, maximumPixelSize: Int) async {
        guard requestedURL != url || requestedMaximumPixelSize != maximumPixelSize || image == nil else { return }

        requestedURL = url
        requestedMaximumPixelSize = maximumPixelSize
        image = nil

        guard let url else { return }

        let cacheKey = Self.cacheKey(url: url, maximumPixelSize: maximumPixelSize)
        if let cachedImage = Self.imageCache.object(forKey: cacheKey) {
            image = cachedImage
            return
        }

        for attempt in 0..<3 {
            guard !Task.isCancelled, requestedURL == url else { return }

            do {
                var request = URLRequest(url: url)
                request.cachePolicy = .returnCacheDataElseLoad
                request.timeoutInterval = 12

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else { return }

                guard (200...299).contains(httpResponse.statusCode) else {
                    guard retryable(statusCode: httpResponse.statusCode), attempt < 2 else { return }
                    try? await Task.sleep(nanoseconds: retryDelay(for: attempt))
                    continue
                }

                let loadedImage = await Task.detached(priority: .utility) {
                    decodeFantasyPlayerProfileImage(data: data, maximumPixelSize: maximumPixelSize)
                }.value
                guard let loadedImage else { return }
                guard requestedURL == url, requestedMaximumPixelSize == maximumPixelSize else { return }

                Self.imageCache.setObject(loadedImage, forKey: cacheKey)
                image = loadedImage
                return
            } catch {
                guard retryable(error: error), attempt < 2 else { return }
                try? await Task.sleep(nanoseconds: retryDelay(for: attempt))
            }
        }
    }

    private func retryable(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
    }

    private func retryable(error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }

        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    private func retryDelay(for attempt: Int) -> UInt64 {
        attempt == 0 ? 350_000_000 : 900_000_000
    }

    private static func cacheKey(url: URL, maximumPixelSize: Int) -> NSString {
        "\(url.absoluteString)|\(maximumPixelSize)" as NSString
    }
}

struct FantasyPlayerProfileImage: View {
    let url: URL?
    let size: CGFloat
    let height: CGFloat

    @StateObject private var loader = FantasyPlayerProfileImageLoader()

    init(url: URL?, size: CGFloat, height: CGFloat? = nil) {
        self.url = url
        self.size = size
        self.height = height ?? size
    }

    private var maximumPixelSize: Int {
        Int((max(size, height) * 2).rounded(.up))
    }

    var body: some View {
        ZStack {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: height)
        .task(id: "\(url?.absoluteString ?? "")|\(maximumPixelSize)") {
            await loader.load(
                url: url,
                maximumPixelSize: maximumPixelSize
            )
        }
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(6, size * 0.18), style: .continuous)
                .fill(Color.white.opacity(0.88))
            Image(systemName: "person.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.gray.opacity(0.68))
                .padding(size * 0.22)
        }
    }
}

private nonisolated func decodeFantasyPlayerProfileImage(
    data: Data,
    maximumPixelSize: Int
) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
    }
    return UIImage(cgImage: image)
}

private struct FantasyScoreBreakdownSelection: Identifiable {
    let id = UUID()
    let teamName: String
    let squad: FantasySquadDisplayData
}

private struct FantasyScoreBreakdownRow: Identifiable {
    let elementID: Int
    let playerName: String
    let profileImageURL: URL?
    let totalPoints: Int
    let components: [FantasyScoreBreakdownComponent]

    var id: Int {
        elementID
    }
}

private struct FantasyScoreBreakdownComponent: Identifiable {
    let title: String
    let points: Int

    var id: String {
        "\(title)-\(points)"
    }
}

private struct FantasySharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

private struct FantasyShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.excludedActivityTypes = [.assignToContact, .addToReadingList]
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private final class FantasyImageShareItemSource: NSObject, UIActivityItemSource {
    private let image: UIImage

    init(image: UIImage) {
        self.image = image
        super.init()
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        image
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        image
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        UTType.png.identifier
    }
}

private enum FantasyLeagueShareImageRenderer {
    private static let viewportWidth: CGFloat = 390

    @MainActor
    static func render(
        gameweekTitle: String,
        rows: [FantasyLeagueTableEntry],
        scoreMode: RivalsScoreMode,
        showEstimatedFooter: Bool
    ) -> UIImage? {
        guard !rows.isEmpty else { return nil }

        let snapshot = FantasyLeagueShareSnapshotView(
            gameweekTitle: gameweekTitle,
            generatedAtText: generatedAtLabel(),
            rows: rows,
            scoreMode: scoreMode,
            showEstimatedFooter: showEstimatedFooter
        )
        .environment(\.colorScheme, .dark)
        .frame(width: viewportWidth, alignment: .topLeading)
        .background(Color.black)
        .fixedSize(horizontal: false, vertical: true)

        let renderer = ImageRenderer(content: snapshot)
        renderer.proposedSize = ProposedViewSize(width: viewportWidth, height: nil)
        renderer.scale = exportScale(forRowCount: rows.count)
        if #available(iOS 17.0, *) {
            renderer.isOpaque = true
        }
        return renderer.uiImage
    }

    private static func generatedAtLabel() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Generated \(formatter.string(from: Date()))"
    }

    private static func exportScale(forRowCount rowCount: Int) -> CGFloat {
        switch rowCount {
        case ...12:
            return 2.0
        case ...24:
            return 1.6
        default:
            return 1.3
        }
    }
}

private struct FantasyLeagueShareSnapshotView: View {
    let gameweekTitle: String
    let generatedAtText: String
    let rows: [FantasyLeagueTableEntry]
    let scoreMode: RivalsScoreMode
    let showEstimatedFooter: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.05, blue: 0.08),
                    Color(red: 0.11, green: 0.12, blue: 0.17)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Top Scores: FPL")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                        Text(
                            scoreMode == .currentGameweek
                                ? "League Table • \(gameweekTitle)"
                                : "League Table • All gameweeks"
                        )
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                        Text(generatedAtText)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.66))
                    }

                    Spacer(minLength: 8)
                    FantasyShareAppIconView(size: 30)
                }

                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("#")
                            .frame(width: 26, alignment: .trailing)
                        Text("Team")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(scoreMode == .currentGameweek ? "GW" : "Total")
                            .frame(width: 44, alignment: .trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)

                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 1)

                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.body.monospacedDigit())
                                .frame(width: 26, alignment: .trailing)
                                .foregroundStyle(.white.opacity(0.72))

                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.teamName)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(row.isUser ? "\(row.managerName) (You)" : row.managerName)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.72))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Text(row.scoreDisplay(for: scoreMode))
                                .font(.body.monospacedDigit().weight(.bold))
                                .foregroundStyle(row.isUser ? .cyan : .white)
                                .frame(width: 44, alignment: .trailing)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                        .background(
                            row.isUser
                                ? Color.cyan.opacity(0.12)
                                : Color.clear
                        )

                        if index < rows.count - 1 {
                            Rectangle()
                                .fill(Color.white.opacity(0.1))
                                .frame(height: 1)
                        }
                    }
                }
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                if showEstimatedFooter {
                    Text("Scores are not final and subject to change")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
            .padding(16)
        }
    }
}

private struct FantasyAssistantManagerSheet: View {
    let entryID: Int
    let apiBaseURL: String
    let currentUserScore: Int
    let portraitAssetName: String

    @ObservedObject var fantasyViewModel: FantasyViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var response: FantasyAssistantManagerResponse?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showInterstitial = false
    @State private var interstitialSessionID = UUID()
    @State private var incomingDetailsByElementID: [Int: FantasyPlayerDetailsData] = [:]
    @State private var incomingDetailsErrorByElementID: [Int: String] = [:]
    @State private var assistantPhrase = "Keep up the good work, boss."
    @State private var pitchDetailMode: FantasyPitchPlayerDetailMode = .opponent
    var body: some View {
        NavigationStack {
            ZStack {
                Group {
                    if let response, response.ready {
                        contentView(response)
                    } else if let errorMessage {
                        errorState(message: errorMessage)
                    } else {
                        warmingState
                    }
                }

                if showInterstitial {
                    FantasyAssistantManagerInterstitialView()
                        .transition(.opacity)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Assistant Manager Matt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Show an "X" button to dismiss the assistant manager screen
                    Button(action: {
                        dismiss()
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: entryID) {
            await loadAssistantManager(forceFetch: true)
        }
    }

    private func contentView(_ response: FantasyAssistantManagerResponse) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                assistantManagerHeroSection(response)
                summaryCard(response)
                transferPlanSection(
                    title: "Top 3 Recommended Player Transfers",
                    plan: response.topTripleTransfers
                )
                captainRecommendationsSection(response.captainRecommendations)
                expectedPointsSection(response.expectedPoints)
                if let idealSquad = response.idealSquad {
                    assistantIdealSquadSection(
                        idealSquad,
                        currentEventID: response.currentEventID,
                        currentEventName: response.currentEventName
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .refreshable {
            await loadAssistantManager(forceFetch: true)
        }
    }

    private func summaryCard(_ response: FantasyAssistantManagerResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(response.currentEventName ?? "Current gameweek")
                .font(.title3.weight(.bold))
            if let algorithmSummary = response.algorithmSummary {
                Text(algorithmSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let squadSummary = response.squadSummary {
                HStack(spacing: 8) {
                    assistantPill(title: "Team Value", value: priceText(squadSummary.reportedTeamValueMillions))
                    assistantPill(title: "Bank", value: priceText(squadSummary.bankMillions))
                }
            }

            if let generatedAt = response.generatedAt {
                Text("Updated \(generatedAtText(generatedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func transferPlanSection(
        title: String,
        plan: FantasyAssistantManagerResponse.TransferPlan?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            if let plan {
                if let summary = plan.summary {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    assistantPill(title: "Next GW", value: signedPointsText(plan.projectedGainNextGameweek))
                    assistantPill(title: "Next 3", value: signedPointsText(plan.projectedGainNext3Gameweeks))
                    assistantPill(title: "Score", value: signedPointsText(plan.projectedScoreDelta))
                }

                bulletList(plan.reasons)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(plan.transfers) { move in
                        transferMoveCard(
                            move,
                            incomingDetails: incomingDetailsByElementID[move.inElementID],
                            incomingDetailsError: incomingDetailsErrorByElementID[move.inElementID],
                            currentEventID: response?.currentEventID ?? 0
                        )
                    }
                }
            } else {
                Text("No legal recommendation found right now.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func transferMoveCard(
        _ move: FantasyAssistantManagerResponse.TransferMove,
        incomingDetails: FantasyPlayerDetailsData?,
        incomingDetailsError: String?,
        currentEventID: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Out")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        assistantPlayerProfileImage(elementID: move.outElementID, size: 16)
                        Text(move.outPlayerName)
                            .font(.subheadline.weight(.semibold))
                    }
                    Text("\(move.outTeamShortName ?? "") • \(priceText(move.outPriceMillions))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 3) {
                    Text("In")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        assistantPlayerProfileImage(elementID: move.inElementID, size: 16)
                        Text(move.inPlayerName)
                            .font(.subheadline.weight(.semibold))
                    }
                    Text("\(move.inTeamShortName ?? "") • \(priceText(move.inPriceMillions))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                assistantPill(title: "Price", value: priceText(move.priceChangeMillions, signed: true))
                assistantPill(title: "Next GW", value: signedPointsText(move.projectedGainNextGameweek))
                assistantPill(title: "Next 3", value: signedPointsText(move.projectedGainNext3Gameweeks))
            }

            if let incomingDetails {
                assistantRecommendationKeyStatsSection(metrics: incomingDetails.metrics)
                assistantRecommendationNextFixturesTable(
                    details: incomingDetails,
                    currentEventID: currentEventID
                )
                assistantRecommendationPreviousFixturesTable(
                    details: incomingDetails,
                    currentEventID: currentEventID
                )
            } else if let incomingDetailsError {
                Text(incomingDetailsError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading incoming player details...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            bulletList(move.reasons)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.systemBackground).opacity(0.75))
        )
    }

    private func captainRecommendationsSection(
        _ recommendations: FantasyAssistantManagerResponse.CaptainRecommendations?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Captain recommendations")
                .font(.headline)

            if let summary = recommendations?.summary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let recommendations {
                recommendationColumn(
                    title: "Captain",
                    items: recommendations.captain
                )
            } else {
                Text("Captaincy advice is still warming up.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func expectedPointsSection(
        _ section: FantasyAssistantManagerResponse.ExpectedPointsSection?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Expected points")
                .font(.headline)

            if let section, let squad = fantasyViewModel.data {
                let startersTotal = section.startersExpectedPointsNextGameweek
                let benchTotal = section.benchExpectedPointsNextGameweek
                let remainingTotal = squad.remainingExpectedPoints(using: section)
                let projectedTotal = Double(currentUserScore) + remainingTotal

                HStack(spacing: 8) {
                    assistantPill(title: "Projected total", value: fantasyExpectedPointsText(projectedTotal))
                    assistantPill(title: "Remaining xP", value: fantasyExpectedPointsText(remainingTotal))
                    assistantPill(title: "Starting XI xP", value: fantasyExpectedPointsText(startersTotal))
                }

                HStack(spacing: 8) {
                    assistantPill(title: "Bench", value: fantasyExpectedPointsText(benchTotal))
                }

                expectedPointsGroup(
                    title: "Starting line-up",
                    players: section.starters
                )
                expectedPointsGroup(
                    title: "Bench",
                    players: section.bench
                )
            } else {
                Text("Expected-points breakdown is still warming up.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func expectedPointsGroup(
        title: String,
        players: [FantasyAssistantManagerResponse.ExpectedPointsPlayer]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            if players.isEmpty {
                Text("No players available.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    assistantHeaderCell("Player", alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    assistantHeaderCell("Opponent", alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    assistantHeaderCell("Difficulty", width: 60, alignment: .leading)
                    assistantHeaderCell("xP", width: 56, alignment: .trailing)
                }

                ForEach(players) { player in
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            assistantPlayerProfileImage(elementID: player.elementID, size: 14)
                            Text(player.playerName)
                                .font(.caption.monospacedDigit())
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if player.isBlank {
                            HStack(spacing: 6) {
                                assistantNoGameIcon(size: 14)
                                Text("No game")
                                    .font(.caption.monospacedDigit())
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            HStack(spacing: 6) {
                                assistantTeamLogoView(teamName: player.opponentTeamName, size: 14)
                                Text(player.opponentLabel)
                                    .font(.caption.monospacedDigit())
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        assistantDifficultyPill(player.difficulty)
                            .frame(width: 60, alignment: .leading)

                        assistantExpectedPointsPill(player.expectedPointsNextGameweek)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func recommendationColumn(
        title: String,
        items: [FantasyAssistantManagerResponse.CaptainRecommendation]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            if items.isEmpty {
                Text("No recommendation available.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1).")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    assistantPlayerProfileImage(elementID: item.elementID, size: 16)
                                    Text(item.playerName)
                                        .font(.subheadline.weight(.semibold))
                                }
                                Text("\(item.teamShortName ?? "") • \(item.opponentLabel)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Text("\(fantasyExpectedPointsText(item.expectedPointsNextGameweek)) pts")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        bulletList(item.reasons)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.systemBackground).opacity(0.75))
                    )
                }
            }
        }
    }

    private func assistantManagerHeroSection(
        _ response: FantasyAssistantManagerResponse
    ) -> some View {
        return HStack(alignment: .top, spacing: 12) {
            AssistantManagerPortraitView(
                size: .large,
                assetName: portraitAssetName
            )

            AssistantManagerSpeechBubbleView(text: assistantPhrase)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func assistantIdealSquadSection(
        _ squad: FantasyAssistantManagerResponse.IdealSquad,
        currentEventID: Int?,
        currentEventName: String?
    ) -> some View {
        let displayData = assistantIdealSquadDisplayData(
            squad,
            currentEventID: currentEventID,
            currentEventName: currentEventName
        )
        let displayedScore = displayData.isEstimatedScore
            ? "\(displayData.resolvedCurrentScore)*"
            : "\(displayData.resolvedCurrentScore)"

        return VStack(alignment: .leading, spacing: 10) {
            Text(squad.title ?? "If I had my way...")
                .font(.headline)

            if let summary = squad.summary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                assistantPill(title: "Formation", value: squad.formation ?? "-")
                assistantPill(title: "Value", value: priceText(squad.totalValueMillions))
                assistantPill(
                    title: "Next GW",
                    value: signedPointsText(squad.expectedPointsNextGameweek)
                )
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(currentEventName ?? "Latest gameweek")
                        .font(.headline)
                    Text(
                        displayData.hasActiveFixtures
                            ? "Current gameweek points for the assistant's XI."
                            : "Latest available player points for the assistant's XI."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                FantasyScoreLozenge(
                    displayedScore: displayedScore,
                    isLive: displayData.hasActiveFixtures
                )
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.systemBackground).opacity(0.75))
            )

                assistantIdealPitchSection(displayData)
                assistantIdealBenchSection(displayData)
                if let reasons = squad.reasons, !reasons.isEmpty {
                    bulletList(reasons)
                }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func assistantIdealPitchSection(_ data: FantasySquadDisplayData) -> some View {
        ZStack(alignment: .topTrailing) {
            FantasyPitchBackground()

            VStack(spacing: 8) {
                assistantIdealPositionRow(data.goalkeepers, scorePhase: data.scorePhase)
                assistantIdealPositionRow(data.defenders, scorePhase: data.scorePhase)
                assistantIdealPositionRow(data.midfielders, scorePhase: data.scorePhase)
                assistantIdealPositionRow(data.forwards, scorePhase: data.scorePhase)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 14)

            FantasyPitchDetailToggleButton(mode: $pitchDetailMode)
                .padding(.top, 10)
                .padding(.trailing, 10)
        }
        .frame(height: 540)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.34), radius: 16, x: 0, y: 9)
    }

    private func assistantIdealPositionRow(
        _ players: [FantasyDisplayPlayer],
        scorePhase: FantasySquadDisplayData.ScorePhase
    ) -> some View {
        GeometryReader { proxy in
            let count = max(players.count, 1)
            let spacing = FantasyPitchLayout.playerSpacing(
                for: players.count,
                availableWidth: proxy.size.width
            )
            let availableWidth = proxy.size.width - (CGFloat(count - 1) * spacing)
                let cardWidth = FantasyPitchLayout.playerCardWidth(
                    for: count,
                    availableWidth: availableWidth
                )

                HStack(spacing: spacing) {
                    ForEach(players) { player in
                        FantasyPlayerCard(
                            player: player,
                            width: cardWidth,
                            detailMode: pitchDetailMode,
                            scorePhase: scorePhase
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        .frame(height: 122)
    }

    private func assistantIdealBenchSection(_ data: FantasySquadDisplayData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bench")
                .font(.headline)

            GeometryReader { proxy in
                let count = max(data.bench.count, 1)
                let spacing = FantasyPitchLayout.benchSpacing(
                    for: data.bench.count,
                    availableWidth: proxy.size.width
                )
                let availableWidth = proxy.size.width - (CGFloat(count - 1) * spacing)
                let cardWidth = FantasyPitchLayout.benchCardWidth(
                    for: count,
                    availableWidth: availableWidth
                )

                HStack(spacing: spacing) {
                    ForEach(data.bench) { player in
                        FantasyPlayerCard(
                            player: player,
                            width: cardWidth,
                            detailMode: pitchDetailMode,
                            scorePhase: data.scorePhase
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 128)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.065, green: 0.08, blue: 0.075), Color(red: 0.035, green: 0.045, blue: 0.042)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.09), lineWidth: 1)
            }
        }
    }

    private func assistantIdealSquadDisplayData(
        _ squad: FantasyAssistantManagerResponse.IdealSquad,
        currentEventID: Int?,
        currentEventName: String?
    ) -> FantasySquadDisplayData {
        let goalkeepers = squad.starters.goalkeepers
            .map(assistantIdealDisplayPlayer)
            .sorted { $0.pickPosition < $1.pickPosition }
        let defenders = squad.starters.defenders
            .map(assistantIdealDisplayPlayer)
            .sorted { $0.pickPosition < $1.pickPosition }
        let midfielders = squad.starters.midfielders
            .map(assistantIdealDisplayPlayer)
            .sorted { $0.pickPosition < $1.pickPosition }
        let forwards = squad.starters.forwards
            .map(assistantIdealDisplayPlayer)
            .sorted { $0.pickPosition < $1.pickPosition }
        let bench = squad.bench
            .map(assistantIdealDisplayPlayer)
            .sorted { $0.pickPosition < $1.pickPosition }

        return FantasySquadDisplayData(
            gameweekID: max(1, currentEventID ?? 1),
            gameweekTitle: currentEventName ?? "Latest gameweek",
            deadlineGameweekID: nil,
            deadlineTime: nil,
            totalPoints: squad.displayedTotalPoints,
            gameweekAverageScore: nil,
            hasActiveFixtures: squad.hasActiveFixtures,
            hasStartedFixturesInGameweek: squad.hasStartedFixturesInGameweek,
            hasFixturesPlayedToday: squad.hasFixturesPlayedToday,
            isEstimatedScore: squad.hasActiveFixtures,
            estimatedCurrentScore: squad.displayedTotalPoints,
            scoreCalculationRulesApplied: [],
            rank: nil,
            overallRank: nil,
            transfersCost: nil,
            pointsOnBench: squad.displayedBenchPoints,
            activeChips: [],
            goalkeepers: goalkeepers,
            defenders: defenders,
            midfielders: midfielders,
            forwards: forwards,
            bench: bench
        )
    }

    private func assistantIdealDisplayPlayer(
        _ player: FantasyAssistantManagerResponse.IdealSquadPlayer
    ) -> FantasyDisplayPlayer {
        FantasyDisplayPlayer(
            elementID: player.elementID,
            pickPosition: player.pickPosition,
            positionType: FantasyPositionType(rawValue: player.positionID) ?? .midfielder,
            displayName: player.playerName,
            fullName: player.playerName,
            teamName: player.teamName,
            profileImageURL: fantasyViewModel.playerProfileImageURL(for: player.elementID),
            nowCostMillions: player.nowCostMillions,
            hasStartedCurrentSeason: true,
            ownershipPercent: nil,
            ownershipCount: nil,
            form: nil,
            pointsPerMatch: nil,
            totalPoints: nil,
            averageMinutes: nil,
            rawPoints: player.rawPoints,
            appliedPoints: player.appliedPoints,
            displayPoints: player.pickPosition <= 11 ? player.appliedPoints : player.rawPoints,
            multiplier: player.multiplier,
            isCaptain: player.isCaptain,
            isViceCaptain: player.isViceCaptain,
            isPlayingNow: player.isPlayingNow,
            isUnavailable: player.isUnavailable,
            isDefinitelyUnavailable: player.isDefinitelyUnavailable,
            hasAnyFixtureThisGameweek: player.hasAnyFixtureThisGameweek,
            hasUpcomingFixtureThisGameweek: player.hasUpcomingFixtureThisGameweek,
            hasActiveFixtureThisGameweek: player.hasActiveFixtureThisGameweek,
            hasFutureAvailabilityIssue: player.hasFutureAvailabilityIssue,
            futureAvailabilityIssueGameweek: player.futureAvailabilityIssueGameweek,
            minutesPlayed: player.minutesPlayed,
            upcomingOpponentDisplay: player.upcomingOpponentDisplay,
            fixtureDifficulty: nil,
            nextFiveFixtureDifficulties: [],
            expectedPointsThisGameweek: player.expectedPointsNextGameweek,
            officialExpectedPointsNextGameweek: nil,
            goalsScored: player.goalsScored,
            assists: player.assists,
            yellowCards: player.yellowCards,
            redCards: player.redCards
        )
    }

    private func assistantPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.systemBackground).opacity(0.75))
        )
    }

    private func assistantRecommendationKeyStatsSection(
        metrics: [FantasyPlayerDetailsData.Metric]
    ) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

        return VStack(alignment: .leading, spacing: 6) {
            Text("Key stats")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(metrics.prefix(8), id: \.title) { metric in
                    VStack(spacing: 2) {
                        Text(metric.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(metric.value)
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                }
            }
        }
    }

    private func assistantRecommendationNextFixturesTable(
        details: FantasyPlayerDetailsData,
        currentEventID: Int
    ) -> some View {
        let fixtures = Array(details.upcomingFixtures.prefix(5))
        let gameweekWidth: CGFloat = 62
        let difficultyWidth: CGFloat = 60
        let xpWidth: CGFloat = 52

        return VStack(alignment: .leading, spacing: 6) {
            Text("Next 5 fixtures")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if fixtures.isEmpty {
                Text("No upcoming fixtures")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    assistantHeaderCell("Gameweek", width: gameweekWidth, alignment: .leading)
                    assistantHeaderCell("Opponent", alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    assistantHeaderCell("Difficulty", width: difficultyWidth, alignment: .leading)
                    assistantHeaderCell("xP", width: xpWidth, alignment: .trailing)
                }

                ForEach(Array(fixtures.enumerated()), id: \.element.id) { index, fixture in
                    let expectedPoints = fixture.isBlank
                        ? nil
                        : assistantExpectedPointsForDetailsFixture(
                            details: details,
                            fixture: fixture,
                            fixtureIndex: index
                        )

                    HStack(spacing: 8) {
                        Text("GW\(fixture.gameweek)")
                            .font(.caption.monospacedDigit())
                            .frame(width: gameweekWidth, alignment: .leading)

                        if fixture.isBlank {
                            HStack(spacing: 6) {
                                assistantNoGameIcon(size: 14)
                                Text("No game")
                                    .font(.caption.monospacedDigit())
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            HStack(spacing: 6) {
                                assistantTeamLogoView(teamName: fixture.opponentTeamName, size: 14)
                                Text(assistantFixtureOpponentText(fixture))
                                    .font(.caption.monospacedDigit())
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        assistantDifficultyPill(fixture.difficulty)
                            .frame(width: difficultyWidth, alignment: .leading)

                        assistantExpectedPointsPill(
                            text: expectedPoints.map(fantasyExpectedPointsText) ?? "0",
                            value: expectedPoints
                        )
                        .frame(width: xpWidth, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func assistantRecommendationPreviousFixturesTable(
        details: FantasyPlayerDetailsData,
        currentEventID: Int
    ) -> some View {
        let rows = assistantPreviousHistoryRowsWithBlanks(
            from: details,
            currentEventID: currentEventID
        )
        let gameweekWidth: CGFloat = 62
        let pointsWidth: CGFloat = 60
        let minutesWidth: CGFloat = 52
        let pointsRange = assistantPointsRange(rows)

        return VStack(alignment: .leading, spacing: 6) {
            Text("Previous 5 fixtures")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if rows.isEmpty {
                Text("No recent fixtures")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    assistantHeaderCell("Gameweek", width: gameweekWidth, alignment: .leading)
                    assistantHeaderCell("Opponent", alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    assistantHeaderCell("Pts", width: pointsWidth, alignment: .trailing)
                    assistantHeaderCell("MP", width: minutesWidth, alignment: .trailing)
                }

                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Text("GW\(row.gameweek)")
                            .font(.caption.monospacedDigit())
                            .frame(width: gameweekWidth, alignment: .leading)

                        if row.opponentTeamID <= 0 {
                            HStack(spacing: 6) {
                                assistantNoGameIcon(size: 14)
                                Text("No game")
                                    .font(.caption.monospacedDigit())
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            HStack(spacing: 6) {
                                assistantTeamLogoView(teamName: row.opponentTeamName, size: 14)
                                Text("\(assistantTeamAbbreviation(row.opponentTeamName)) (\(row.wasHome ? "H" : "A"))")
                                    .font(.caption.monospacedDigit())
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        assistantPreviousPointsPill(points: row.points, range: pointsRange)
                            .frame(width: pointsWidth, alignment: .trailing)

                        Text(
                            row.opponentTeamID <= 0
                                ? "-"
                                : assistantMinutesWithStartsText(minutes: row.minutes, starts: row.starts)
                        )
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: minutesWidth, alignment: .trailing)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func assistantHeaderCell(
        _ title: String,
        width: CGFloat? = nil,
        alignment: Alignment
    ) -> some View {
        let text = Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        if let width {
            text.frame(width: width, alignment: alignment)
        } else {
            text.frame(maxWidth: .infinity, alignment: alignment)
        }
    }

    @ViewBuilder
    private func assistantPlayerProfileImage(elementID: Int, size: CGFloat) -> some View {
        FantasyPlayerProfileImage(
            url: fantasyViewModel.playerProfileImageURL(for: elementID),
            size: size
        )
    }

    @ViewBuilder
    private func assistantTeamLogoView(teamName: String, size: CGFloat) -> some View {
        let resolvedTeamName = FantasyTeamShortNameMappingsStore.shared.resolveTeamName(for: teamName)
        Group {
            if let logo = LogoResolver.shared.image(for: resolvedTeamName) ?? LogoResolver.shared.image(for: teamName) {
                Image(uiImage: logo)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "person.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(size * 0.2)
            }
        }
        .frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: max(4, size * 0.2), style: .continuous)
                .fill(Color(.systemBackground))
        )
    }

    private func assistantNoGameIcon(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(4, size * 0.2), style: .continuous)
                .fill(Color.red.opacity(0.18))
            Image(systemName: "xmark.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.red)
                .padding(size * 0.16)
        }
        .frame(width: size, height: size)
    }

    private func assistantFixtureOpponentText(_ fixture: FantasyPlayerDetailsData.UpcomingFixture) -> String {
        guard !fixture.isBlank else { return "No game" }
        let side = fixture.isHome == true ? "H" : "A"
        return "\(assistantTeamAbbreviation(fixture.opponentTeamName)) (\(side))"
    }

    private func assistantDifficultyPill(_ difficulty: Int?) -> some View {
        let color = assistantFixtureDifficultyColor(difficulty)
        let text = difficulty.map(String.init) ?? "-"

        return Text(text)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(difficulty == nil ? Color.secondary : Color.white)
            .frame(minWidth: 40, alignment: .center)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.opacity(difficulty == nil ? 0.20 : 0.92))
            )
    }

    private func assistantExpectedPointsPill(_ value: Double) -> some View {
        assistantExpectedPointsPill(text: fantasyExpectedPointsText(value), value: value)
    }

    private func assistantExpectedPointsPill(text: String, value: Double?) -> some View {
        let color = assistantExpectedPointsPillColor(value)

        return Text(text)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(value == nil ? Color.secondary : assistantExpectedPointsPillForegroundColor(value))
            .frame(minWidth: 40, alignment: .center)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.opacity(value == nil ? 0.20 : 0.92))
            )
    }

    private func assistantExpectedPointsPillColor(_ value: Double?) -> Color {
        guard let value else { return Color.gray }
        switch value {
        case ..<2.0:
            return Color.red
        case ..<4.0:
            return Color.orange
        case ..<6.0:
            return Color.yellow
        default:
            return Color.green
        }
    }

    private func assistantExpectedPointsPillForegroundColor(_ value: Double?) -> Color {
        guard let value else { return Color.secondary }
        return value >= 4.0 ? Color.black.opacity(0.82) : Color.white
    }

    private func assistantFixtureDifficultyColor(_ difficulty: Int?) -> Color {
        guard let difficulty else { return Color.gray }
        switch difficulty {
        case ...1: return Color.green
        case 2: return Color(red: 0.29, green: 0.71, blue: 0.27)
        case 3: return Color(red: 0.95, green: 0.68, blue: 0.16)
        case 4: return Color(red: 0.91, green: 0.37, blue: 0.15)
        default: return Color(red: 0.78, green: 0.16, blue: 0.14)
        }
    }

    private func assistantTeamAbbreviation(_ teamName: String) -> String {
        let trimmed = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "TBD" }
        let tokens = trimmed
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }

        if tokens.count >= 2 {
            let combined = "\(tokens[0].prefix(1))\(tokens[1].prefix(2))".uppercased()
            if combined.count == 3 { return combined }
        }

        let lettersOnly = trimmed.uppercased().filter { $0.isLetter || $0.isNumber }
        if lettersOnly.count >= 3 {
            return String(lettersOnly.prefix(3))
        }
        return lettersOnly.isEmpty ? "TBD" : lettersOnly
    }

    private func assistantPreviousHistoryRowsWithBlanks(
        from details: FantasyPlayerDetailsData,
        currentEventID: Int
    ) -> [FantasyPlayerDetailsData.HistoryRow] {
        var playedRowsByGameweek: [Int: FantasyPlayerDetailsData.HistoryRow] = [:]
        for row in details.historyRows where playedRowsByGameweek[row.gameweek] == nil {
            playedRowsByGameweek[row.gameweek] = row
        }

        guard let latestPlayedGameweek = playedRowsByGameweek.keys.max() else {
            return []
        }

        let startGameweek = max(1, min(currentEventID, latestPlayedGameweek))
        let floorGameweek = max(1, startGameweek - 4)

        return stride(from: startGameweek, through: floorGameweek, by: -1).map { gameweek in
            if let row = playedRowsByGameweek[gameweek] {
                return row
            }
            return FantasyPlayerDetailsData.HistoryRow(
                gameweek: gameweek,
                opponentTeamID: -1,
                opponentTeamName: "No game",
                wasHome: true,
                points: 0,
                starts: 0,
                minutes: 0,
                goalsScored: 0,
                assists: 0,
                expectedGoals: "0.0"
            )
        }
    }

    private func assistantPointsRange(
        _ rows: [FantasyPlayerDetailsData.HistoryRow]
    ) -> (min: Int, max: Int) {
        let points = rows.map(\.points)
        guard let minValue = points.min(), let maxValue = points.max() else {
            return (0, 0)
        }
        return (minValue, maxValue)
    }

    private func assistantPreviousPointsPill(
        points: Int,
        range: (min: Int, max: Int)
    ) -> some View {
        let color: Color
        if range.min == range.max {
            color = points > 0 ? .green : .red
        } else {
            let normalized = Double(points - range.min) / Double(max(1, range.max - range.min))
            let hue = 0.02 + (0.34 * min(max(normalized, 0), 1))
            color = Color(hue: hue, saturation: 0.78, brightness: 0.90)
        }

        return Text("\(points)")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)
            .frame(minWidth: 40, alignment: .center)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.opacity(0.94))
            )
    }

    private func assistantExpectedPointsForDetailsFixture(
        details: FantasyPlayerDetailsData,
        fixture: FantasyPlayerDetailsData.UpcomingFixture,
        fixtureIndex: Int
    ) -> Double {
        let pointsPerMatch = assistantMetricDouble(details.metrics, title: "Pts / Match") ?? 0
        let form = assistantMetricDouble(details.metrics, title: "Form") ?? pointsPerMatch
        let previousTen = details.historyRows.prefix(10).map(\.points)
        let previousTenAverage = previousTen.isEmpty
            ? ((pointsPerMatch * 0.65) + (form * 0.35))
            : Double(previousTen.reduce(0, +)) / Double(previousTen.count)

        let formVsPPG = pointsPerMatch > 0 ? form / max(pointsPerMatch, 0.1) : 1.0
        let momentumMultiplier = min(max(formVsPPG, 0.78), 1.25)

        let difficultyMultiplier: Double = {
            switch fixture.difficulty ?? 3 {
            case ...1: return 1.32
            case 2: return 1.16
            case 3: return 1.0
            case 4: return 0.84
            default: return 0.68
            }
        }()

        let homeAwayMultiplier: Double = fixture.isHome == true ? 1.04 : 0.96
        let horizonDecay = 1.0 - (Double(fixtureIndex) * 0.02)

        let raw = previousTenAverage *
            momentumMultiplier *
            difficultyMultiplier *
            homeAwayMultiplier *
            max(0.85, horizonDecay)

        let bounded = min(max(raw, 0.0), 20.0)
        return (bounded * 10).rounded() / 10
    }

    private func assistantMetricDouble(
        _ metrics: [FantasyPlayerDetailsData.Metric],
        title: String
    ) -> Double? {
        guard let value = metrics.first(where: { $0.title == title })?.value else {
            return nil
        }
        let normalized = value
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "£", with: "")
            .replacingOccurrences(of: "m", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(normalized)
    }

    private func assistantMinutesWithStartsText(minutes: Int, starts: Int) -> String {
        guard starts > 1 else { return "\(minutes)" }
        return "\(minutes) (\(starts))"
    }

    @ViewBuilder
    private func bulletList(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines.filter { !$0.isEmpty }, id: \.self) { line in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 5, height: 5)
                        .padding(.top, 6)
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var warmingState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Assistant Manager is warming up")
                .font(.headline)
            Text("Matt is looking for his clipboard and sharpening his pencils. This usually takes around 10-15 seconds, but can take a bit longer if he's distracted. Sorry for the inconvenience!")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Try again") {
                Task { await loadAssistantManager(forceFetch: true) }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }

    private func errorState(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Assistant Manager unavailable")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Retry") {
                Task { await loadAssistantManager(forceFetch: true) }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }

    private func loadAssistantManager(forceFetch: Bool) async {
        let sessionID = UUID()
        interstitialSessionID = sessionID
        showInterstitial = true
        isLoading = true
        errorMessage = nil
        Task {
            await loadAssistantPhrase()
        }

        do {
            await fantasyViewModel.prewarmAssistantManagerCache(
                entryID: entryID,
                apiBaseURL: apiBaseURL,
                force: forceFetch
            )

            let loaded = try await pollForAssistantManager(forceFetch: forceFetch)
            guard interstitialSessionID == sessionID else { return }
            response = loaded
            errorMessage = nil
            await preloadIncomingPlayerDetails(from: loaded)
        } catch {
            guard interstitialSessionID == sessionID else { return }
            response = nil
            incomingDetailsByElementID = [:]
            incomingDetailsErrorByElementID = [:]
            errorMessage = userFriendlyAssistantManagerError(error)
        }

        guard interstitialSessionID == sessionID else { return }
        isLoading = false
        showInterstitial = false
    }

    private func loadAssistantPhrase() async {
        guard let baseURL = URL(string: apiBaseURL) else { return }

        do {
            let client = APIClient(baseURL: baseURL)
            let payload = try await client.fetchFantasyAssistantManagerPhrases()
            if let chosen = payload.phrases.randomElement(), !chosen.isEmpty {
                assistantPhrase = chosen
            }
        } catch {
            // Keep the existing fallback phrase if the endpoint is unavailable.
        }
    }

    private func pollForAssistantManager(forceFetch: Bool) async throws -> FantasyAssistantManagerResponse {
        try await fantasyViewModel.fetchAssistantManager(
            entryID: entryID,
            apiBaseURL: apiBaseURL,
            forceRefresh: forceFetch
        )
    }

    private func generatedAtText(_ rawValue: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: rawValue) else { return rawValue }
        let displayFormatter = DateFormatter()
        displayFormatter.dateStyle = .medium
        displayFormatter.timeStyle = .short
        return displayFormatter.string(from: date)
    }

    private func signedPointsText(_ value: Double) -> String {
        let prefix = value > 0 ? "+" : ""
        return "\(prefix)\(String(format: "%.1f", value))"
    }

    private func priceText(_ value: Double, signed: Bool = false) -> String {
        let prefix = signed && value > 0 ? "+" : ""
        return "\(prefix)£\(String(format: "%.1f", value))m"
    }

    private func preloadIncomingPlayerDetails(
        from response: FantasyAssistantManagerResponse
    ) async {
        let elementIDs = Set((response.topTripleTransfers?.transfers ?? []).map(\.inElementID))

        guard !elementIDs.isEmpty else {
            incomingDetailsByElementID = [:]
            incomingDetailsErrorByElementID = [:]
            return
        }

        incomingDetailsByElementID = incomingDetailsByElementID.filter { elementIDs.contains($0.key) }
        incomingDetailsErrorByElementID = [:]

        for elementID in elementIDs where incomingDetailsByElementID[elementID] == nil {
            do {
                let loaded = try await fantasyViewModel.loadPlayerDetails(
                    elementID: elementID,
                    gameweekID: max(1, response.currentEventID ?? 1),
                    apiBaseURL: apiBaseURL
                )
                incomingDetailsByElementID[elementID] = loaded
                incomingDetailsErrorByElementID[elementID] = nil
            } catch {
                incomingDetailsErrorByElementID[elementID] = "Could not load player details."
            }
        }
    }

    private func userFriendlyAssistantManagerError(_ error: Error) -> String {
        let message = error.localizedDescription
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if message.contains("game is being updated") || message.contains("temporarily unavailable") {
            return "Assistant Manager is temporarily unavailable while Fantasy Premier League updates."
        }
        return "Could not load Assistant Manager advice right now."
    }
}

private struct FantasyAssistantManagerInterstitialView: View {
    @State private var animate = false
    @State private var messageIndex = 0

    private static let messagePool = [
        "Checking captaincy upside...",
        "Scanning transfer combinations...",
        "Balancing budget against fixtures...",
        "Looking for availability risks...",
        "Planning the next three gameweeks...",
        "Comparing squad structure options...",
        "Working through club-limit constraints...",
        "Sharpening the shortlist..."
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.18, blue: 0.24),
                    Color(red: 0.14, green: 0.45, blue: 0.39),
                    Color(red: 0.83, green: 0.61, blue: 0.19)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                        .frame(width: 214, height: 214)

                    Circle()
                        .trim(from: 0.10, to: 0.88)
                        .stroke(
                            AngularGradient(
                                colors: [
                                    Color.white.opacity(0.22),
                                    Color(red: 0.97, green: 0.77, blue: 0.25),
                                    Color.white.opacity(0.92),
                                    Color.white.opacity(0.18)
                                ],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .frame(width: 176, height: 176)
                        .rotationEffect(.degrees(animate ? 360 : 0))
                        .animation(.linear(duration: 2.7).repeatForever(autoreverses: false), value: animate)

                    Circle()
                        .trim(from: 0.18, to: 0.44)
                        .stroke(
                            Color.white.opacity(0.82),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .frame(width: 144, height: 144)
                        .rotationEffect(.degrees(animate ? -360 : 0))
                        .animation(.linear(duration: 1.8).repeatForever(autoreverses: false), value: animate)

                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 56, weight: .regular))
                        .foregroundStyle(.white)
                        .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 8)
                }

                VStack(spacing: 8) {
                    Text("Assistant Manager")
                        .font(.title.weight(.bold))
                        .foregroundStyle(.white)

                    Text(Self.messagePool[messageIndex])
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }

                ProgressView()
                    .tint(.white)
            }
            .padding(24)
        }
        .onAppear {
            animate = true
            messageIndex = Int.random(in: 0..<Self.messagePool.count)
        }
        .onReceive(Timer.publish(every: 1.1, on: .main, in: .common).autoconnect()) { _ in
            guard Self.messagePool.count > 1 else { return }
            messageIndex = Int.random(in: 0..<Self.messagePool.count)
        }
    }
}

private struct FantasyShareAppIconView: View {
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

#Preview {
    FantasyView(isSelected: true)
        .environmentObject(PreferencesStore())
        .environmentObject(FantasyViewModel())
}
