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
    @State private var deferredStartupWorkTask: Task<Void, Never>?
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    private let startupDeferredDelayNanos: UInt64 = 8_000_000_000
    private let startupDeferredSpacingNanos: UInt64 = 2_000_000_000

    init() {
        NSLog("=====================================")
        NSLog("Top Scores App Init - BUILD TIMESTAMP: 2026-02-15 16:45:00")
        NSLog("=====================================")
        PerformanceSignposter.startup.emitEvent("AppInit")
        BackgroundRefreshManager.register()
        PhoneWatchSyncService.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(preferences)
                .environmentObject(matchesStore)
                .environmentObject(fantasyViewModel)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                deferredStartupWorkTask?.cancel()
                deferredStartupWorkTask = nil
                BackgroundRefreshManager.scheduleNextRefresh(
                    intervalMinutes: preferences.refreshIntervalMinutes,
                    hasInProgressMatches: matchesStore.hasInProgressMatches
                )
            case .active:
                LiveActivitySyncService.shared.reconcileOnForeground()
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
    private let liveActivityStartupDelayNanos: UInt64 = 5_000_000_000
    private let notificationAuthorizationDelayNanos: UInt64 = 12_000_000_000

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PerformanceSignposter.startup.emitEvent("AppDidFinishLaunching")
        UNUserNotificationCenter.current().delegate = self
        Task {
            try? await Task.sleep(nanoseconds: liveActivityStartupDelayNanos)
            let signpost = PerformanceSignposter.startup.beginInterval("LiveActivityStartup")
            defer { PerformanceSignposter.startup.endInterval("LiveActivityStartup", signpost) }
            LiveActivitySyncService.shared.start()
        }

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
        NSLog("[APNS] Successfully registered for remote notifications")
        NSLog("[APNS] Device token: %@", tokenString.prefix(12) + "...")

        // Store the APNS token
        Task {
            await NotificationManager.shared.updateDeviceToken(tokenString)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("[APNS] Failed to register for remote notifications: %@", error.localizedDescription)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        NSLog("[APNS] Foreground push received: %@", notification.request.identifier)
        completionHandler([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        NSLog("[APNS] User interacted with push: %@", response.notification.request.identifier)
        completionHandler()
    }
}
