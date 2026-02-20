//
//  Top_Scores_WatchApp.swift
//  Top Scores Watch Watch App
//
//  Created by Mike Wagstaff on 12/02/2026.
//

import SwiftUI

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
                matchesStore.refresh(requestPhoneSync: true)
            }
        }
    }
}
