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
            List {
                Section {
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
            }
            .navigationTitle("Profile")
        }
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
                .frame(width: 28, height: 28)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
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
        List {
            Section {
                Text(
                    isAccountConnected
                        ? "Your Fantasy Premier League account is connected to Top Scores."
                        : "No Fantasy Premier League account is connected."
                )
                .foregroundStyle(.secondary)
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
        .navigationTitle("FPL")
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
