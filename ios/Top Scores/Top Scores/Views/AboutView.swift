import SwiftUI
#if DEBUG
import UserNotifications
#endif

struct AboutView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    #if DEBUG
    @EnvironmentObject private var fantasyViewModel: FantasyViewModel
    @AppStorage(AppGroupConfig.fantasyManagerEntryIDKey) private var fantasyManagerEntryID = ""
    @State private var diagnostics = DebugDiagnosticsState()
    @State private var isLoadingDiagnostics = false
    @State private var isLoadingHarnessMatches = false
    #endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerView
                List {
                    Section("Version") {
                        Text("\(appVersion)")
                            .foregroundStyle(.secondary)
                    }

                    Section("Developer") {
                        Text("Developed by Mike Wagstaff")
                        Link(destination: URL(string: "https://skynolimit.dev")!) {
                            Label("Sky No Limit", systemImage: "globe")
                        }
                    }

                    Section("Feedback") {
                        Link(destination: feedbackMailURL) {
                            Label("Email Feedback", systemImage: "envelope")
                        }
                    }

                    Section("Data sources") {
                        Link(destination: URL(string: "https://www.bbc.co.uk/sport/football")!) {
                            Label("BBC Sport", systemImage: "tv")
                        }
                        Link(destination: URL(string: "http://clubelo.com")!) {
                            Label("ClubElo", systemImage: "chart.bar.xaxis")
                        }
                        Link(destination: URL(string: "https://www.eloratings.net")!) {
                            Label("World Football Elo Ratings", systemImage: "chart.bar.xaxis")
                        }
                    }

                    #if DEBUG
                    Section {
                        if isLoadingDiagnostics {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Refreshing diagnostics...")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        diagnosticsRow(title: "Device token", value: diagnostics.deviceToken)
                        diagnosticsRow(title: "Server device token", value: diagnostics.serverDeviceToken ?? "Unknown")
                        diagnosticsRow(title: "Local APNS token", value: diagnostics.localAPNSToken ?? "None")
                        diagnosticsRow(title: "Server APNS token", value: diagnostics.serverAPNSToken ?? "None")
                        diagnosticsRow(title: "Token match", value: diagnostics.tokenMatch)
                        diagnosticsRow(title: "Push auth status", value: diagnostics.pushAuthStatus)
                        diagnosticsRow(title: "Build environment", value: diagnostics.localBuildEnvironment)
                        diagnosticsRow(title: "Server build environment", value: diagnostics.serverBuildEnvironment)
                        diagnosticsRow(title: "API base URL", value: preferences.apiBaseURL)
                        diagnosticsRow(title: "Last sync attempt", value: diagnostics.lastSyncAttempt)
                        diagnosticsRow(title: "Last sync success", value: diagnostics.lastSyncSuccess)
                        diagnosticsRow(title: "Last sync failure", value: diagnostics.lastSyncFailure)
                        diagnosticsRow(
                            title: "Last sync HTTP status",
                            value: diagnostics.lastSyncHTTPStatus.map(String.init) ?? "N/A"
                        )
                        diagnosticsRow(title: "Last sync failure reason", value: diagnostics.lastSyncFailureReason ?? "None")
                        diagnosticsRow(title: "Server record updated at", value: diagnostics.serverRecordUpdatedAt ?? "Unknown")

                        HStack {
                            Button("Refresh diagnostics") {
                                Task { await refreshDiagnostics() }
                            }
                            Spacer()
                            Button("Sync preferences now") {
                                Task {
                                    await PreferencesSyncService.shared.syncPreferences(preferences.snapshot)
                                    await refreshDiagnostics()
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Debug Diagnostics")
                            Spacer()
                            Text("DEBUG")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }
                    }

                    Section {
                        if fantasyManagerEntryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Link a Fantasy Premier League account first to generate harness matches with your current squad.")
                                .foregroundStyle(.secondary)
                        } else if isLoadingHarnessMatches {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Generating fantasy harness matches...")
                                    .foregroundStyle(.secondary)
                            }
                        } else if debugHarnessMatches.isEmpty {
                            Text("Load your Fantasy squad to generate synthetic Premier League match-detail screens for lineup testing.")
                                .foregroundStyle(.secondary)

                            Button("Generate harness matches") {
                                Task { await loadHarnessMatches() }
                            }
                        } else {
                            Button("Refresh harness matches") {
                                Task { await loadHarnessMatches() }
                            }

                            NavigationLink {
                                DebugFantasyHarnessMatchesView(matches: debugHarnessMatches)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Open fixtures-style harness")
                                        .font(.body.weight(.semibold))
                                    Text("Shows synthetic Premier League fixtures using the same match lozenges as the Fixtures screen.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }

                            ForEach(debugHarnessMatches) { harnessMatch in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(harnessMatch.title)
                                        .font(.footnote.weight(.semibold))
                                    Text(harnessMatch.subtitle)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 1)
                            }
                        }
                    } header: {
                        HStack {
                            Text("Match Details Harness")
                            Spacer()
                            Text("DEBUG")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }
                    }
                    #endif
                }
                .scrollContentBackground(.hidden)
                .background(Color(.systemGroupedBackground))
            }
            #if DEBUG
            .task {
                await refreshDiagnostics()
            }
            #endif
        }
    }

    private var headerView: some View {
        TopLevelScreenHeader(screenTitle: "About") {
            Image(systemName: "info.circle")
                .font(.system(size: 24, weight: .semibold))
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    private var feedbackMailURL: URL {
        let subject = "Top Scores feedback [\(DeviceIdentity.currentToken)]"
        let encoded = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
        return URL(string: "mailto:mike.wagstaff@gmail.com?subject=\(encoded)") ?? URL(string: "mailto:mike.wagstaff@gmail.com")!
    }

    #if DEBUG
    private func diagnosticsRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospaced())
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func refreshDiagnostics() async {
        isLoadingDiagnostics = true
        await NotificationManager.shared.checkAuthorizationStatus()

        let localAPNSToken = NotificationManager.shared.currentAPNSToken
        let pushStatus = displayAuthorizationStatus(NotificationManager.shared.authorizationStatus)
        let localBuild = NotificationManager.shared.isDevelopmentBuild ? "Development (sandbox APNS)" : "Production (live APNS)"
        let syncDiagnostics = await PreferencesSyncService.shared.diagnostics()
        let serverDiagnostics = await fetchServerDiagnostics(
            baseURL: preferences.apiBaseURL,
            deviceToken: DeviceIdentity.currentToken
        )

        diagnostics = DebugDiagnosticsState(
            deviceToken: DeviceIdentity.currentToken,
            serverDeviceToken: serverDiagnostics?.deviceToken,
            localAPNSToken: localAPNSToken,
            serverAPNSToken: serverDiagnostics?.apnsToken,
            tokenMatch: tokenMatchLabel(
                deviceToken: DeviceIdentity.currentToken,
                serverDeviceToken: serverDiagnostics?.deviceToken,
                apnsToken: localAPNSToken,
                serverAPNSToken: serverDiagnostics?.apnsToken
            ),
            pushAuthStatus: pushStatus,
            localBuildEnvironment: localBuild,
            serverBuildEnvironment: serverBuildLabel(serverDiagnostics?.isDevelopmentBuild),
            lastSyncAttempt: displayDate(syncDiagnostics.lastSyncAttempt),
            lastSyncSuccess: displayDate(syncDiagnostics.lastSyncSuccess),
            lastSyncFailure: displayDate(syncDiagnostics.lastSyncFailure),
            lastSyncHTTPStatus: syncDiagnostics.lastSyncHTTPStatus,
            lastSyncFailureReason: syncDiagnostics.lastSyncFailureReason,
            serverRecordUpdatedAt: serverDiagnostics?.updatedAt
        )
        isLoadingDiagnostics = false
    }

    private var debugHarnessMatches: [DebugFantasyHarnessMatch] {
        DebugFantasyHarnessFactory.matches(from: fantasyViewModel.data)
    }

    private func loadHarnessMatches() async {
        guard !fantasyManagerEntryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isLoadingHarnessMatches = true
        defer { isLoadingHarnessMatches = false }
        await fantasyViewModel.refresh(
            managerEntryID: fantasyManagerEntryID,
            apiBaseURL: preferences.apiBaseURL,
            rivalManagers: [],
            trackedLeagues: []
        )
    }

    private func fetchServerDiagnostics(baseURL: String, deviceToken: String) async -> ServerPreferencesRecord? {
        guard let root = URL(string: baseURL) else { return nil }
        let endpoint = root.appendingPathComponent("preferences").appendingPathComponent(deviceToken)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        DeviceIdentity.applyHeader(to: &request)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            let payload = try JSONDecoder().decode(ServerPreferencesEnvelope.self, from: data)
            return payload.data
        } catch {
            return nil
        }
    }

    private func displayAuthorizationStatus(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .notDetermined:
            return "notDetermined"
        case .provisional:
            return "provisional"
        case .ephemeral:
            return "ephemeral"
        @unknown default:
            return "unknown"
        }
    }

    private func serverBuildLabel(_ isDevelopmentBuild: Bool?) -> String {
        switch isDevelopmentBuild {
        case .some(true):
            return "Development (sandbox APNS)"
        case .some(false):
            return "Production (live APNS)"
        case .none:
            return "Unknown"
        }
    }

    private func tokenMatchLabel(
        deviceToken: String,
        serverDeviceToken: String?,
        apnsToken: String?,
        serverAPNSToken: String?
    ) -> String {
        if serverDeviceToken == nil && serverAPNSToken == nil {
            return "Unknown"
        }
        let deviceMatch = serverDeviceToken == deviceToken
        let apnsMatch: Bool
        if let apnsToken, let serverAPNSToken {
            apnsMatch = apnsToken == serverAPNSToken
        } else {
            apnsMatch = false
        }

        if deviceMatch && apnsMatch {
            return "Match"
        }
        if deviceMatch || apnsMatch {
            return "Partial match"
        }
        return "Mismatch"
    }

    private func displayDate(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return Self.diagnosticsDateFormatter.string(from: date)
    }

    private static let diagnosticsDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private struct DebugDiagnosticsState {
        var deviceToken: String = DeviceIdentity.currentToken
        var serverDeviceToken: String?
        var localAPNSToken: String?
        var serverAPNSToken: String?
        var tokenMatch: String = "Unknown"
        var pushAuthStatus: String = "notDetermined"
        var localBuildEnvironment: String = "Unknown"
        var serverBuildEnvironment: String = "Unknown"
        var lastSyncAttempt: String = "Never"
        var lastSyncSuccess: String = "Never"
        var lastSyncFailure: String = "Never"
        var lastSyncHTTPStatus: Int?
        var lastSyncFailureReason: String?
        var serverRecordUpdatedAt: String?
    }

    private struct DebugFantasyHarnessMatch: Identifiable {
        let title: String
        let subtitle: String
        let match: Match

        var id: String {
            match.id
        }
    }

    private enum DebugFantasyHarnessFactory {
        private static let formationRows: [(category: String, size: Int)] = [
            ("goalkeeper", 1),
            ("defender", 4),
            ("midfielder", 3),
            ("attacker", 3)
        ]

        static func matches(from squad: FantasySquadDisplayData?) -> [DebugFantasyHarnessMatch] {
            guard let squad else { return [] }

            let grouped = Dictionary(grouping: squad.allPlayers) {
                FantasyTeamShortNameMappingsStore.shared.resolveTeamName(for: $0.teamName)
            }
            .map {
                (
                    teamName: $0.key,
                    players: $0.value.sorted { lhs, rhs in
                        if lhs.isStarter != rhs.isStarter {
                            return lhs.isStarter && !rhs.isStarter
                        }
                        if lhs.pickPosition != rhs.pickPosition {
                            return lhs.pickPosition < rhs.pickPosition
                        }
                        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                    }
                )
            }
            .sorted {
                if $0.players.count != $1.players.count {
                    return $0.players.count > $1.players.count
                }
                return $0.teamName.localizedCaseInsensitiveCompare($1.teamName) == .orderedAscending
            }

            guard !grouped.isEmpty else { return [] }

            let limited = Array(grouped.prefix(6))
            var results: [DebugFantasyHarnessMatch] = []
            var index = 0
            var sampleNumber = 1

            while index < limited.count, results.count < 3 {
                let home = limited[index]
                let away: (teamName: String, players: [FantasyDisplayPlayer])?
                if index + 1 < limited.count {
                    away = limited[index + 1]
                    index += 2
                } else {
                    away = nil
                    index += 1
                }

                results.append(buildMatch(home: home, away: away, sampleNumber: sampleNumber))
                sampleNumber += 1
            }

            return results
        }

        private static func buildMatch(
            home: (teamName: String, players: [FantasyDisplayPlayer]),
            away: (teamName: String, players: [FantasyDisplayPlayer])?,
            sampleNumber: Int
        ) -> DebugFantasyHarnessMatch {
            let awayGroup = away ?? (
                teamName: "Debug United \(sampleNumber)",
                players: []
            )

            let homeLineup = buildTeamLineup(teamName: home.teamName, fantasyPlayers: home.players, fillerPrefix: "Home")
            let awayLineup = buildTeamLineup(teamName: awayGroup.teamName, fantasyPlayers: awayGroup.players, fillerPrefix: "Away")

            let kickoff = Date().addingTimeInterval(TimeInterval(86_400 * sampleNumber))
            let matchState = harnessState(for: sampleNumber)
            let dateFormatter = DateFormatter()
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.dateFormat = "yyyy-MM-dd"
            let timeFormatter = DateFormatter()
            timeFormatter.locale = Locale(identifier: "en_US_POSIX")
            timeFormatter.dateFormat = "HH:mm"

            let homeHighlightNames = Array(home.players.prefix(4)).map(\.displayName)
            let awayHighlightNames = Array(awayGroup.players.prefix(4)).map(\.displayName)
            let highlighted = (homeHighlightNames + awayHighlightNames).joined(separator: ", ")

            let homeScorer = homeLineup.highlightedStarters.first ?? homeLineup.startingLineup.first
            let awayScorer = awayLineup.highlightedStarters.first ?? awayLineup.startingLineup.first
            let homeAssist = homeLineup.highlightedStarters.dropFirst().first
            let awayAssist = awayLineup.highlightedStarters.dropFirst().first
            let homeBooked = homeLineup.highlightedStarters.dropFirst(2).first
            let awayBooked = awayLineup.highlightedStarters.dropFirst(2).first

            let match = Match(
                date: dateFormatter.string(from: kickoff),
                time: timeFormatter.string(from: kickoff),
                homeTeam: home.teamName,
                awayTeam: awayGroup.teamName,
                league: "Premier League",
                tvChannels: ["Sky Sports Premier League", "Sky Sports Main Event"],
                homeScore: matchState.homeScore,
                awayScore: matchState.awayScore,
                scoreStatus: matchState.scoreStatus,
                homeGoalScorers: matchState.homeScore.map { _ in
                    homeScorer.map { [MatchGoalScorer(player: $0.name, goalTimes: ["18"])] } ?? []
                } ?? [],
                awayGoalScorers: matchState.awayScore.map { _ in
                    awayScorer.map { [MatchGoalScorer(player: $0.name, goalTimes: ["63"])] } ?? []
                } ?? [],
                homeAssists: matchState.homeScore.map { _ in
                    homeAssist.map { [MatchAssistProvider(player: $0.name, assistTimes: ["18"])] } ?? []
                } ?? [],
                awayAssists: matchState.awayScore.map { _ in
                    awayAssist.map { [MatchAssistProvider(player: $0.name, assistTimes: ["63"])] } ?? []
                } ?? [],
                homeYellowCards: matchState.scoreStatus == nil ? [] : (homeBooked.map { [MatchYellowCardEvent(player: $0.name, yellowCardTimes: ["52"])] } ?? []),
                awayYellowCards: matchState.scoreStatus == nil ? [] : (awayBooked.map { [MatchYellowCardEvent(player: $0.name, yellowCardTimes: ["71"])] } ?? []),
                teamLineups: MatchTeamLineups(home: homeLineup.teamLineup, away: awayLineup.teamLineup),
                isTestMatch: true
            )

            let subtitle: String
            if highlighted.isEmpty {
                subtitle = "Synthetic Premier League test match with made-up line-ups."
            } else {
                subtitle = "\(matchState.label): fantasy badge and lineup highlights should appear for \(highlighted)"
            }

            return DebugFantasyHarnessMatch(
                title: "\(home.teamName) vs \(awayGroup.teamName)",
                subtitle: subtitle,
                match: match
            )
        }

        private static func harnessState(for sampleNumber: Int) -> (label: String, homeScore: Int?, awayScore: Int?, scoreStatus: String?) {
            switch sampleNumber {
            case 1:
                return ("Upcoming", nil, nil, nil)
            case 2:
                return ("Live", 1, 1, "63")
            default:
                return ("Full time", 2, 1, "FT")
            }
        }

        private static func buildTeamLineup(
            teamName: String,
            fantasyPlayers: [FantasyDisplayPlayer],
            fillerPrefix: String
        ) -> (teamLineup: MatchTeamLineup, startingLineup: [MatchLineupPlayer], highlightedStarters: [MatchLineupPlayer]) {
            var remainingByPosition: [FantasyPositionType: [FantasyDisplayPlayer]] = Dictionary(
                grouping: fantasyPlayers,
                by: \.positionType
            )
            .mapValues {
                $0.sorted { lhs, rhs in
                    if lhs.isStarter != rhs.isStarter {
                        return lhs.isStarter && !rhs.isStarter
                    }
                    if lhs.pickPosition != rhs.pickPosition {
                        return lhs.pickPosition < rhs.pickPosition
                    }
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
            }

            let numberSeed = Int(abs(teamName.hashValue % 40)) + 1
            var nextFillerNumber = 1
            var starters: [MatchLineupPlayer] = []
            var highlighted: [MatchLineupPlayer] = []

            for (rowIndex, row) in formationRows.enumerated() {
                for slotIndex in 0..<row.size {
                    let player = takePlayer(
                        for: row.category,
                        rowIndex: rowIndex,
                        slotIndex: slotIndex,
                        rowSize: row.size,
                        from: &remainingByPosition,
                        fallbackName: "\(fillerPrefix) \(row.category.capitalized) \(slotIndex + 1)",
                        fallbackNumber: numberSeed + nextFillerNumber
                    )
                    if fantasyPlayers.contains(where: { $0.fullName == player.name || $0.displayName == player.name }) {
                        highlighted.append(player)
                    }
                    starters.append(player)
                    nextFillerNumber += 1
                }
            }

            let substitutes = Array(remainingByPosition.values.joined().prefix(4)).enumerated().map { offset, player in
                MatchLineupPlayer(
                    number: numberSeed + 20 + offset,
                    name: player.fullName,
                    positionCategory: positionCategory(for: player.positionType),
                    formationRowIndex: nil,
                    formationSlotIndex: nil,
                    formationRowSize: nil
                )
            }

            let teamLineup = MatchTeamLineup(
                team: teamName,
                manager: "Debug Manager",
                formation: "4-3-3",
                startingLineup: starters,
                substitutes: substitutes,
                substitutions: []
            )

            return (teamLineup, starters, highlighted)
        }

        private static func takePlayer(
            for category: String,
            rowIndex: Int,
            slotIndex: Int,
            rowSize: Int,
            from playersByPosition: inout [FantasyPositionType: [FantasyDisplayPlayer]],
            fallbackName: String,
            fallbackNumber: Int
        ) -> MatchLineupPlayer {
            let positionType = fantasyPosition(for: category)
            if let positionType,
               var players = playersByPosition[positionType],
               !players.isEmpty {
                let player = players.removeFirst()
                playersByPosition[positionType] = players
                return MatchLineupPlayer(
                    number: fallbackNumber,
                    name: player.fullName,
                    positionCategory: category,
                    formationRowIndex: rowIndex,
                    formationSlotIndex: slotIndex,
                    formationRowSize: rowSize
                )
            }

            return MatchLineupPlayer(
                number: fallbackNumber,
                name: fallbackName,
                positionCategory: category,
                formationRowIndex: rowIndex,
                formationSlotIndex: slotIndex,
                formationRowSize: rowSize
            )
        }

        private static func fantasyPosition(for category: String) -> FantasyPositionType? {
            switch category {
            case "goalkeeper":
                return .goalkeeper
            case "defender":
                return .defender
            case "midfielder":
                return .midfielder
            case "attacker":
                return .forward
            default:
                return nil
            }
        }

        private static func positionCategory(for position: FantasyPositionType) -> String {
            switch position {
            case .goalkeeper:
                return "goalkeeper"
            case .defender:
                return "defender"
            case .midfielder:
                return "midfielder"
            case .forward:
                return "attacker"
            }
        }
    }

    private struct DebugFantasyHarnessMatchesView: View {
        @EnvironmentObject private var fantasyViewModel: FantasyViewModel
        let matches: [DebugFantasyHarnessMatch]

        var body: some View {
            List {
                Section {
                    Text("Synthetic Premier League fixtures that reuse the same match lozenges as the Fixtures screen. Open any row to inspect the match details lineup highlighting.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)

                    Text("Premier League")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 2, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)

                    ForEach(matches) { harnessMatch in
                        NavigationLink {
                            MatchDetailView(match: harnessMatch.match)
                        } label: {
                            MatchRow(
                                match: harnessMatch.match,
                                highlightToday: false,
                                showLeague: false,
                                fantasyContext: fantasyViewModel.matchRowContext
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Fixtures Harness")
            .toolbarTitleDisplayMode(.inline)
        }
    }

    private struct ServerPreferencesEnvelope: Decodable {
        let data: ServerPreferencesRecord?
    }

    private struct ServerPreferencesRecord: Decodable {
        let deviceToken: String?
        let apnsToken: String?
        let isDevelopmentBuild: Bool?
        let updatedAt: String?

        enum CodingKeys: String, CodingKey {
            case deviceToken
            case apnsToken
            case isDevelopmentBuild
            case updatedAt
        }
    }
    #endif
}

#Preview {
    AboutView()
        .environmentObject(PreferencesStore())
        .environmentObject(FantasyViewModel())
}
