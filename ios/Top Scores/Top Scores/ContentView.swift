//
//  ContentView.swift
//  Top Scores
//
//  Created by Mike Wagstaff on 11/02/2026.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var matchesStore: MatchesStore
    @EnvironmentObject private var fantasyViewModel: FantasyViewModel
    @AppStorage("fantasy.managerEntryID") private var fantasyManagerEntryID = ""
    @State private var selectedTab = 0
    @State private var deferredFantasyRefreshTask: Task<Void, Never>?

    private let fantasyLiveRefreshInterval: TimeInterval = 30
    private let fantasyIdleRefreshInterval: TimeInterval = 5 * 60
    private let fantasyStartupDelayNanos: UInt64 = 10_000_000_000

    var body: some View {
        GeometryReader { proxy in
            TabView(selection: $selectedTab) {
                MatchesView(mode: .fixtures, isSelected: selectedTab == 0)
                    .tabItem {
                        Label("Fixtures", systemImage: "calendar")
                    }
                    .tag(0)
                MatchesView(mode: .results, isSelected: selectedTab == 1)
                    .tabItem {
                        Label("Results", systemImage: "clock.arrow.circlepath")
                    }
                    .tag(1)
                TablesView()
                    .tabItem {
                        Label("Tables", systemImage: "tablecells")
                    }
                    .tag(2)
                FantasyView(isSelected: selectedTab == 3)
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
                    .tag(3)
                ProfileView()
                    .tabItem {
                        Label("Profile", systemImage: "person.crop.circle")
                    }
                    .tag(4)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .background(Color(.systemBackground))
            .onChange(of: selectedTab) { _, newValue in
                guard newValue == 3 else { return }
                deferredFantasyRefreshTask?.cancel()
                deferredFantasyRefreshTask = Task {
                    await refreshFantasySummaryIfNeeded(force: false)
                }
            }
            .onChange(of: fantasyManagerEntryID) { _, newValue in
                Task {
                    await syncFantasyState(managerEntryID: newValue, squad: nil)
                }
            }
            .onChange(of: fantasyViewModel.data) { _, newValue in
                Task {
                    await syncFantasyState(managerEntryID: fantasyManagerEntryID, squad: newValue)
                }
            }
            .task(id: fantasyManagerEntryID) {
                deferredFantasyRefreshTask?.cancel()
                deferredFantasyRefreshTask = Task {
                    if selectedTab != 3 {
                        try? await Task.sleep(nanoseconds: fantasyStartupDelayNanos)
                    }
                    guard !Task.isCancelled else { return }
                    await refreshFantasySummaryIfNeeded(force: selectedTab == 3)
                }
            }
            .task(id: preferences.apiBaseURL) {
                await refreshCompetitionCatalogIfNeeded(force: true)
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                deferredFantasyRefreshTask?.cancel()
                Task {
                    await refreshCompetitionCatalogIfNeeded(force: false)
                }
                deferredFantasyRefreshTask = Task {
                    if selectedTab != 3 {
                        try? await Task.sleep(nanoseconds: fantasyStartupDelayNanos)
                    }
                    guard !Task.isCancelled else { return }
                    await refreshFantasySummaryIfNeeded(force: false)
                }
            }
            .onChange(of: preferences.snapshot) { _, _ in
                guard selectedTab != 0, selectedTab != 1 else { return }
                let snapshot = preferences.showAllMatches ? preferences.unfilteredSnapshot : preferences.snapshot
                matchesStore.prepareForPreferencesChange(snapshot, publishVisibleState: false)
            }
            .onChange(of: preferences.showAllMatches) { _, newValue in
                guard selectedTab != 0, selectedTab != 1 else { return }
                let snapshot = newValue ? preferences.unfilteredSnapshot : preferences.snapshot
                matchesStore.prepareForPreferencesChange(snapshot, publishVisibleState: false)
            }
        }
    }

    private var trimmedFantasyManagerEntryID: String {
        fantasyManagerEntryID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var fantasyTabBadge: String? {
        guard !trimmedFantasyManagerEntryID.isEmpty,
              let score = fantasyViewModel.data?.resolvedCurrentScore else {
            return nil
        }

        return "\(score)"
    }

    private var fantasyTabShouldPulse: Bool {
        guard !trimmedFantasyManagerEntryID.isEmpty,
              let squad = fantasyViewModel.data else {
            return false
        }

        return matchesStore.matches.contains { match in
            guard isPremierLeagueMatch(match), match.isInProgress else { return false }
            return squad.matchSquadSection(forTeamName: match.homeTeam)?.hasPlayers == true ||
                squad.matchSquadSection(forTeamName: match.awayTeam)?.hasPlayers == true
        }
    }

    private func isPremierLeagueMatch(_ match: Match) -> Bool {
        match.league.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare("Premier League") == .orderedSame
    }

    private var fantasySummaryRefreshInterval: TimeInterval {
        fantasyViewModel.data?.hasActiveFixtures == true
            ? fantasyLiveRefreshInterval
            : fantasyIdleRefreshInterval
    }

    private func refreshFantasySummaryIfNeeded(force: Bool) async {
        let managerEntryID = trimmedFantasyManagerEntryID
        guard !managerEntryID.isEmpty else { return }
        guard !fantasyViewModel.isLoading, !fantasyViewModel.isRefreshing else { return }

        if !force,
           let lastUpdated = fantasyViewModel.lastUpdated,
           fantasyViewModel.data != nil,
           Date().timeIntervalSince(lastUpdated) < fantasySummaryRefreshInterval {
            return
        }

        await fantasyViewModel.refresh(
            managerEntryID: managerEntryID,
            apiBaseURL: preferences.apiBaseURL,
            rivalManagers: [],
            trackedLeagues: []
        )
    }

    private func refreshCompetitionCatalogIfNeeded(force: Bool) async {
        let snapshot = preferences.showAllMatches ? preferences.unfilteredSnapshot : preferences.snapshot
        let didRefresh = await CompetitionWeightConfig.refreshIfNeeded(
            apiBaseURL: snapshot.apiBaseURL,
            force: force
        )
        guard didRefresh else { return }
        await MainActor.run {
            matchesStore.refreshCompetitionCatalog(using: snapshot, publishVisibleState: true)
        }
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
    ContentView()
        .environmentObject(PreferencesStore())
        .environmentObject(MatchesStore())
        .environmentObject(FantasyViewModel())
}
