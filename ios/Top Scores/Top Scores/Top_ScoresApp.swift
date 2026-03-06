//
//  Top_ScoresApp.swift
//  Top Scores
//
//  Created by Mike Wagstaff on 11/02/2026.
//

import SwiftUI
import UserNotifications

@main
struct Top_ScoresApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var preferences = PreferencesStore()
    @StateObject private var matchesStore = MatchesStore()
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        NSLog("=====================================")
        NSLog("Top Scores App Init - BUILD TIMESTAMP: 2026-02-15 16:45:00")
        NSLog("=====================================")
        BackgroundRefreshManager.register()
        PhoneWatchSyncService.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(preferences)
                .environmentObject(matchesStore)
                .task {
                    async let teamRankingsWarmTask: Void = TeamRankingsCatalog.shared.ensureFresh(
                        apiBaseURL: preferences.snapshot.apiBaseURL
                    )
                    async let teamRankingSettingsWarmTask: Void =
                        TeamRankingSettingsCatalog.shared.ensureFresh(
                            apiBaseURL: preferences.snapshot.apiBaseURL
                        )
                    async let fantasyMappingsWarmTask: Void =
                        FantasyTeamShortNameMappingsCatalog.shared.ensureFresh(
                            apiBaseURL: preferences.snapshot.apiBaseURL
                        )
                    _ = await (
                        teamRankingsWarmTask,
                        teamRankingSettingsWarmTask,
                        fantasyMappingsWarmTask
                    )
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                BackgroundRefreshManager.scheduleNextRefresh(
                    intervalMinutes: preferences.refreshIntervalMinutes,
                    hasInProgressMatches: matchesStore.hasInProgressMatches
                )
            case .active:
                LiveActivitySyncService.shared.reconcileOnForeground()
                let snapshot = preferences.showAllMatches ? preferences.unfilteredSnapshot : preferences.snapshot
                Task {
                    async let refreshTask: Void = matchesStore.refresh(preferences: snapshot)
                    async let syncTask: Void = PreferencesSyncService.shared.syncPreferences(snapshot)
                    async let metricTask: Void = AppMetricsService.shared.sendAppOpenMetric(
                        apiBaseURL: snapshot.apiBaseURL
                    )
                    async let teamRankingWarmTask: Void = TeamRankingsCatalog.shared.ensureFresh(
                        apiBaseURL: snapshot.apiBaseURL
                    )
                    async let teamRankingSettingsWarmTask: Void =
                        TeamRankingSettingsCatalog.shared.ensureFresh(
                            apiBaseURL: snapshot.apiBaseURL
                        )
                    async let fantasyMappingsWarmTask: Void =
                        FantasyTeamShortNameMappingsCatalog.shared.ensureFresh(
                            apiBaseURL: snapshot.apiBaseURL
                        )
                    _ = await (
                        refreshTask,
                        syncTask,
                        metricTask,
                        teamRankingWarmTask,
                        teamRankingSettingsWarmTask,
                        fantasyMappingsWarmTask
                    )
                }
            default:
                break
            }
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        LiveActivitySyncService.shared.start()

        // Request notification authorization
        Task {
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
