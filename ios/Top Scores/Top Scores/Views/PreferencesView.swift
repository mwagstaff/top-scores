import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct PreferencesView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @StateObject private var viewModel = PreferencesViewModel()
    #if DEBUG
    @ObservedObject private var fixtureLoadDiagnostics = FixtureLoadDiagnosticsStore.shared
    #endif
    @State private var leagueSearch = ""
    @State private var channelSearch = ""
    @State private var notificationLeagueSearch = ""
    @State private var reloadTask: Task<Void, Never>?
    @State private var isSendingTestNotification = false
    @State private var testNotificationStatusMessage: String?
    @State private var testNotificationStatusIsError = false
    @State private var predictionDebugStatusMessage: String?
    @State private var deviceIDDebugStatusMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerView
                Form {

                    Section("Club games") {
                        Toggle("Premier League teams only", isOn: englishPremierLeagueTeamsOnlyBinding)
                        Text("Show club matches involving at least one English Premier League team.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Toggle("All major UEFA games", isOn: majorUEFAClubGamesEnabledBinding)
                        Text("Always show UEFA Champions League, Europa League, and Conference League quarter-finals, semi-finals, and finals, even when no Premier League team is involved.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Section("International games") {
                        Toggle("Home nations", isOn: homeNationsFilterEnabledBinding)
                        Text("Show international matches involving England, Northern Ireland, Scotland, or Wales, including friendlies.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Toggle("Major tournaments", isOn: majorTournamentsFilterEnabledBinding)
                        Text("Show FIFA World Cup and UEFA European Championship matches, excluding qualifying games.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Section("Display") {
                        Toggle("Show unfinished fixtures badge", isOn: showTodayUnfinishedFixturesBadgeBinding)
                        Text("Shows the number of today's fixtures that have not started or are still in play on the app icon.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Picker("Fixtures view", selection: fixturesViewDensityBinding) {
                            ForEach(FixturesViewDensity.allCases) { density in
                                Text(density.title).tag(density)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text("Extended shows the original two-row layout. Compact loosens the single-line layout slightly. Ultra compact matches the tighter previous setting.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if preferences.fixturesViewDensity != .extended {
                            Toggle("TV channel logo", isOn: showCompactFixtureTvLogoBinding)
                            Text("Shows the primary TV channel logo on the right side of compact fixture lozenges.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            Toggle("Fantasy football logo", isOn: showCompactFixtureFantasyLogoBinding)
                            Text("Shows the fantasy logo on the left side of compact fixture lozenges when your squad has one or more players involved in the match.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Competitions") {
                        Toggle("Enable competition filter", isOn: competitionFilterEnabledBinding)

                        if preferences.competitionFilterEnabled {
                            TextField("Search competitions", text: $leagueSearch)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                            if viewModel.isLoadingLeagues {
                                ProgressView("Loading competitions")
                            } else if viewModel.availableLeagues.isEmpty {
                                Text("No competitions loaded")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(filteredLeagues, id: \.self) { league in
                                    MultiSelectRow(
                                        title: league,
                                        isSelected: preferences.selectedLeagues.contains(league)
                                    ) {
                                        toggleLeague(league)
                                    }
                                }
                            }
                        } else {
                            Text("Competition filtering is off. Fixtures and results include all competitions.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Notifications") {
                        Toggle("Enable push notifications", isOn: notificationsEnabledBinding)
                        Text("Get notified of goals, red cards, kick-offs, half-time, and full-time for your selected matches.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Toggle("Premier League teams only", isOn: notificationPremierLeagueTeamsOnlyBinding)
                            .disabled(!preferences.notificationsEnabled)
                        Text("Only receive notifications for matches where at least one team is in the English Premier League.")
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

                        Section("Notification Competitions") {
                            Toggle("Use viewing competition preferences", isOn: notificationUseViewingFilterBinding)

                            if preferences.notificationUseViewingFilter {
                                Text("Notifications use the same competition filter as the viewing preferences.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                TextField("Search competitions", text: $notificationLeagueSearch)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()

                                if viewModel.isLoadingLeagues {
                                    ProgressView("Loading competitions")
                                } else if viewModel.availableLeagues.isEmpty {
                                    Text("No competitions loaded")
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(filteredNotificationLeagues, id: \.self) { league in
                                        MultiSelectRow(
                                            title: league,
                                            isSelected: preferences.notificationSelectedLeagues.contains(league)
                                        ) {
                                            toggleNotificationLeague(league)
                                        }
                                    }
                                }
                            }
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

                            Picker("Environment", selection: apiEnvironmentBinding) {
                                ForEach(APIEnvironment.allCases) { environment in
                                    Text(environment.title).tag(environment)
                                }
                            }
                            .pickerStyle(.segmented)

                            Text("Base URL: \(preferences.apiBaseURL)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Predictions")
                                .font(.subheadline)
                                .fontWeight(.semibold)

                            Toggle("Show prediction redo button", isOn: showPredictionRedoButtonBinding)

                            Button("Clear saved predictions", role: .destructive) {
                                FixturePredictionStore.clearAll()
                                predictionDebugStatusMessage = "Cleared all saved predictions."
                            }

                            if let predictionDebugStatusMessage {
                                Text(predictionDebugStatusMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            Text("Shows the \"Redo\" control for regenerating saved predictions. Off by default, even in debug builds.")
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
                .scrollContentBackground(.hidden)
                .background(Color(.systemGroupedBackground))
            }
            .background(Color(.systemGroupedBackground))
        }
        .task {
            await viewModel.reload(baseURL: preferences.apiBaseURL)
        }
        .onChange(of: preferences.apiBaseURL) { _, newValue in
            reloadTask?.cancel()
            reloadTask = Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                await viewModel.reload(baseURL: newValue)
            }
        }
    }

    private var headerView: some View {
        TopLevelScreenHeader(screenTitle: "Preferences") {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 24, weight: .semibold))
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
            set: { preferences.englishPremierLeagueTeamsOnly = $0 }
        )
    }

    private var homeNationsFilterEnabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.homeNationsFilterEnabled },
            set: { preferences.homeNationsFilterEnabled = $0 }
        )
    }

    private var majorUEFAClubGamesEnabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.majorUEFAClubGamesEnabled },
            set: { preferences.majorUEFAClubGamesEnabled = $0 }
        )
    }

    private var majorTournamentsFilterEnabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.majorTournamentsFilterEnabled },
            set: { preferences.majorTournamentsFilterEnabled = $0 }
        )
    }

    private var matchGroupSortOrderBinding: Binding<MatchGroupSortOrder> {
        Binding(
            get: { preferences.matchGroupSortOrder },
            set: { preferences.matchGroupSortOrder = $0 }
        )
    }

    private var showTodayUnfinishedFixturesBadgeBinding: Binding<Bool> {
        Binding(
            get: { preferences.showTodayUnfinishedFixturesBadge },
            set: { preferences.showTodayUnfinishedFixturesBadge = $0 }
        )
    }

    private var fixturesViewDensityBinding: Binding<FixturesViewDensity> {
        Binding(
            get: { preferences.fixturesViewDensity },
            set: { preferences.fixturesViewDensity = $0 }
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

    #if DEBUG
    private var showPredictionRedoButtonBinding: Binding<Bool> {
        Binding(
            get: { preferences.showPredictionRedoButton },
            set: { preferences.showPredictionRedoButton = $0 }
        )
    }
    #endif

    private var competitionFilterEnabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.competitionFilterEnabled },
            set: { preferences.competitionFilterEnabled = $0 }
        )
    }

    private var channelFilterEnabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.channelFilterEnabled },
            set: { preferences.channelFilterEnabled = $0 }
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

    private var notificationUseViewingFilterBinding: Binding<Bool> {
        Binding(
            get: { preferences.notificationUseViewingFilter },
            set: { newValue in
                if !newValue && preferences.notificationSelectedLeagues.isEmpty {
                    preferences.notificationSelectedLeagues = preferences.selectedLeagues
                }
                preferences.notificationUseViewingFilter = newValue
            }
        )
    }

    private var filteredNotificationLeagues: [String] {
        let trimmed = notificationLeagueSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return viewModel.availableLeagues }
        return viewModel.availableLeagues.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    private func toggleNotificationLeague(_ league: String) {
        if let index = preferences.notificationSelectedLeagues.firstIndex(of: league) {
            preferences.notificationSelectedLeagues.remove(at: index)
        } else {
            preferences.notificationSelectedLeagues.append(league)
            preferences.notificationSelectedLeagues.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
    }

    private var filteredLeagues: [String] {
        let trimmed = leagueSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return viewModel.availableLeagues }
        return viewModel.availableLeagues.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    private var filteredChannels: [String] {
        let trimmed = channelSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return viewModel.availableChannels }
        return viewModel.availableChannels.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    private func toggleLeague(_ league: String) {
        if let index = preferences.selectedLeagues.firstIndex(of: league) {
            preferences.selectedLeagues.remove(at: index)
        } else {
            preferences.selectedLeagues.append(league)
            preferences.selectedLeagues.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
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

#Preview {
    PreferencesView()
        .environmentObject(PreferencesStore())
}
