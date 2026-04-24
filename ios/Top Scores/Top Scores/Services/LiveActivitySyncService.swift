import Foundation
import os
import SwiftUI
import UIKit
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
    private let maxMatchesPerActivityPayload = 4

    private let lock = NSLock()
    private var started = false
    private var lastForegroundReconcileAt: Date?
    private var lastObservedScenePhase: ScenePhase = .background
    private let foregroundReconcileMinInterval: TimeInterval = 15
    private var pushToStartTask: Task<Void, Never>?
    private var activityUpdatesTask: Task<Void, Never>?
    private var foregroundReconcileTask: Task<Void, Never>?
    private var observedActivityIDs = Set<String>()
    private var activityPushTokenTasks: [String: Task<Void, Never>] = [:]
    private var activityContentTasks: [String: Task<Void, Never>] = [:]
    private var activityStateTasks: [String: Task<Void, Never>] = [:]
    private var lastUploadedPushToStartTokenHex: String?
    private var pendingPushToStartTokenData: Data?
    private var lastUploadedActivityPushTokenHexByActivityID: [String: String] = [:]
    private var pendingForegroundStartContentState: TopScoresLiveActivityAttributes.ContentState?
    private var pendingForegroundStartRetryTask: Task<Void, Never>?
    private var foregroundReconcileInFlight = false

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
                    self.flushSharedWidgetDiagnostics()
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
                    self.flushSharedWidgetDiagnostics()
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

        // Foreground reconciliation must wait until the app's scene is actually active.
        // start() now runs from didFinishLaunching so activity observers come up early,
        // but triggering a foreground Activity.request here can race before the scene
        // reaches .active and fail with "Target is not foreground".
    }

    func reconcileOnForeground() {
        guard #available(iOS 16.1, *) else { return }
        let now = Date()
        lock.lock()
        if let last = lastForegroundReconcileAt,
           now.timeIntervalSince(last) < foregroundReconcileMinInterval,
           lastObservedScenePhase == .active {
            NSLog(
                "[LiveActivitySync] reconcileOnForeground skipped due to rate limit elapsed=%.2f",
                now.timeIntervalSince(last)
            )
            lock.unlock()
            return
        }
        lastForegroundReconcileAt = now
        lock.unlock()

        NSLog(
            "[LiveActivitySync] reconcileOnForeground scheduling activeCount=%d",
            Activity<TopScoresLiveActivityAttributes>.activities.count
        )
        flushSharedWidgetDiagnostics()

        let shouldStartTask = lock.withLock { () -> Bool in
            if foregroundReconcileInFlight {
                NSLog("[LiveActivitySync] reconcileOnForeground skipped: reconcile already in flight")
                return false
            }
            foregroundReconcileInFlight = true
            return true
        }
        guard shouldStartTask else { return }

        let task = Task(priority: .background) {
            await self.reconcileLiveActivityStateOnForeground()
            self.lock.withLock {
                self.foregroundReconcileInFlight = false
                self.foregroundReconcileTask = nil
            }
        }
        lock.withLock {
            foregroundReconcileTask = task
        }
    }

    func handleScenePhaseChange(_ newPhase: ScenePhase) {
        let pendingStartToRetry: TopScoresLiveActivityAttributes.ContentState?
        let pendingPushToStartTokenData: Data?
        lock.lock()
        lastObservedScenePhase = newPhase
        pendingStartToRetry = newPhase == .active ? pendingForegroundStartContentState : nil
        pendingPushToStartTokenData = newPhase != .active ? self.pendingPushToStartTokenData : nil
        if newPhase != .active {
            lastForegroundReconcileAt = nil
        }
        lock.unlock()

        if newPhase != .active, let pendingPushToStartTokenData {
            Task(priority: .background) {
                await self.uploadPushToStartToken(pendingPushToStartTokenData)
            }
        }

        if newPhase == .active, let pendingStartToRetry {
            Task(priority: .userInitiated) {
                await self.retryPendingForegroundStartIfNeeded(contentState: pendingStartToRetry)
            }
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
        flushSharedWidgetDiagnostics()

        if let tokenData = activity.pushToken {
            NSLog(
                "[LiveActivitySync] Existing activity push token %@ token=%@",
                activityID,
                Self.shortHex(tokenData)
            )
            enqueueActivityPushTokenUpload(activityID: activityID, tokenData: tokenData)
        }

        let pushTokenTask = Task(priority: .background) {
            for await tokenData in activity.pushTokenUpdates {
                NSLog(
                    "[LiveActivitySync] Activity push token update %@ token=%@",
                    activityID,
                    Self.shortHex(tokenData)
                )
                self.flushSharedWidgetDiagnostics()
                self.enqueueActivityPushTokenUpload(activityID: activityID, tokenData: tokenData)
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
                    self.flushSharedWidgetDiagnostics()
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
                self.flushSharedWidgetDiagnostics()
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

    private func enqueueActivityPushTokenUpload(activityID: String, tokenData: Data) {
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            await self.uploadActivityPushToken(activityID: activityID, tokenData: tokenData)
        }
    }

    @available(iOS 16.1, *)
    private func reconcileLiveActivityStateOnForeground() async {
        let signpost = PerformanceSignposter.liveActivity.beginInterval("LiveActivityForegroundReconcile")
        defer { PerformanceSignposter.liveActivity.endInterval("LiveActivityForegroundReconcile", signpost) }

        guard !Task.isCancelled else { return }
        NSLog(
            "[LiveActivitySync] reconcileLiveActivityStateOnForeground begin activeCount=%d",
            Activity<TopScoresLiveActivityAttributes>.activities.count
        )
        flushSharedWidgetDiagnostics()

        let activeActivities = await enforceSingleActiveActivity(among: Activity<TopScoresLiveActivityAttributes>.activities)
        if activeActivities.isEmpty {
            NSLog("[LiveActivitySync] Foreground reconcile found no active local activities")
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
        guard !Task.isCancelled else { return }
        // If no active activity and the server has live content, start one directly
        // so push-to-start (which requires background) is not the only path.
        // Re-check Activity.activities here rather than using the snapshot captured before
        // the HTTP call, in case a push-to-start arrived during the round-trip.
        let currentActivities = Activity<TopScoresLiveActivityAttributes>.activities
        NSLog(
            "[LiveActivitySync] reconcile response currentActiveCount=%d hasForegroundStart=%d",
            currentActivities.count,
            reconcileResponse == nil ? 0 : 1
        )
        flushSharedWidgetDiagnostics()
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

        // Upload the survivor's push token BEFORE ending duplicates so the server
        // registers the correct activity before any activity-ended call arrives.
        // This prevents a race where activity-ended (for a duplicate) clears the
        // server state before the survivor's token upload lands, causing the server
        // to fire another push-to-start and creating an infinite loop.
        if let survivorToken = survivor.pushToken {
            await uploadActivityPushToken(activityID: survivor.id, tokenData: survivorToken)
            NSLog("[LiveActivitySync] Pre-uploaded survivor token before ending duplicates %@", survivor.id)
        }

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
        let isAppActive = await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
        if isAppActive {
            lock.withLock {
                pendingPushToStartTokenData = tokenData
            }
            NSLog("[LiveActivitySync] Deferring push-to-start token upload while app is active")
            return
        }

        let shouldUpload = lock.withLock {
            let shouldUpload = lastUploadedPushToStartTokenHex != tokenHex
            if shouldUpload {
                lastUploadedPushToStartTokenHex = tokenHex
                pendingPushToStartTokenData = nil
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
        let generatedAtEpochSeconds = Self.currentContentState(for: activityID)?.generatedAtEpochSeconds
        let payload: [String: Any] = [
            "deviceToken": DeviceIdentity.currentToken,
            "activityId": activityID,
            "activityPushToken": tokenHex,
            "activityGeneratedAtEpochSeconds": generatedAtEpochSeconds as Any,
            "isDevelopmentBuild": await MainActor.run { NotificationManager.shared.isDevelopmentBuild }
        ]
        await sendJSONRequest(url: endpoint, payload: payload, logContext: "activity-token")
    }

    private func uploadActivityStarted(
        activityID: String,
        generatedAtEpochSeconds: Int?,
        contentState: TopScoresLiveActivityAttributes.ContentState
    ) async {
        guard let endpoint = await endpointURL(path: "live-activity/activity-started") else { return }
        let encoder = JSONEncoder()
        let encodedContentState = try? encoder.encode(contentState)
        let contentStateJSONObject = encodedContentState.flatMap { data in
            try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        let payload: [String: Any] = [
            "deviceToken": DeviceIdentity.currentToken,
            "activityId": activityID,
            "activityGeneratedAtEpochSeconds": generatedAtEpochSeconds as Any,
            "contentState": contentStateJSONObject as Any,
            "isDevelopmentBuild": await MainActor.run { NotificationManager.shared.isDevelopmentBuild }
        ]
        await sendJSONRequest(url: endpoint, payload: payload, logContext: "activity-started")
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
        let activeActivities = Activity<TopScoresLiveActivityAttributes>.activities
        let payload: [String: Any] = [
            "deviceToken": DeviceIdentity.currentToken,
            "isDevelopmentBuild": await MainActor.run { NotificationManager.shared.isDevelopmentBuild },
            "force": activeActivities.isEmpty,
            "trigger": "app_foreground",
            "activeActivityCount": activeActivities.count,
            "activeActivityIds": activeActivities.map { $0.id }
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
        let sanitized = sanitizedContentState(contentState)
        if sanitized.matches.count != contentState.matches.count {
            NSLog(
                "[LiveActivitySync] Trimmed foreground content state matches from %d to %d",
                contentState.matches.count,
                sanitized.matches.count
            )
        }
        return sanitized
    }

    @available(iOS 16.1, *)
    private func startForegroundActivityIfNeeded(contentState: TopScoresLiveActivityAttributes.ContentState) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            NSLog("[LiveActivitySync] Foreground start skipped: activities not enabled")
            await reportForegroundStartFailed(reason: "activities_not_enabled")
            return
        }
        let isAppActive = await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
        guard isAppActive else {
            NSLog("[LiveActivitySync] Foreground start skipped: app is not active")
            lock.withLock {
                pendingForegroundStartContentState = contentState
            }
            schedulePendingForegroundStartRetry()
            return
        }
        do {
            let attributes = TopScoresLiveActivityAttributes(appScope: "top-scores")
            let sanitizedState = sanitizedContentState(contentState)
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: sanitizedState, staleDate: nil),
                pushType: .token
            )
            NSLog("[LiveActivitySync] Foreground start succeeded activityId=%@", activity.id)
            flushSharedWidgetDiagnostics()
            lock.withLock {
                pendingForegroundStartContentState = nil
                pendingForegroundStartRetryTask?.cancel()
                pendingForegroundStartRetryTask = nil
            }
            await uploadActivityStarted(
                activityID: activity.id,
                generatedAtEpochSeconds: sanitizedState.generatedAtEpochSeconds,
                contentState: sanitizedState
            )
            // Register immediately — don't rely solely on activityUpdatesTask picking this up
            beginObserving(activity)
        } catch {
            NSLog("[LiveActivitySync] Foreground start failed: %@", error.localizedDescription)
            await reportForegroundStartFailed(reason: error.localizedDescription)
        }
    }

    @available(iOS 16.1, *)
    private func retryPendingForegroundStartIfNeeded(
        contentState: TopScoresLiveActivityAttributes.ContentState
    ) async {
        let shouldRetry = lock.withLock {
            guard let pendingForegroundStartContentState else { return false }
            return pendingForegroundStartContentState == contentState
        }
        guard shouldRetry else { return }
        guard Activity<TopScoresLiveActivityAttributes>.activities.isEmpty else {
            lock.withLock {
                pendingForegroundStartContentState = nil
            }
            return
        }
        NSLog("[LiveActivitySync] Retrying pending foreground start on active scene")
        await startForegroundActivityIfNeeded(contentState: contentState)
    }

    private func schedulePendingForegroundStartRetry() {
        let shouldSchedule = lock.withLock {
            if pendingForegroundStartRetryTask != nil {
                return false
            }
            return pendingForegroundStartContentState != nil
        }
        guard shouldSchedule else { return }

        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                self.lock.withLock {
                    self.pendingForegroundStartRetryTask = nil
                }
            }
            for _ in 0..<120 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }

                let pendingContentState = self.lock.withLock { self.pendingForegroundStartContentState }
                guard let pendingContentState else { return }

                let isAppActive = await MainActor.run {
                    UIApplication.shared.applicationState == .active
                }
                guard isAppActive else { continue }

                guard #available(iOS 16.1, *) else { return }
                if Activity<TopScoresLiveActivityAttributes>.activities.isEmpty {
                    NSLog("[LiveActivitySync] Retrying pending foreground start after delayed active transition")
                    await self.startForegroundActivityIfNeeded(contentState: pendingContentState)
                }
                return
            }
        }

        lock.withLock {
            pendingForegroundStartRetryTask = task
        }
    }

    private func reportForegroundStartFailed(reason: String) async {
        guard let endpoint = await endpointURL(path: "live-activity/foreground-start-failed") else { return }
        let payload: [String: Any] = [
            "deviceToken": DeviceIdentity.currentToken,
            "isDevelopmentBuild": await MainActor.run { NotificationManager.shared.isDevelopmentBuild },
            "error": reason
        ]
        await sendJSONRequest(url: endpoint, payload: payload, logContext: "foreground-start-failed")
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

    private func flushSharedWidgetDiagnostics() {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroupConfig.identifier)?
            .appendingPathComponent(AppGroupConfig.liveActivityDiagnosticsFileName)
        else { return }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        let entries = contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard !entries.isEmpty else { return }

        try? FileManager.default.removeItem(at: url)
        for entry in entries {
            NSLog("%@", entry)
        }
    }

    private func sanitizedContentState(
        _ state: TopScoresLiveActivityAttributes.ContentState
    ) -> TopScoresLiveActivityAttributes.ContentState {
        let trimmedMatches = Array(state.matches.prefix(maxMatchesPerActivityPayload))
        guard trimmedMatches.count != state.matches.count else { return state }
        return TopScoresLiveActivityAttributes.ContentState(
            mode: state.mode,
            generatedAtEpochSeconds: state.generatedAtEpochSeconds,
            delayMinutes: state.delayMinutes,
            fantasyCurrentScore: state.fantasyCurrentScore,
            matches: trimmedMatches
        )
    }

    private static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func shortHex(_ data: Data) -> String {
        String(hexString(from: data).prefix(16))
    }

    @available(iOS 16.1, *)
    private static func currentContentState(
        for activityID: String
    ) -> TopScoresLiveActivityAttributes.ContentState? {
        Activity<TopScoresLiveActivityAttributes>.activities.first(where: { $0.id == activityID })?.content.state
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
        let payloadMetrics = (serverPresentation?["debug"] as? [String: Any])?["payloadMetrics"] as? [String: Any]
        let contentStateBytes = String(describing: payloadMetrics?["contentStateBytes"] ?? "nil")
        let archiveEstimateBytes = String(describing: payloadMetrics?["archiveEstimateBytes"] ?? "nil")
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
        return "activityId=\(currentActivityId) tokenUpdatedAt=\(currentActivityTokenUpdatedAt) lastDispatchAt=\(lastDispatchAt) serverMode=\(mode) delay=\(delayMinutes) ff=\(fantasyScore) contentStateBytes=\(contentStateBytes) archiveEstimateBytes=\(archiveEstimateBytes) matches=[\(matches)]"
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
