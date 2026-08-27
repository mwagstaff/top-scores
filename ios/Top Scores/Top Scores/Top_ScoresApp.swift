//
//  Top_ScoresApp.swift
//  Top Scores
//
//  Created by Mike Wagstaff on 11/02/2026.
//

import SwiftUI
import UserNotifications
import os

@main
struct Top_ScoresApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var preferences = PreferencesStore()
    @StateObject private var matchesStore = MatchesStore()
    @StateObject private var fantasyViewModel = FantasyViewModel()
    @StateObject private var stadiumBackdropStore = StadiumBackdropStore()
    @StateObject private var stadiumArtworkStore = StadiumArtworkStore()
    @State private var deferredStartupWorkTask: Task<Void, Never>?
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    private let startupDeferredDelayNanos: UInt64 = 8_000_000_000
    private let startupDeferredSpacingNanos: UInt64 = 2_000_000_000

    init() {
        PerformanceSignposter.startup.emitEvent("AppInit")
        BackgroundRefreshManager.register()
        PhoneWatchSyncService.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(matchesStore: matchesStore)
                .environmentObject(preferences)
                .environmentObject(matchesStore)
                .environmentObject(fantasyViewModel)
                .environmentObject(stadiumArtworkStore)
                .environment(\.stadiumBackdropAssetName, stadiumBackdropStore.assetName)
                .task {
                    await stadiumBackdropStore.runHourlyRotation()
                }
                .task(id: preferences.apiBaseURL) {
                    await TopTeamsPresetStore.shared.ensureFresh(
                        apiBaseURL: preferences.apiBaseURL
                    )
                }
                .task(id: preferences.apiBaseURL) {
                    await stadiumArtworkStore.ensureFresh(
                        apiBaseURL: preferences.apiBaseURL
                    )
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            diagnosticLog("[TopScoresApp] scenePhase changed to %@", String(describing: newPhase))
            LiveActivitySyncService.shared.handleScenePhaseChange(newPhase)
            switch newPhase {
            case .background:
                deferredStartupWorkTask?.cancel()
                deferredStartupWorkTask = nil
                BackgroundRefreshManager.scheduleNextRefresh(
                    intervalMinutes: preferences.refreshIntervalMinutes
                )
            case .active:
                diagnosticLog("[TopScoresApp] scenePhase active -> reconcileOnForeground")
                stadiumBackdropStore.rotateIfNeeded()
                LiveActivitySyncService.shared.reconcileOnForeground()
                let snapshot = preferences.showAllMatches ? preferences.unfilteredSnapshot : preferences.snapshot
                matchesStore.refreshOnForeground(preferences: snapshot)
                Task {
                    await TopTeamsPresetStore.shared.ensureFresh(
                        apiBaseURL: preferences.apiBaseURL
                    )
                }
                Task {
                    await stadiumArtworkStore.ensureFresh(
                        apiBaseURL: preferences.apiBaseURL
                    )
                }
                scheduleDeferredStartupWork(snapshot: preferences.snapshot)
            default:
                break
            }
        }
    }

    private func scheduleDeferredStartupWork(snapshot: PreferencesSnapshot) {
        deferredStartupWorkTask?.cancel()
        deferredStartupWorkTask = Task(priority: .utility) {
            let taskState = PerformanceSignposter.startup.beginInterval("DeferredStartupWork")
            defer { PerformanceSignposter.startup.endInterval("DeferredStartupWork", taskState) }

            try? await Task.sleep(nanoseconds: startupDeferredDelayNanos)
            guard !Task.isCancelled else { return }

            PerformanceSignposter.startup.emitEvent("DeferredStartupPreferencesSync")
            await PreferencesSyncService.shared.syncPreferences(snapshot)
            guard !Task.isCancelled else { return }

            try? await Task.sleep(nanoseconds: startupDeferredSpacingNanos)
            guard !Task.isCancelled else { return }

            PerformanceSignposter.startup.emitEvent("DeferredStartupAppMetric")
            await AppMetricsService.shared.sendAppOpenMetric(apiBaseURL: snapshot.apiBaseURL)
            guard !Task.isCancelled else { return }

            try? await Task.sleep(nanoseconds: startupDeferredSpacingNanos)
            guard !Task.isCancelled else { return }

            PerformanceSignposter.startup.emitEvent("DeferredStartupMissingLogoAuditCleanup")
            await MissingTeamLogoAuditCleanupService.shared.pruneIfNeeded(
                apiBaseURL: snapshot.apiBaseURL
            )
            guard !Task.isCancelled else { return }

            try? await Task.sleep(nanoseconds: startupDeferredSpacingNanos)
            guard !Task.isCancelled else { return }

            PerformanceSignposter.startup.emitEvent("DeferredStartupLeagueTablesPrefetch")
            await LeagueTablesCatalog.shared.prefetch(apiBaseURL: snapshot.apiBaseURL)
            guard !Task.isCancelled else { return }

            try? await Task.sleep(nanoseconds: startupDeferredSpacingNanos)
            guard !Task.isCancelled else { return }

            PerformanceSignposter.startup.emitEvent("DeferredStartupTeamRatingSettings")
            await TeamRankingSettingsCatalog.shared.ensureFresh(apiBaseURL: snapshot.apiBaseURL)
            guard !Task.isCancelled else { return }

            try? await Task.sleep(nanoseconds: startupDeferredSpacingNanos)
            guard !Task.isCancelled else { return }

            PerformanceSignposter.startup.emitEvent("DeferredStartupTeamRatings")
            await TeamRankingsCatalog.shared.ensureFresh(apiBaseURL: snapshot.apiBaseURL)
            guard !Task.isCancelled else { return }

            try? await Task.sleep(nanoseconds: startupDeferredSpacingNanos)
            guard !Task.isCancelled else { return }

            PerformanceSignposter.startup.emitEvent("DeferredStartupPredictions")
            await PredictionsCatalog.shared.ensureFresh(apiBaseURL: snapshot.apiBaseURL)
            guard !Task.isCancelled else { return }

            try? await Task.sleep(nanoseconds: startupDeferredSpacingNanos)
            guard !Task.isCancelled else { return }

            PerformanceSignposter.startup.emitEvent("DeferredStartupFantasyLoadingMessages")
            await FantasyLoadingMessagesCatalog.shared.ensureFresh(apiBaseURL: snapshot.apiBaseURL)
            guard !Task.isCancelled else { return }

            try? await Task.sleep(nanoseconds: startupDeferredSpacingNanos)
            guard !Task.isCancelled else { return }

            PerformanceSignposter.startup.emitEvent("DeferredStartupTeamColors")
            await TeamColorCatalog.shared.ensureFresh(apiBaseURL: snapshot.apiBaseURL)
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private let notificationAuthorizationDelayNanos: UInt64 = 12_000_000_000

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PerformanceSignposter.startup.emitEvent("AppDidFinishLaunching")
        UNUserNotificationCenter.current().delegate = self
        // start() only creates background Tasks — calling it here (before scenePhase
        // transitions to .active) ensures activityUpdatesTask is running before
        // reconcileOnForeground() fires, preventing a race where the server dispatches
        // a push-to-start into an unobserved window and creates a duplicate activity.
        let signpost = PerformanceSignposter.startup.beginInterval("LiveActivityStartup")
        LiveActivitySyncService.shared.start()
        PerformanceSignposter.startup.endInterval("LiveActivityStartup", signpost)

        Task {
            try? await Task.sleep(nanoseconds: notificationAuthorizationDelayNanos)
            let signpost = PerformanceSignposter.startup.beginInterval("NotificationAuthorization")
            defer { PerformanceSignposter.startup.endInterval("NotificationAuthorization", signpost) }
            await NotificationManager.shared.requestAuthorization()
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        diagnosticLog("[APNS] Successfully registered for remote notifications")
        diagnosticLog("[APNS] Device token: %@", tokenString.prefix(12) + "...")

        // Store the APNS token
        Task {
            await NotificationManager.shared.updateDeviceToken(tokenString)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        diagnosticLog("[APNS] Failed to register for remote notifications: %@", error.localizedDescription)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        diagnosticLog("[APNS] Foreground push received: %@", notification.request.identifier)
        completionHandler([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        diagnosticLog("[APNS] User interacted with push: %@", response.notification.request.identifier)
        completionHandler()
    }
}

actor MissingTeamLogoAuditCleanupService {
    static let shared = MissingTeamLogoAuditCleanupService()

    private var attemptedBaseURLs = Set<String>()

    func pruneIfNeeded(apiBaseURL: String) async {
        let trimmedBaseURL = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBaseURL.isEmpty else { return }
        guard attemptedBaseURLs.insert(trimmedBaseURL).inserted else { return }
        guard let baseURL = URL(string: trimmedBaseURL) else { return }

        let signpost = PerformanceSignposter.startup.beginInterval("MissingLogoAuditCleanup")
        defer { PerformanceSignposter.startup.endInterval("MissingLogoAuditCleanup", signpost) }

        let client = APIClient(baseURL: baseURL)

        do {
            async let missingTask = client.fetchMissingTeamLogosAudit()
            async let shortNamesTask = client.fetchTeamShortNames()
            let (missingTeamNames, shortNamesResponse) = try await (missingTask, shortNamesTask)
            guard !missingTeamNames.isEmpty else { return }

            let alternateLookup = Self.buildAlternateLookup(shortNames: shortNamesResponse.shortNames)
            let resolvedEntries = await MainActor.run {
                missingTeamNames.filter { teamName in
                    let alternates = alternateLookup[Self.normalizedTeamKey(teamName)] ?? []
                    return LogoResolver.shared.hasDedicatedLogo(
                        for: teamName,
                        alternateNames: alternates
                    )
                }
            }

            guard !resolvedEntries.isEmpty else { return }
            try await client.removeMissingTeamLogosAuditEntries(resolvedEntries)
            diagnosticLog(
                "[MissingTeamLogoAuditCleanup] removed_count=%d names=%@",
                resolvedEntries.count,
                resolvedEntries.joined(separator: ", ")
            )
        } catch {
            diagnosticLog(
                "[MissingTeamLogoAuditCleanup] failed api_base_url=%@ error=%@",
                trimmedBaseURL,
                String(describing: error)
            )
        }
    }

    private static func buildAlternateLookup(shortNames: [String: String]) -> [String: [String]] {
        var output: [String: [String]] = [:]

        func add(_ source: String, _ candidate: String) {
            let sourceKey = normalizedTeamKey(source)
            let normalizedCandidate = normalizedDisplayName(candidate)
            guard !sourceKey.isEmpty, !normalizedCandidate.isEmpty else { return }

            var existing = output[sourceKey] ?? []
            if !existing.contains(where: { normalizedTeamKey($0) == normalizedTeamKey(normalizedCandidate) }) {
                existing.append(normalizedCandidate)
            }
            output[sourceKey] = existing
        }

        for (name, shortName) in shortNames {
            add(name, shortName)
            add(shortName, name)
        }

        return output
    }

    private static func normalizedDisplayName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func normalizedTeamKey(_ value: String) -> String {
        normalizedDisplayName(value).lowercased()
    }
}
