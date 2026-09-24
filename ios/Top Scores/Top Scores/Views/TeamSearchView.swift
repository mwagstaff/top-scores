import SwiftUI

enum TeamSearchDestinationResolver {
    static func context(for team: TeamCatalogEntry) -> TeamDetailsContext {
        let sourceTeamID = team.sourceTeamIDs.first { id in
            !id.isEmpty && id.allSatisfy(\.isNumber)
        }

        return TeamDetailsContext(
            teamID: sourceTeamID,
            teamName: team.name,
            displayName: team.name,
            alternateNames: team.aliases,
            originatingLeagueID: team.competitionIDs.first,
            originatingLeagueName: team.competitionNames.first ?? "",
            originatingMatch: nil
        )
    }
}

struct TeamSearchView: View {
    let apiBaseURL: String
    let onSelect: (TeamDetailsContext) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @StateObject private var store = TeamCatalogStore()
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 14)

                Divider()
                    .overlay(Color.white.opacity(0.10))

                resultsContent
            }
            .background(FootballVisualStyle.pageBackground.ignoresSafeArea())
            .navigationTitle("Find a Team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FootballVisualStyle.pageBackground.opacity(0.96), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            store.configureForSearch(apiBaseURL: apiBaseURL)
            // Focus only after the sheet's presentation transition has settled: raising the
            // keyboard while UIKit is still resolving the sheet's detents crashes in
            // SheetLayoutInfo._activeDetents (iOS 26).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                isSearchFocused = true
            }
        }
        .task(id: searchText) {
            await store.search(searchText)
        }
        .animation(
            accessibilityReduceMotion ? nil : .easeOut(duration: 0.18),
            value: store.searchResults
        )
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .accessibilityHidden(true)

            TextField("Enter team name", text: $searchText)
                .focused($isSearchFocused)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel("Team name")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear team search")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(minHeight: 50)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(
                    isSearchFocused ? Color.accentColor.opacity(0.88) : Color.white.opacity(0.16),
                    lineWidth: 1
                )
        }
    }

    @ViewBuilder
    private var resultsContent: some View {
        if query.isEmpty {
            searchPrompt(
                title: "Find a team",
                systemImage: "shield.lefthalf.filled",
                message: "Start typing a team name..."
            )
        } else if query.count < 2 {
            searchPrompt(
                title: "Keep typing",
                systemImage: "ellipsis",
                message: "Enter at least two characters to search."
            )
        } else if store.isSearching && store.searchResults.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Searching teams")
                    .font(.headline)
                Text("Results will appear as you type.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = store.errorMessage {
            searchPrompt(
                title: "Unable to search",
                systemImage: "exclamationmark.triangle",
                message: errorMessage
            )
        } else if store.searchResults.isEmpty {
            searchPrompt(
                title: "No teams found",
                systemImage: "magnifyingglass",
                message: "Try another name or spelling."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(store.searchResults) { team in
                        let destinationContext = TeamSearchDestinationResolver.context(for: team)
                        TeamSearchResultRow(team: team) {
                            onSelect(destinationContext)
                            dismiss()
                        }
                        .prewarmTeamStadiumPhoto(
                            for: destinationContext,
                            apiBaseURL: apiBaseURL
                        )
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func searchPrompt(title: String, systemImage: String, message: String) -> some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(message)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TeamSearchResultRow: View {
    let team: TeamCatalogEntry
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                TeamSearchLogo(team: team)

                VStack(alignment: .leading, spacing: 3) {
                    Text(team.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    if !team.competitionNames.isEmpty {
                        Text(team.competitionNames.joined(separator: " • "))
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 62)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(team.name)
        .accessibilityHint("Opens team details")
    }
}

private struct TeamSearchLogo: View {
    let team: TeamCatalogEntry

    var body: some View {
        Group {
            if let image = LogoResolver.shared.image(for: team.name, alternateNames: team.aliases) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "shield.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.secondary)
                    .padding(5)
            }
        }
        .frame(width: 38, height: 38)
        .accessibilityHidden(true)
    }
}
