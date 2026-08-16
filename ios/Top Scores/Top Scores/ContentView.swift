//
//  ContentView.swift
//  Top Scores
//
//  Created by Mike Wagstaff on 11/02/2026.
//

import Combine
import SwiftUI

struct ContentView: View {
    // Plain reference (not @EnvironmentObject) so ContentView does not re-render
    // on every store publish; MatchesView observes its own per-mode view state.
    let matchesStore: MatchesStore

    @AppStorage("fantasy.managerEntryID") private var fantasyManagerEntryID = ""
    @State private var selectedTab = 0
    @State private var fantasyTabBadge: String?
    @State private var fantasyTabShouldPulse = false
    @ObservedObject private var tablesNavigationCoordinator = TablesNavigationCoordinator.shared

    private static let tablesTabIndex = 1

    var body: some View {
        TabView(selection: $selectedTab) {
            MatchesView(mode: .fixtures, isSelected: selectedTab == 0, store: matchesStore)
                .tabItem {
                    Label("Scores", systemImage: "soccerball")
                }
                .tag(0)
            TablesView()
                .tabItem {
                    Label("Tables", systemImage: "tablecells")
                }
                .tag(1)
            FantasyView(isSelected: selectedTab == 2)
                .tabItem {
                    Label {
                        Text("FPL")
                    } icon: {
                        Image("FantasyPremierLeagueLionTab")
                            .renderingMode(.original)
                            .scaleEffect(fantasyTabShouldPulse ? 1.08 : 1.0)
                            .animation(
                                fantasyTabShouldPulse
                                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                                    : .default,
                                value: fantasyTabShouldPulse
                            )
                    }
                }
                .badge(fantasyTabBadge)
                .tag(2)
            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle")
                }
                .tag(3)
        }
        .background(Color(.systemBackground))
        .onChange(of: tablesNavigationCoordinator.pendingTarget) { _, newValue in
            guard newValue != nil else { return }
            if selectedTab != Self.tablesTabIndex {
                tablesNavigationCoordinator.setReturnTabIndex(selectedTab)
            }
            selectedTab = Self.tablesTabIndex
        }
        .onChange(of: tablesNavigationCoordinator.returnRequestToken) { _, _ in
            if let originTab = tablesNavigationCoordinator.consumeReturnTabIndex() {
                selectedTab = originTab
            }
        }
        .overlay {
            ContentLifecycleCoordinator(
                selectedTab: $selectedTab,
                fantasyManagerEntryID: fantasyManagerEntryID,
                fantasyTabBadge: $fantasyTabBadge,
                fantasyTabShouldPulse: $fantasyTabShouldPulse
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
    }
}

private struct ContentLifecycleCoordinator: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var matchesStore: MatchesStore
    @EnvironmentObject private var fantasyViewModel: FantasyViewModel
    @Environment(\.scenePhase) private var scenePhase

    @Binding var selectedTab: Int
    let fantasyManagerEntryID: String
    @Binding var fantasyTabBadge: String?
    @Binding var fantasyTabShouldPulse: Bool

    private let fantasyBackgroundRefreshTimer = Timer.publish(
        every: 300,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        Color.clear
            .onAppear {
                updateFantasyTabPresentation()
            }
            .onChange(of: fantasyManagerEntryID) { _, newValue in
                updateFantasyTabPresentation()
                Task {
                    await syncFantasyState(managerEntryID: newValue, squad: nil)
                }
            }
            .onChange(of: fantasyViewModel.data) { _, newValue in
                updateFantasyTabPresentation()
                Task {
                    await syncFantasyState(managerEntryID: fantasyManagerEntryID, squad: newValue)
                }
            }
            .onChange(of: fantasyViewModel.isSeasonActive) { _, _ in
                updateFantasyTabPresentation()
            }
            .onChange(of: matchesStore.matches) { _, _ in
                updateFantasyTabPresentation()
            }
            .task(id: fantasyManagerEntryID) {
                updateFantasyTabPresentation()
                await refreshFantasyInBackground()
            }
            .task(id: preferences.apiBaseURL) {
                await fantasyViewModel.refreshSeasonActiveStatus(apiBaseURL: preferences.apiBaseURL)
                await refreshFantasyInBackground()
                updateFantasyTabPresentation()
            }
            .onReceive(fantasyBackgroundRefreshTimer) { _ in
                guard scenePhase == .active else { return }
                Task {
                    await refreshFantasyInBackground()
                }
            }
            .onChange(of: preferences.snapshot) { _, _ in
                guard selectedTab != 0 else { return }
                let snapshot = preferences.showAllMatches ? preferences.unfilteredSnapshot : preferences.snapshot
                matchesStore.prepareForPreferencesChange(snapshot, publishVisibleState: false)
            }
            .onChange(of: preferences.showAllMatches) { _, newValue in
                guard selectedTab != 0 else { return }
                let snapshot = newValue ? preferences.unfilteredSnapshot : preferences.snapshot
                matchesStore.prepareForPreferencesChange(snapshot, publishVisibleState: false)
            }
    }

    private var trimmedFantasyManagerEntryID: String {
        fantasyManagerEntryID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refreshFantasyInBackground() async {
        guard !trimmedFantasyManagerEntryID.isEmpty else { return }

        let defaults = UserDefaults.standard
        let rivals = Self.decodeRivals(defaults.string(forKey: "fantasy.rivalManagersJSON"))
        let leagues = Self.decodeLeagues(defaults.string(forKey: "fantasy.trackedLeaguesJSON"))
        await fantasyViewModel.refreshInBackground(
            managerEntryID: trimmedFantasyManagerEntryID,
            apiBaseURL: preferences.apiBaseURL,
            rivalManagers: rivals,
            trackedLeagues: leagues
        )
    }

    private static func decodeRivals(_ value: String?) -> [FantasyRivalManager] {
        guard let value,
              let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([FantasyRivalManager].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func decodeLeagues(_ value: String?) -> [FantasyTrackedLeague] {
        guard let value,
              let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([FantasyTrackedLeague].self, from: data) else {
            return []
        }
        return decoded
    }

    private func updateFantasyTabPresentation() {
        let nextBadge: String?
        let nextShouldPulse: Bool

        if fantasyViewModel.isSeasonActive,
           !trimmedFantasyManagerEntryID.isEmpty,
           let squad = fantasyViewModel.data {
            nextBadge = "\(squad.resolvedCurrentScore)"
            nextShouldPulse = matchesStore.matches.contains { match in
                guard isPremierLeagueMatch(match), match.isInProgress else { return false }
                return squad.matchSquadSection(forTeamName: match.homeTeam)?.hasPlayers == true ||
                    squad.matchSquadSection(forTeamName: match.awayTeam)?.hasPlayers == true
            }
        } else {
            nextBadge = nil
            nextShouldPulse = false
        }

        if fantasyTabBadge != nextBadge {
            fantasyTabBadge = nextBadge
        }
        if fantasyTabShouldPulse != nextShouldPulse {
            fantasyTabShouldPulse = nextShouldPulse
        }
    }

    private func isPremierLeagueMatch(_ match: Match) -> Bool {
        match.league.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare("Premier League") == .orderedSame
    }

    private func syncFantasyState(
        managerEntryID: String,
        squad: FantasySquadDisplayData?
    ) async {
        FantasySyncStore.persist(managerEntryID: managerEntryID, squad: squad)
        await PreferencesSyncService.shared.syncPreferences(preferences.snapshot)
    }
}

#Preview {
    let store = MatchesStore()
    return ContentView(matchesStore: store)
        .environmentObject(PreferencesStore())
        .environmentObject(store)
        .environmentObject(FantasyViewModel())
}
