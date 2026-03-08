import Foundation
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
    let homeScore: Int?
    let awayScore: Int?
    let aggregateHomeScore: Int?
    let aggregateAwayScore: Int?
    let matchTime: String?
    let homeTeamScore: Double?
    let awayTeamScore: Double?
    let totalTeamScore: Double?
    let tvChannels: [String]
}

@available(iOS 16.1, *)
struct TopScoresLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let mode: String
        let generatedAtEpochSeconds: Int
        let delayMinutes: Int
        let delayLabel: String?
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
    private var activityStateTasks: [String: Task<Void, Never>] = [:]

    private init() {}

    func start() {
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
            for activity in Activity<TopScoresLiveActivityAttributes>.activities {
                beginObserving(activity)
            }

            activityUpdatesTask = Task(priority: .background) {
                for await activity in Activity<TopScoresLiveActivityAttributes>.activityUpdates {
                    self.beginObserving(activity)
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

        let pushTokenTask = Task(priority: .background) {
            for await tokenData in activity.pushTokenUpdates {
                await self.uploadActivityPushToken(activityID: activityID, tokenData: tokenData)
            }
        }

        let stateTask = Task(priority: .background) {
            var ended = false
            for await state in activity.activityStateUpdates {
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
        activityStateTasks[activityID] = stateTask
        lock.unlock()
    }

    private func stopObserving(activityID: String, cancelStateTask: Bool) {
        lock.lock()
        let pushTask = activityPushTokenTasks.removeValue(forKey: activityID)
        let stateTask = activityStateTasks.removeValue(forKey: activityID)
        observedActivityIDs.remove(activityID)
        lock.unlock()

        pushTask?.cancel()
        if cancelStateTask {
            stateTask?.cancel()
        }
    }

    @available(iOS 16.1, *)
    private func reconcileLiveActivityStateOnForeground() async {
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
                    "[LiveActivitySync] Foreground reconcile active activity %@ mode=%@ matches=%d generatedAt=%d",
                    activity.id,
                    activity.contentState.mode,
                    activity.contentState.matches.count,
                    activity.contentState.generatedAtEpochSeconds
                )
                if let tokenData = activity.pushToken {
                    await uploadActivityPushToken(activityID: activity.id, tokenData: tokenData)
                }
            }
        }
        await requestLiveActivityReconcile()
    }

    @available(iOS 16.1, *)
    private func enforceSingleActiveActivity(
        among activities: [Activity<TopScoresLiveActivityAttributes>]
    ) async -> [Activity<TopScoresLiveActivityAttributes>] {
        guard activities.count > 1 else { return activities }

        let sortedActivities = activities.sorted { lhs, rhs in
            if lhs.contentState.generatedAtEpochSeconds != rhs.contentState.generatedAtEpochSeconds {
                return lhs.contentState.generatedAtEpochSeconds > rhs.contentState.generatedAtEpochSeconds
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
        guard let endpoint = endpointURL(path: "live-activity/push-to-start-token") else { return }
        let payload: [String: Any] = [
            "deviceToken": DeviceIdentity.currentToken,
            "pushToStartToken": Self.hexString(from: tokenData),
            "isDevelopmentBuild": await MainActor.run { NotificationManager.shared.isDevelopmentBuild }
        ]
        await sendJSONRequest(url: endpoint, payload: payload, logContext: "push-to-start")
    }

    private func uploadActivityPushToken(activityID: String, tokenData: Data) async {
        guard let endpoint = endpointURL(path: "live-activity/activity-token") else { return }
        let payload: [String: Any] = [
            "deviceToken": DeviceIdentity.currentToken,
            "activityId": activityID,
            "activityPushToken": Self.hexString(from: tokenData),
            "isDevelopmentBuild": await MainActor.run { NotificationManager.shared.isDevelopmentBuild }
        ]
        await sendJSONRequest(url: endpoint, payload: payload, logContext: "activity-token")
    }

    private func uploadActivityEnded(activityID: String) async {
        guard let endpoint = endpointURL(path: "live-activity/activity-ended") else { return }
        let payload: [String: Any] = [
            "deviceToken": DeviceIdentity.currentToken,
            "activityId": activityID,
            "isDevelopmentBuild": await MainActor.run { NotificationManager.shared.isDevelopmentBuild }
        ]
        await sendJSONRequest(url: endpoint, payload: payload, logContext: "activity-ended")
    }

    private func requestLiveActivityReconcile() async {
        guard let endpoint = endpointURL(path: "live-activity/reconcile") else { return }
        let payload: [String: Any] = [
            "deviceToken": DeviceIdentity.currentToken,
            "isDevelopmentBuild": await MainActor.run { NotificationManager.shared.isDevelopmentBuild }
        ]
        await sendJSONRequest(url: endpoint, payload: payload, logContext: "live-activity-reconcile")
    }

    private func endpointURL(path: String) -> URL? {
        let snapshot = PreferencesStore.loadSnapshot()
        guard let baseURL = URL(string: snapshot.apiBaseURL) else {
            NSLog("[LiveActivitySync] Invalid API base URL: %@", snapshot.apiBaseURL)
            return nil
        }
        return baseURL.appendingPathComponent(path)
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
        } catch {
            NSLog("[LiveActivitySync] %@ failed: %@", logContext, error.localizedDescription)
        }
    }

    private static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
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
