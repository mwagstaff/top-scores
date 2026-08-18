import SwiftUI

struct TeamSelectionView: View {
    let apiBaseURL: String
    @Binding var selectedTeamIDs: Set<String>
    var onCancel: (() -> Void)?
    var onDone: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            searchCompletionAction
        }
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
        .animation(
            accessibilityReduceMotion ? nil : .easeOut(duration: 0.22),
            value: trimmedSearch.isEmpty
        )
    }

    @ViewBuilder
    private var searchCompletionAction: some View {
        if let onDone, !trimmedSearch.isEmpty {
            Button(action: onDone) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2.weight(.semibold))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Done selecting teams")
                            .font(.headline)
                        Text(selectedTeamCountText)
                            .font(.caption)
                            .foregroundStyle(Color.primary.opacity(0.74))
                            .contentTransition(.numericText())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 16)
                .frame(minHeight: 56)
                .background(
                    Color.accentColor.opacity(0.20),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.78), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            .accessibilityLabel("Done selecting teams")
            .accessibilityValue(selectedTeamCountText)
            .accessibilityHint("Applies your team selection and closes the team picker")
            .transition(
                accessibilityReduceMotion
                    ? .opacity
                    : .move(edge: .bottom).combined(with: .opacity)
            )
        }
    }

    private var selectedTeamCountText: String {
        switch selectedTeamIDs.count {
        case 0:
            return "No teams selected"
        case 1:
            return "1 team selected"
        default:
            return "\(selectedTeamIDs.count) teams selected"
        }
    }

    @ViewBuilder
    private var selectedTeamsSection: some View {
        if !selectedTeamIDs.isEmpty {
            Section("Selected teams") {
                ForEach(sortedSelectedTeamIDs, id: \.self) { teamID in
                    SelectedTeamRow(
                        team: store.team(for: teamID),
                        fallbackName: Self.displayName(for: teamID),
                        removeAction: { selectedTeamIDs.remove(teamID) }
                    )
                }

                if selectedTeamIDs.count > 1 {
                    Button(role: .destructive) {
                        selectedTeamIDs.removeAll()
                    } label: {
                        Label("Clear all teams", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var sortedSelectedTeamIDs: [String] {
        selectedTeamIDs.sorted { leftID, rightID in
            selectedTeamName(for: leftID).localizedCaseInsensitiveCompare(
                selectedTeamName(for: rightID)
            ) == .orderedAscending
        }
    }

    private func selectedTeamName(for teamID: String) -> String {
        store.team(for: teamID)?.name ?? Self.displayName(for: teamID)
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

    private func toggle(_ teamID: String) {
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

private struct SelectedTeamRow: View {
    let team: TeamCatalogEntry?
    let fallbackName: String
    let removeAction: () -> Void

    private var name: String {
        team?.name ?? fallbackName
    }

    var body: some View {
        HStack(spacing: 12) {
            if let team {
                TeamSelectionLogo(team: team)
            } else {
                TeamSelectionFallbackIcon()
            }

            Text(name)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(role: .destructive, action: removeAction) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(name)")
        }
        .accessibilityElement(children: .contain)
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
