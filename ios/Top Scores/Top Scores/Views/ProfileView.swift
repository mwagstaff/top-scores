import SwiftUI

struct ProfileView: View {
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
}

#Preview {
    ProfileView()
        .environmentObject(PreferencesStore())
        .environmentObject(FantasyViewModel())
}
