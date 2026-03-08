import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @StateObject private var viewModel = PreferencesViewModel()
    @State private var leagueSearch = ""
    @State private var channelSearch = ""
    @State private var notificationLeagueSearch = ""
    @State private var reloadTask: Task<Void, Never>?
    @State private var isSendingTestNotification = false
    @State private var testNotificationStatusMessage: String?
    @State private var testNotificationStatusIsError = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Refresh") {
                    Stepper(value: refreshIntervalBinding, in: 1...60) {
                        Text("Refresh every \(preferences.refreshIntervalMinutes) min")
                    }
                    Text("Controls automatic in-app and scheduled background refreshes. During live matches, in-app updates can run as often as every 30 seconds.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Sorting") {
                    Picker("Match order", selection: matchGroupSortOrderBinding) {
                        ForEach(MatchGroupSortOrder.allCases) { sortOrder in
                            Text(sortOrder.title).tag(sortOrder)
                        }
                    }

                    Text("Kick-off based modes order competition groups by the first visible match. The other modes rank competition groups by combined team Elo.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Filters") {
                    Toggle("Premier League teams only", isOn: englishPremierLeagueTeamsOnlyBinding)
                    Text("Show only matches where at least one team is in the BBC Premier League table.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Fantasy Football") {
                    Toggle("Show Fantasy match pills", isOn: showFantasyMatchPillsBinding)
                    Text("Displays the Fantasy trophy icon before kick-off once line-ups are available, then shows total estimated points for the players involved while matches are in play.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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

                Section("Channels") {
                    Toggle("Enable TV channel filter", isOn: channelFilterEnabledBinding)
                    Text("TV channel filtering applies to Fixtures only.")
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
                        Text("TV channel filtering is off. Fixtures include all channels.")
                            .foregroundStyle(.secondary)
                    }
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
                }
                #endif
            }
            .navigationTitle("Preferences")
            .toolbarTitleDisplayMode(.inline)
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

    private var matchGroupSortOrderBinding: Binding<MatchGroupSortOrder> {
        Binding(
            get: { preferences.matchGroupSortOrder },
            set: { preferences.matchGroupSortOrder = $0 }
        )
    }

    private var showFantasyMatchPillsBinding: Binding<Bool> {
        Binding(
            get: { preferences.showFantasyMatchPills },
            set: { preferences.showFantasyMatchPills = $0 }
        )
    }

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
