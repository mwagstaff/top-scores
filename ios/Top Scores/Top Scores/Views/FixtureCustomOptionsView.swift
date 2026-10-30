import SwiftUI

/// All three tabs edit one draft; only Apply writes the active fixture view.
struct FixtureCustomOptionsView: View {
    let competitions: [CompetitionCatalogEntry]
    let apiBaseURL: String
    @Binding var selection: Set<String>
    let onBack: () -> Void
    let onClose: () -> Void
    let onApply: () -> Void

    private enum Tab: String, CaseIterable { case competitions = "Competitions", teams = "Teams", rivalries = "Rivalries" }
    @State private var tab: Tab = .competitions
    @State private var search = ""
    @State private var teamCompetition: CompetitionCatalogEntry?
    @StateObject private var teams = TeamCatalogStore()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var selectedTeamIDs: Set<String> { Set(selection.compactMap(FixtureViewOptionID.teamStableID)) }
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func matchesSearch(_ text: String) -> Bool { query.isEmpty || text.localizedStandardContains(query) }

    var body: some View {
        VStack(spacing: 12) {
            header
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView {
                    VStack(spacing: 12) { filters; optionRows }
                }
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("customOptionsList")
            } else {
                filters
                ScrollView { optionRows }
                    .scrollDismissesKeyboard(.interactively)
                    .accessibilityIdentifier("customOptionsList")
            }
            footer
        }
        .padding(.top, 8)
        .onChange(of: tab) { _, _ in search = ""; teamCompetition = nil }
        .task {
            await teams.configure(apiBaseURL: apiBaseURL, selectedTeamIDs: selectedTeamIDs)
        }
        .task(id: search) {
            if tab == .teams { await teams.search(search) }
        }
        .task(id: teamCompetition?.stableID) {
            if let teamCompetition { await teams.loadTeams(for: teamCompetition.stableID) }
        }
    }

    private var header: some View {
        HStack {
            Button(action: onBack) { Label("Options", systemImage: "chevron.left") }
                .accessibilityIdentifier("customOptionsBack")
            Spacer()
            Text("Custom").font(.headline)
            Spacer()
            Button("Close", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("customOptionsClose")
        }
        .padding(.horizontal, 14)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var filters: some View {
        VStack(spacing: 12) {
            Toggle("Include Top Teams", isOn: Binding(
                get: { selection.contains(FixtureViewOptionID.topTeamsPreset) },
                set: { enabled in
                    if enabled { selection.insert(FixtureViewOptionID.topTeamsPreset) }
                    else { selection.remove(FixtureViewOptionID.topTeamsPreset) }
                }
            ))
            .font(.subheadline)
            .padding(.horizontal, 16)
            .accessibilityIdentifier("customTopTeams")
            Picker("Choose options", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .padding(.horizontal, 12)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search \(tab.rawValue.lowercased())", text: $search)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("customOptionsSearch")
                if !search.isEmpty {
                    Button("Clear search", systemImage: "xmark.circle.fill") { search = "" }
                        .labelStyle(.iconOnly)
                }
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12)
        }
    }

    private var optionRows: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            switch tab {
            case .competitions: competitionRows
            case .teams: teamRows
            case .rivalries: rivalryRows
            }
        }
        .padding(.horizontal, 16)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 8) {
                Text("\(selection.count) " + (selection.count == 1 ? "selection" : "selections"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(action: onApply) {
                    Text("Apply view").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("customOptionsApply")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    private func regionID(_ competition: CompetitionCatalogEntry) -> String {
        if let region = competition.region, !region.isEmpty { return region.lowercased() }
        let name = competition.name.lowercased()
        if name.contains("uefa") { return "europe" }
        if name.contains("fifa") || name.contains("international") { return "world" }
        if name.contains("scottish") { return "scotland" }
        if name.contains("la liga") || name.contains("copa del rey") { return "spain" }
        if name.contains("bundesliga") { return "germany" }
        if name.contains("serie a") { return "italy" }
        if name.contains("ligue 1") { return "france" }
        return "england"
    }

    private var regions: [FixtureCompetitionRegion] {
        let known = Set(FixtureCompetitionRegion.all.map(\.id))
        let extra = Set(competitions.map(regionID)).subtracting(known).sorted().map {
            FixtureCompetitionRegion(id: $0, name: $0.capitalized)
        }
        return FixtureCompetitionRegion.all + extra
    }

    private func regionHeader(_ region: FixtureCompetitionRegion) -> some View {
        HStack(spacing: 8) {
            FixtureRegionFlagIcon(regionID: region.id, size: 24).accessibilityHidden(true)
            Text(region.name).font(.subheadline.weight(.semibold))
        }
        .padding(.top, 12).padding(.bottom, 6)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var competitionRows: some View {
        ForEach(regions) { region in
            let entries = competitions.filter { regionID($0) == region.id && matchesSearch($0.name + " " + region.name) }
                .sorted { $0.weight == $1.weight ? $0.name < $1.name : $0.weight > $1.weight }
            let rules = FixtureViewSpecialOption.all.filter {
                $0.id.hasPrefix("rule:") && $0.regionID == region.id && matchesSearch($0.title)
            }
            if !entries.isEmpty || !rules.isEmpty {
                regionHeader(region)
                ForEach(entries, id: \.stableID) { competition in
                    optionRow(id: FixtureViewOptionID.competition(competition.stableID), title: competition.name) {
                        LeagueBadgeImage(competitionID: competition.stableID, competitionName: competition.name, size: 30)
                    }
                }
                ForEach(rules) { option in specialRow(option) }
            }
        }
        if !query.isEmpty && !competitions.contains(where: { matchesSearch($0.name + " " + regionID($0)) }) {
            Text("No matching competitions").foregroundStyle(.secondary).padding(.vertical)
        }
    }

    @ViewBuilder private var rivalryRows: some View {
        ForEach(regions) { region in
            let options = FixtureViewSpecialOption.all.filter {
                $0.id.hasPrefix("rivalry:") && $0.regionID == region.id && matchesSearch($0.title + " " + $0.subtitle)
            }
            if !options.isEmpty {
                regionHeader(region)
                ForEach(options) { option in specialRow(option) }
            }
        }
    }

    private func specialRow(_ option: FixtureViewSpecialOption) -> some View {
        optionRow(id: option.id, title: option.title, subtitle: option.subtitle) {
            FixtureViewSpecialOptionIcon(option: option, size: 30)
        }
    }

    @ViewBuilder private var teamRows: some View {
        if let error = teams.errorMessage {
            Text(error).font(.caption).foregroundStyle(.secondary)
            Button("Retry") {
                Task {
                    await teams.configure(apiBaseURL: apiBaseURL, selectedTeamIDs: selectedTeamIDs)
                    if let teamCompetition { await teams.loadTeams(for: teamCompetition.stableID) }
                    if !query.isEmpty { await teams.search(query) }
                }
            }
        }
        if !query.isEmpty {
            if query.count < 2 {
                Text("Enter at least two characters").foregroundStyle(.secondary).padding(.vertical)
            } else if teams.isSearching {
                ProgressView("Searching teams").padding(.vertical)
            } else if teams.searchResults.isEmpty {
                Text("No matching teams").foregroundStyle(.secondary).padding(.vertical)
            } else {
                ForEach(teams.searchResults) { team in teamRow(team) }
            }
        } else if let teamCompetition {
            Button { self.teamCompetition = nil } label: {
                Label("All competitions", systemImage: "chevron.left").padding(.vertical, 12)
            }
            Text(teamCompetition.name).font(.headline)
            if teams.loadingCompetitionIDs.contains(teamCompetition.stableID) {
                ProgressView("Loading teams").padding(.vertical)
            } else {
                let entries = teams.teamsByCompetitionID[teamCompetition.stableID] ?? []
                ForEach(entries) { team in teamRow(team) }
                if entries.isEmpty { Text("No teams available").foregroundStyle(.secondary).padding(.vertical) }
            }
        } else {
            if !selectedTeamIDs.isEmpty {
                Text("Selected teams").font(.subheadline.weight(.semibold)).padding(.vertical, 8)
                ForEach(selectedTeamIDs.sorted(), id: \.self) { id in
                    if let team = teams.team(for: id) { teamRow(team) }
                    else {
                        optionRow(id: FixtureViewOptionID.team(id), title: id.replacingOccurrences(of: "-", with: " ").capitalized) {
                            Image(systemName: "shield").frame(width: 30)
                        }
                    }
                }
            }
            ForEach(regions) { region in
                let entries = competitions.filter { regionID($0) == region.id }
                if !entries.isEmpty {
                    regionHeader(region)
                    ForEach(entries, id: \.stableID) { competition in
                        Button { teamCompetition = competition } label: {
                            HStack(spacing: 10) {
                                LeagueBadgeImage(competitionID: competition.stableID, competitionName: competition.name, size: 30)
                                Text(competition.name).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }
                            .frame(minHeight: 48).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func teamRow(_ team: TeamCatalogEntry) -> some View {
        optionRow(id: FixtureViewOptionID.team(team.id), title: team.name) {
            Group {
                if let image = LogoResolver.shared.image(for: team.name, alternateNames: team.aliases) {
                    Image(uiImage: image).resizable().scaledToFit()
                } else { Image(systemName: "shield.fill").foregroundStyle(.secondary) }
            }.frame(width: 30, height: 30)
        }
    }

    private func optionRow<Icon: View>(id: String, title: String, subtitle: String? = nil, @ViewBuilder icon: () -> Icon) -> some View {
        Button {
            selection = FixtureViewOptionID.toggling(id, in: selection)
        } label: {
            HStack(spacing: 10) {
                icon().accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(.primary)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selection.contains(id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection.contains(id) ? Color.accentColor : Color.secondary)
            }
            .font(.subheadline)
            .padding(.vertical, 8).frame(minHeight: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(selection.contains(id) ? "Selected" : "Not selected")
        .accessibilityIdentifier("customOption-\(id)")
    }
}
