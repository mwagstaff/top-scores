import Foundation

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

        let payload: [String: Any] = [
            "deviceToken": deviceToken,
            "apnsToken": apnsToken as Any,
            "isDevelopmentBuild": isDevelopmentBuild,
            "preferences": [
                "selectedLeagues": snapshot.selectedLeagues,
                "selectedChannels": snapshot.selectedChannels,
                "competitionFilterEnabled": snapshot.competitionFilterEnabled,
                "channelFilterEnabled": snapshot.channelFilterEnabled,
                "englishPremierLeagueTeamsOnly": snapshot.englishPremierLeagueTeamsOnly,
                "apiBaseURL": snapshot.apiBaseURL,
                "refreshIntervalMinutes": snapshot.refreshIntervalMinutes,
                "showAllMatches": snapshot.showAllMatches,
                "matchGroupSortOrder": snapshot.matchGroupSortOrder.rawValue,
                "notificationsEnabled": snapshot.notificationsEnabled,
                "notificationDelayMinutes": snapshot.notificationDelayMinutes,
                "notificationEventTypes": Array(snapshot.notificationEventTypes),
                "notificationUseViewingFilter": snapshot.notificationUseViewingFilter,
                "notificationCompetitionFilterEnabled": snapshot.notificationCompetitionFilterEnabled,
                "notificationSelectedLeagues": snapshot.notificationSelectedLeagues
            ]
        ]

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
                NSLog("[PreferencesSync] Successfully synced preferences to Redis")
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
            let snapshot = PreferencesSnapshot(
                selectedLeagues: preferences["selectedLeagues"] as? [String] ?? PreferencesStore.defaultSelectedLeagues,
                selectedChannels: preferences["selectedChannels"] as? [String] ?? PreferencesStore.defaultSelectedChannels,
                competitionFilterEnabled: preferences["competitionFilterEnabled"] as? Bool ?? PreferencesStore.defaultCompetitionFilterEnabled,
                channelFilterEnabled: preferences["channelFilterEnabled"] as? Bool ?? PreferencesStore.defaultChannelFilterEnabled,
                englishPremierLeagueTeamsOnly: preferences["englishPremierLeagueTeamsOnly"] as? Bool ?? PreferencesStore.defaultEnglishPremierLeagueTeamsOnly,
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
                notificationSelectedLeagues: preferences["notificationSelectedLeagues"] as? [String] ?? PreferencesStore.defaultNotificationSelectedLeagues
            )

            NSLog("[PreferencesSync] Successfully fetched preferences from Redis")
            return snapshot
        } catch {
            NSLog("[PreferencesSync] Error fetching preferences: %@", error.localizedDescription)
            return nil
        }
    }
}
