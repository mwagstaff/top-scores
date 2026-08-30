import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private enum FixturePreferenceMode: String, CaseIterable, Identifiable {
    case favourites
    case topTeams
    case all
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .favourites: return "Favourites"
        case .topTeams: return "Top teams"
        case .all: return "All"
        case .custom: return "Custom"
        }
    }
}

private enum NotificationCoverageMode: String, CaseIterable, Identifiable {
    case favourites
    case topTeams
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .favourites: return "Favourites"
        case .topTeams: return "Top teams"
        case .custom: return "Custom"
        }
    }
}

private struct ProfileFixtureRegion: Identifiable {
    let id: String
    let name: String
}

private struct NotificationTeamSelectionEditor: View {
    let apiBaseURL: String
    let onCommit: (Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draftTeamIDs: Set<String>

    init(
        apiBaseURL: String,
        selectedTeamIDs: Set<String>,
        onCommit: @escaping (Set<String>) -> Void
    ) {
        self.apiBaseURL = apiBaseURL
        self.onCommit = onCommit
        _draftTeamIDs = State(initialValue: selectedTeamIDs)
    }

    var body: some View {
        TeamSelectionView(
            apiBaseURL: apiBaseURL,
            selectedTeamIDs: $draftTeamIDs,
            onCancel: { dismiss() },
            onDone: {
                onCommit(draftTeamIDs)
                dismiss()
            }
        )
    }
}

struct PreferencesView: View {
    var embeddedInNavigation: Bool = false
    var showsOnlyAdvancedSettings: Bool = false

    @EnvironmentObject private var preferences: PreferencesStore
    @StateObject private var viewModel = PreferencesViewModel()
    @ObservedObject private var topTeamsPresetStore = TopTeamsPresetStore.shared
    #if DEBUG
    @ObservedObject private var fixtureLoadDiagnostics = FixtureLoadDiagnosticsStore.shared
    #endif
    @State private var leagueSearch = ""
    @State private var notificationLeagueSearch = ""
    @State private var channelSearch = ""
    @State private var reloadTask: Task<Void, Never>?
    @State private var isSendingTestNotification = false
    @State private var testNotificationStatusMessage: String?
    @State private var testNotificationStatusIsError = false
    @State private var predictionDebugStatusMessage: String?
    @State private var deviceIDDebugStatusMessage: String?
    @State private var isMajorTeamsExpanded = false

    var body: some View {
        Group {
            if embeddedInNavigation {
                styledContent
            } else {
                NavigationStack {
                    styledContent
                }
            }
        }
        .task {
            async let catalogs: Void = reloadVisibleCatalogs(baseURL: preferences.apiBaseURL)
            async let topTeams: Void = topTeamsPresetStore.ensureFresh(
                apiBaseURL: preferences.apiBaseURL
            )
            _ = await (catalogs, topTeams)
        }
        .onAppear {
            let openedAt = Date()
            let durationMs = Int(Date().timeIntervalSince(openedAt) * 1000)
            AppMetricsService.shared.fireScreenView(screen: "preferences", durationMs: durationMs, apiBaseURL: preferences.apiBaseURL)
        }
        .onChange(of: preferences.apiBaseURL) { _, newValue in
            reloadTask?.cancel()
            reloadTask = Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                await reloadVisibleCatalogs(baseURL: newValue)
            }
        }
    }

    private var styledContent: some View {
        FootballNavigationScreen(
            title: "Preferences",
            subtitle: showsOnlyAdvancedSettings ? "Advanced settings" : "Scores, notifications and display"
        ) {
            content
        }
    }

    private func reloadVisibleCatalogs(baseURL: String) async {
        await viewModel.reload(
            baseURL: baseURL,
            loadCompetitions: !showsOnlyAdvancedSettings,
            loadChannels: showsOnlyAdvancedSettings
        )
        if !showsOnlyAdvancedSettings {
            canonicalizeNotificationCompetitionSelection()
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Form {

                    if !showsOnlyAdvancedSettings {
                        Section("Fixtures") {
                            Picker("Fixture view", selection: fixturePreferenceModeBinding) {
                                ForEach(availableFixturePreferenceModes) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }

                            Text(fixturePreferenceModeDescription)
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            if [.favourites, .custom].contains(fixturePreferenceModeBinding.wrappedValue) {
                                fixtureViewOptionPicker(
                                    editingFavourites: fixturePreferenceModeBinding.wrappedValue == .favourites
                                )
                            }
                        }

                        if fixturePreferenceModeBinding.wrappedValue == .topTeams {
                            topTeamsInformationSection
                        }

                        Section("Notifications") {
                            Toggle("Same as fixtures", isOn: notificationMatchesFixturesBinding)
                            Text("Notify only for matches shown in your Fixtures view.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            if !preferences.notificationMatchesFixturesEnabled {
                                Picker("Match coverage", selection: notificationCoverageModeBinding) {
                                    ForEach(availableNotificationCoverageModes) { mode in
                                        Text(mode.title).tag(mode)
                                    }
                                }

                                if notificationCoverageModeBinding.wrappedValue == .custom {
                                    competitionPicker(
                                        search: $notificationLeagueSearch,
                                        selectionIsActive: notificationLeagueIsSelected,
                                        selectionChanged: toggleNotificationLeague
                                    )

                                    NavigationLink {
                                        NotificationTeamSelectionEditor(
                                            apiBaseURL: preferences.apiBaseURL,
                                            selectedTeamIDs: notificationTeamSelectionBinding.wrappedValue,
                                            onCommit: { teamIDs in
                                                notificationTeamSelectionBinding.wrappedValue = teamIDs
                                            }
                                        )
                                    } label: {
                                        LabeledContent("Teams") {
                                            Text(notificationTeamSelectionCountText)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }

                        Section {
                            NavigationLink("Advanced settings") {
                                PreferencesView(embeddedInNavigation: true, showsOnlyAdvancedSettings: true)
                            }
                        }
                    }

                    if showsOnlyAdvancedSettings {
                    Section("Display") {
                        Toggle("Show postponed games", isOn: showPostponedGamesBinding)
                        Text("When off, postponed matches are hidden from the Fixtures screen.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Toggle("App icon badge", isOn: showTodayUnfinishedFixturesBadgeBinding)
                        Text("Shows an app icon badge with the number of today's fixtures (either yet to kick off or in play).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Toggle("TV channel logo", isOn: showCompactFixtureTvLogoBinding)
                        Text("Shows the primary TV channel beneath the match time and alongside the prediction.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Toggle("Fantasy Premier League indicator", isOn: showCompactFixtureFantasyLogoBinding)
                        Text("Shows a purple chevron on fixture rows when your squad has one or more players involved in the match.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Toggle("Kick-off time dividers", isOn: showKickoffTimeDividersBinding)
                        Text("Shows kick-off time divider headings to easily distinguish different match kick-off times")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Toggle("Predicted scores", isOn: showPredictedScoresBinding)
                        Text("Shows a predicted scoreline on upcoming fixtures, and how it compared once the match finishes. Can also be toggled from the Fixtures screen.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Section("Notifications") {
                        Toggle("Enable push notifications", isOn: notificationsEnabledBinding)
                        Text("Get notified of goals, red cards, kick-offs, half-time, and full-time for your selected matches.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if preferences.notificationsEnabled {
                            Picker("Notification delay", selection: notificationDelayBinding) {
                                Text("No delay").tag(0)
                                Text("1 minute").tag(1)
                                Text("2 minutes").tag(2)
                                Text("3 minutes").tag(3)
                                Text("4 minutes").tag(4)
                                Text("5 minutes").tag(5)
                                Text("6 minutes").tag(6)
                                Text("7 minutes").tag(7)
                                Text("8 minutes").tag(8)
                                Text("9 minutes").tag(9)
                                Text("10 minutes").tag(10)
                            }
                            Text("Delay notifications when streaming to avoid spoilers.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if preferences.notificationsEnabled {
                        Section("Notification Events") {
                            NotificationEventToggle(label: "Goals", eventType: "goal", eventTypes: notificationEventTypesBinding)
                            NotificationEventToggle(label: "Kick offs", eventType: "kickoff", eventTypes: notificationEventTypesBinding)
                            NotificationEventToggle(label: "Half time", eventType: "halftime", eventTypes: notificationEventTypesBinding)
                            NotificationEventToggle(label: "Full time", eventType: "fulltime", eventTypes: notificationEventTypesBinding)
                            NotificationEventToggle(label: "Red cards", eventType: "redcard", eventTypes: notificationEventTypesBinding)
                        }

                    }

                    Section("Sorting") {
                        Picker("Match order", selection: matchGroupSortOrderBinding) {
                            ForEach(MatchGroupSortOrder.allCases) { sortOrder in
                                Text(sortOrder.title).tag(sortOrder)
                            }
                        }

                        Text("Kick-off based modes order competition groups by the first visible match. The other modes rank competition groups by combined team ranking scores.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Toggle("Show matches with Premier League teams first", isOn: premierLeagueMatchesFirstBinding)
                        Text("When enabled, fixtures involving Premier League teams are listed ahead of other matches within each competition group.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Section("Fantasy Premier League") {
                        Toggle("Show FPL logo in Fixtures", isOn: showFantasyFixtureLogosBinding)
                        Text("Displays the FPL logo against fixtures involving players from your connected team.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Toggle("Show xP in Fixtures", isOn: showFantasyExpectedPointsBinding)
                        Text("Shows expected points for your players on upcoming fixtures in the Fixtures screen.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Toggle("Show live points in Fixtures", isOn: showFantasyRealTimePointsBinding)
                        Text("Shows real-time points for your players while fixtures are in play.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Toggle("Deadline reminder push", isOn: fantasyDeadlineRemindersEnabledBinding)
                        Text("Sends one push reminder 24 hours before the next Fantasy Premier League deadline when your fantasy team is connected.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Section("Channels") {
                        Toggle("Enable TV channel filter", isOn: channelFilterEnabledBinding)
                        Text("Show only fixtures on your preferred TV channels.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if preferences.channelFilterEnabled {
                            TextField("Search channels", text: $channelSearch)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                            if viewModel.isLoadingChannels {
                                ProgressView("Loading channels")
                            } else if viewModel.availableChannels.isEmpty {
                                Text("No channels loaded")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(filteredChannels, id: \.self) { channel in
                                    MultiSelectRow(
                                        title: channel,
                                        isSelected: preferences.selectedChannels.contains(channel)
                                    ) {
                                        toggleChannel(channel)
                                    }
                                }
                            }
                        } else {
                            Text("TV channel filtering is off. Showing matches for all channels.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let error = viewModel.errorMessage {
                        Section {
                            Text(error)
                                .foregroundStyle(.red)
                        }
                    }

                    Section {
                        Button("Clear selections", role: .destructive) {
                            preferences.selectedLeagues = []
                            preferences.selectedFixtureViewOptionIDs = []
                            preferences.selectedNotificationLeagues = []
                            preferences.selectedNotificationViewOptionIDs = []
                            preferences.selectedChannels = []
                        }
                    }

                    #if DEBUG
                    Section("Debug") {
                        Text("These settings are available in debug builds only and will not appear in production.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Device Identity")
                                .font(.subheadline)
                                .fontWeight(.semibold)

                            Text("Use this ID in the Live Activity server harness to target this device.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            Text(DeviceIdentity.currentToken)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)

                            Button("Copy device ID") {
                                copyDebugDeviceID()
                            }

                            if let deviceIDDebugStatusMessage {
                                Text(deviceIDDebugStatusMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("API")
                                .font(.subheadline)
                                .fontWeight(.semibold)

                            FootballPitchSegmentedControl(
                                selection: apiEnvironmentBinding,
                                options: [
                                    FootballPitchSegmentOption(
                                        value: APIEnvironment.production,
                                        title: "Production",
                                        subtitle: "Live service",
                                        systemImage: "server.rack"
                                    ),
                                    FootballPitchSegmentOption(
                                        value: APIEnvironment.development,
                                        title: "Development",
                                        subtitle: "Development service",
                                        systemImage: "hammer.fill"
                                    ),
                                ],
                                accessibilityLabel: "API environment",
                                minimumHeight: 68
                            )

                            Text("Base URL: \(preferences.apiBaseURL)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Predictions")
                                .font(.subheadline)
                                .fontWeight(.semibold)

                            Button("Clear saved predictions", role: .destructive) {
                                FixturePredictionStore.clearAll()
                                predictionDebugStatusMessage = "Cleared all saved predictions."
                            }

                            if let predictionDebugStatusMessage {
                                Text(predictionDebugStatusMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            Text("Predictions are frozen once computed so they stay comparable to the eventual result. Clearing removes all saved predictions from this device.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Push Notifications")
                                .font(.subheadline)
                                .fontWeight(.semibold)

                            Button(isSendingTestNotification ? "Sending test notification..." : "Send test notification") {
                                sendDebugTestNotification()
                            }
                            .disabled(isSendingTestNotification)

                            if let message = testNotificationStatusMessage {
                                Text(message)
                                    .font(.footnote)
                                    .foregroundStyle(testNotificationStatusIsError ? .red : .secondary)
                            }
                        }
                        .padding(.vertical, 4)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Fixture logs")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Spacer()
                                Button("Clear") {
                                    fixtureLoadDiagnostics.clear()
                                }
                                .font(.footnote)
                            }

                            Text("Shows the initial fixture load and lazy backfill timings for the Fixtures screen.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            if fixtureLoadDiagnostics.entries.isEmpty {
                                Text("No fixture load logs yet.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(fixtureLoadDiagnostics.entries) { entry in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("\(debugTimestampFormatter.string(from: entry.recordedAt))  \(entry.title)")
                                            .font(.footnote.monospaced())
                                            .fontWeight(.semibold)
                                        Text(entry.summary)
                                            .font(.footnote.monospaced())
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    #endif
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .tint(Color.accentColor)
            }
            .background(Color.clear)
        }
    }

    @ViewBuilder
    private func competitionPicker(
        search: Binding<String>,
        selectionIsActive: @escaping (String) -> Bool,
        selectionChanged: @escaping (String) -> Void
    ) -> some View {
        TextField("Search competitions", text: search)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

        if viewModel.isLoadingLeagues {
            ProgressView("Loading competitions")
        } else if viewModel.availableLeagues.isEmpty {
            Text("No competitions loaded")
                .foregroundStyle(.secondary)
        } else {
            ForEach(filteredLeagues(matching: search.wrappedValue), id: \.self) { league in
                MultiSelectRow(
                    title: league,
                    isSelected: selectionIsActive(league),
                    action: { selectionChanged(league) }
                )
            }
        }
    }

    @ViewBuilder
    private func fixtureViewOptionPicker(editingFavourites: Bool) -> some View {
        TextField("Search competitions", text: $leagueSearch)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

        if viewModel.isLoadingLeagues {
            ProgressView("Loading competitions")
        } else {
            ForEach(profileFixtureRegions, id: \.id) { region in
                let specialOptions = FixtureViewSpecialOption.options(in: region.id)
                    .filter { fixtureOptionMatchesSearch($0.title) || fixtureOptionMatchesSearch($0.subtitle) }
                let competitions = filteredFixtureCompetitions(in: region.id)
                if !specialOptions.isEmpty || !competitions.isEmpty {
                    DisclosureGroup(region.name) {
                        ForEach(specialOptions) { option in
                            FixturePreferenceOptionRow(
                                title: option.title,
                                subtitle: option.subtitle,
                                isSelected: fixtureViewOptionIsSelected(
                                    option.id,
                                    editingFavourites: editingFavourites
                                ),
                                action: {
                                    toggleFixtureViewOption(
                                        option.id,
                                        editingFavourites: editingFavourites
                                    )
                                }
                            )
                        }

                        if !specialOptions.isEmpty && !competitions.isEmpty {
                            Divider()
                        }

                        ForEach(competitions, id: \.stableID) { competition in
                            let optionID = FixtureViewOptionID.competition(competition.stableID)
                            FixturePreferenceOptionRow(
                                title: competition.name,
                                subtitle: "Competition",
                                isSelected: fixtureViewOptionIsSelected(
                                    optionID,
                                    editingFavourites: editingFavourites
                                ),
                                action: {
                                    toggleFixtureViewOption(
                                        optionID,
                                        editingFavourites: editingFavourites
                                    )
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    #if DEBUG
    private var debugTimestampFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }
    #endif

    private var refreshIntervalBinding: Binding<Int> {
        Binding(
            get: { preferences.refreshIntervalMinutes },
            set: { preferences.refreshIntervalMinutes = $0 }
        )
    }

    private var englishPremierLeagueTeamsOnlyBinding: Binding<Bool> {
        Binding(
            get: { preferences.englishPremierLeagueTeamsOnly },
            set: {
                preferences.englishPremierLeagueTeamsOnly = $0
                AppMetricsService.shared.fireActivity("pref_epl_only_toggle", screen: "preferences", apiBaseURL: preferences.apiBaseURL)
            }
        )
    }

    private var homeNationsFilterEnabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.homeNationsFilterEnabled },
            set: {
                preferences.homeNationsFilterEnabled = $0
                AppMetricsService.shared.fireActivity("pref_home_nations_toggle", screen: "preferences", apiBaseURL: preferences.apiBaseURL)
            }
        )
    }

    private var majorUEFAClubGamesEnabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.majorUEFAClubGamesEnabled },
            set: {
                preferences.majorUEFAClubGamesEnabled = $0
                AppMetricsService.shared.fireActivity("pref_major_uefa_toggle", screen: "preferences", apiBaseURL: preferences.apiBaseURL)
            }
        )
    }

    private var majorTournamentsFilterEnabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.majorTournamentsFilterEnabled },
            set: {
                preferences.majorTournamentsFilterEnabled = $0
                AppMetricsService.shared.fireActivity("pref_major_tournaments_toggle", screen: "preferences", apiBaseURL: preferences.apiBaseURL)
            }
        )
    }

    private var matchGroupSortOrderBinding: Binding<MatchGroupSortOrder> {
        Binding(
            get: { preferences.matchGroupSortOrder },
            set: { preferences.matchGroupSortOrder = $0 }
        )
    }

    private var premierLeagueMatchesFirstBinding: Binding<Bool> {
        Binding(
            get: { preferences.premierLeagueMatchesFirst },
            set: { preferences.premierLeagueMatchesFirst = $0 }
        )
    }

    private var showPostponedGamesBinding: Binding<Bool> {
        Binding(
            get: { preferences.showPostponedGames },
            set: { preferences.showPostponedGames = $0 }
        )
    }

    private var showTodayUnfinishedFixturesBadgeBinding: Binding<Bool> {
        Binding(
            get: { preferences.showTodayUnfinishedFixturesBadge },
            set: { preferences.showTodayUnfinishedFixturesBadge = $0 }
        )
    }

    private var showCompactFixtureTvLogoBinding: Binding<Bool> {
        Binding(
            get: { preferences.showCompactFixtureTvLogo },
            set: { preferences.showCompactFixtureTvLogo = $0 }
        )
    }

    private var showCompactFixtureFantasyLogoBinding: Binding<Bool> {
        Binding(
            get: { preferences.showCompactFixtureFantasyLogo },
            set: { preferences.showCompactFixtureFantasyLogo = $0 }
        )
    }

    private var showPredictedScoresBinding: Binding<Bool> {
        Binding(
            get: { preferences.showPredictedScores },
            set: { preferences.showPredictedScores = $0 }
        )
    }

    private var showKickoffTimeDividersBinding: Binding<Bool> {
        Binding(
            get: { preferences.showKickoffTimeDividers },
            set: { preferences.showKickoffTimeDividers = $0 }
        )
    }

    private var showFantasyFixtureLogosBinding: Binding<Bool> {
        Binding(
            get: { preferences.showFantasyFixtureLogos },
            set: { preferences.showFantasyFixtureLogos = $0 }
        )
    }

    private var showFantasyExpectedPointsBinding: Binding<Bool> {
        Binding(
            get: { preferences.showFantasyExpectedPoints },
            set: { preferences.showFantasyExpectedPoints = $0 }
        )
    }

    private var showFantasyRealTimePointsBinding: Binding<Bool> {
        Binding(
            get: { preferences.showFantasyRealTimePoints },
            set: { preferences.showFantasyRealTimePoints = $0 }
        )
    }

    private var fantasyDeadlineRemindersEnabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.fantasyDeadlineRemindersEnabled },
            set: { preferences.fantasyDeadlineRemindersEnabled = $0 }
        )
    }

    private var competitionFilterEnabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.competitionFilterEnabled },
            set: {
                preferences.competitionFilterEnabled = $0
                AppMetricsService.shared.fireActivity("pref_competition_filter_toggle", screen: "preferences", apiBaseURL: preferences.apiBaseURL)
            }
        )
    }

    private var topTeamsInformationSection: some View {
        let preset = topTeamsPresetStore.preset
        return Section("Top teams includes") {
            ForEach(Array(preset.displaySections.enumerated()), id: \.offset) { _, description in
                Label(description, systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
            }

            DisclosureGroup(isExpanded: $isMajorTeamsExpanded) {
                ForEach(preset.majorTeams) { team in
                    HStack(spacing: 10) {
                        MajorTeamLogo(team: team)
                        Text(team.name)
                        Spacer()
                        if let elo = team.elo {
                            Text(String(Int(elo.rounded())))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .accessibilityLabel("Club Elo \(Int(elo.rounded()))")
                        }
                    }
                }
            } label: {
                Text("Major teams (\(preset.majorTeams.count))")
            }

            LabeledContent("Club Elo threshold") {
                Text(String(Int(preset.clubEloThreshold.rounded())))
                    .monospacedDigit()
            }

            if topTeamsPresetStore.isRefreshing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Updating server-defined team list…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var fixturePreferenceModeBinding: Binding<FixturePreferenceMode> {
        Binding(
            get: {
                if preferences.showAllMatches { return .all }
                if Set(preferences.selectedFixtureViewOptionIDs) == Set([FixtureViewOptionID.topTeamsPreset]),
                   !preferences.fixtureAllMajorMatchesEnabled {
                    return .topTeams
                }
                return preferences.fixtureAllMajorMatchesEnabled && preferences.hasSavedFavouriteFixtureView
                    ? .favourites
                    : .custom
            },
            set: { mode in
                preferences.fixtureAllMajorMatchesEnabled = mode == .favourites
                preferences.showAllMatches = mode == .all
                preferences.competitionFilterEnabled = mode == .custom || mode == .topTeams
                if mode == .topTeams {
                    preferences.selectedFixtureViewOptionIDs = [FixtureViewOptionID.topTeamsPreset]
                }
                if mode == .custom,
                   preferences.selectedFixtureViewOptionIDs.isEmpty ||
                    Set(preferences.selectedFixtureViewOptionIDs) == Set([FixtureViewOptionID.topTeamsPreset]) {
                    preferences.selectedFixtureViewOptionIDs = preferences.hasSavedFavouriteFixtureView
                        ? preferences.favouriteFixtureViewOptionIDs.filter { $0 != FixtureViewOptionID.all }
                        : []
                }
                AppMetricsService.shared.fireActivity("pref_fixtures_all_major_matches_toggle", screen: "preferences", apiBaseURL: preferences.apiBaseURL)
            }
        )
    }

    private var availableFixturePreferenceModes: [FixturePreferenceMode] {
        FixturePreferenceMode.allCases.filter {
            $0 != .favourites || preferences.hasSavedFavouriteFixtureView
        }
    }

    private var fixturePreferenceModeDescription: String {
        switch fixturePreferenceModeBinding.wrappedValue {
        case .favourites:
            return "Edit the saved leagues, teams and rivalry fixtures shown in Favourites."
        case .topTeams:
            return "Show featured clubs, home internationals and selected European matches."
        case .all:
            return "Show fixtures from every available competition."
        case .custom:
            return "Choose a temporary mix of leagues, teams and rivalry fixtures."
        }
    }

    private var notificationCoverageModeBinding: Binding<NotificationCoverageMode> {
        Binding(
            get: {
                if preferences.notificationAllMajorMatchesEnabled,
                   preferences.hasSavedFavouriteFixtureView {
                    return .favourites
                }
                if Set(preferences.selectedNotificationViewOptionIDs) == Set([FixtureViewOptionID.topTeamsPreset]) {
                    return .topTeams
                }
                return .custom
            },
            set: { mode in
                let usesFavourites = mode == .favourites
                preferences.notificationAllMajorMatchesEnabled = usesFavourites
                preferences.notificationPremierLeagueTeamsOnly = usesFavourites
                preferences.notificationMajorUEFAClubGamesEnabled = usesFavourites
                preferences.notificationHomeNationsFilterEnabled = usesFavourites
                preferences.notificationMajorTournamentsFilterEnabled = usesFavourites
                if mode == .topTeams {
                    preferences.selectedNotificationViewOptionIDs = [FixtureViewOptionID.topTeamsPreset]
                } else if mode == .custom,
                          Set(preferences.selectedNotificationViewOptionIDs) == Set([FixtureViewOptionID.topTeamsPreset]) {
                    preferences.selectedNotificationViewOptionIDs = []
                }
                AppMetricsService.shared.fireActivity("pref_notifications_all_major_matches_toggle", screen: "preferences", apiBaseURL: preferences.apiBaseURL)
            }
        )
    }

    private var availableNotificationCoverageModes: [NotificationCoverageMode] {
        NotificationCoverageMode.allCases.filter {
            $0 != .favourites || preferences.hasSavedFavouriteFixtureView
        }
    }

    private var notificationMatchesFixturesBinding: Binding<Bool> {
        Binding(
            get: { preferences.notificationMatchesFixturesEnabled },
            set: { enabled in
                preferences.notificationMatchesFixturesEnabled = enabled
                AppMetricsService.shared.fireActivity("pref_notifications_same_as_fixtures_toggle", screen: "preferences", apiBaseURL: preferences.apiBaseURL)
            }
        )
    }

    private var channelFilterEnabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.channelFilterEnabled },
            set: {
                preferences.channelFilterEnabled = $0
                AppMetricsService.shared.fireActivity("pref_channel_filter_toggle", screen: "preferences", apiBaseURL: preferences.apiBaseURL)
            }
        )
    }

    private var notificationsEnabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.notificationsEnabled },
            set: { newValue in
                if newValue {
                    // Request notification permission when enabling
                    Task {
                        await NotificationManager.shared.requestAuthorization()
                        // Only enable if permission was granted
                        let status = NotificationManager.shared.authorizationStatus
                        preferences.notificationsEnabled = (status == .authorized)
                    }
                } else {
                    preferences.notificationsEnabled = false
                }
            }
        )
    }

    private var notificationDelayBinding: Binding<Int> {
        Binding(
            get: { preferences.notificationDelayMinutes },
            set: { preferences.notificationDelayMinutes = $0 }
        )
    }

    private var notificationEventTypesBinding: Binding<Set<String>> {
        Binding(
            get: { preferences.notificationEventTypes },
            set: { preferences.notificationEventTypes = $0 }
        )
    }

    private var notificationPremierLeagueTeamsOnlyBinding: Binding<Bool> {
        Binding(
            get: { preferences.notificationPremierLeagueTeamsOnly },
            set: { preferences.notificationPremierLeagueTeamsOnly = $0 }
        )
    }

    private var notificationMajorUEFAClubGamesEnabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.notificationMajorUEFAClubGamesEnabled },
            set: { preferences.notificationMajorUEFAClubGamesEnabled = $0 }
        )
    }

    private var notificationHomeNationsFilterEnabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.notificationHomeNationsFilterEnabled },
            set: { preferences.notificationHomeNationsFilterEnabled = $0 }
        )
    }

    private var notificationMajorTournamentsFilterEnabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.notificationMajorTournamentsFilterEnabled },
            set: { preferences.notificationMajorTournamentsFilterEnabled = $0 }
        )
    }

    private func filteredLeagues(matching search: String) -> [String] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let leagues = viewModel.availableLeagues
        guard !trimmed.isEmpty else { return leagues }
        return leagues.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    private var profileFixtureRegions: [ProfileFixtureRegion] {
        [
            .init(id: "england", name: "England"),
            .init(id: "scotland", name: "Scotland"),
            .init(id: "germany", name: "Germany"),
            .init(id: "spain", name: "Spain"),
            .init(id: "italy", name: "Italy"),
            .init(id: "france", name: "France"),
            .init(id: "europe", name: "Europe"),
            .init(id: "world", name: "World"),
        ]
    }

    private func fixtureOptionMatchesSearch(_ value: String) -> Bool {
        let trimmed = leagueSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || value.localizedCaseInsensitiveContains(trimmed)
    }

    private func filteredFixtureCompetitions(in regionID: String) -> [CompetitionCatalogEntry] {
        viewModel.competitionCatalog
            .filter { ($0.region ?? "").lowercased() == regionID && fixtureOptionMatchesSearch($0.name) }
            .sorted { left, right in
                if left.weight != right.weight { return left.weight > right.weight }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }

    private func fixtureViewOptionIsSelected(
        _ optionID: String,
        editingFavourites: Bool
    ) -> Bool {
        let optionIDs = editingFavourites
            ? preferences.favouriteFixtureViewOptionIDs
            : preferences.selectedFixtureViewOptionIDs
        return optionIDs.contains(optionID)
    }

    private func toggleFixtureViewOption(
        _ optionID: String,
        editingFavourites: Bool
    ) {
        let optionIDs = Set(
            editingFavourites
                ? preferences.favouriteFixtureViewOptionIDs
                : preferences.selectedFixtureViewOptionIDs
        )
        let updatedOptionIDs = FixtureViewOptionID.toggling(optionID, in: optionIDs)
        guard !updatedOptionIDs.isEmpty else { return }

        if editingFavourites {
            preferences.favouriteFixtureViewOptionIDs = updatedOptionIDs.sorted()
        } else {
            preferences.selectedFixtureViewOptionIDs = updatedOptionIDs.sorted()
            let competitionIDs = Set(updatedOptionIDs.compactMap(FixtureViewOptionID.competitionStableID))
            preferences.selectedLeagues = viewModel.competitionCatalog
                .filter { competitionIDs.contains($0.stableID) }
                .map(\.name)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
    }

    private var filteredChannels: [String] {
        let trimmed = channelSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return viewModel.availableChannels }
        return viewModel.availableChannels.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    private func toggleNotificationLeague(_ league: String) {
        preferences.selectedNotificationViewOptionIDs = NotificationCompetitionSelection.toggling(
            leagueName: league,
            optionIDs: preferences.selectedNotificationViewOptionIDs,
            catalog: viewModel.competitionCatalog
        )
        canonicalizeNotificationCompetitionSelection()
    }

    private func notificationLeagueIsSelected(_ league: String) -> Bool {
        NotificationCompetitionSelection.isSelected(
            leagueName: league,
            optionIDs: preferences.selectedNotificationViewOptionIDs,
            catalog: viewModel.competitionCatalog
        )
    }

    private func canonicalizeNotificationCompetitionSelection() {
        let canonicalOptionIDs = NotificationCompetitionSelection.canonicalOptionIDs(
            optionIDs: preferences.selectedNotificationViewOptionIDs,
            existingLeagueNames: preferences.selectedNotificationLeagues,
            catalog: viewModel.competitionCatalog
        )
        if canonicalOptionIDs != preferences.selectedNotificationViewOptionIDs {
            preferences.selectedNotificationViewOptionIDs = canonicalOptionIDs
        }
        let canonicalNames = NotificationCompetitionSelection.canonicalLeagueNames(
            optionIDs: canonicalOptionIDs,
            existingLeagueNames: preferences.selectedNotificationLeagues,
            catalog: viewModel.competitionCatalog
        )
        if canonicalNames != preferences.selectedNotificationLeagues {
            preferences.selectedNotificationLeagues = canonicalNames
        }
    }

    private var notificationTeamSelectionBinding: Binding<Set<String>> {
        Binding(
            get: {
                Set(preferences.selectedNotificationViewOptionIDs.compactMap(FixtureViewOptionID.teamStableID))
            },
            set: { teamIDs in
                let nonTeamIDs = preferences.selectedNotificationViewOptionIDs.filter {
                    FixtureViewOptionID.teamStableID(from: $0) == nil
                }
                preferences.selectedNotificationViewOptionIDs = (
                    nonTeamIDs + teamIDs.map(FixtureViewOptionID.team)
                ).sorted()
            }
        )
    }

    private var notificationTeamSelectionCountText: String {
        let count = notificationTeamSelectionBinding.wrappedValue.count
        return count == 1 ? "1 selected" : "\(count) selected"
    }

    private func toggleChannel(_ channel: String) {
        if let index = preferences.selectedChannels.firstIndex(of: channel) {
            preferences.selectedChannels.remove(at: index)
        } else {
            preferences.selectedChannels.append(channel)
            preferences.selectedChannels = ChannelSelection.normalizedSelectedOptions(preferences.selectedChannels)
        }
    }

    #if DEBUG
    private func sendDebugTestNotification() {
        isSendingTestNotification = true
        testNotificationStatusMessage = nil
        testNotificationStatusIsError = false

        Task { @MainActor in
            do {
                let result = try await NotificationManager.shared.sendTestNotification(
                    apiBaseURL: preferences.apiBaseURL
                )
                let environment = result.environment ?? "unknown"
                testNotificationStatusMessage =
                    "APNs accepted test send (env: \(environment)). Delivery may take a few seconds."
                testNotificationStatusIsError = false
            } catch {
                testNotificationStatusMessage = error.localizedDescription
                testNotificationStatusIsError = true
            }
            isSendingTestNotification = false
        }
    }

    private func copyDebugDeviceID() {
        UIPasteboard.general.string = DeviceIdentity.currentToken
        deviceIDDebugStatusMessage = "Copied device ID for the Live Activity harness."
    }
    #endif

    #if DEBUG
    private enum APIEnvironment: String, CaseIterable, Identifiable {
        case production
        case development

        var id: String { rawValue }

        var title: String {
            switch self {
            case .production:
                return "Production"
            case .development:
                return "Development"
            }
        }

        var baseURL: String {
            switch self {
            case .production:
                return PreferencesStore.productionApiBaseURL
            case .development:
                return PreferencesStore.developmentApiBaseURL
            }
        }

        static func from(baseURL: String) -> APIEnvironment {
            switch baseURL {
            case PreferencesStore.developmentApiBaseURL:
                return .development
            default:
                return .production
            }
        }
    }

    private var apiEnvironmentBinding: Binding<APIEnvironment> {
        Binding(
            get: { APIEnvironment.from(baseURL: preferences.apiBaseURL) },
            set: { preferences.apiBaseURL = $0.baseURL }
        )
    }
    #endif
}

private struct FixturePreferenceOptionRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(isSelected ? Color.accentColor : Color.secondary, lineWidth: 1.25)
                    }
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

private struct MultiSelectRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
        }
    }
}

private struct NotificationEventToggle: View {
    let label: String
    let eventType: String
    @Binding var eventTypes: Set<String>

    var body: some View {
        Toggle(label, isOn: Binding(
            get: { eventTypes.contains(eventType) },
            set: { enabled in
                if enabled {
                    eventTypes.insert(eventType)
                } else {
                    eventTypes.remove(eventType)
                }
            }
        ))
    }
}

private struct MajorTeamLogo: View {
    let team: TopTeamsPresetTeam

    var body: some View {
        Group {
            if let image = LogoResolver.shared.image(
                for: team.name,
                alternateNames: team.aliases
            ) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "shield.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}

#Preview {
    PreferencesView()
        .environmentObject(PreferencesStore())
}
