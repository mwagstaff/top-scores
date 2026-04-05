import Foundation

private struct FantasySyncPlayerPayload: Codable, Sendable {
    let elementID: Int
    let pickPosition: Int
    let positionType: Int
    let displayName: String
    let fullName: String
    let teamName: String
    let rawPoints: Int
    let appliedPoints: Int
    let displayPoints: Int
    let multiplier: Int
    let isCaptain: Bool
    let isViceCaptain: Bool
    let isStarter: Bool
    let hasAnyFixtureThisGameweek: Bool
    let hasUpcomingFixtureThisGameweek: Bool
    let hasActiveFixtureThisGameweek: Bool
    let minutesPlayed: Int

    nonisolated init(player: FantasyDisplayPlayer) {
        elementID = player.elementID
        pickPosition = player.pickPosition
        positionType = player.positionType.rawValue
        displayName = player.displayName
        fullName = player.fullName
        teamName = player.teamName
        rawPoints = player.rawPoints
        appliedPoints = player.appliedPoints
        displayPoints = player.displayPoints
        multiplier = player.multiplier
        isCaptain = player.isCaptain
        isViceCaptain = player.isViceCaptain
        isStarter = player.isStarter
        hasAnyFixtureThisGameweek = player.hasAnyFixtureThisGameweek
        hasUpcomingFixtureThisGameweek = player.hasUpcomingFixtureThisGameweek
        hasActiveFixtureThisGameweek = player.hasActiveFixtureThisGameweek
        minutesPlayed = player.minutesPlayed
    }
}

private struct FantasySyncContributionPayload: Codable, Sendable {
    let elementID: Int
    let displayName: String
    let fullName: String
    let teamName: String
    let points: Int

    nonisolated init(contribution: FantasyEffectivePlayerContribution) {
        elementID = contribution.elementID
        displayName = contribution.displayName
        fullName = contribution.fullName
        teamName = contribution.teamName
        points = contribution.points
    }
}

private struct FantasySyncSquadPayload: Codable, Sendable {
    let managerEntryID: Int
    let syncedAt: String
    let gameweekID: Int
    let gameweekTitle: String
    let totalPoints: Int
    let estimatedCurrentScore: Int
    let resolvedCurrentScore: Int
    let isEstimatedScore: Bool
    let hasActiveFixtures: Bool
    let activeChipCodes: [String]
    let players: [FantasySyncPlayerPayload]
    let effectiveContributions: [FantasySyncContributionPayload]

    nonisolated init(managerEntryID: Int, squad: FantasySquadDisplayData, now: Date = Date()) {
        self.managerEntryID = managerEntryID
        syncedAt = ISO8601DateFormatter().string(from: now)
        gameweekID = squad.gameweekID
        gameweekTitle = squad.gameweekTitle
        totalPoints = squad.totalPoints
        estimatedCurrentScore = squad.estimatedCurrentScore
        resolvedCurrentScore = squad.resolvedCurrentScore
        isEstimatedScore = squad.isEstimatedScore
        hasActiveFixtures = squad.hasActiveFixtures
        activeChipCodes = squad.activeChips.map(\.code)
        players = squad.allPlayers.map(FantasySyncPlayerPayload.init(player:))
        effectiveContributions = squad.effectivePlayerContributions.map(
            FantasySyncContributionPayload.init(contribution:)
        )
    }
}

private struct FantasySyncStatePayload: Codable, Sendable {
    let managerEntryID: Int?
    let squad: FantasySyncSquadPayload?

    nonisolated init(managerEntryID: Int?, squad: FantasySyncSquadPayload?) {
        self.managerEntryID = managerEntryID
        self.squad = squad
    }
}

enum FantasySyncStore {
    private nonisolated static let userDefaultsKey = "fantasy.syncedSquadState"

    nonisolated static func persist(managerEntryID: String, squad: FantasySquadDisplayData?) {
        let defaults = UserDefaults.standard
        let trimmedManagerID = managerEntryID.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedManagerEntryID = Int(trimmedManagerID)

        guard let parsedManagerEntryID, parsedManagerEntryID > 0 else {
            defaults.removeObject(forKey: userDefaultsKey)
            return
        }

        let payload = FantasySyncStatePayload(
            managerEntryID: parsedManagerEntryID,
            squad: squad.map { FantasySyncSquadPayload(managerEntryID: parsedManagerEntryID, squad: $0) }
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: userDefaultsKey)
    }

    nonisolated static func jsonObject() -> Any? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

struct PreferencesSyncDiagnostics: Sendable {
    let lastSyncAttempt: Date?
    let lastSyncSuccess: Date?
    let lastSyncFailure: Date?
    let lastSyncHTTPStatus: Int?
    let lastSyncFailureReason: String?
}

actor PreferencesSyncService {
    static let shared = PreferencesSyncService()

    private var syncTask: Task<Void, Never>?
    private var lastSyncAttempt: Date?
    private var lastSyncSuccess: Date?
    private var lastSyncFailure: Date?
    private var lastSyncHTTPStatus: Int?
    private var lastSyncFailureReason: String?
    private let minSyncInterval: TimeInterval = 2.0 // Debounce syncs to max once per 2 seconds

    private init() {}

    /// Syncs user preferences to the Redis backend
    func syncPreferences(_ snapshot: PreferencesSnapshot) async {
        // Cancel any pending sync
        syncTask?.cancel()

        // Check if we should debounce
        if let lastSync = lastSyncAttempt {
            let timeSinceLastSync = Date().timeIntervalSince(lastSync)
            if timeSinceLastSync < minSyncInterval {
                // Schedule a delayed sync
                syncTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(minSyncInterval * 1_000_000_000))
                    if !Task.isCancelled {
                        await performSync(snapshot)
                    }
                }
                return
            }
        }

        await performSync(snapshot)
    }

    func diagnostics() -> PreferencesSyncDiagnostics {
        PreferencesSyncDiagnostics(
            lastSyncAttempt: lastSyncAttempt,
            lastSyncSuccess: lastSyncSuccess,
            lastSyncFailure: lastSyncFailure,
            lastSyncHTTPStatus: lastSyncHTTPStatus,
            lastSyncFailureReason: lastSyncFailureReason
        )
    }

    private func performSync(_ snapshot: PreferencesSnapshot) async {
        let now = Date()
        lastSyncAttempt = now

        let deviceToken = getDeviceToken()

        guard let baseURL = URL(string: snapshot.apiBaseURL) else {
            NSLog("[PreferencesSync] Invalid API base URL: %@", snapshot.apiBaseURL)
            lastSyncFailure = now
            lastSyncHTTPStatus = nil
            lastSyncFailureReason = "Invalid API base URL"
            return
        }

        let endpoint = baseURL.appendingPathComponent("preferences")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        DeviceIdentity.applyHeader(to: &request)

        // Get APNS token and development build status
        let apnsToken = await MainActor.run { NotificationManager.shared.currentAPNSToken }
        let isDevelopmentBuild = await MainActor.run { NotificationManager.shared.isDevelopmentBuild }
        let fantasyState = FantasySyncStore.jsonObject() ?? NSNull()

        let payload: [String: Any] = [
            "deviceToken": deviceToken,
            "apnsToken": apnsToken as Any,
            "isDevelopmentBuild": isDevelopmentBuild,
            "fantasy": fantasyState,
            "preferences": [
                "selectedLeagues": snapshot.selectedLeagues,
                "selectedChannels": snapshot.selectedChannels,
                "competitionFilterEnabled": snapshot.competitionFilterEnabled,
                "channelFilterEnabled": snapshot.channelFilterEnabled,
                "englishPremierLeagueTeamsOnly": snapshot.englishPremierLeagueTeamsOnly,
                "majorUEFAClubGamesEnabled": snapshot.majorUEFAClubGamesEnabled,
                "homeNationsFilterEnabled": snapshot.homeNationsFilterEnabled,
                "majorTournamentsFilterEnabled": snapshot.majorTournamentsFilterEnabled,
                "apiBaseURL": snapshot.apiBaseURL,
                "refreshIntervalMinutes": snapshot.refreshIntervalMinutes,
                "showAllMatches": snapshot.showAllMatches,
                "matchGroupSortOrder": snapshot.matchGroupSortOrder.rawValue,
                "notificationsEnabled": snapshot.notificationsEnabled,
                "notificationDelayMinutes": snapshot.notificationDelayMinutes,
                "notificationEventTypes": Array(snapshot.notificationEventTypes),
                "notificationUseViewingFilter": snapshot.notificationUseViewingFilter,
                "notificationCompetitionFilterEnabled": snapshot.notificationCompetitionFilterEnabled,
                "notificationSelectedLeagues": snapshot.notificationSelectedLeagues,
                "notificationPremierLeagueTeamsOnly": snapshot.notificationPremierLeagueTeamsOnly,
                "fantasyDeadlineRemindersEnabled": snapshot.fantasyDeadlineRemindersEnabled,
                "showTodayUnfinishedFixturesBadge": snapshot.showTodayUnfinishedFixturesBadge,
                "showFantasyFixtureLogos": snapshot.showFantasyFixtureLogos,
                "showFantasyExpectedPoints": snapshot.showFantasyExpectedPoints,
                "showFantasyRealTimePoints": snapshot.showFantasyRealTimePoints,
                "showFantasyMatchPills": snapshot.showsFantasyDataInFixtures,
                "deviceLocale": Locale.current.identifier,
                "deviceTimeZone": TimeZone.current.identifier
            ]
        ]

        NSLog(
            "[PreferencesSync] Sending sync device=%@ fantasy=%@",
            shortDeviceToken(deviceToken),
            summarizeFantasyPayload(fantasyState)
        )

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                NSLog("[PreferencesSync] Invalid response type")
                lastSyncFailure = Date()
                lastSyncHTTPStatus = nil
                lastSyncFailureReason = "Invalid response type"
                return
            }

            if (200...299).contains(httpResponse.statusCode) {
                let responseFantasySummary = summarizeFantasyPayload(fromResponseData: data)
                NSLog(
                    "[PreferencesSync] Successfully synced preferences to Redis device=%@ fantasy=%@",
                    shortDeviceToken(deviceToken),
                    responseFantasySummary
                )
                lastSyncSuccess = Date()
                lastSyncFailure = nil
                lastSyncHTTPStatus = httpResponse.statusCode
                lastSyncFailureReason = nil
            } else {
                let errorBody = String(data: data, encoding: .utf8) ?? "No response body"
                NSLog("[PreferencesSync] Failed to sync: HTTP %d - %@", httpResponse.statusCode, errorBody)
                lastSyncFailure = Date()
                lastSyncHTTPStatus = httpResponse.statusCode
                lastSyncFailureReason = errorBody
            }
        } catch {
            NSLog("[PreferencesSync] Error syncing preferences: %@", error.localizedDescription)
            lastSyncFailure = Date()
            lastSyncHTTPStatus = nil
            lastSyncFailureReason = error.localizedDescription
        }
    }

    private func getDeviceToken() -> String {
        DeviceIdentity.currentToken
    }

    private func shortDeviceToken(_ token: String) -> String {
        String(token.prefix(12))
    }

    private func summarizeFantasyPayload(_ fantasyState: Any) -> String {
        if fantasyState is NSNull {
            return "null"
        }

        guard let fantasy = fantasyState as? [String: Any] else {
            return "missing"
        }

        let managerEntryID = fantasy["managerEntryID"] as? Int
        let squad = fantasy["squad"] as? [String: Any]
        let squadManagerEntryID = squad?["managerEntryID"] as? Int
        return "manager=\(managerEntryID.map(String.init) ?? "nil") squadManager=\(squadManagerEntryID.map(String.init) ?? "nil")"
    }

    private func summarizeFantasyPayload(fromResponseData data: Data) -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let responseData = json["data"] as? [String: Any]
        else {
            return "unparsed"
        }

        if let fantasy = responseData["fantasy"] {
            return summarizeFantasyPayload(fantasy)
        }

        return "missing"
    }

    /// Fetches user preferences from Redis (optional - for restore functionality)
    func fetchPreferences(apiBaseURL: String) async -> PreferencesSnapshot? {
        let deviceToken = getDeviceToken()

        guard let baseURL = URL(string: apiBaseURL) else {
            NSLog("[PreferencesSync] Invalid API base URL: %@", apiBaseURL)
            return nil
        }

        let endpoint = baseURL.appendingPathComponent("preferences").appendingPathComponent(deviceToken)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        DeviceIdentity.applyHeader(to: &request)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                NSLog("[PreferencesSync] Invalid response type")
                return nil
            }

            if httpResponse.statusCode == 404 {
                NSLog("[PreferencesSync] No preferences found in Redis for this device")
                return nil
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                NSLog("[PreferencesSync] Failed to fetch: HTTP %d", httpResponse.statusCode)
                return nil
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let responseData = json?["data"] as? [String: Any],
                  let preferences = responseData["preferences"] as? [String: Any] else {
                NSLog("[PreferencesSync] Invalid response format")
                return nil
            }

            let notificationEventTypesArray = preferences["notificationEventTypes"] as? [String]
            let notificationEventTypes = notificationEventTypesArray.map { Set($0) } ?? PreferencesStore.defaultNotificationEventTypes
            let legacyShowFantasyMatchPills = preferences["showFantasyMatchPills"] as? Bool ?? PreferencesStore.defaultShowFantasyMatchPills
            let snapshot = PreferencesSnapshot(
                selectedLeagues: preferences["selectedLeagues"] as? [String] ?? PreferencesStore.defaultSelectedLeagues,
                selectedChannels: preferences["selectedChannels"] as? [String] ?? PreferencesStore.defaultSelectedChannels,
                competitionFilterEnabled: preferences["competitionFilterEnabled"] as? Bool ?? PreferencesStore.defaultCompetitionFilterEnabled,
                channelFilterEnabled: preferences["channelFilterEnabled"] as? Bool ?? PreferencesStore.defaultChannelFilterEnabled,
                englishPremierLeagueTeamsOnly: preferences["englishPremierLeagueTeamsOnly"] as? Bool ?? PreferencesStore.defaultEnglishPremierLeagueTeamsOnly,
                majorUEFAClubGamesEnabled: preferences["majorUEFAClubGamesEnabled"] as? Bool ?? PreferencesStore.defaultMajorUEFAClubGamesEnabled,
                homeNationsFilterEnabled: preferences["homeNationsFilterEnabled"] as? Bool ?? PreferencesStore.defaultHomeNationsFilterEnabled,
                majorTournamentsFilterEnabled: preferences["majorTournamentsFilterEnabled"] as? Bool ?? PreferencesStore.defaultMajorTournamentsFilterEnabled,
                apiBaseURL: preferences["apiBaseURL"] as? String ?? PreferencesStore.defaultApiBaseURL,
                refreshIntervalMinutes: preferences["refreshIntervalMinutes"] as? Int ?? PreferencesStore.defaultRefreshIntervalMinutes,
                showAllMatches: preferences["showAllMatches"] as? Bool ?? PreferencesStore.defaultShowAllMatches,
                matchGroupSortOrder: (preferences["matchGroupSortOrder"] as? String)
                    .flatMap(MatchGroupSortOrder.init(rawValue:))
                    ?? PreferencesStore.defaultMatchGroupSortOrder,
                notificationsEnabled: preferences["notificationsEnabled"] as? Bool ?? PreferencesStore.defaultNotificationsEnabled,
                notificationDelayMinutes: preferences["notificationDelayMinutes"] as? Int ?? PreferencesStore.defaultNotificationDelayMinutes,
                notificationEventTypes: notificationEventTypes,
                notificationUseViewingFilter: preferences["notificationUseViewingFilter"] as? Bool ?? PreferencesStore.defaultNotificationUseViewingFilter,
                notificationCompetitionFilterEnabled: preferences["notificationCompetitionFilterEnabled"] as? Bool ?? PreferencesStore.defaultNotificationCompetitionFilterEnabled,
                notificationSelectedLeagues: preferences["notificationSelectedLeagues"] as? [String] ?? PreferencesStore.defaultNotificationSelectedLeagues,
                notificationPremierLeagueTeamsOnly: preferences["notificationPremierLeagueTeamsOnly"] as? Bool ?? PreferencesStore.defaultNotificationPremierLeagueTeamsOnly,
                fantasyDeadlineRemindersEnabled: preferences["fantasyDeadlineRemindersEnabled"] as? Bool ?? PreferencesStore.defaultFantasyDeadlineRemindersEnabled,
                showTodayUnfinishedFixturesBadge: preferences["showTodayUnfinishedFixturesBadge"] as? Bool ?? PreferencesStore.defaultShowTodayUnfinishedFixturesBadge,
                showFantasyFixtureLogos: preferences["showFantasyFixtureLogos"] as? Bool ?? legacyShowFantasyMatchPills,
                showFantasyExpectedPoints: preferences["showFantasyExpectedPoints"] as? Bool ?? legacyShowFantasyMatchPills,
                showFantasyRealTimePoints: preferences["showFantasyRealTimePoints"] as? Bool ?? legacyShowFantasyMatchPills
            )

            NSLog("[PreferencesSync] Successfully fetched preferences from Redis")
            return snapshot
        } catch {
            NSLog("[PreferencesSync] Error fetching preferences: %@", error.localizedDescription)
            return nil
        }
    }
}
