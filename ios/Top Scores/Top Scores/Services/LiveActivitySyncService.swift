import Foundation
import os
#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.1, *)
struct TopScoresLiveActivityMatchState: Codable, Hashable {
    let matchId: String
    let date: String
    let time: String
    let league: String
    let leagueSubcategory: String?
    let homeTeam: String
    let awayTeam: String
    let homeShortName: String?
    let awayShortName: String?
    let homeScore: Int?
    let awayScore: Int?
    let aggregateHomeScore: Int?
    let aggregateAwayScore: Int?
    let firstLegHomeScore: Int?
    let firstLegAwayScore: Int?
    let matchTime: String?
    let penaltyWinner: String?
    let tvChannels: [String]

    enum CodingKeys: String, CodingKey {
        case matchId
        case date
        case time
        case league
        case leagueSubcategory
        case homeTeam
        case awayTeam
        case homeShortName
        case awayShortName
        case homeScore
        case awayScore
        case aggregateHomeScore
        case aggregateAwayScore
        case firstLegHomeScore
        case firstLegAwayScore
        case matchTime
        case penaltyWinner
        case tvChannels
    }

    init(
        matchId: String,
        date: String,
        time: String,
        league: String,
        leagueSubcategory: String? = nil,
        homeTeam: String,
        awayTeam: String,
        homeShortName: String? = nil,
        awayShortName: String? = nil,
        homeScore: Int? = nil,
        awayScore: Int? = nil,
        aggregateHomeScore: Int? = nil,
        aggregateAwayScore: Int? = nil,
        firstLegHomeScore: Int? = nil,
        firstLegAwayScore: Int? = nil,
        matchTime: String? = nil,
        penaltyWinner: String? = nil,
        tvChannels: [String] = []
    ) {
        self.matchId = matchId
        self.date = date
        self.time = time
        self.league = league
        self.leagueSubcategory = leagueSubcategory
        self.homeTeam = homeTeam
        self.awayTeam = awayTeam
        self.homeShortName = homeShortName
        self.awayShortName = awayShortName
        self.homeScore = homeScore
        self.awayScore = awayScore
        self.aggregateHomeScore = aggregateHomeScore
        self.aggregateAwayScore = aggregateAwayScore
        self.firstLegHomeScore = firstLegHomeScore
        self.firstLegAwayScore = firstLegAwayScore
        self.matchTime = matchTime
        self.penaltyWinner = penaltyWinner
        self.tvChannels = tvChannels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        matchId = try container.decode(String.self, forKey: .matchId)
        date = try container.decode(String.self, forKey: .date)
        time = try container.decode(String.self, forKey: .time)
        league = try container.decode(String.self, forKey: .league)
        leagueSubcategory = try container.decodeIfPresent(String.self, forKey: .leagueSubcategory)
        homeTeam = try container.decode(String.self, forKey: .homeTeam)
        awayTeam = try container.decode(String.self, forKey: .awayTeam)
        homeShortName = try container.decodeIfPresent(String.self, forKey: .homeShortName)
        awayShortName = try container.decodeIfPresent(String.self, forKey: .awayShortName)
        homeScore = try container.decodeIfPresent(Int.self, forKey: .homeScore)
        awayScore = try container.decodeIfPresent(Int.self, forKey: .awayScore)
        aggregateHomeScore = try container.decodeIfPresent(Int.self, forKey: .aggregateHomeScore)
        aggregateAwayScore = try container.decodeIfPresent(Int.self, forKey: .aggregateAwayScore)
        firstLegHomeScore = try container.decodeIfPresent(Int.self, forKey: .firstLegHomeScore)
        firstLegAwayScore = try container.decodeIfPresent(Int.self, forKey: .firstLegAwayScore)
        matchTime = try container.decodeIfPresent(String.self, forKey: .matchTime)
        penaltyWinner = try container.decodeIfPresent(String.self, forKey: .penaltyWinner)
        tvChannels = try container.decodeIfPresent([String].self, forKey: .tvChannels) ?? []
    }

    var displayHomeTeam: String {
        let trimmed = homeShortName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? homeTeam : trimmed
    }

    var displayAwayTeam: String {
        let trimmed = awayShortName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? awayTeam : trimmed
    }
}

@available(iOS 16.1, *)
struct TopScoresLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let mode: String
        let generatedAtEpochSeconds: Int
        let delayMinutes: Int
        let fantasyCurrentScore: Int?
        let matches: [TopScoresLiveActivityMatchState]
    }

    let appScope: String
}

final class LiveActivitySyncService {
    static let shared = LiveActivitySyncService()

    private let lock = NSLock()
    private var started = false
    private var lastForegroundReconcileAt: Date?
    private let foregroundReconcileMinInterval: TimeInterval = 15
    private var pushToStartTask: Task<Void, Never>?
    private var activityUpdatesTask: Task<Void, Never>?
    private var observedActivityIDs = Set<String>()
    private var activityPushTokenTasks: [String: Task<Void, Never>] = [:]
    private var activityContentTasks: [String: Task<Void, Never>] = [:]
    private var activityStateTasks: [String: Task<Void, Never>] = [:]
    private var lastUploadedPushToStartTokenHex: String?
    private var lastUploadedActivityPushTokenHexByActivityID: [String: String] = [:]

    private init() {}

    func start() {
        let signpost = PerformanceSignposter.liveActivity.beginInterval("LiveActivityStart")
        defer { PerformanceSignposter.liveActivity.endInterval("LiveActivityStart", signpost) }

        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        if #available(iOS 17.2, *) {
            pushToStartTask = Task(priority: .background) {
                for await tokenData in Activity<TopScoresLiveActivityAttributes>.pushToStartTokenUpdates {
                    await self.uploadPushToStartToken(tokenData)
                }
            }
            NSLog("[LiveActivitySync] Monitoring push-to-start token updates")
        } else {
            NSLog("[LiveActivitySync] pushToStartTokenUpdates requires iOS 17.2+")
        }

        if #available(iOS 16.1, *) {
            NSLog(
                "[LiveActivitySync] Existing ActivityKit activities on start: %d",
                Activity<TopScoresLiveActivityAttributes>.activities.count
            )
            for activity in Activity<TopScoresLiveActivityAttributes>.activities {
                beginObserving(activity)
            }

            activityUpdatesTask = Task(priority: .background) {
                for await activity in Activity<TopScoresLiveActivityAttributes>.activityUpdates {
                    self.beginObserving(activity)
                    // Deduplicate immediately when a new activity appears (e.g. a second
                    // push-to-start while one is already active) so the lock screen never
                    // shows two widgets, even when the app never comes to the foreground.
                    let current = Activity<TopScoresLiveActivityAttributes>.activities
                    if current.count > 1 {
                        _ = await self.enforceSingleActiveActivity(among: current)
                    }
                }
            }
            NSLog("[LiveActivitySync] Monitoring activity push token updates")
        }

        reconcileOnForeground()
    }

    func reconcileOnForeground() {
        guard #available(iOS 16.1, *) else { return }
        let now = Date()
        lock.lock()
        if let last = lastForegroundReconcileAt,
           now.timeIntervalSince(last) < foregroundReconcileMinInterval {
            lock.unlock()
            return
        }
        lastForegroundReconcileAt = now
        lock.unlock()

        Task(priority: .background) {
            await self.reconcileLiveActivityStateOnForeground()
        }
    }

    @available(iOS 16.1, *)
    private func beginObserving(_ activity: Activity<TopScoresLiveActivityAttributes>) {
        let activityID = activity.id

        lock.lock()
        if observedActivityIDs.contains(activityID) {
            lock.unlock()
            return
        }
        observedActivityIDs.insert(activityID)
        lock.unlock()

        NSLog(
            "[LiveActivitySync] Begin observing activity %@ state=%@ %@",
            activityID,
            String(describing: activity.activityState),
            Self.contentStateSummary(Self.currentContentState(for: activity))
        )

        if let tokenData = activity.pushToken {
            NSLog(
                "[LiveActivitySync] Existing activity push token %@ token=%@",
                activityID,
                Self.shortHex(tokenData)
            )
            Task(priority: .background) {
                await self.uploadActivityPushToken(activityID: activityID, tokenData: tokenData)
            }
        }

        let pushTokenTask = Task(priority: .background) {
            for await tokenData in activity.pushTokenUpdates {
                NSLog(
                    "[LiveActivitySync] Activity push token update %@ token=%@",
                    activityID,
                    Self.shortHex(tokenData)
                )
                await self.uploadActivityPushToken(activityID: activityID, tokenData: tokenData)
            }
        }

        let contentTask: Task<Void, Never>?
        if #available(iOS 16.2, *) {
            contentTask = Task(priority: .background) {
                for await content in activity.contentUpdates {
                    NSLog(
                        "[LiveActivitySync] Activity content update %@ staleDate=%@ %@",
                        activityID,
                        content.staleDate?.description ?? "nil",
                        Self.contentStateSummary(content.state)
                    )
                }
            }
        } else {
            contentTask = nil
        }

        let stateTask = Task(priority: .background) {
            var ended = false
            for await state in activity.activityStateUpdates {
                NSLog(
                    "[LiveActivitySync] Activity state update %@ state=%@",
                    activityID,
                    String(describing: state)
                )
                if state == .ended {
                    ended = true
                    await self.uploadActivityEnded(activityID: activityID)
                    break
                }
            }
            self.stopObserving(activityID: activityID, cancelStateTask: false)
            if !ended {
                NSLog("[LiveActivitySync] Activity stream closed without explicit ended state: %@", activityID)
            }
        }

        lock.lock()
        activityPushTokenTasks[activityID] = pushTokenTask
        if let contentTask {
            activityContentTasks[activityID] = contentTask
        }
        activityStateTasks[activityID] = stateTask
        lock.unlock()
    }

    private func stopObserving(activityID: String, cancelStateTask: Bool) {
        lock.lock()
        let pushTask = activityPushTokenTasks.removeValue(forKey: activityID)
        let contentTask = activityContentTasks.removeValue(forKey: activityID)
        let stateTask = activityStateTasks.removeValue(forKey: activityID)
        lastUploadedActivityPushTokenHexByActivityID.removeValue(forKey: activityID)
        observedActivityIDs.remove(activityID)
        lock.unlock()

        pushTask?.cancel()
        contentTask?.cancel()
        if cancelStateTask {
            stateTask?.cancel()
        }
    }

    @available(iOS 16.1, *)
    private func reconcileLiveActivityStateOnForeground() async {
        let signpost = PerformanceSignposter.liveActivity.beginInterval("LiveActivityForegroundReconcile")
        defer { PerformanceSignposter.liveActivity.endInterval("LiveActivityForegroundReconcile", signpost) }

        if #available(iOS 17.2, *),
           let pushToStartToken = Activity<TopScoresLiveActivityAttributes>.pushToStartToken {
            await uploadPushToStartToken(pushToStartToken)
        }

        let activeActivities = await enforceSingleActiveActivity(among: Activity<TopScoresLiveActivityAttributes>.activities)
        if activeActivities.isEmpty {
            await uploadActivityEnded(activityID: "")
        } else {
            for activity in activeActivities {
                NSLog(
                    "[LiveActivitySync] Foreground reconcile active activity %@ state=%@ tokenPresent=%d %@",
                    activity.id,
                    String(describing: activity.activityState),
                    activity.pushToken == nil ? 0 : 1,
                    Self.contentStateSummary(Self.currentContentState(for: activity))
                )
                if let tokenData = activity.pushToken {
                    await uploadActivityPushToken(activityID: activity.id, tokenData: tokenData)
                }
            }
        }

        guard activeActivities.isEmpty else {
            #if DEBUG
            await fetchServerDebugState()
            #endif
            return
        }

        let reconcileResponse = await requestLiveActivityReconcile()
        // If no active activity and the server has live content, start one directly
        // so push-to-start (which requires background) is not the only path.
        // Re-check Activity.activities here rather than using the snapshot captured before
        // the HTTP call, in case a push-to-start arrived during the round-trip.
        let currentActivities = Activity<TopScoresLiveActivityAttributes>.activities
        if currentActivities.isEmpty, let contentState = reconcileResponse {
            await startForegroundActivityIfNeeded(contentState: contentState)
        }
        #if DEBUG
        await fetchServerDebugState()
        #endif
    }

    @available(iOS 16.1, *)
    private func enforceSingleActiveActivity(
        among activities: [Activity<TopScoresLiveActivityAttributes>]
    ) async -> [Activity<TopScoresLiveActivityAttributes>] {
        let signpost = PerformanceSignposter.liveActivity.beginInterval("LiveActivityEnforceSingle")
        defer { PerformanceSignposter.liveActivity.endInterval("LiveActivityEnforceSingle", signpost) }

        guard activities.count > 1 else { return activities }

        let sortedActivities = activities.sorted { lhs, rhs in
            let leftState = Self.currentContentState(for: lhs)
            let rightState = Self.currentContentState(for: rhs)
            if leftState.generatedAtEpochSeconds != rightState.generatedAtEpochSeconds {
                return leftState.generatedAtEpochSeconds > rightState.generatedAtEpochSeconds
            }
            return lhs.id > rhs.id
        }

        guard let survivor = sortedActivities.first else { return [] }

        NSLog(
            "[LiveActivitySync] Found %d active activities; keeping %@ and ending duplicates",
            activities.count,
            survivor.id
        )

        for duplicate in sortedActivities.dropFirst() {
            NSLog("[LiveActivitySync] Ending duplicate activity %@", duplicate.id)
            stopObserving(activityID: duplicate.id, cancelStateTask: true)
            await duplicate.end(nil, dismissalPolicy: .immediate)
            await uploadActivityEnded(activityID: duplicate.id)
        }

        return [survivor]
    }

    private func uploadPushToStartToken(_ tokenData: Data) async {
        let tokenHex = Self.hexString(from: tokenData)
        let shouldUpload = lock.withLock {
            let shouldUpload = lastUploadedPushToStartTokenHex != tokenHex
            if shouldUpload {
                lastUploadedPushToStartTokenHex = tokenHex
            }
            return shouldUpload
        }
        guard shouldUpload else { return }

        guard let endpoint = await endpointURL(path: "live-activity/push-to-start-token") else { return }
        let payload: [String: Any] = [
            "deviceToken": DeviceIdentity.currentToken,
            "pushToStartToken": tokenHex,
            "isDevelopmentBuild": await MainActor.run { NotificationManager.shared.isDevelopmentBuild }
        ]
        await sendJSONRequest(url: endpoint, payload: payload, logContext: "push-to-start")
    }

    private func uploadActivityPushToken(activityID: String, tokenData: Data) async {
        let tokenHex = Self.hexString(from: tokenData)
        let shouldUpload = lock.withLock {
            let shouldUpload = lastUploadedActivityPushTokenHexByActivityID[activityID] != tokenHex
            if shouldUpload {
                lastUploadedActivityPushTokenHexByActivityID[activityID] = tokenHex
            }
            return shouldUpload
        }
        guard shouldUpload else { return }

        guard let endpoint = await endpointURL(path: "live-activity/activity-token") else { return }
        let payload: [String: Any] = [
            "deviceToken": DeviceIdentity.currentToken,
            "activityId": activityID,
            "activityPushToken": tokenHex,
            "isDevelopmentBuild": await MainActor.run { NotificationManager.shared.isDevelopmentBuild }
        ]
        await sendJSONRequest(url: endpoint, payload: payload, logContext: "activity-token")
    }

    private func uploadActivityEnded(activityID: String) async {
        guard let endpoint = await endpointURL(path: "live-activity/activity-ended") else { return }
        let payload: [String: Any] = [
            "deviceToken": DeviceIdentity.currentToken,
            "activityId": activityID,
            "isDevelopmentBuild": await MainActor.run { NotificationManager.shared.isDevelopmentBuild }
        ]
        await sendJSONRequest(url: endpoint, payload: payload, logContext: "activity-ended")
    }

    @available(iOS 16.1, *)
    private func requestLiveActivityReconcile() async -> TopScoresLiveActivityAttributes.ContentState? {
        guard let endpoint = await endpointURL(path: "live-activity/reconcile") else { return nil }
        let payload: [String: Any] = [
            "deviceToken": DeviceIdentity.currentToken,
            "isDevelopmentBuild": await MainActor.run { NotificationManager.shared.isDevelopmentBuild },
            "force": true,
            "trigger": "app_foreground"
        ]
        guard let responseData = await sendJSONRequestReturningData(url: endpoint, payload: payload, logContext: "live-activity-reconcile") else {
            return nil
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let foregroundStart = json["foregroundStart"] as? [String: Any],
            let rawContentState = foregroundStart["contentState"]
        else { return nil }
        guard let contentStateData = try? JSONSerialization.data(withJSONObject: rawContentState),
              let contentState = try? JSONDecoder().decode(TopScoresLiveActivityAttributes.ContentState.self, from: contentStateData)
        else { return nil }
        return contentState
    }

    @available(iOS 16.1, *)
    private func startForegroundActivityIfNeeded(contentState: TopScoresLiveActivityAttributes.ContentState) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            NSLog("[LiveActivitySync] Foreground start skipped: activities not enabled")
            return
        }
        do {
            let attributes = TopScoresLiveActivityAttributes(appScope: "top-scores")
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: contentState, staleDate: nil),
                pushType: .token
            )
            NSLog("[LiveActivitySync] Foreground start succeeded activityId=%@", activity.id)
            // Register immediately — don't rely solely on activityUpdatesTask picking this up
            beginObserving(activity)
        } catch {
            NSLog("[LiveActivitySync] Foreground start failed: %@", error.localizedDescription)
        }
    }

    private func fetchServerDebugState() async {
        guard var endpoint = await endpointURL(path: "live-activity/test/state") else { return }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "userDeviceToken", value: DeviceIdentity.currentToken)]
        if let url = components?.url {
            endpoint = url
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        DeviceIdentity.applyHeader(to: &request)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                NSLog("[LiveActivitySync] live-activity-test-state failed: invalid response type")
                return
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "No response body"
                NSLog("[LiveActivitySync] live-activity-test-state failed: HTTP %d - %@", httpResponse.statusCode, body)
                return
            }
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                NSLog("[LiveActivitySync] live-activity-test-state failed: invalid JSON")
                return
            }
            NSLog(
                "[LiveActivitySync] Server debug state %@",
                Self.serverDebugSummary(json)
            )
        } catch {
            NSLog("[LiveActivitySync] live-activity-test-state failed: %@", error.localizedDescription)
        }
    }

    private func endpointURL(path: String) async -> URL? {
        let snapshot = PreferencesStore.loadSnapshot()
        guard let baseURL = URL(string: snapshot.apiBaseURL) else {
            NSLog("[LiveActivitySync] Invalid API base URL: %@", snapshot.apiBaseURL)
            return nil
        }
        return baseURL.appendingPathComponent(path)
    }

    private func sendJSONRequestReturningData(url: URL, payload: [String: Any], logContext: String) async -> Data? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        DeviceIdentity.applyHeader(to: &request)

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                NSLog("[LiveActivitySync] %@ failed: invalid response type", logContext)
                return nil
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "No response body"
                NSLog("[LiveActivitySync] %@ failed: HTTP %d - %@", logContext, httpResponse.statusCode, body)
                return nil
            }
            NSLog("[LiveActivitySync] %@ succeeded: HTTP %d", logContext, httpResponse.statusCode)
            return data
        } catch {
            NSLog("[LiveActivitySync] %@ failed: %@", logContext, error.localizedDescription)
            return nil
        }
    }

    private func sendJSONRequest(url: URL, payload: [String: Any], logContext: String) async {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        DeviceIdentity.applyHeader(to: &request)

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                NSLog("[LiveActivitySync] %@ failed: invalid response type", logContext)
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "No response body"
                NSLog("[LiveActivitySync] %@ failed: HTTP %d - %@", logContext, httpResponse.statusCode, body)
                return
            }
            NSLog("[LiveActivitySync] %@ succeeded: HTTP %d", logContext, httpResponse.statusCode)
        } catch {
            NSLog("[LiveActivitySync] %@ failed: %@", logContext, error.localizedDescription)
        }
    }

    private static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func shortHex(_ data: Data) -> String {
        String(hexString(from: data).prefix(16))
    }

    @available(iOS 16.1, *)
    private static func currentContentState(
        for activity: Activity<TopScoresLiveActivityAttributes>
    ) -> TopScoresLiveActivityAttributes.ContentState {
        activity.content.state
    }

    private static func contentStateSummary(_ state: TopScoresLiveActivityAttributes.ContentState) -> String {
        let matches = state.matches.prefix(4).map { match in
            let score: String
            if let home = match.homeScore, let away = match.awayScore {
                score = "\(home)-\(away)"
            } else {
                score = "nil"
            }
            let channels = match.tvChannels.isEmpty ? "noCh" : match.tvChannels.joined(separator: ",")
            return "\(match.displayHomeTeam) v \(match.displayAwayTeam) \(score) \(match.matchTime ?? "nil") ch=[\(channels)]"
        }.joined(separator: " | ")
        let fantasyScoreSummary = state.fantasyCurrentScore.map { " ff=\($0)" } ?? ""
        return "mode=\(state.mode) generatedAt=\(state.generatedAtEpochSeconds) delay=\(state.delayMinutes)\(fantasyScoreSummary) matches=\(state.matches.count) [\(matches)]"
    }

    private static func serverDebugSummary(_ json: [String: Any]) -> String {
        let liveActivity = json["liveActivity"] as? [String: Any]
        let serverPresentation = json["serverPresentation"] as? [String: Any]
        let currentActivityId = String(describing: liveActivity?["currentActivityId"] ?? "nil")
        let lastDispatchAt = String(describing: liveActivity?["lastDispatchAt"] ?? "nil")
        let currentActivityTokenUpdatedAt = String(describing: liveActivity?["currentActivityTokenUpdatedAt"] ?? "nil")
        let mode = String(describing: serverPresentation?["mode"] ?? "nil")
        let delayMinutes = String(describing: serverPresentation?["delayMinutes"] ?? "nil")
        let matches = (serverPresentation?["matches"] as? [[String: Any]] ?? []).prefix(4).map { match in
            let homeTeam = String(describing: match["homeTeam"] ?? "")
            let awayTeam = String(describing: match["awayTeam"] ?? "")
            let homeScore = String(describing: match["homeScore"] ?? "nil")
            let awayScore = String(describing: match["awayScore"] ?? "nil")
            let matchTime = String(describing: match["matchTime"] ?? "nil")
            let channels = (match["tvChannels"] as? [String] ?? [])
            let channelStr = channels.isEmpty ? "noCh" : channels.joined(separator: ",")
            return "\(homeTeam) v \(awayTeam) \(homeScore)-\(awayScore) \(matchTime) ch=[\(channelStr)]"
        }.joined(separator: " | ")
        let fantasyScore = String(describing: serverPresentation?["fantasyCurrentScore"] ?? "nil")
        return "activityId=\(currentActivityId) tokenUpdatedAt=\(currentActivityTokenUpdatedAt) lastDispatchAt=\(lastDispatchAt) serverMode=\(mode) delay=\(delayMinutes) ff=\(fantasyScore) matches=[\(matches)]"
    }
}
#else
final class LiveActivitySyncService {
    static let shared = LiveActivitySyncService()
    private init() {}
    func start() {}
    func reconcileOnForeground() {}
}
#endif
