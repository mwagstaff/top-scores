import SwiftUI

struct TablesView: View {
    @EnvironmentObject private var preferences: PreferencesStore

    @State private var leagues: [LeagueTable]
    @State private var selectedLeagueID: String
    @State private var isLoading: Bool
    @State private var errorMessage: String?
    @State private var lastUpdated: Date?
    @State private var hasLoaded = false

    private static let apiBaseURLDefaultsKey = "preferences.apiBaseURL"

    private let refreshFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    init() {
        let apiBaseURL = UserDefaults.standard.string(forKey: Self.apiBaseURLDefaultsKey)
            ?? PreferencesStore.defaultApiBaseURL
        let cachedResponse = LeagueTablesCache.load(for: apiBaseURL)?.response
        let initialLeagues = cachedResponse?.leagues ?? []

        _leagues = State(initialValue: initialLeagues)
        _selectedLeagueID = State(initialValue: Self.defaultLeagueID(from: initialLeagues))
        _isLoading = State(initialValue: initialLeagues.isEmpty)
        _lastUpdated = State(initialValue: cachedResponse?.lastUpdated)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    headerView
                    contentView
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .background(Color(.systemBackground))
            }
        }
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            applyCachedTables(for: preferences.apiBaseURL, clearWhenMissing: false)
            Task {
                await loadTables(force: false)
            }
        }
        .onChange(of: preferences.apiBaseURL) { _, newValue in
            applyCachedTables(for: newValue, clearWhenMissing: true)
            Task {
                await loadTables(force: true)
            }
        }
    }

    private var contentView: some View {
        Group {
            if isLoading && leagues.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading tables")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if leagues.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "tablecells")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No tables to show")
                        .font(.title3)
                    Text("League tables will appear here once available.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        competitionPicker
                        if let league = selectedLeague {
                            LeagueTableCard(league: league)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                .refreshable {
                    await loadTables(force: true)
                }
                .safeAreaPadding(.bottom, 80)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var sortedLeagues: [LeagueTable] {
        leagues.sorted {
            $0.leagueName.localizedCaseInsensitiveCompare($1.leagueName) == .orderedAscending
        }
    }

    private var selectedLeague: LeagueTable? {
        sortedLeagues.first { $0.leagueID == selectedLeagueID } ?? sortedLeagues.first
    }

    private var competitionPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Competition")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("Competition", selection: $selectedLeagueID) {
                ForEach(sortedLeagues) { league in
                    Text(league.leagueName).tag(league.leagueID)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var headerView: some View {
        TopLevelScreenHeader(screenTitle: "Tables") {
            Image(systemName: "tablecells")
                .font(.system(size: 24, weight: .semibold))
        } detail: {
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Refreshing tables")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if let lastUpdated {
                Text("Updated \(refreshFormatter.string(from: lastUpdated))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadTables(force: Bool) async {
        let apiBaseURL = preferences.apiBaseURL
        await MainActor.run {
            applyCachedTables(for: apiBaseURL, clearWhenMissing: false)
        }

        guard !apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await MainActor.run {
                errorMessage = "Invalid API base URL"
                isLoading = false
            }
            return
        }

        await MainActor.run {
            if force || leagues.isEmpty {
                isLoading = true
            }
            errorMessage = nil
        }

        do {
            let response = try await LeagueTablesCatalog.shared.refresh(
                apiBaseURL: apiBaseURL,
                force: force
            )
            await MainActor.run {
                apply(response: response)
                isLoading = false
                errorMessage = nil
            }
        } catch {
            let cachedResponse = await LeagueTablesCatalog.shared.cachedResponse(apiBaseURL: apiBaseURL)
            await MainActor.run {
                if let cachedResponse {
                    apply(response: cachedResponse)
                }
                isLoading = false
                errorMessage = leagues.isEmpty
                    ? "Failed to load tables: \(error.localizedDescription)"
                    : "Couldn't refresh tables. Showing saved data."
            }
        }
    }

    private func applyCachedTables(for apiBaseURL: String, clearWhenMissing: Bool) {
        guard let cachedResponse = LeagueTablesCache.load(for: apiBaseURL)?.response else {
            guard clearWhenMissing else { return }
            leagues = []
            selectedLeagueID = Self.defaultLeagueID(from: [])
            lastUpdated = nil
            return
        }

        apply(response: cachedResponse)
    }

    private func apply(response: LeagueTablesResponse) {
        leagues = response.leagues
        selectedLeagueID = resolvedLeagueID(
            from: response.leagues,
            currentSelection: selectedLeagueID
        )
        lastUpdated = response.lastUpdated
    }

    private func resolvedLeagueID(from leagues: [LeagueTable], currentSelection: String) -> String {
        guard !leagues.isEmpty else { return Self.defaultLeagueID(from: leagues) }
        if leagues.contains(where: { $0.leagueID == currentSelection }) {
            return currentSelection
        }
        return Self.defaultLeagueID(from: leagues)
    }

    private static func defaultLeagueID(from leagues: [LeagueTable]) -> String {
        if leagues.contains(where: { $0.leagueID == "premier-league" }) {
            return "premier-league"
        }
        return leagues
            .sorted {
                $0.leagueName.localizedCaseInsensitiveCompare($1.leagueName) == .orderedAscending
            }
            .first?
            .leagueID ?? "premier-league"
    }
}

private struct LeagueTableCard: View {
    let league: LeagueTable

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var expandedRows: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(league.leagueName)
                .font(.headline)
            if let stage = visibleStageName {
                Text(stage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                headingRow
                tableSeparator(isThick: false)
                ForEach(Array(league.rows.enumerated()), id: \.element.id) { index, row in
                    rowView(row)
                    if index < league.rows.count - 1 {
                        tableSeparator(isThick: isBenefitBoundary(after: index))
                    }
                }
            }
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var visibleStageName: String? {
        let stage = String(league.stageName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stage.isEmpty else { return nil }
        if stage.caseInsensitiveCompare("Regular Season") == .orderedSame {
            return nil
        }
        return stage
    }

    private var headingRow: some View {
        HStack(spacing: 6) {
            Text("")
                .frame(width: 28, alignment: .trailing)
            Text("")
                .frame(width: 24)
            Text("Team")
                .frame(maxWidth: .infinity, alignment: .leading)
            shortHeading("P", width: 30)
            shortHeading("GD", width: 34)
            shortHeading("Pts", width: 38)
            Color.clear
                .frame(width: 16)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .foregroundStyle(.secondary)
    }

    private func rowView(_ row: LeagueTableRow) -> some View {
        VStack(spacing: 0) {
            Button {
                toggleExpansion(for: row.id)
            } label: {
                HStack(spacing: 6) {
                    cell(String(row.position), width: 28)
                    TableTeamLogo(name: row.team)
                    Text(row.team)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    cell(String(row.played), width: 30)
                    subtleCell(signedNumber(row.goalDifference), width: 34)
                    cell(String(row.points), width: 38, weight: .semibold)
                    Image(systemName: expandedRows.contains(row.id) ? "chevron.up" : "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 16)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expandedRows.contains(row.id) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Stats")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        ExpandedStatTile(title: statTitle("won"), value: String(row.won))
                        ExpandedStatTile(title: statTitle("drawn"), value: String(row.drawn))
                        ExpandedStatTile(title: statTitle("lost"), value: String(row.lost))
                        ExpandedStatTile(title: statTitle("goals_for"), value: String(row.goalsFor))
                        ExpandedStatTile(title: statTitle("goals_against"), value: String(row.goalsAgainst))
                    }

                    Text("Recent Form")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)

                    let formEntries = formItems(row.form)
                    if formEntries.isEmpty {
                        Text("No recent form available")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            ForEach(formEntries.indices, id: \.self) { index in
                                FormResultTile(
                                    result: compactLabels ? formEntries[index].shortLabel : formEntries[index].label,
                                    symbol: formEntries[index].symbol
                                )
                            }
                            Spacer(minLength: 0)
                        }
                    }

                    if let rankStatus = row.rankStatus, !rankStatus.isEmpty {
                        Text(rankStatus)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
    }

    private func tableSeparator(isThick: Bool) -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(isThick ? 0.45 : 0.22))
            .frame(height: isThick ? 2.5 : 1)
    }

    private func isBenefitBoundary(after index: Int) -> Bool {
        guard index >= 0, index < league.rows.count - 1 else { return false }
        let current = normalizedRankStatus(league.rows[index].rankStatus)
        let next = normalizedRankStatus(league.rows[index + 1].rankStatus)
        return current != next
    }

    private func normalizedRankStatus(_ value: String?) -> String {
        String(value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func shortHeading(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .frame(width: width, alignment: .trailing)
    }

    private func cell(_ text: String, width: CGFloat, weight: Font.Weight = .regular) -> some View {
        Text(text)
            .font(.body.monospacedDigit().weight(weight))
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }

    private func subtleCell(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }

    private var compactLabels: Bool {
        horizontalSizeClass == .compact
    }

    private func statTitle(_ key: String) -> String {
        if compactLabels {
            switch key {
            case "won": return "W"
            case "drawn": return "D"
            case "lost": return "L"
            case "goals_for": return "GF"
            case "goals_against": return "GA"
            default: return key
            }
        }

        switch key {
        case "won": return "Won"
        case "drawn": return "Drawn"
        case "lost": return "Lost"
        case "goals_for": return "Goals For"
        case "goals_against": return "Goals Against"
        default: return key
        }
    }

    private func formItems(_ form: [String]) -> [(label: String, shortLabel: String, symbol: String)] {
        Array(form.suffix(5)).map { code in
            switch code.uppercased() {
            case "W":
                return ("Win", "W", "✅")
            case "L":
                return ("Loss", "L", "❌")
            default:
                return ("Draw", "D", "➖")
            }
        }
    }

    private func signedNumber(_ value: Int) -> String {
        if value > 0 {
            return "+\(value)"
        }
        return String(value)
    }

    private func toggleExpansion(for rowID: String) {
        if expandedRows.contains(rowID) {
            expandedRows.remove(rowID)
        } else {
            expandedRows.insert(rowID)
        }
    }
}

private struct ExpandedStatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(value)
                .font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

private struct FormResultTile: View {
    let result: String
    let symbol: String

    var body: some View {
        VStack(spacing: 3) {
            Text(symbol)
                .font(.body)
            Text(result)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

private struct TableTeamLogo: View {
    let name: String

    var body: some View {
        Group {
            if let image = LogoResolver.shared.image(for: name) {
                Image(uiImage: image)
                    .resizable()
            } else {
                Image(systemName: "shield")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityHidden(true)
    }
}

#Preview {
    TablesView()
        .environmentObject(PreferencesStore())
}
