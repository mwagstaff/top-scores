//
//  Top_Scores_WatchApp.swift
//  Top Scores Watch Watch App
//
//  Created by Mike Wagstaff on 12/02/2026.
//

import SwiftUI
import OSLog

@main
struct Top_Scores_Watch_Watch_AppApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var matchesStore = WatchMatchesStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(matchesStore)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                matchesStore.setSceneActive(true)
                WatchPerformanceDiagnostics.logger.notice("Scene became active")
                WatchMainThreadStallMonitor.shared.start()
                matchesStore.refresh(requestPhoneSync: true)
            } else {
                matchesStore.setSceneActive(false)
                WatchPerformanceDiagnostics.logger.notice("Scene left active state")
                WatchMainThreadStallMonitor.shared.stop()
            }
        }
    }
}
