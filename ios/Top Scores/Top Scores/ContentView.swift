//
//  ContentView.swift
//  Top Scores
//
//  Created by Mike Wagstaff on 11/02/2026.
//

import SwiftUI

struct ContentView: View {
    @AppStorage("fantasy.managerEntryID") private var fantasyManagerEntryID = ""
    @State private var selectedTab = 0
    @State private var fantasyTabBadge: String?
    @State private var fantasyTabShouldPulse = false

    var body: some View {
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
        .background(Color(.systemBackground))
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

    @Binding var selectedTab: Int
    let fantasyManagerEntryID: String
    @Binding var fantasyTabBadge: String?
    @Binding var fantasyTabShouldPulse: Bool

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
            .onChange(of: matchesStore.matches) { _, _ in
                updateFantasyTabPresentation()
            }
            .task(id: fantasyManagerEntryID) {
                updateFantasyTabPresentation()
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

    private var trimmedFantasyManagerEntryID: String {
        fantasyManagerEntryID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateFantasyTabPresentation() {
        let nextBadge: String?
        let nextShouldPulse: Bool

        if !trimmedFantasyManagerEntryID.isEmpty,
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
    ContentView()
        .environmentObject(PreferencesStore())
        .environmentObject(MatchesStore())
        .environmentObject(FantasyViewModel())
}
