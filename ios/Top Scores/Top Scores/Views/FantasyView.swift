import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

struct FantasyView: View {
    let isSelected: Bool

    @EnvironmentObject private var preferences: PreferencesStore
    @AppStorage(StorageKeys.managerEntryID) private var managerEntryID = ""
    @AppStorage(StorageKeys.rivalManagersJSON) private var rivalManagersJSON = "[]"
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var fantasyViewModel = FantasyViewModel()

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
    @State private var showAddRivalSheet = false
    @State private var rivalEntryInput = ""
    @State private var managerEntryInput = ""
    @State private var pendingRivalProfile: FantasyEntryProfile?
    @State private var rivalValidationErrorMessage: String?
    @State private var managerValidationErrorMessage: String?
    @State private var isValidatingManager = false
    @State private var isValidatingRival = false
    @State private var selectedRivalSquad: FantasyRivalSquad?
    @State private var selectedPlayerSelection: FantasySelectedPlayerSelection?
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
    @State private var showUnlinkAccountConfirmation = false
    @FocusState private var isRivalEntryInputFocused: Bool

    private let fantasyRefreshTimer = Timer.publish(every: 30.0, on: .main, in: .common).autoconnect()
    private let sharedEntryPollTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
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
        .overlay {
            ZStack {
                if showSuccessInterstitial {
                    successOverlay
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
        .alert("Unlink Fantasy account?", isPresented: $showUnlinkAccountConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Unlink", role: .destructive) {
                unlinkFantasyAccountData()
            }
        } message: {
            Text("This will remove your linked manager account, rivals, and Fantasy Football data from this device.")
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
        .onAppear {
            loadRivalManagersFromStorage()
            syncManagerEntryIDToSharedDefaults()
            if managerEntryID.isEmpty {
                managerCaptureStatusMessage = "Waiting for shared Fantasy entry URL. Open your Points page in Safari/Chrome and share it to Top Scores."
            } else {
                triggerFantasyRefresh(force: fantasyViewModel.data == nil)
            }
            armSharedEntryPolling()
            consumeSharedFantasyEntryURLIfNeeded()
        }
        .onChange(of: isSelected) { _, selected in
            guard selected else { return }
            if !managerEntryID.isEmpty {
                triggerFantasyRefresh(force: fantasyViewModel.data == nil)
            }
            armSharedEntryPolling()
            consumeSharedFantasyEntryURLIfNeeded()
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else { return }
            if isSelected, !managerEntryID.isEmpty {
                triggerFantasyRefresh(force: false)
            }
            armSharedEntryPolling()
            consumeSharedFantasyEntryURLIfNeeded()
        }
        .onChange(of: managerEntryID) { _, newValue in
            syncManagerEntryIDToSharedDefaults()
            if newValue.isEmpty {
                fantasyViewModel.reset()
                managerCaptureStatusMessage = "Waiting for shared Fantasy entry URL. Open your Points page in Safari/Chrome and share it to Top Scores."
                managerValidationErrorMessage = nil
            } else {
                triggerFantasyRefresh(force: true)
                managerValidationErrorMessage = nil
            }
        }
        .onChange(of: preferences.apiBaseURL) { _, _ in
            guard !managerEntryID.isEmpty else { return }
            triggerFantasyRefresh(force: true)
        }
        .onChange(of: rivalManagersJSON) { _, _ in
            loadRivalManagersFromStorage()
            guard !managerEntryID.isEmpty else { return }
            triggerFantasyRefresh(force: true)
        }
        .onReceive(fantasyRefreshTimer) { _ in
            guard isSelected,
                  scenePhase == .active,
                  !managerEntryID.isEmpty else { return }
            if let currentData = fantasyViewModel.data, !currentData.hasActiveFixtures {
                guard let lastUpdated = fantasyViewModel.lastUpdated else { return }
                guard Date().timeIntervalSince(lastUpdated) >= 15 * 60 else { return }
            }
            triggerFantasyRefresh(force: false)
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
    }

    private var setupFlowView: some View {
        Form {
            setupSection
            managerEntryInputSection
            shareFromBrowserHelpSection
            managerCaptureStatusSection
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

                if let data = fantasyViewModel.data {
                    if let shareImportStatusMessage {
                        shareImportStatusCard(
                            message: shareImportStatusMessage,
                            isError: shareImportStatusIsError
                        )
                    }
                    scoreSummaryCard(data)
                    pitchSection(data, playerSelectionEnabled: true)
                    benchSection(data, playerSelectionEnabled: true)
                    eventLegendSection(data)
                    if data.isEstimatedScore {
                        scoreCalculationSection(data)
                    }
                    rivalsSection
                } else if fantasyViewModel.isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Loading Fantasy score...")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                }

                if let errorMessage = fantasyViewModel.errorMessage {
                    errorCard(errorMessage)
                }

                if let data = fantasyViewModel.data {
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
                rivalManagers: rivalManagers
            )
        }
    }

    private var setupSection: some View {
        Section("Connect your Fantasy account") {
            instructionStep(number: 1, text: "Open Fantasy Premier League in Safari or Chrome.")
            instructionStep(number: 2, text: "Sign in and open your Points page URL.")
            instructionStep(number: 3, text: "Tap Share and choose Top Scores.")
            instructionStep(number: 4, text: "If Top Scores is missing, open More/Edit Actions and enable Top Scores.")
            instructionStep(number: 5, text: "Return to Top Scores to complete setup or view your updated Rivals table.")

            Button {
                openFantasyWebsiteInBrowser()
            } label: {
                Label("Open fantasy.premierleague.com", systemImage: "safari")
            }
        }
    }

    private var managerEntryInputSection: some View {
        Section("Or enter manager ID manually") {
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

    private var shareFromBrowserHelpSection: some View {
        Section("Share Extension Flow") {
            Text("First setup: share your own Points page to Top Scores.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("After setup: any shared Fantasy entry URL is treated as a rival and validated automatically.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Because all shared entry URLs have the same format, the first successful share is always used as your manager ID.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("If Google sign-in blocks in-app browsers, use Safari or Chrome, then Share -> Top Scores.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Example: https://fantasy.premierleague.com/entry/6653695/event/28")
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
        }
    }

    private var managerCaptureStatusSection: some View {
        Section("Connection status") {
            Text(managerCaptureStatusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let managerValidationErrorMessage {
                Text(managerValidationErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
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
                Label("Unlink account", systemImage: "person.crop.circle.badge.xmark")
                    .font(.subheadline.weight(.semibold))
            }

            Text("Removes your linked manager account and locally saved Fantasy data.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func scoreSummaryCard(_ data: FantasySquadDisplayData) -> some View {
        let currentScore = data.resolvedCurrentScore
        let displayedScore = data.isEstimatedScore ? "\(currentScore)*" : "\(currentScore)"
        let rivalPills = rivalScorePills(for: data)

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(data.gameweekTitle)
                    .font(.headline)
                if !rivalPills.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(rivalPills) { pill in
                                HStack(spacing: 6) {
                                    Text(pill.initials)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text("\(pill.score)")
                                        .font(.caption.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(.primary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color(.tertiarySystemGroupedBackground))
                                )
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            FantasyScoreLozenge(
                displayedScore: displayedScore,
                isLive: data.hasActiveFixtures
            )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func rivalScorePills(for data: FantasySquadDisplayData) -> [FantasyRivalScorePill] {
        fantasyViewModel.rivalSquads
            .map { rival in
                FantasyRivalScorePill(
                    entryID: rival.entryID,
                    initials: initials(for: rival.managerName),
                    score: data.hasActiveFixtures ? rival.squad.resolvedCurrentScore : rival.squad.totalPoints
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
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
            .map(String.init)
            .filter { !$0.isEmpty }

        if words.isEmpty {
            return "R"
        }

        if words.count == 1 {
            return String(words[0].prefix(2)).uppercased()
        }

        let first = words.first?.prefix(1) ?? ""
        let last = words.last?.prefix(1) ?? ""
        return String(first + last).uppercased()
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
                squad: mySquad,
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
                squad: rivalSquad?.squad,
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

            Text("Share a rival's Fantasy Points page to Top Scores from Safari/Chrome to add them automatically.")
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

    private func rivalTableRow(
        rank: Int,
        entry: FantasyLeagueTableEntry,
        scoreMode: RivalsScoreMode
    ) -> some View {
        HStack(spacing: 8) {
            Text("\(rank)")
                .font(.body.monospacedDigit())
                .frame(width: 26, alignment: .trailing)
                .foregroundStyle(.secondary)

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
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.scoreDisplay(for: scoreMode))
                .font(.body.monospacedDigit().weight(.semibold))
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(Color.primary)

            Text(">")
                .font(.body.weight(.semibold))
                .frame(width: 16, alignment: .center)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
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
                    Text("For the fastest flow, open a rival's Points page in Safari/Chrome and share it to Top Scores. It will auto-validate when you return to the app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button {
                        openFantasyWebsiteInBrowser()
                    } label: {
                        Label("Open fantasy.premierleague.com", systemImage: "globe")
                    }
                }

                Section("Manager ID") {
                    Text("Alternatively, if you know their ID, please enter it here...")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    TextField("Enter manager ID", text: $rivalEntryInput)
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
                            await validateRivalEntryInput()
                        }
                    } label: {
                        if isValidatingRival {
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
                    .disabled(!isRivalSubmitEnabled)
                }

                if let rivalValidationErrorMessage {
                    Section {
                        Text(rivalValidationErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if let pendingRivalProfile {
                    Section("Confirm manager") {
                        Text("Team: \(pendingRivalProfile.name)")
                        Text("Manager: \(pendingRivalProfile.playerFirstName) \(pendingRivalProfile.playerLastName)")
                        Button("Add rival manager") {
                            addPendingRivalProfile()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Add Rival")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        showAddRivalSheet = false
                    }
                }
            }
            .onAppear {
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
            ScrollView {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rival.managerName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("Entry ID: \(rival.entryID)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    scoreSummaryCard(rival.squad)
                    pitchSection(rival.squad, playerSelectionEnabled: false)
                    benchSection(rival.squad, playerSelectionEnabled: false)
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

    private func pitchSection(_ data: FantasySquadDisplayData, playerSelectionEnabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pitch")
                .font(.headline)

            ZStack {
                FantasyPitchBackground()

                VStack(spacing: 8) {
                    positionRow(data.goalkeepers, gameweekID: data.gameweekID, playerSelectionEnabled: playerSelectionEnabled)
                    positionRow(data.defenders, gameweekID: data.gameweekID, playerSelectionEnabled: playerSelectionEnabled)
                    positionRow(data.midfielders, gameweekID: data.gameweekID, playerSelectionEnabled: playerSelectionEnabled)
                    positionRow(data.forwards, gameweekID: data.gameweekID, playerSelectionEnabled: playerSelectionEnabled)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            }
            .frame(height: 470)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func positionRow(
        _ players: [FantasyDisplayPlayer],
        gameweekID: Int,
        playerSelectionEnabled: Bool
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
                        playerSelectionEnabled: playerSelectionEnabled
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 90)
    }

    private func benchSection(_ data: FantasySquadDisplayData, playerSelectionEnabled: Bool) -> some View {
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
                            playerSelectionEnabled: playerSelectionEnabled
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 104)
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
        playerSelectionEnabled: Bool
    ) -> some View {
        if playerSelectionEnabled {
            Button {
                openPlayerDetails(player: player, gameweekID: gameweekID)
            } label: {
                FantasyPlayerCard(player: player, width: width)
            }
            .buttonStyle(.plain)
        } else {
            FantasyPlayerCard(player: player, width: width)
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
                Text("Icon legend")
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

    private var successOverlay: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(.green)
                Text("Manager ID saved")
                    .font(.headline)
                Text(managerEntryID)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
            )
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: showSuccessInterstitial)
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

    private func triggerFantasyRefresh(force: Bool) {
        guard !managerEntryID.isEmpty else { return }
        guard isSelected else { return }
        guard scenePhase == .active else { return }
        if fantasyViewModel.isLoading || fantasyViewModel.isRefreshing {
            return
        }

        Task {
            await fantasyViewModel.refresh(
                managerEntryID: managerEntryID,
                apiBaseURL: preferences.apiBaseURL,
                rivalManagers: rivalManagers
            )
        }
    }

    private func prepareRivalEntrySheet() {
        rivalEntryInput = ""
        rivalValidationErrorMessage = nil
        pendingRivalProfile = nil
        isValidatingRival = false
        showAddRivalSheet = true
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

    private func addPendingRivalProfile() {
        guard let pendingRivalProfile else { return }
        let rival = FantasyRivalManager(
            entryID: pendingRivalProfile.id,
            teamName: pendingRivalProfile.name,
            managerFirstName: pendingRivalProfile.playerFirstName,
            managerLastName: pendingRivalProfile.playerLastName,
            overallPoints: pendingRivalProfile.summaryOverallPoints
        )
        guard !rivalManagers.contains(where: { $0.entryID == rival.entryID }) else {
            return
        }

        rivalManagers.append(rival)
        rivalManagers.sort { lhs, rhs in
            let left = lhs.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
            let right = rhs.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
            if left.localizedCaseInsensitiveCompare(right) != .orderedSame {
                return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
            }
            return lhs.entryID < rhs.entryID
        }
        persistRivalManagersToStorage()
        showAddRivalSheet = false
        triggerFantasyRefresh(force: true)
    }

    private func removeRival(entryID: Int) {
        rivalManagers.removeAll { $0.entryID == entryID }
        persistRivalManagersToStorage()
        triggerFantasyRefresh(force: true)
    }

    private func unlinkFantasyAccountData() {
        managerEntryID = ""
        rivalManagers = []
        rivalManagersJSON = "[]"
        selectedRivalSquad = nil
        selectedPlayerSelection = nil
        pendingRivalProfile = nil
        rivalEntryInput = ""
        managerEntryInput = ""
        rivalValidationErrorMessage = nil
        managerValidationErrorMessage = nil
        showAddRivalSheet = false
        showReviewShareSheet = false
        shareRemovedEntryIDs = []
        shareImportStatusMessage = nil
        shareImportStatusIsError = false
        managerCaptureStatusMessage = "Waiting for shared Fantasy entry URL. Open your Points page in Safari/Chrome and share it to Top Scores."

        guard let defaults = UserDefaults(suiteName: AppGroupConfig.identifier) else { return }
        defaults.removeObject(forKey: AppGroupConfig.fantasySharedEntryURLKey)
        defaults.removeObject(forKey: AppGroupConfig.fantasySharedEntryUpdatedAtKey)
        defaults.removeObject(forKey: AppGroupConfig.fantasyManagerEntryIDKey)
        defaults.synchronize()
    }

    private func openLeagueTableEntry(_ entry: FantasyLeagueTableEntry) {
        guard let squad = entry.squad else { return }
        selectedRivalSquad = FantasyRivalSquad(
            entryID: entry.entryID,
            teamName: entry.teamName,
            managerName: entry.managerName,
            squad: squad,
            allGameweeksPoints: entry.allGameweeksScore
        )
    }

    private func openPlayerDetails(player: FantasyDisplayPlayer, gameweekID: Int) {
        selectedPlayerSelection = FantasySelectedPlayerSelection(
            player: player,
            gameweekID: gameweekID
        )
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
        managerCaptureStatusMessage = "Manager ID \(capturedID) linked from shared URL."
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
        guard let sharedURL = defaults.string(forKey: AppGroupConfig.fantasySharedEntryURLKey) else { return }
        let sharedUpdatedAt = defaults.double(forKey: AppGroupConfig.fantasySharedEntryUpdatedAtKey)

        let trimmed = sharedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearSharedEntryImportPayload()
            return
        }

        if sharedUpdatedAt > 0, sharedUpdatedAt <= lastProcessedSharedEntryUpdatedAt {
            return
        }
        if sharedUpdatedAt <= 0, trimmed == lastProcessedSharedEntryURL {
            return
        }

        guard let parsedID = FantasyManagerIDParser.parse(from: trimmed) else {
            managerCaptureStatusMessage = "Received a shared link, but it did not contain a valid Fantasy entry URL."
            setShareImportStatus(
                "Received a shared link, but it did not contain a valid Fantasy entry URL.",
                isError: true
            )
            markSharedEntryAsProcessed(updatedAt: sharedUpdatedAt, rawURL: trimmed)
            clearSharedEntryImportPayload()
            return
        }

        if managerEntryID.isEmpty {
            applyCapturedManagerID(parsedID)
            setShareImportStatus("Manager ID \(parsedID) linked from shared URL.", isError: false)
            markSharedEntryAsProcessed(updatedAt: sharedUpdatedAt, rawURL: trimmed)
            clearSharedEntryImportPayload()
            return
        }

        if showAddRivalSheet {
            showAddRivalSheet = false
        }

        isProcessingSharedEntryImport = true
        Task {
            let handled = await addRivalFromSharedEntryID(parsedID)
            await MainActor.run {
                if handled {
                    markSharedEntryAsProcessed(updatedAt: sharedUpdatedAt, rawURL: trimmed)
                    clearSharedEntryImportPayload()
                } else {
                    nextSharedEntryRetryAt = Date().addingTimeInterval(3)
                }
                isProcessingSharedEntryImport = false
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
                overallPoints: profile.summaryOverallPoints
            )
            guard !rivalManagers.contains(where: { $0.entryID == rival.entryID }) else {
                setShareImportStatus("Rival \(capturedID) is already in your rivals list.", isError: false)
                return true
            }
            rivalManagers.append(rival)
            rivalManagers.sort { lhs, rhs in
                let left = lhs.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
                let right = rhs.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
                if left.localizedCaseInsensitiveCompare(right) != .orderedSame {
                    return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
                }
                return lhs.entryID < rhs.entryID
            }

            let managerNameParts = [
                profile.playerFirstName.trimmingCharacters(in: .whitespacesAndNewlines),
                profile.playerLastName.trimmingCharacters(in: .whitespacesAndNewlines)
            ].filter { !$0.isEmpty }
            let managerName = managerNameParts.joined(separator: " ")
            let rivalDisplayName = managerName.isEmpty ? profile.name : "\(profile.name) (\(managerName))"

            persistRivalManagersToStorage()
            managerCaptureStatusMessage = "Rival added from shared URL: \(rivalDisplayName)."
            setShareImportStatus("Rival added: \(rivalDisplayName)", isError: false)
            rivalEntryInput = ""
            pendingRivalProfile = nil
            rivalValidationErrorMessage = nil
            showAddRivalSheet = false
            triggerFantasyRefresh(force: true)
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

    private func clearSharedEntryImportPayload() {
        guard let defaults = UserDefaults(suiteName: AppGroupConfig.identifier) else { return }
        defaults.removeObject(forKey: AppGroupConfig.fantasySharedEntryURLKey)
        defaults.removeObject(forKey: AppGroupConfig.fantasySharedEntryUpdatedAtKey)
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

    private func loadRivalManagersFromStorage() {
        guard let data = rivalManagersJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([FantasyRivalManager].self, from: data) else {
            rivalManagers = []
            return
        }
        rivalManagers = decoded
    }

    private func persistRivalManagersToStorage() {
        guard let data = try? JSONEncoder().encode(rivalManagers),
              let encoded = String(data: data, encoding: .utf8) else {
            rivalManagersJSON = "[]"
            return
        }
        rivalManagersJSON = encoded
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

private struct FantasyPlayerCard: View {
    let player: FantasyDisplayPlayer
    let width: CGFloat
    @State private var isPulsing = false

    private var logoImage: UIImage? {
        LogoResolver.shared.image(for: player.teamName)
    }

    private var pointsBackground: AnyShapeStyle {
        if player.isUnavailable {
            return AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.62, green: 0.62, blue: 0.66), Color(red: 0.46, green: 0.46, blue: 0.50)],
                startPoint: .leading,
                endPoint: .trailing
            ))
        }
        if player.isPlayingNow {
            return AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.95, green: 0.20, blue: 0.66), Color(red: 1.0, green: 0.29, blue: 0.29)],
                startPoint: .leading,
                endPoint: .trailing
            ))
        }
        return AnyShapeStyle(Color(red: 0.20, green: 0.03, blue: 0.28))
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
        if player.isUnavailable {
            return Color.white.opacity(0.82)
        }
        return .white
    }

    private var hasEventStats: Bool {
        player.goalsScored > 0 || player.assists > 0 || player.yellowCards > 0 || player.redCards > 0
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

                if player.isUnavailable {
                    HStack(spacing: 0) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.orange)
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

            VStack(spacing: 2) {
                Text(player.displayName)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(primaryTextColor)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .frame(width: width)
            .background(nameBackgroundColor)

            Text(player.upcomingOpponentDisplay ?? "\(player.displayPoints)")
                .font(
                    player.upcomingOpponentDisplay == nil
                    ? .system(size: 10, weight: .bold, design: .rounded)
                    : .system(size: 8, weight: .semibold, design: .rounded)
                )
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .foregroundStyle(pointsForegroundColor)
                .frame(width: width)
                .padding(.vertical, 3)
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

private struct FantasyLeagueTableEntry: Identifiable, Hashable {
    let entryID: Int
    let teamName: String
    let managerName: String
    let currentGameweekScore: Int?
    let allGameweeksScore: Int?
    let squad: FantasySquadDisplayData?
    let isUser: Bool

    var id: Int {
        entryID
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
        return "\(score)"
    }
}

private struct FantasyRivalScorePill: Identifiable, Hashable {
    let entryID: Int
    let initials: String
    let score: Int

    var id: Int {
        entryID
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

struct FantasySelectedPlayerSelection: Identifiable {
    let player: FantasyDisplayPlayer
    let gameweekID: Int

    var id: String {
        "\(player.elementID)-\(gameweekID)-\(player.pickPosition)"
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
}
