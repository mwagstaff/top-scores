//
//  ContentView.swift
//  Top Scores
//
//  Created by Mike Wagstaff on 11/02/2026.
//

import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0

    var body: some View {
        GeometryReader { proxy in
            TabView(selection: $selectedTab) {
                MatchesView(mode: .fixtures)
                    .tabItem {
                        Label("Fixtures", systemImage: "calendar")
                    }
                    .tag(0)
                MatchesView(mode: .results)
                    .tabItem {
                        Label("Results", systemImage: "clock.arrow.circlepath")
                    }
                    .tag(1)
                PreferencesView()
                    .tabItem {
                        Label("Preferences", systemImage: "slider.horizontal.3")
                    }
                    .tag(2)
                AboutView()
                    .tabItem {
                        Label("About", systemImage: "info.circle")
                    }
                    .tag(3)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .background(Color(.systemBackground))
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(PreferencesStore())
        .environmentObject(MatchesStore())
}
