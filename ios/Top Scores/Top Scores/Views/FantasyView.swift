import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

struct FantasyView: View {
    private struct PendingFantasyRefreshRequest {
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
    @State private var showSuccessInterstitial = false
    @State private var rivalManagers: [FantasyRivalManager] = []
    @State private var trackedLeagues: [FantasyTrackedLeague] = []
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
    @State private var showDeleteLeagueConfirmation = false
    @State private var leagueIDPendingDeletion: Int?
    @State private var leagueNamePendingDeletion = ""
    @State private var rivalsScoreMode: RivalsScoreMode = .currentGameweek
    @State private var showUnlinkAccountConfirmation = false
    @State private var showAssistantManager = false
    @State private var assistantManagerPortraitAssetName = AssistantManagerPortraitCatalog.randomAssetName()
    @State private var fantasyPitchDetailMode: FantasyPitchPlayerDetailMode = .opponent
    @FocusState private var isRivalEntryInputFocused: Bool
    @State private var lastObservedClipboardChangeCount = UIPasteboard.general.changeCount
    @State private var isFantasyLoadingInterstitialActive = false
    @State private var isFantasyLoadingInterstitialMinimumDurationMet = false
    @State private var fantasyLoadingInterstitialSessionID = UUID()
    @State private var pendingFantasyRefreshRequest: PendingFantasyRefreshRequest?

    private let rivalsSectionScrollID = "fantasy-rivals-section"
    private let fantasyLoadingInterstitialMinimumDurationNanoseconds: UInt64 = 3_000_000_000
    private let fantasyRefreshTimer = Timer.publish(every: 30.0, on: .main, in: .common).autoconnect()
    private let sharedEntryPollTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    private let addSheetClipboardPollTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        lifecycleBoundView
    }

    private var baseNavigationView: some View {
        NavigationStack {
            Group {
                if managerEntryID.isEmpty {
                    setupFlowView
                } else {
                    linkedFantasyView
                }
            }
            .navigationTitle("Fantasy Football")
            .toolbarTitleDisplayMode(.inline)
        }
    }

    private var modalPresentationView: some View {
        baseNavigationView
            .overlay {
                ZStack {
                    if showFantasyLoadingInterstitial {
                        fantasyLoadingOverlay
                    }
                    if isLaunchingShareFlow {
                        shareLoadingOverlay
                    }
                }
            }
            .sheet(isPresented: $showAddRivalSheet) {
                addRivalSheet
            }
            .sheet(item: $selectedRivalSquad) { rival in
                rivalDetailSheet(rival)
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $selectedLeagueStanding) { league in
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
            .alert("Delete league?", isPresented: $showDeleteLeagueConfirmation) {
                Button("Cancel", role: .cancel) {
                    leagueIDPendingDeletion = nil
                    leagueNamePendingDeletion = ""
                }
                Button("Delete", role: .destructive) {
                    guard let leagueID = leagueIDPendingDeletion else { return }
                    removeLeague(leagueID: leagueID)
                    selectedLeagueStanding = nil
                    leagueIDPendingDeletion = nil
                    leagueNamePendingDeletion = ""
                    setShareImportStatus("League removed.", isError: false)
                }
            } message: {
                if leagueNamePendingDeletion.isEmpty {
                    Text("This league will be removed from your saved leagues.")
                } else {
                    Text("Remove \(leagueNamePendingDeletion) from your leagues?")
                }
            }
            .alert("Disconnect Fantasy account?", isPresented: $showUnlinkAccountConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Disconnect", role: .destructive) {
                    unlinkFantasyAccountData()
                }
            } message: {
                Text("This will remove your linked manager account, rivals, and Fantasy Football data from this device. You can always reconnect your account at any time.")
            }
            .sheet(item: $selectedPlayerSelection) { selection in
                FantasyPlayerDetailsSheet(
                    selection: selection,
                    apiBaseURL: preferences.apiBaseURL,
                    fantasyViewModel: fantasyViewModel
                )
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showAssistantManager) {
                if let currentManagerEntryID {
                    FantasyAssistantManagerSheet(
                        entryID: currentManagerEntryID,
                        apiBaseURL: preferences.apiBaseURL,
                        currentUserScore: fantasyViewModel.data?.resolvedCurrentScore ?? 0,
                        portraitAssetName: assistantManagerPortraitAssetName,
                        fantasyViewModel: fantasyViewModel
                    )
                    .presentationDragIndicator(.visible)
                }
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
                syncManagerEntryIDToSharedDefaults()
                if managerEntryID.isEmpty {
                    managerCaptureStatusMessage = "Waiting for shared Fantasy entry URL. Open your Points page in Safari/Chrome and share it to Top Scores."
                } else {
                    triggerFantasyRefresh(
                        force: fantasyViewModel.data == nil,
                        rivalManagers: storedRivals,
                        trackedLeagues: storedLeagues
                    )
                }
                armSharedEntryPolling()
                consumeSharedFantasyEntryURLIfNeeded()
            }
            .onChange(of: isSelected) { _, selected in
                guard selected else { return }
                if !managerEntryID.isEmpty {
                    triggerFantasyRefresh(
                        force: fantasyViewModel.data == nil,
                        rivalManagers: rivalManagers,
                        trackedLeagues: trackedLeagues
                    )
                }
                armSharedEntryPolling()
                consumeSharedFantasyEntryURLIfNeeded()
            }
            .onChange(of: scenePhase) { _, newValue in
                guard newValue == .active else { return }
                if isSelected, !managerEntryID.isEmpty {
                    triggerFantasyRefresh(
                        force: false,
                        rivalManagers: rivalManagers,
                        trackedLeagues: trackedLeagues
                    )
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
            .onChange(of: managerEntryID) { _, newValue in
                syncManagerEntryIDToSharedDefaults()
                if newValue.isEmpty {
                    resetFantasyLoadingInterstitial()
                    pendingFantasyRefreshRequest = nil
                    fantasyViewModel.reset()
                    managerCaptureStatusMessage = "Waiting for shared Fantasy entry URL. Open your Points page in Safari/Chrome and share it to Top Scores."
                    managerValidationErrorMessage = nil
                } else {
                    triggerFantasyRefresh(force: true)
                    managerValidationErrorMessage = nil
                }
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
                guard !managerEntryID.isEmpty else { return }
                triggerFantasyRefresh(
                    force: true,
                    rivalManagers: rivalManagers,
                    trackedLeagues: trackedLeagues
                )
            }
            .onChange(of: fantasyViewModel.isLoading) { _, isLoading in
                handleFantasyLoadingInterstitialChange(isLoading: isLoading)
                if !isLoading {
                    drainPendingFantasyRefreshIfNeeded()
                }
            }
            .onChange(of: fantasyViewModel.isRefreshing) { _, isRefreshing in
                if !isRefreshing {
                    drainPendingFantasyRefreshIfNeeded()
                }
            }
            .onChange(of: rivalManagersJSON) { _, _ in
                let storedRivals = loadRivalManagersFromStorage()
                guard !managerEntryID.isEmpty else { return }
                triggerFantasyRefresh(
                    force: true,
                    rivalManagers: storedRivals,
                    trackedLeagues: trackedLeagues
                )
            }
            .onChange(of: trackedLeaguesJSON) { _, _ in
                let storedLeagues = loadTrackedLeaguesFromStorage()
                guard !managerEntryID.isEmpty else { return }
                triggerFantasyRefresh(
                    force: true,
                    rivalManagers: rivalManagers,
                    trackedLeagues: storedLeagues
                )
            }
            .onReceive(fantasyRefreshTimer) { _ in
                guard isSelected,
                      scenePhase == .active,
                      !managerEntryID.isEmpty else { return }
                if let currentData = fantasyViewModel.data, !currentData.hasActiveFixtures {
                    guard let lastUpdated = fantasyViewModel.lastUpdated else { return }
                    guard Date().timeIntervalSince(lastUpdated) >= 15 * 60 else { return }
                }
                triggerFantasyRefresh(
                    force: false,
                    rivalManagers: rivalManagers,
                    trackedLeagues: trackedLeagues
                )
            }
            .onReceive(sharedEntryPollTimer) { _ in
                guard isSelected, scenePhase == .active else { return }
                guard let deadline = sharedEntryPollingDeadline else { return }
                if Date() > deadline {
                    sharedEntryPollingDeadline = nil
                    return
                }
                consumeSharedFantasyEntryURLIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
                guard showAddRivalSheet else { return }
                autoPopulateAddSheetIDFromClipboard(forceRead: false)
            }
            .onReceive(addSheetClipboardPollTimer) { _ in
                guard showAddRivalSheet, scenePhase == .active else { return }
                autoPopulateAddSheetIDFromClipboard(forceRead: false)
            }
    }

    private var setupFlowView: some View {
        Form {
            setupSection
            managerEntryInputSection
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

    private var showFantasyLoadingInterstitial: Bool {
        !managerEntryID.isEmpty && isFantasyLoadingInterstitialActive
    }

    private var currentManagerEntryID: Int? {
        let trimmed = managerEntryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let entryID = Int(trimmed), entryID > 0 else { return nil }
        return entryID
    }

    private var linkedFantasyView: some View {
        ScrollViewReader { proxy in
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

                    if let data = fantasyViewModel.data {
                        let displayData = data.applyingExpectedPoints(
                            fantasyViewModel.assistantManagerPreview?.expectedPoints
                        )
                        if let shareImportStatusMessage {
                            shareImportStatusCard(
                                message: shareImportStatusMessage,
                                isError: shareImportStatusIsError
                            )
                        }
                        scoreSummaryCard(
                            data,
                            showsActiveChipMessage: data.hasActiveChip,
                            projectedGameweekPoints: fantasyViewModel.assistantManagerPreview?.expectedPoints.map {
                                data.projectedGameweekPoints(using: $0)
                            },
                            isExpectedPointsLoading: fantasyViewModel.assistantManagerPreview?.ready != true,
                            moreRivalsTapAction: {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    proxy.scrollTo(rivalsSectionScrollID, anchor: .top)
                                }
                            }
                        )
                        FantasyTransferDeadlineLabel(
                            gameweekID: data.deadlineGameweekID,
                            deadlineTime: data.deadlineTime
                        )
                        pitchSection(
                            displayData,
                            playerSelectionEnabled: true,
                            detailMode: $fantasyPitchDetailMode
                        )
                        benchSection(
                            displayData,
                            playerSelectionEnabled: true,
                            detailMode: fantasyPitchDetailMode
                        )
                        eventLegendSection(data)
                        if data.isEstimatedScore {
                            scoreCalculationSection(data)
                        }
                        rivalsSection
                            .id(rivalsSectionScrollID)
                        leaguesSection
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

                    if let data = fantasyViewModel.data {
                        assistantManagerSection
                        summaryStatsSection(data)
                    }

                    unlinkAccountCard
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .refreshable {
                await fantasyViewModel.refresh(
                    managerEntryID: managerEntryID,
                    apiBaseURL: preferences.apiBaseURL,
                    rivalManagers: rivalManagers,
                    trackedLeagues: trackedLeagues
                )
            }
        }
    }

    private var setupSection: some View {
        Section("Connect your Fantasy Football account") {
            instructionStep(number: 1, text: "Open Fantasy Premier League (link below) and sign in.")
            instructionStep(number: 2, text: "Open your Points page, then tap Share and choose Top Scores.")
            instructionStep(number: 3, text: "Return to Top Scores to complete setup.")

            Button {
                openFantasyWebsiteInBrowser()
            } label: {
                Label("Open Fantasy Premier League website", systemImage: "safari")
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

    private var unlinkAccountCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(role: .destructive) {
                showUnlinkAccountConfirmation = true
            } label: {
                // Center align
                Label("Disconnect account", systemImage: "person.crop.circle.badge.xmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

        if selectedRivalSquad != nil {
            pendingScoreBreakdownAfterRivalDismiss = selection
            selectedRivalSquad = nil
            return
        }

        selectedScoreBreakdown = selection
    }

    private func scoreBreakdownSheet(_ breakdown: FantasyScoreBreakdownSelection) -> some View {
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
                                scoreBreakdownTeamLogo(teamName: row.teamName)
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
                        selectedScoreBreakdown = nil
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
                    teamName: player.teamName,
                    totalPoints: player.appliedPoints,
                    components: scoreBreakdownComponents(for: player)
                )
            }
    }

    @ViewBuilder
    private func scoreBreakdownTeamLogo(teamName: String) -> some View {
        if let logo = LogoResolver.shared.image(for: teamName) {
            Image(uiImage: logo)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: "shield")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(.tertiarySystemGroupedBackground))
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

    private var assistantManagerSection: some View {
        let assistantScore = fantasyViewModel.assistantManagerPreview?.idealSquad?.displayedTotalPoints
        let userScore = fantasyViewModel.data?.resolvedCurrentScore ?? 0

        return VStack(alignment: .leading, spacing: 10) {
            Text("Assistant Manager Matt")
                .font(.headline)

            HStack(alignment: .center, spacing: 12) {
                // Show image and allow tapping to show assistant manager advice screen
                AssistantManagerPortraitView(
                    size: .small,
                    assetName: assistantManagerPortraitAssetName
                )
                .onTapGesture {
                    assistantManagerPortraitAssetName = AssistantManagerPortraitCatalog.randomAssetName()
                    showAssistantManager = true
                }

                Text("Your assistant manager, Matt (Mastermind of Analysis, Tactics and Transfers), is at your command. Tap his lovely face or the button below to get his advice on how to improve your team for the upcoming gameweek.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                assistantManagerPortraitAssetName = AssistantManagerPortraitCatalog.randomAssetName()
                showAssistantManager = true
            } label: {
                Label("Get Matt's advice", systemImage: "person.crop.circle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(currentManagerEntryID == nil)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var leagueTableEntries: [FantasyLeagueTableEntry] {
        guard let mySquad = fantasyViewModel.data else { return [] }

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
                projectedGameweekPoints: fantasyViewModel.assistantManagerPreview?.expectedPoints.map {
                    mySquad.projectedGameweekPoints(using: $0)
                },
                isExpectedPointsLoading: fantasyViewModel.assistantManagerPreview?.ready != true,
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
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Button {
                    prepareRivalEntrySheet()
                } label: {
                    Label("Add rival", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var leaguesSection: some View {
        let leagueSnapshots = fantasyViewModel.trackedLeagueStandings
        let hasConfiguredLeagues = !trackedLeagues.isEmpty

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Leagues")
                    .font(.headline)
                Spacer(minLength: 0)
            }

            if !hasConfiguredLeagues {
                Button {
                    prepareLeagueEntrySheet()
                } label: {
                    Label("Add league", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                if leagueSnapshots.isEmpty {
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
                        Text("League standings are unavailable right now. Pull to refresh and try again.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(spacing: 8) {
                        ForEach(leagueSnapshots) { league in
                            Button {
                                selectedLeagueStanding = league
                            } label: {
                                leagueSummaryRow(league)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Button {
                    prepareLeagueEntrySheet()
                } label: {
                    Label("Add league", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func leagueSummaryRow(_ league: FantasyTrackedLeagueStanding) -> some View {
        let trend = leagueRankTrend(currentRank: league.myRank, lastRank: league.myLastRank)

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
                        leagueTrendIcon(currentRank: rank, lastRank: league.myLastRank)
                        Text("\(rank)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
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

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.8))
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
                    Text(entry.projectedGameweekPointsDisplay)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
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

    private func leagueDetailSheet(_ league: FantasyTrackedLeagueStanding) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("Your rank")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(league.myRank.map(String.init) ?? "-")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                    }

                    VStack(spacing: 0) {
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
                                .frame(width: 20, alignment: .trailing)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .foregroundStyle(.secondary)

                        Rectangle()
                            .fill(Color.secondary.opacity(0.22))
                            .frame(height: 1)

                        ForEach(Array(league.standings.enumerated()), id: \.element.id) { index, row in
                            leagueStandingRow(row, isCurrentUser: row.entry == league.myEntryID)
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
                .padding(14)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(league.leagueName)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) {
                        leagueIDPendingDeletion = league.leagueID
                        leagueNamePendingDeletion = league.leagueName
                        showDeleteLeagueConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("Delete league")
                }
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
        }
    }

    private func leagueStandingRow(_ row: FantasyClassicLeagueStandingEntry, isCurrentUser: Bool) -> some View {
        HStack(spacing: 8) {
            Text("\(row.rank)")
                .font(.body.monospacedDigit())
                .frame(width: 30, alignment: .trailing)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                leagueBadgeImage(urlString: row.clubBadgeSrc)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.entryName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
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

            leagueTrendIcon(currentRank: row.rank, lastRank: row.lastRank)
                .frame(width: 20, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrentUser ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isCurrentUser ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
        )
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
        switch leagueRankTrend(currentRank: currentRank, lastRank: lastRank) {
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
        }
    }

    private func leagueRankTrend(currentRank: Int?, lastRank: Int?) -> LeagueRankTrend {
        guard let currentRank else { return .equal }
        guard let lastRank else { return .equal }
        if currentRank < lastRank {
            return .up
        }
        if currentRank > lastRank {
            return .down
        }
        return .equal
    }

    private func leagueTrendOutlineColor(for trend: LeagueRankTrend) -> Color {
        switch trend {
        case .up:
            return .green.opacity(0.7)
        case .down:
            return .red.opacity(0.7)
        case .equal:
            return .gray.opacity(0.6)
        }
    }

    @ViewBuilder
    private func leagueBadgeImage(urlString: String?) -> some View {
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
                    Image(systemName: "shield")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                @unknown default:
                    Image(systemName: "shield")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
            }
        } else {
            Image(systemName: "shield")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        }
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
        let displayData = rival.squad.applyingExpectedPoints(rival.expectedPointsSection)

        return NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rival.managerName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    scoreSummaryCard(
                        rival.squad,
                        showRivalPills: false,
                        showsActiveChipMessage: rival.squad.hasActiveChip,
                        projectedGameweekPoints: rival.projectedGameweekPoints,
                        isExpectedPointsLoading: rival.isExpectedPointsLoading,
                        scoreTapEnabled: true,
                        scoreTapAction: {
                            openScoreBreakdown(for: rival.squad, teamNameOverride: rival.teamName)
                        }
                    )
                    pitchSection(
                        displayData,
                        playerSelectionEnabled: true,
                        detailMode: $fantasyPitchDetailMode
                    )
                    benchSection(
                        displayData,
                        playerSelectionEnabled: true,
                        detailMode: fantasyPitchDetailMode
                    )
                    eventLegendSection(rival.squad)
                    if rival.squad.isEstimatedScore {
                        scoreCalculationSection(rival.squad)
                    }
                    summaryStatsSection(rival.squad)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(rival.teamName)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        selectedRivalSquad = nil
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
        detailMode: Binding<FantasyPitchPlayerDetailMode>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {

            ZStack(alignment: .topTrailing) {
                FantasyPitchBackground()

                VStack(spacing: 8) {
                    positionRow(
                        data.goalkeepers,
                        gameweekID: data.gameweekID,
                        playerSelectionEnabled: playerSelectionEnabled,
                        detailMode: detailMode.wrappedValue
                    )
                    positionRow(
                        data.defenders,
                        gameweekID: data.gameweekID,
                        playerSelectionEnabled: playerSelectionEnabled,
                        detailMode: detailMode.wrappedValue
                    )
                    positionRow(
                        data.midfielders,
                        gameweekID: data.gameweekID,
                        playerSelectionEnabled: playerSelectionEnabled,
                        detailMode: detailMode.wrappedValue
                    )
                    positionRow(
                        data.forwards,
                        gameweekID: data.gameweekID,
                        playerSelectionEnabled: playerSelectionEnabled,
                        detailMode: detailMode.wrappedValue
                    )
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)

                FantasyPitchDetailToggleButton(mode: detailMode)
                    .padding(.top, 10)
                    .padding(.trailing, 10)
            }
            .frame(height: 470)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func positionRow(
        _ players: [FantasyDisplayPlayer],
        gameweekID: Int,
        playerSelectionEnabled: Bool,
        detailMode: FantasyPitchPlayerDetailMode
    ) -> some View {
        GeometryReader { proxy in
            let count = max(players.count, 1)
            let spacing: CGFloat = 4
            let availableWidth = proxy.size.width - (CGFloat(count - 1) * spacing)
            let cardWidth = min(68, max(42, floor(availableWidth / CGFloat(count))))

            HStack(spacing: spacing) {
                ForEach(players) { player in
                    selectablePlayerCard(
                        player: player,
                        width: cardWidth,
                        gameweekID: gameweekID,
                        playerSelectionEnabled: playerSelectionEnabled,
                        detailMode: detailMode
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 104)
    }

    private func benchSection(
        _ data: FantasySquadDisplayData,
        playerSelectionEnabled: Bool,
        detailMode: FantasyPitchPlayerDetailMode
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bench")
                .font(.headline)

            GeometryReader { proxy in
                let count = max(data.bench.count, 1)
                let spacing: CGFloat = 5
                let availableWidth = proxy.size.width - (CGFloat(count - 1) * spacing)
                let cardWidth = min(70, max(44, floor(availableWidth / CGFloat(count))))

                HStack(spacing: spacing) {
                    ForEach(data.bench) { player in
                        selectablePlayerCard(
                            player: player,
                            width: cardWidth,
                            gameweekID: data.gameweekID,
                            playerSelectionEnabled: playerSelectionEnabled,
                            detailMode: detailMode
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 118)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }

    @ViewBuilder
    private func selectablePlayerCard(
        player: FantasyDisplayPlayer,
        width: CGFloat,
        gameweekID: Int,
        playerSelectionEnabled: Bool,
        detailMode: FantasyPitchPlayerDetailMode
    ) -> some View {
        if playerSelectionEnabled {
            Button {
                openPlayerDetails(player: player, gameweekID: gameweekID)
            } label: {
                FantasyPlayerCard(player: player, width: width, detailMode: detailMode)
            }
            .buttonStyle(.plain)
        } else {
            FantasyPlayerCard(player: player, width: width, detailMode: detailMode)
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

    private var fantasyLoadingOverlay: some View {
        FantasyLoadingInterstitialView()
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: showFantasyLoadingInterstitial)
    }

    private func handleFantasyLoadingInterstitialChange(isLoading: Bool) {
        let isInitialLoad = !managerEntryID.isEmpty && fantasyViewModel.data == nil
        if isLoading && isInitialLoad {
            beginFantasyLoadingInterstitialMinimumDisplay()
            return
        }

        guard !isLoading else { return }
        if isFantasyLoadingInterstitialMinimumDurationMet {
            isFantasyLoadingInterstitialActive = false
        }
    }

    private func beginFantasyLoadingInterstitialMinimumDisplay() {
        let sessionID = UUID()
        fantasyLoadingInterstitialSessionID = sessionID
        isFantasyLoadingInterstitialActive = true
        isFantasyLoadingInterstitialMinimumDurationMet = false

        Task {
            try? await Task.sleep(nanoseconds: fantasyLoadingInterstitialMinimumDurationNanoseconds)
            guard fantasyLoadingInterstitialSessionID == sessionID else { return }
            isFantasyLoadingInterstitialMinimumDurationMet = true
            if !fantasyViewModel.isLoading {
                isFantasyLoadingInterstitialActive = false
            }
        }
    }

    private func resetFantasyLoadingInterstitial() {
        fantasyLoadingInterstitialSessionID = UUID()
        isFantasyLoadingInterstitialActive = false
        isFantasyLoadingInterstitialMinimumDurationMet = false
    }

    private func triggerFantasyRefresh(
        force: Bool,
        rivalManagers rivalManagersOverride: [FantasyRivalManager]? = nil,
        trackedLeagues trackedLeaguesOverride: [FantasyTrackedLeague]? = nil
    ) {
        guard !managerEntryID.isEmpty else { return }
        guard isSelected else { return }
        guard scenePhase == .active else { return }

        let rivalManagersSnapshot = rivalManagersOverride ?? rivalManagers
        let trackedLeaguesSnapshot = trackedLeaguesOverride ?? trackedLeagues

        if fantasyViewModel.isLoading || fantasyViewModel.isRefreshing {
            pendingFantasyRefreshRequest = PendingFantasyRefreshRequest(
                force: force,
                rivalManagers: rivalManagersSnapshot,
                trackedLeagues: trackedLeaguesSnapshot
            )
            #if DEBUG
            print(
                "[FantasyUI] queue_refresh force=\(force) rivals=\(rivalManagersSnapshot.count) leagues=\(trackedLeaguesSnapshot.count)"
            )
            #endif
            return
        }

        #if DEBUG
        print(
            "[FantasyUI] trigger_refresh force=\(force) rivals=\(rivalManagersSnapshot.count) leagues=\(trackedLeaguesSnapshot.count)"
        )
        #endif

        Task {
            await fantasyViewModel.refresh(
                managerEntryID: managerEntryID,
                apiBaseURL: preferences.apiBaseURL,
                rivalManagers: rivalManagersSnapshot,
                trackedLeagues: trackedLeaguesSnapshot
            )
        }
    }

    private func drainPendingFantasyRefreshIfNeeded() {
        guard let pendingRequest = pendingFantasyRefreshRequest else { return }
        guard !fantasyViewModel.isLoading, !fantasyViewModel.isRefreshing else { return }

        self.pendingFantasyRefreshRequest = nil
        triggerFantasyRefresh(
            force: pendingRequest.force,
            rivalManagers: pendingRequest.rivalManagers,
            trackedLeagues: pendingRequest.trackedLeagues
        )
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

    private func removeLeague(leagueID: Int) {
        let updatedLeagues = trackedLeagues.filter { $0.leagueID != leagueID }
        trackedLeagues = updatedLeagues
        persistTrackedLeaguesToStorage(updatedLeagues)
        triggerFantasyRefresh(force: true, trackedLeagues: updatedLeagues)
    }

    private func unlinkFantasyAccountData() {
        managerEntryID = ""
        rivalManagers = []
        rivalManagersJSON = "[]"
        trackedLeagues = []
        trackedLeaguesJSON = "[]"
        selectedRivalSquad = nil
        selectedLeagueStanding = nil
        selectedPlayerSelection = nil
        pendingRivalProfile = nil
        pendingLeagueStanding = nil
        rivalEntryInput = ""
        managerEntryInput = ""
        rivalValidationErrorMessage = nil
        leagueValidationErrorMessage = nil
        managerValidationErrorMessage = nil
        showAddRivalSheet = false
        showReviewShareSheet = false
        shareRemovedEntryIDs = []
        shareImportStatusMessage = nil
        shareImportStatusIsError = false
        pendingFantasyRefreshRequest = nil
        managerCaptureStatusMessage = "Waiting for shared Fantasy entry URL. Open your Points page in Safari/Chrome and share it to Top Scores."

        guard let defaults = UserDefaults(suiteName: AppGroupConfig.identifier) else { return }
        defaults.removeObject(forKey: AppGroupConfig.fantasySharedEntryURLKey)
        defaults.removeObject(forKey: AppGroupConfig.fantasySharedEntryUpdatedAtKey)
        defaults.removeObject(forKey: AppGroupConfig.fantasyManagerEntryIDKey)
        defaults.synchronize()
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
                print("[FantasyShare] rendered image size=\(Int(image.size.width))x\(Int(image.size.height)) scale=\(image.scale)")
                #endif
                queuedShareItems = [FantasyImageShareItemSource(image: image)]
                showReviewShareSheet = false
            } else {
                #if DEBUG
                print("[FantasyShare] render returned nil")
                #endif
                isLaunchingShareFlow = false
            }
        }
    }

    private func presentShareSheet(with items: [Any]) {
        guard activeSharePayload == nil else { return }
        #if DEBUG
        let typeDescriptions = items.map { String(describing: type(of: $0)) }.joined(separator: ",")
        print("[FantasyShare] presenting share sheet items=\(items.count) types=[\(typeDescriptions)]")
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

    private func applyCapturedManagerID(_ capturedID: String) {
        guard capturedID.allSatisfy(\.isNumber), !capturedID.isEmpty else {
            managerCaptureStatusMessage = "Shared URL did not include a valid manager ID. Share the Points page URL."
            return
        }

        managerEntryID = capturedID
        managerCaptureStatusMessage = "Successfully connected your account! Add rivals and leagues below..."
        showSuccessInterstitial = true

        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation {
                showSuccessInterstitial = false
            }
        }
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
                setShareImportStatus("Fantasy Football account linked successfully!", isError: false)
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
                managerCaptureStatusMessage = "Fantasy Football is temporarily updating. We'll retry adding this rival shortly."
                setShareImportStatus(
                    "Fantasy Football is temporarily updating. We'll retry adding this rival shortly.",
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
                    "Fantasy Football is temporarily updating. We'll retry adding this league shortly.",
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
                    colors: [Color(red: 0.00, green: 0.67, blue: 0.34), Color(red: 0.00, green: 0.52, blue: 0.27)],
                    startPoint: .top,
                    endPoint: .bottom
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
                .stroke(Color.white.opacity(0.85), lineWidth: 2)
            }
        }
    }
}

private enum FantasyPitchPlayerDetailMode {
    case opponent
    case value
    case expectedPoints

    var buttonLabel: String {
        switch self {
        case .opponent: return "OPP"
        case .value: return "VAL"
        case .expectedPoints: return "xP"
        }
    }

    var systemImageName: String {
        switch self {
        case .opponent:
            return "figure.soccer"
        case .value:
            return "sterlingsign.circle.fill"
        case .expectedPoints:
            return "sparkles"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .opponent:
            return "Showing opponents. Tap to show player values."
        case .value:
            return "Showing player values. Tap to show expected points."
        case .expectedPoints:
            return "Showing expected points. Tap to show opponents."
        }
    }

    mutating func toggle() {
        switch self {
        case .opponent:
            self = .value
        case .value:
            self = .expectedPoints
        case .expectedPoints:
            self = .opponent
        }
    }
}

private struct FantasyPitchDetailToggleButton: View {
    @Binding var mode: FantasyPitchPlayerDetailMode

    var body: some View {
        Button {
            mode.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: mode.systemImageName)
                    .font(.system(size: 10, weight: .semibold))
                Text(mode.buttonLabel)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(.white)
            .background(Color.black.opacity(0.35), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.accessibilityLabel)
    }
}

private struct FantasyPlayerCard: View {
    let player: FantasyDisplayPlayer
    let width: CGFloat
    let detailMode: FantasyPitchPlayerDetailMode
    @State private var isPulsing = false

    private var logoImage: UIImage? {
        LogoResolver.shared.image(for: player.teamName)
    }

    private var scoreState: FantasyDisplayPlayer.GameweekScoreState {
        player.gameweekScoreState
    }

    private var pointsBackground: AnyShapeStyle {
        switch scoreState {
        case .live:
            return AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.95, green: 0.20, blue: 0.66), Color(red: 1.0, green: 0.29, blue: 0.29)],
                startPoint: .leading,
                endPoint: .trailing
            ))
        case .upcoming:
            return AnyShapeStyle(Color(red: 0.20, green: 0.03, blue: 0.28))
        case .completed:
            return AnyShapeStyle(fantasyScoreHeatmapColor(player.displayPoints))
        case .noFixture:
            return AnyShapeStyle(Color(red: 0.12, green: 0.04, blue: 0.18))
        }
    }

    private var nameBackgroundColor: Color {
        if player.isUnavailable {
            return Color(red: 0.90, green: 0.90, blue: 0.92)
        }
        return .white
    }

    private var primaryTextColor: Color {
        player.isUnavailable ? Color.gray.opacity(0.9) : .black
    }

    private var pointsForegroundColor: Color {
        switch scoreState {
        case .completed:
            return player.displayPoints >= 3 ? Color.black.opacity(0.82) : .white
        case .live, .upcoming, .noFixture:
            return .white
        }
    }

    private var scoreStateSymbolName: String? {
        switch scoreState {
        case .completed:
            return nil
        case .noFixture:
            return "minus"
        case .live, .upcoming:
            return nil
        }
    }

    private var accessibilityLabelText: String {
        "\(player.displayName), \(secondaryDisplayText), \(player.displayPoints) points, \(scoreState.accessibilityDescription)"
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
        case .value:
            return String(format: "£%.1fm", player.nowCostMillions)
        case .expectedPoints:
            return "-"
        }
    }

    private var secondaryXPValue: Int? {
        guard detailMode == .expectedPoints else { return nil }
        return player.expectedPointsThisGameweek
    }

    private var secondaryXPForegroundColor: Color {
        guard let secondaryXPValue else { return .secondary }
        return secondaryXPValue >= 3 ? Color.black.opacity(0.82) : .white
    }

    var body: some View {
        let crestContainerSize = max(22, min(width * 0.48, 32))
        let crestImageSize = crestContainerSize * 0.78

        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(red: 0.07, green: 0.46, blue: 0.26).opacity(0.94))

                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.92))
                        .frame(width: crestContainerSize, height: crestContainerSize)

                    if let logoImage {
                        Image(uiImage: logoImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: crestImageSize, height: crestImageSize)
                    } else {
                        Image(systemName: "person.fill")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(Color.gray.opacity(0.8))
                            .frame(width: crestImageSize * 0.62, height: crestImageSize * 0.62)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 4)

                if player.isUnavailable || player.hasFutureAvailabilityIssue {
                    HStack(spacing: 3) {
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
                        Spacer(minLength: 0)
                    }
                    .padding(3)
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
                    .padding(3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }

                HStack(spacing: 4) {
                    if player.isCaptain {
                        badge(text: "C", color: .yellow)
                    }
                    if player.isViceCaptain {
                        badge(text: "V", color: .cyan)
                    }
                    if player.multiplier > 1 {
                        badge(text: "x\(player.multiplier)", color: .mint)
                    }
                }
                .padding(3)
            }
            .frame(width: width, height: 46)

            VStack(spacing: 1) {
                Text(player.displayName)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(primaryTextColor)

                if let secondaryXPValue {
                    Text("xP \(secondaryXPValue)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .foregroundStyle(secondaryXPForegroundColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(fantasyScoreHeatmapColor(secondaryXPValue))
                        )
                } else {
                    Text(secondaryDisplayText)
                        .font(.system(size: detailMode == .expectedPoints ? 12 : 9, weight: .semibold, design: detailMode == .expectedPoints ? .rounded : .default))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(detailMode == .expectedPoints ? Color.secondary : primaryTextColor)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .frame(width: width)
            .background(nameBackgroundColor)

            ZStack(alignment: .trailing) {
                Text("\(player.displayPoints)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .foregroundStyle(pointsForegroundColor)
                    .frame(width: width)
                    .padding(.vertical, 3)

                if let scoreStateSymbolName {
                    Image(systemName: scoreStateSymbolName)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(pointsForegroundColor.opacity(0.62))
                        .padding(.trailing, 4)
                }
            }
            .background(pointsBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            if player.isPlayingNow {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.red.opacity(isPulsing ? 0.45 : 0.9), lineWidth: 1)
                    .scaleEffect(isPulsing ? 1.03 : 1.0)
            }
        }
        .shadow(color: player.isPlayingNow ? Color.red.opacity(isPulsing ? 0.25 : 0.1) : .black.opacity(0.1), radius: 2, x: 0, y: 1)
        .animation(
            player.isPlayingNow ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
            value: isPulsing
        )
        .onAppear {
            isPulsing = player.isPlayingNow
        }
        .onChange(of: player.isPlayingNow) { _, newValue in
            isPulsing = newValue
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText)
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 7, weight: .bold, design: .rounded))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.95))
            )
            .foregroundStyle(.black.opacity(0.8))
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

private enum LeagueRankTrend {
    case up
    case down
    case equal
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
    "\(Int(value.rounded()))"
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

    var id: String {
        "\(player.elementID)-\(gameweekID)-\(player.pickPosition)"
    }
}

private struct FantasyScoreBreakdownSelection: Identifiable {
    let id = UUID()
    let teamName: String
    let squad: FantasySquadDisplayData
}

private struct FantasyScoreBreakdownRow: Identifiable {
    let elementID: Int
    let playerName: String
    let teamName: String
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
                        Text("Top Scores: Fantasy Football")
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
    @AppStorage("fantasy.assistantManagerInterstitialShown")
    private var hasShownAssistantManagerInterstitial = false

    private let minimumInterstitialNanoseconds: UInt64 = 3_000_000_000

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
                        assistantTeamLogoView(
                            teamName: move.outTeamName ?? move.outTeamShortName ?? "",
                            size: 16
                        )
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
                        assistantTeamLogoView(
                            teamName: move.inTeamName ?? move.inTeamShortName ?? "",
                            size: 16
                        )
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
                            assistantTeamLogoView(teamName: player.teamName, size: 14)
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
                                    assistantTeamLogoView(
                                        teamName: item.teamName ?? item.teamShortName ?? "",
                                        size: 16
                                    )
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
        let assistantScore = response.idealSquad?.displayedTotalPoints

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
                assistantIdealPositionRow(data.goalkeepers)
                assistantIdealPositionRow(data.defenders)
                assistantIdealPositionRow(data.midfielders)
                assistantIdealPositionRow(data.forwards)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)

            FantasyPitchDetailToggleButton(mode: $pitchDetailMode)
                .padding(.top, 10)
                .padding(.trailing, 10)
        }
        .frame(height: 470)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func assistantIdealPositionRow(
        _ players: [FantasyDisplayPlayer]
    ) -> some View {
        GeometryReader { proxy in
            let count = max(players.count, 1)
            let spacing: CGFloat = 4
            let availableWidth = proxy.size.width - (CGFloat(count - 1) * spacing)
                let cardWidth = min(68, max(42, floor(availableWidth / CGFloat(count))))

                HStack(spacing: spacing) {
                    ForEach(players) { player in
                        FantasyPlayerCard(player: player, width: cardWidth, detailMode: pitchDetailMode)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        .frame(height: 104)
    }

    private func assistantIdealBenchSection(_ data: FantasySquadDisplayData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bench")
                .font(.headline)

            GeometryReader { proxy in
                let count = max(data.bench.count, 1)
                let spacing: CGFloat = 5
                let availableWidth = proxy.size.width - (CGFloat(count - 1) * spacing)
                let cardWidth = min(70, max(44, floor(availableWidth / CGFloat(count))))

                HStack(spacing: spacing) {
                    ForEach(data.bench) { player in
                        FantasyPlayerCard(player: player, width: cardWidth, detailMode: pitchDetailMode)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 118)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.systemBackground).opacity(0.75))
            )
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
            nowCostMillions: player.nowCostMillions,
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
            expectedPointsThisGameweek: Int(player.expectedPointsNextGameweek.rounded()),
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

                        Text(
                            fixture.isBlank
                                ? "0"
                                : fantasyExpectedPointsText(
                                    assistantExpectedPointsForDetailsFixture(
                                        details: details,
                                        fixture: fixture,
                                        fixtureIndex: index
                                    )
                                )
                        )
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
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
        let color: Color
        switch value {
        case ..<2.0:
            color = Color.red
        case ..<4.0:
            color = Color.orange
        case ..<6.0:
            color = Color.yellow
        default:
            color = Color.green
        }

        return Text(fantasyExpectedPointsText(value))
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(value >= 4.0 ? Color.black.opacity(0.82) : Color.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.92))
            )
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
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
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
        let shouldApplyMinimumDelay = !hasShownAssistantManagerInterstitial

        let minimumDelayTask = Task<Void, Never> {
            guard shouldApplyMinimumDelay else { return }
            try? await Task.sleep(nanoseconds: minimumInterstitialNanoseconds)
        }
        let phraseTask = Task {
            await loadAssistantPhrase()
        }

        do {
            await fantasyViewModel.prewarmAssistantManagerCache(
                entryID: entryID,
                apiBaseURL: apiBaseURL,
                force: forceFetch
            )

            let loaded = try await pollForAssistantManager(forceFetch: forceFetch)
            await phraseTask.value
            await minimumDelayTask.value
            if shouldApplyMinimumDelay {
                hasShownAssistantManagerInterstitial = true
            }
            guard interstitialSessionID == sessionID else { return }
            response = loaded
            errorMessage = nil
            await preloadIncomingPlayerDetails(from: loaded)
        } catch {
            await phraseTask.value
            await minimumDelayTask.value
            if shouldApplyMinimumDelay {
                hasShownAssistantManagerInterstitial = true
            }
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
        var lastResponse: FantasyAssistantManagerResponse?

        for attempt in 0..<8 {
            let loaded = try await fantasyViewModel.fetchAssistantManager(
                entryID: entryID,
                apiBaseURL: apiBaseURL,
                forceRefresh: forceFetch || attempt > 0
            )
            lastResponse = loaded
            if loaded.ready {
                return loaded
            }
            try? await Task.sleep(nanoseconds: 450_000_000)
        }

        if let lastResponse {
            return lastResponse
        }
        throw URLError(.badServerResponse)
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
            return "Assistant Manager is temporarily unavailable while Fantasy Football updates."
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

private struct FantasyLoadingInterstitialView: View {
    @State private var animate = false
    @State private var statusMessage = "Loading Fantasy Football..."

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.22, blue: 0.32),
                    Color(red: 0.10, green: 0.76, blue: 0.90),
                    Color(red: 0.05, green: 0.53, blue: 0.77),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                        .frame(width: 214, height: 214)

                    Circle()
                        .trim(from: 0.12, to: 0.90)
                        .stroke(
                            AngularGradient(
                                colors: [
                                    Color.white.opacity(0.18),
                                    Color(red: 0.23, green: 0.0, blue: 0.29),
                                    Color.white.opacity(0.82),
                                    Color.white.opacity(0.18),
                                ],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .frame(width: 176, height: 176)
                        .rotationEffect(.degrees(animate ? 360 : 0))
                        .animation(.linear(duration: 2.8).repeatForever(autoreverses: false), value: animate)

                    Circle()
                        .trim(from: 0.06, to: 0.42)
                        .stroke(
                            Color.white.opacity(0.72),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .frame(width: 144, height: 144)
                        .rotationEffect(.degrees(animate ? -360 : 0))
                        .animation(.linear(duration: 1.9).repeatForever(autoreverses: false), value: animate)

                    ForEach(0..<20, id: \.self) { index in
                        Circle()
                            .fill(.white.opacity(animate ? 0.92 : 0.36))
                            .frame(width: index.isMultiple(of: 4) ? 7 : 4, height: index.isMultiple(of: 4) ? 7 : 4)
                            .offset(y: -86)
                            .rotationEffect(.degrees(Double(index) * 18 + (animate ? 360 : 0)))
                            .animation(
                                .easeInOut(duration: 1.15)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.03),
                                value: animate
                            )
                    }

                    Image(systemName: "trophy")
                        .font(.system(size: 56, weight: .regular))
                        .foregroundStyle(.white)
                        .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 8)
                }

                VStack(spacing: 8) {
                    Text("Fantasy Football")
                        .font(.title.weight(.bold))
                        .foregroundStyle(.white)

                    Text(statusMessage)
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
            Task {
                statusMessage = await FantasyLoadingMessagesCatalog.shared.randomMessage()
            }
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
