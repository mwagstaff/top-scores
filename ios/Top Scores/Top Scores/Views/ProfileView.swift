import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var fantasyViewModel: FantasyViewModel

    @AppStorage("fantasy.managerEntryID") private var fantasyManagerEntryID = ""
    @AppStorage("fantasy.rivalManagersJSON") private var fantasyRivalsJSON = "[]"
    @AppStorage("fantasy.trackedLeaguesJSON") private var fantasyTrackedLeaguesJSON = "[]"
    @AppStorage("fantasy.initialSetupVersion") private var fantasyInitialSetupVersion = 0

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    FootballVisualStyle.pageBackground
                        .ignoresSafeArea()

                    FootballScreenBackdrop()

                    VStack(spacing: 0) {
                        FootballHeroHeader(title: "Profile")

                        ScrollView {
                            LazyVStack(spacing: 12) {
                                NavigationLink {
                                    PreferencesView(embeddedInNavigation: true)
                                } label: {
                                    profileRow(
                                        title: "Preferences",
                                        subtitle: "Competition filters, notifications, display, channels, and fantasy settings.",
                                        systemImage: "slider.horizontal.3"
                                    )
                                }

                                NavigationLink {
                                    TeamSelectionView(
                                        apiBaseURL: preferences.apiBaseURL,
                                        selectedTeamIDs: fixtureTeamSelectionBinding
                                    )
                                } label: {
                                    profileRow(
                                        title: "Teams",
                                        subtitle: fixtureTeamSelectionSubtitle,
                                        systemImage: "person.3.fill"
                                    )
                                }

                                NavigationLink {
                                    FantasyAccountSettingsView(signOut: signOutOfFantasyAccount)
                                } label: {
                                    profileRow(
                                        title: "FPL",
                                        subtitle: "Manage your connected Fantasy Premier League account.",
                                        systemImage: "trophy.fill"
                                    )
                                }

                                NavigationLink {
                                    AboutView(embeddedInNavigation: true)
                                } label: {
                                    profileRow(
                                        title: "About",
                                        subtitle: "Version info, feedback, credits, and data sources.",
                                        systemImage: "info.circle"
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .safeAreaPadding(.bottom, 80)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            let openedAt = Date()
            let durationMs = Int(Date().timeIntervalSince(openedAt) * 1000)
            AppMetricsService.shared.fireScreenView(screen: "profile", durationMs: durationMs, apiBaseURL: preferences.apiBaseURL)
        }
    }

    private func profileRow(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 42, height: 42)
                .foregroundStyle(Color.accentColor)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.96))
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(FootballVisualStyle.mutedText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(FootballVisualStyle.mutedText)
                .padding(.top, 14)
        }
        .padding(16)
        .background {
            FootballCardSurface(accentColor: Color.accentColor)
        }
        .clipShape(RoundedRectangle(cornerRadius: FootballVisualStyle.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FootballVisualStyle.cardCornerRadius, style: .continuous)
                .stroke(FootballVisualStyle.border, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: FootballVisualStyle.cardCornerRadius, style: .continuous))
    }

    private var fixtureTeamSelectionBinding: Binding<Set<String>> {
        Binding(
            get: {
                let optionIDs = preferences.fixtureAllMajorMatchesEnabled
                    ? preferences.favouriteFixtureViewOptionIDs
                    : preferences.selectedFixtureViewOptionIDs
                return Set(optionIDs.compactMap(FixtureViewOptionID.teamStableID))
            },
            set: { teamIDs in
                if preferences.fixtureAllMajorMatchesEnabled {
                    let nonTeamIDs = preferences.favouriteFixtureViewOptionIDs.filter {
                        FixtureViewOptionID.teamStableID(from: $0) == nil
                    }
                    preferences.favouriteFixtureViewOptionIDs = (
                        nonTeamIDs + teamIDs.map(FixtureViewOptionID.team)
                    ).sorted()
                    return
                }

                let nonTeamIDs = preferences.showAllMatches
                    ? []
                    : preferences.selectedFixtureViewOptionIDs.filter {
                        FixtureViewOptionID.teamStableID(from: $0) == nil
                    }
                preferences.selectedFixtureViewOptionIDs = (
                    nonTeamIDs + teamIDs.map(FixtureViewOptionID.team)
                ).sorted()
                if !teamIDs.isEmpty {
                    preferences.fixtureAllMajorMatchesEnabled = false
                    preferences.competitionFilterEnabled = true
                    preferences.showAllMatches = false
                }
            }
        )
    }

    private var fixtureTeamSelectionSubtitle: String {
        let count = fixtureTeamSelectionBinding.wrappedValue.count
        if count == 0 {
            return "Add individual teams alongside your selected competitions."
        }
        return count == 1
            ? "1 team included in your Scores view."
            : "\(count) teams included in your Scores view."
    }

    private func signOutOfFantasyAccount() {
        fantasyManagerEntryID = ""
        fantasyRivalsJSON = "[]"
        fantasyTrackedLeaguesJSON = "[]"
        fantasyInitialSetupVersion = 0
        fantasyViewModel.reset()
        FantasySyncStore.persist(managerEntryID: "", squad: nil)

        guard let defaults = UserDefaults(suiteName: AppGroupConfig.identifier) else { return }
        defaults.removeObject(forKey: AppGroupConfig.fantasySharedEntryURLKey)
        defaults.removeObject(forKey: AppGroupConfig.fantasySharedEntryUpdatedAtKey)
        defaults.removeObject(forKey: AppGroupConfig.fantasyManagerEntryIDKey)
        defaults.synchronize()
    }
}

private struct FantasyAccountSettingsView: View {
    let signOut: () -> Void

    @AppStorage("fantasy.managerEntryID") private var fantasyManagerEntryID = ""
    @State private var showSignOutConfirmation = false

    private var isAccountConnected: Bool {
        !fantasyManagerEntryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        FootballNavigationScreen(title: "FPL", subtitle: "Account settings") {
            List {
                Section {
                    Label {
                        Text(
                            isAccountConnected
                                ? "Your Fantasy Premier League account is connected to Top Scores."
                                : "No Fantasy Premier League account is connected."
                        )
                        .foregroundStyle(FootballVisualStyle.mutedText)
                    } icon: {
                        Image(systemName: isAccountConnected ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark")
                            .foregroundStyle(isAccountConnected ? Color.accentColor : FootballVisualStyle.mutedText)
                    }
                }

                if isAccountConnected {
                    Section {
                        Button("Sign out", role: .destructive) {
                            showSignOutConfirmation = true
                        }
                    } footer: {
                        Text("Signing out removes your manager account, rivals, and FPL data from this device. You can connect again at any time.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
        .alert("Sign out of FPL?", isPresented: $showSignOutConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Sign out", role: .destructive, action: signOut)
        } message: {
            Text("This will remove your linked manager account, rivals, and Fantasy Premier League data from this device. You can connect again at any time.")
        }
    }
}

#Preview {
    ProfileView()
        .environmentObject(PreferencesStore())
        .environmentObject(FantasyViewModel())
}
