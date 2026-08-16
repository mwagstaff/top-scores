import SwiftUI

struct TeamSelectionView: View {
    let apiBaseURL: String
    @Binding var selectedTeamIDs: Set<String>
    var onCancel: (() -> Void)?
    var onDone: (() -> Void)?

    @StateObject private var store = TeamCatalogStore()
    @State private var searchText = ""

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List {
            if trimmedSearch.isEmpty {
                selectedTeamsSection
                browseSection
            } else if trimmedSearch.count < 2 {
                ContentUnavailableView(
                    "Keep typing",
                    systemImage: "magnifyingglass",
                    description: Text("Enter at least two characters to search for a team.")
                )
                .listRowBackground(Color.clear)
            } else {
                searchResultsSection
            }

            if let errorMessage = store.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Teams")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search teams")
        .toolbar {
            if let onCancel {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
            if let onDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                        .fontWeight(.semibold)
                }
            }
        }
        .task {
            await store.configure(apiBaseURL: apiBaseURL, selectedTeamIDs: selectedTeamIDs)
        }
        .task(id: searchText) {
            await store.search(searchText)
        }
        .onChange(of: selectedTeamIDs) { _, ids in
            Task { await store.updateSelectedTeamIDs(ids) }
        }
    }

    @ViewBuilder
    private var selectedTeamsSection: some View {
        if !selectedTeamIDs.isEmpty {
            Section("Selected teams") {
                ForEach(selectedTeamIDs.sorted(), id: \.self) { teamID in
                    if let team = store.team(for: teamID) {
                        TeamSelectionRow(
                            team: team,
                            isSelected: true,
                            action: { toggle(team.id, selectedAliasID: teamID) }
                        )
                    } else {
                        Button {
                            selectedTeamIDs.remove(teamID)
                        } label: {
                            HStack(spacing: 12) {
                                TeamSelectionFallbackIcon()
                                Text(Self.displayName(for: teamID))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var browseSection: some View {
        Section {
            if store.isLoadingCatalog && store.competitions.isEmpty {
                ProgressView("Loading competitions")
            } else {
                ForEach(store.competitions, id: \.stableID) { competition in
                    NavigationLink {
                        CompetitionTeamSelectionView(
                            competition: competition,
                            selectedTeamIDs: $selectedTeamIDs,
                            store: store
                        )
                    } label: {
                        HStack(spacing: 12) {
                            TeamCompetitionIcon(competitionID: competition.stableID)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(competition.name)
                                    .foregroundStyle(.primary)
                                Text("Browse teams")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Browse by competition")
        } footer: {
            Text("Selected teams are included alongside your chosen competitions.")
        }
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        Section("Search results") {
            if store.isSearching && store.searchResults.isEmpty {
                ProgressView("Searching teams")
            } else if store.searchResults.isEmpty {
                ContentUnavailableView.search(text: trimmedSearch)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(store.searchResults) { team in
                    TeamSelectionRow(
                        team: team,
                        isSelected: selectedTeamIDs.contains(team.id),
                        action: { toggle(team.id) }
                    )
                }
            }
        }
    }

    private func toggle(_ teamID: String, selectedAliasID: String? = nil) {
        if let selectedAliasID, selectedTeamIDs.contains(selectedAliasID) {
            selectedTeamIDs.remove(selectedAliasID)
            return
        }
        if selectedTeamIDs.contains(teamID) {
            selectedTeamIDs.remove(teamID)
        } else {
            selectedTeamIDs.insert(teamID)
        }
    }

    private static func displayName(for teamID: String) -> String {
        teamID
            .split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}

private struct CompetitionTeamSelectionView: View {
    let competition: CompetitionCatalogEntry
    @Binding var selectedTeamIDs: Set<String>
    @ObservedObject var store: TeamCatalogStore

    private var teams: [TeamCatalogEntry] {
        store.teamsByCompetitionID[competition.stableID] ?? []
    }

    var body: some View {
        List {
            if store.loadingCompetitionIDs.contains(competition.stableID) && teams.isEmpty {
                ProgressView("Loading teams")
            } else if teams.isEmpty {
                ContentUnavailableView(
                    "No teams available",
                    systemImage: "person.3",
                    description: Text("Pull back and try this competition again later.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(teams) { team in
                    TeamSelectionRow(
                        team: team,
                        isSelected: selectedTeamIDs.contains(team.id),
                        action: {
                            if selectedTeamIDs.contains(team.id) {
                                selectedTeamIDs.remove(team.id)
                            } else {
                                selectedTeamIDs.insert(team.id)
                            }
                        }
                    )
                }
            }
        }
        .navigationTitle(competition.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.loadTeams(for: competition.stableID)
        }
    }
}

private struct TeamSelectionRow: View {
    let team: TeamCatalogEntry
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                TeamSelectionLogo(team: team)
                VStack(alignment: .leading, spacing: 2) {
                    Text(team.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    if !team.competitionNames.isEmpty {
                        Text(team.competitionNames.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(team.name)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

private struct TeamSelectionLogo: View {
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
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }
}

private struct TeamSelectionFallbackIcon: View {
    var body: some View {
        Image(systemName: "shield.fill")
            .foregroundStyle(.secondary)
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)
    }
}

private struct TeamCompetitionIcon: View {
    let competitionID: String

    var body: some View {
        Group {
            if let image = CompetitionBadgeCache.shared.image(for: competitionID) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "trophy.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }
}
