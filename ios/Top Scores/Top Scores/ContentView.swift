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
    @StateObject private var fixturesCoordinator = FixturesViewCoordinator()
    @ObservedObject private var tablesNavigationCoordinator = TablesNavigationCoordinator.shared

    private static let tablesTabIndex = 1

    var body: some View {
        TabView(selection: $selectedTab) {
            MatchesView(
                mode: .fixtures,
                isSelected: selectedTab == 0,
                store: matchesStore,
                fixturesCoordinator: fixturesCoordinator
            )
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if selectedTab == 0 && fixturesCoordinator.isDockEnabled {
                        FixtureCompetitionDockView(coordinator: fixturesCoordinator)
                    }
                }
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
                            .renderingMode(.template)
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
        .overlayPreferenceValue(FixtureCompetitionDockBoundsPreferenceKey.self) { dockBounds in
            if selectedTab == 0,
               fixturesCoordinator.isDockEnabled,
               fixturesCoordinator.hasExpandedPanel,
               let dockBounds {
                GeometryReader { proxy in
                    let dockFrame = proxy[dockBounds]
                    let bottomPadding = max(0, proxy.size.height - dockFrame.minY + 2)

                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        FixtureCompetitionDockView(
                            coordinator: fixturesCoordinator,
                            content: .panel
                        )
                        .padding(.horizontal, 24)
                        .padding(.bottom, bottomPadding)
                    }
                }
            }
        }
        .sheet(isPresented: $fixturesCoordinator.isTeamPickerPresented) {
            FixtureCompetitionDockView(
                coordinator: fixturesCoordinator,
                content: .teamPicker
            )
        }
        .background(FootballVisualStyle.pageBackground)
        .tint(Color.accentColor)
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
    @State private var lastAutomaticFantasyScoreRefreshAt: Date?

    private let fantasyBackgroundRefreshTimer = Timer.publish(
        every: 300,
        on: .main,
        in: .common
    ).autoconnect()
    private let fantasyScoreRefreshTimer = Timer.publish(
        every: 30,
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
            .onReceive(fantasyScoreRefreshTimer) { date in
                updateFantasyTabPresentation(now: date)
                guard scenePhase == .active,
                      selectedTab != 2,
                      fantasyViewModel.data != nil,
                      date.timeIntervalSince(lastAutomaticFantasyScoreRefreshAt ?? .distantPast)
                        >= fantasyViewModel.automaticScoreRefreshMinimumInterval else {
                    return
                }
                lastAutomaticFantasyScoreRefreshAt = date
                Task {
                    let becameFinal = await fantasyViewModel.refreshCurrentScores()
                    if becameFinal {
                        await refreshFantasyInBackground()
                    }
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

    private func updateFantasyTabPresentation(now: Date = Date()) {
        let nextBadge: String?
        let nextShouldPulse: Bool

        if fantasyViewModel.isSeasonActive,
           !trimmedFantasyManagerEntryID.isEmpty,
           let squad = fantasyViewModel.data {
            let relevantMatches = matchesStore.matches.filter { match in
                guard isPremierLeagueMatch(match) else { return false }
                return squad.matchSquadSection(forTeamName: match.homeTeam)?.hasPlayers == true ||
                    squad.matchSquadSection(forTeamName: match.awayTeam)?.hasPlayers == true
            }
            let shouldShowScore = relevantMatches.contains {
                fantasyTabMatchIsLiveOrRecentlyFinished($0, now: now)
            }

            nextBadge = shouldShowScore ? "\(squad.resolvedCurrentScore)" : nil
            nextShouldPulse = relevantMatches.contains { match in
                guard let status = match.stabilizedScoreStatus(now: now) else { return false }
                return MatchStatusFormatter.isInProgress(status)
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

func fantasyTabMatchIsLiveOrRecentlyFinished(
    _ match: Match,
    now: Date = Date(),
    recentlyFinishedWindow: TimeInterval = 30 * 60
) -> Bool {
    guard let status = match.stabilizedScoreStatus(now: now) else {
        return false
    }

    if MatchStatusFormatter.isInProgress(status) {
        return true
    }

    guard MatchStatusFormatter.isFinished(status),
          let updatedAt = match.updatedAt,
          let finishedAt = fantasyTabISO8601Date(from: updatedAt) else {
        return false
    }

    let elapsed = now.timeIntervalSince(finishedAt)
    return elapsed >= 0 && elapsed < recentlyFinishedWindow
}

private func fantasyTabISO8601Date(from value: String) -> Date? {
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractionalFormatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

#Preview {
    let store = MatchesStore()
    return ContentView(matchesStore: store)
        .environmentObject(PreferencesStore())
        .environmentObject(store)
        .environmentObject(FantasyViewModel())
}
