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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var fantasyViewModel = FantasyViewModel()

    @State private var showSafariHelp = false
    @State private var showChromeHelp = false
    @State private var hasInitiatedClipboardCapture = false
    @State private var clipboardStatusMessage = ""
    @State private var lastClipboardChangeCount = UIPasteboard.general.changeCount
    @State private var showSuccessInterstitial = false
    @State private var rivalManagers: [FantasyRivalManager] = []
    @State private var showAddRivalSheet = false
    @State private var rivalEntryInput = ""
    @State private var pendingRivalProfile: FantasyEntryProfile?
    @State private var rivalValidationErrorMessage: String?
    @State private var isValidatingRival = false
    @State private var selectedRivalSquad: FantasyRivalSquad?
    @State private var selectedPlayerSelection: FantasySelectedPlayerSelection?
    @State private var showReviewShareSheet = false
    @State private var shareRemovedEntryIDs: Set<Int> = []
    @State private var queuedShareItems: [Any] = []
    @State private var activeSharePayload: FantasySharePayload?
    @State private var isPreparingShareImage = false
    @State private var isLaunchingShareFlow = false

    private let clipboardPollTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    private let fantasyRefreshTimer = Timer.publish(every: 30.0, on: .main, in: .common).autoconnect()

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
            if managerEntryID.isEmpty {
                updateClipboardStatusMessage()
                if isSelected, hasInitiatedClipboardCapture {
                    checkClipboardForManagerID(forceRead: true)
                }
            } else {
                triggerFantasyRefresh(force: fantasyViewModel.data == nil)
            }
        }
        .onChange(of: isSelected) { _, selected in
            guard selected else { return }
            if managerEntryID.isEmpty {
                if hasInitiatedClipboardCapture {
                    checkClipboardForManagerID(forceRead: true)
                }
            } else {
                triggerFantasyRefresh(force: fantasyViewModel.data == nil)
            }
        }
        .onChange(of: scenePhase) { _, newValue in
            guard isSelected, newValue == .active else { return }
            if managerEntryID.isEmpty {
                guard hasInitiatedClipboardCapture else { return }
                checkClipboardForManagerID(forceRead: true)
            } else {
                triggerFantasyRefresh(force: false)
            }
        }
        .onChange(of: managerEntryID) { _, newValue in
            if newValue.isEmpty {
                hasInitiatedClipboardCapture = false
                lastClipboardChangeCount = UIPasteboard.general.changeCount
                fantasyViewModel.reset()
                updateClipboardStatusMessage()
            } else {
                triggerFantasyRefresh(force: true)
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
        .onReceive(clipboardPollTimer) { _ in
            guard isSelected,
                  hasInitiatedClipboardCapture,
                  scenePhase == .active,
                  managerEntryID.isEmpty else { return }
            checkClipboardForManagerID(forceRead: false)
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
    }

    private var setupFlowView: some View {
        Form {
            setupSection
            safariHelpSection
            chromeHelpSection
            clipboardStatusSection
        }
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

                managerMetadataCard
                debugCard

                if let data = fantasyViewModel.data {
                    summaryStatsSection(data)
                }
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
            instructionStep(number: 1, text: "Open the Fantasy Premier League website using the link below")
            instructionStep(number: 2, text: "Sign in to your account, and tap the Points tab.")
            instructionStep(number: 3, text: "Copy the website address, return to this app and tap \"Allow Paste\".")

            Button {
                openFantasyLogin()
            } label: {
                Label("Open fantasy.premierleague.com", systemImage: "safari")
            }
        }
    }

    private var safariHelpSection: some View {
        Section {
            DisclosureGroup("How to do this in Safari", isExpanded: $showSafariHelp) {
                VStack(alignment: .leading, spacing: 12) {
                    browserStepCard(
                        step: 1,
                        title: "Tap the 3 dots button",
                        detail: "Use the bottom-right menu button in Safari.",
                        symbol: "ellipsis.circle.fill"
                    )

                    browserStepCard(
                        step: 2,
                        title: "Tap Share",
                        detail: "Select Share from the menu that opens.",
                        symbol: "square.and.arrow.up.fill"
                    )

                    browserStepCard(
                        step: 3,
                        title: "Tap Copy",
                        detail: "Copy the URL, then return to Top Scores.",
                        symbol: "doc.on.doc.fill"
                    )
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var chromeHelpSection: some View {
        Section {
            DisclosureGroup("How to do this in Chrome", isExpanded: $showChromeHelp) {
                VStack(alignment: .leading, spacing: 12) {
                    browserStepCard(
                        step: 1,
                        title: "Tap the Share button",
                        detail: "Tap the Share button in the top right-hand corner, at the end of the address bar.",
                        symbol: "square.and.arrow.up.fill"
                    )

                    browserStepCard(
                        step: 2,
                        title: "Tap Copy",
                        detail: "Copy the website address, then return to Top Scores.",
                        symbol: "doc.on.doc.fill"
                    )
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var clipboardStatusSection: some View {
        Section("Clipboard status") {
            if !hasInitiatedClipboardCapture && managerEntryID.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(clipboardStatusMessage)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                Text(clipboardStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var managerMetadataCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Manager ID")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(managerEntryID)
                .font(.headline.monospacedDigit())
                .textSelection(.enabled)

            if let lastUpdated = fantasyViewModel.lastUpdated {
                Text("Updated \(Self.timeFormatter.string(from: lastUpdated))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var debugCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Debug")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Button("Delete stored manager ID", role: .destructive) {
                managerEntryID = ""
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func scoreSummaryCard(_ data: FantasySquadDisplayData) -> some View {
        let currentScore = data.resolvedCurrentScore
        let displayedScore = data.isEstimatedScore ? "\(currentScore)*" : "\(currentScore)"

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(data.gameweekTitle)
                    .font(.headline)
                Text("Current gameweek score")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.cyan, Color.blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                VStack(spacing: 0) {
                    Text(displayedScore)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color(.label))
                    Text("PTS")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(.label).opacity(0.86))
                }
                .padding(.horizontal, 12)
            }
            .frame(width: 110, height: 72)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func summaryStatsSection(_ data: FantasySquadDisplayData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gameweek stats")
                .font(.headline)

            HStack(spacing: 8) {
                summaryPill(title: "GW Rank", value: formatNumber(data.rank))
                summaryPill(title: "Overall", value: formatNumber(data.overallRank))
                summaryPill(title: "Bench", value: formatNumber(data.pointsOnBench))
                summaryPill(title: "TCost", value: formatNumber(data.transfersCost))
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
                score: mySquad.resolvedCurrentScore,
                squad: mySquad,
                isUser: true
            )
        ]

        rows.append(contentsOf: fantasyViewModel.rivalSquads.map { rival in
            FantasyLeagueTableEntry(
                entryID: rival.entryID,
                teamName: rival.teamName,
                managerName: rival.managerName,
                score: rival.currentScore,
                squad: rival.squad,
                isUser: false
            )
        })

        return rows.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
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

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Rivals")
                    .font(.headline)
                Spacer(minLength: 0)
                Button {
                    prepareReviewShareSheet()
                } label: {
                    Text("Review and share")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .disabled(rankedEntries.count < 2)

                Button {
                    prepareRivalEntrySheet()
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
            }

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
                    Text("Pts")
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
                        rivalTableRow(rank: index + 1, entry: entry)
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
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func rivalTableRow(rank: Int, entry: FantasyLeagueTableEntry) -> some View {
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

            Text("\(entry.score)")
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

            Text("\(entry.score)")
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
                Section("Manager ID") {
                    TextField("Enter manager ID", text: $rivalEntryInput)
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

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
                            Text("Validate manager ID")
                        }
                    }
                    .disabled(isValidatingRival)
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
        }
    }

    private func rivalDetailSheet(_ rival: FantasyRivalSquad) -> some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.95))
                        .frame(width: 38, height: 5)
                        .shadow(color: .black.opacity(0.12), radius: 1, x: 0, y: 1)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)

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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
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

        return VStack(alignment: .leading, spacing: 8) {
            Text("Icon legend")
                .font(.headline)

            if lines.isEmpty {
                Text("No goals, assists, or cards recorded yet this gameweek.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(lines, id: \.self) { line in
                    Text(line)
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
            managerLastName: pendingRivalProfile.playerLastName
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

    private func openLeagueTableEntry(_ entry: FantasyLeagueTableEntry) {
        guard let squad = entry.squad else { return }
        selectedRivalSquad = FantasyRivalSquad(
            entryID: entry.entryID,
            teamName: entry.teamName,
            managerName: entry.managerName,
            squad: squad
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

    private func browserStepCard(step: Int, title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(.blue)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text("Step \(step): \(title)")
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func openFantasyLogin() {
        guard let url = URL(string: "https://fantasy.premierleague.com/") else { return }
        hasInitiatedClipboardCapture = true
        openURL(url)
        clipboardStatusMessage = "After copying your Points URL, return here and tap \"Allow Paste\"."
    }

    private func checkClipboardForManagerID(forceRead: Bool) {
        guard managerEntryID.isEmpty else { return }

        let pasteboard = UIPasteboard.general
        let currentChangeCount = pasteboard.changeCount

        if !forceRead, currentChangeCount == lastClipboardChangeCount {
            return
        }

        lastClipboardChangeCount = currentChangeCount

        guard let clipboardText = clipboardText(from: pasteboard) else {
            clipboardStatusMessage = "Clipboard is empty. Copy your Fantasy Points URL first."
            return
        }

        guard let parsedID = FantasyManagerIDParser.parse(from: clipboardText) else {
            clipboardStatusMessage = "No manager ID found yet. Make sure you copied the URL from the Points page."
            return
        }

        managerEntryID = parsedID
        clipboardStatusMessage = "Manager ID captured from clipboard."
        showSuccessInterstitial = true

        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation {
                showSuccessInterstitial = false
            }
        }
    }

    private func clipboardText(from pasteboard: UIPasteboard) -> String? {
        if let text = pasteboard.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }

        if let url = pasteboard.url?.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            return url
        }

        return nil
    }

    private func updateClipboardStatusMessage() {
        if managerEntryID.isEmpty, !hasInitiatedClipboardCapture {
            clipboardStatusMessage = "Waiting for Fantasy Football address..."
            return
        }

        if managerEntryID.isEmpty {
            clipboardStatusMessage = "Copy your Points URL, return to this screen, and tap \"Allow Paste\"."
        }
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

    private enum StorageKeys {
        static let managerEntryID = "fantasy.managerEntryID"
        static let rivalManagersJSON = "fantasy.rivalManagersJSON"
    }

    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
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
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
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

private struct FantasyLeagueTableEntry: Identifiable, Hashable {
    let entryID: Int
    let teamName: String
    let managerName: String
    let score: Int
    let squad: FantasySquadDisplayData?
    let isUser: Bool

    var id: Int {
        entryID
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
        showEstimatedFooter: Bool
    ) -> UIImage? {
        guard !rows.isEmpty else { return nil }

        let snapshot = FantasyLeagueShareSnapshotView(
            gameweekTitle: gameweekTitle,
            generatedAtText: generatedAtLabel(),
            rows: rows,
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
                        Text("League Table • \(gameweekTitle)")
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
                        Text("Pts")
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

                            Text("\(row.score)")
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
