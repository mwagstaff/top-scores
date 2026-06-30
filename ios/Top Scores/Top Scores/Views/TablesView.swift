import Combine
import SwiftUI

struct TablesView: View {
    @EnvironmentObject private var preferences: PreferencesStore

    @State private var leagues: [LeagueTable]
    @State private var selectedLeagueID: String
    @State private var isLoading: Bool
    @State private var errorMessage: String?
    @State private var lastUpdated: Date?
    @State private var hasLoaded = false
    @State private var shortNameRefreshVersion = 0
    @State private var screenOpenedAt: Date?
    @State private var isVisible = false
    @State private var scrollTargetRowID: String?
    @State private var highlightedRowID: String?
    @ObservedObject private var navigationCoordinator = TablesNavigationCoordinator.shared

    // While the Tables screen is visible, refresh on a live cadence so
    // in-progress scores flow into the (server-recomputed) standings within
    // ~30s. The endpoint is cached server-side, so this stays cheap.
    private let liveRefreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

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
                    if navigationCoordinator.returnTabIndex != nil {
                        backToMatchButton
                    }
                    contentView
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .background(Color(.systemBackground))
            }
        }
        .onAppear {
            isVisible = true
            guard !hasLoaded else { return }
            hasLoaded = true
            screenOpenedAt = Date()
            applyCachedTables(for: preferences.apiBaseURL, clearWhenMissing: false)
            Task {
                await refreshTeamShortNames(apiBaseURL: preferences.apiBaseURL)
                await loadTables(force: false)
                let durationMs = screenOpenedAt.map { Int(Date().timeIntervalSince($0) * 1000) }
                screenOpenedAt = nil
                AppMetricsService.shared.fireScreenView(screen: "tables", durationMs: durationMs, apiBaseURL: preferences.apiBaseURL)
                // Pull fresh (server-recomputed) standings right away so any live
                // match shows immediately, rather than waiting for the first timer tick.
                await liveRefreshTables()
            }
        }
        .onDisappear {
            isVisible = false
            // Leaving Tables for any reason — tapping "Back to match", or
            // switching to another tab directly — drops the stale return
            // target and the pulsing row highlight, so neither lingers if
            // the user comes back to Tables later for an unrelated reason.
            _ = navigationCoordinator.consumeReturnTabIndex()
            highlightedRowID = nil
        }
        .onChange(of: preferences.apiBaseURL) { _, newValue in
            applyCachedTables(for: newValue, clearWhenMissing: true)
            Task {
                await refreshTeamShortNames(apiBaseURL: newValue)
                await loadTables(force: true)
            }
        }
        .onReceive(liveRefreshTimer) { _ in
            guard isVisible, hasLoaded else { return }
            Task { await liveRefreshTables() }
        }
        .onChange(of: navigationCoordinator.pendingTarget) { _, _ in
            consumePendingNavigationIfNeeded()
        }
        .onChange(of: leagues) { _, _ in
            consumePendingNavigationIfNeeded()
        }
    }

    // Applies a cross-tab navigation request from MatchDetailView (selects the
    // league, then scrolls to + highlights the team's row) once the matching
    // league/row are available, then clears the request. The highlight pulses
    // indefinitely — it only moves when a new navigation request arrives.
    private func consumePendingNavigationIfNeeded() {
        guard let target = navigationCoordinator.pendingTarget else { return }
        guard let league = leagues.first(where: { $0.leagueID == target.leagueID }) else { return }
        guard let row = matchingRow(forTeamName: target.teamName, in: league) else {
            _ = navigationCoordinator.consumeTarget()
            return
        }

        _ = navigationCoordinator.consumeTarget()
        selectedLeagueID = target.leagueID

        // A short delay lets the newly-selected league's rows lay out before
        // ScrollViewReader can resolve the target id.
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            scrollTargetRowID = row.id
            highlightedRowID = row.id
        }
    }

    private func matchingRow(forTeamName teamName: String, in league: LeagueTable) -> LeagueTableRow? {
        let target = TeamIdentityStore.shared.canonicalName(for: teamName).lowercased()
        let allRows = league.rows + league.groups.flatMap(\.rows)
        return allRows.first { TeamIdentityStore.shared.canonicalName(for: $0.team).lowercased() == target }
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
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(spacing: 14) {
                            competitionPicker
                            if let league = selectedLeague {
                                LeagueTableHero(league: league)
                                LeagueTableCard(league: league, highlightedRowID: highlightedRowID)
                                    .id("\(league.id)-\(shortNameRefreshVersion)")
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                    }
                    .refreshable {
                        let refreshStart = Date()
                        await loadTables(force: true)
                        let durationMs = Int(Date().timeIntervalSince(refreshStart) * 1000)
                        AppMetricsService.shared.fireActivity("manual_refresh", screen: "tables", durationMs: durationMs, apiBaseURL: preferences.apiBaseURL)
                    }
                    .safeAreaPadding(.bottom, 80)
                    .onChange(of: scrollTargetRowID) { _, newValue in
                        guard let newValue else { return }
                        withAnimation {
                            scrollProxy.scrollTo(newValue, anchor: .center)
                        }
                        scrollTargetRowID = nil
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private static let competitionWeights: [String: Int] = [
        "Premier League": 100,
        "UEFA Champions League": 90,
        "FIFA World Cup 2026": 85,
        "UEFA Europa League": 80,
        "UEFA Conference League": 70,
        "UEFA Nations League": 69,
        "UEFA Super Cup": 68,
        "FA Cup": 65,
        "English League Cup": 60,
        "Copa del Rey": 58,
        "La Liga": 50,
        "Bundesliga": 48,
        "Serie A": 48,
        "Championship": 40,
        "Scottish Premiership": 30,
        "Scottish Championship": 25,
        "Scottish League One": 20,
        "Scottish League Two": 15,
        "League One": 14,
        "League Two": 12,
        "International Friendly": 10
    ]

    private var sortedLeagues: [LeagueTable] {
        leagues.sorted {
            let weightA = Self.competitionWeights[$0.leagueName] ?? 0
            let weightB = Self.competitionWeights[$1.leagueName] ?? 0
            if weightA != weightB { return weightA > weightB }
            return $0.leagueName.localizedCaseInsensitiveCompare($1.leagueName) == .orderedAscending
        }
    }

    private var selectedLeague: LeagueTable? {
        sortedLeagues.first { $0.leagueID == selectedLeagueID } ?? sortedLeagues.first
    }

    private var competitionPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
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

    // Small, unobtrusive pinned bar (sits between the header and the scroll
    // content, so it never scrolls away) offering a quick way back to the
    // match detail screen the user arrived from via a league position chip.
    private var backToMatchButton: some View {
        Button {
            navigationCoordinator.requestReturnToMatch()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.semibold))
                Text("Back to match")
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(.thinMaterial)
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

    // Silent live refresh: force-fetches the latest (server-recomputed) tables
    // without toggling the loading spinner, so the standings update in place.
    private func liveRefreshTables() async {
        let apiBaseURL = preferences.apiBaseURL
        guard !apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let response = try await LeagueTablesCatalog.shared.refresh(apiBaseURL: apiBaseURL, force: true)
            await MainActor.run { apply(response: response) }
        } catch {
            // Keep showing existing data on a transient failure.
        }
    }

    private func refreshTeamShortNames(apiBaseURL: String) async {
        await FantasyTeamShortNameMappingsCatalog.shared.ensureFresh(apiBaseURL: apiBaseURL)
        await MainActor.run {
            shortNameRefreshVersion &+= 1
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
                let weightA = competitionWeights[$0.leagueName] ?? 0
                let weightB = competitionWeights[$1.leagueName] ?? 0
                if weightA != weightB { return weightA > weightB }
                return $0.leagueName.localizedCaseInsensitiveCompare($1.leagueName) == .orderedAscending
            }
            .first?
            .leagueID ?? "premier-league"
    }
}

private struct LeagueTableCard: View {
    let league: LeagueTable
    var highlightedRowID: String?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var expandedRows: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if league.hasLiveRows {
                liveProvisionalNote
            }
            VStack(spacing: 0) {
                headingRow
                tableSeparator(isThick: false)
                ForEach(Array(displayGroups.enumerated()), id: \.element.id) { groupIndex, group in
                    if let heading = groupHeading(for: group) {
                        groupHeadingRow(heading)
                    }

                    ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row)
                        if index < group.rows.count - 1 {
                            tableSeparator(isThick: isBenefitBoundary(in: group.rows, after: index))
                        }
                    }

                    if groupIndex < displayGroups.count - 1 {
                        tableSeparator(isThick: true)
                    }
                }
            }
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var displayGroups: [LeagueTableGroup] {
        let groupsWithRows = league.groups.filter { !$0.rows.isEmpty }
        if !groupsWithRows.isEmpty {
            return groupsWithRows
        }
        return [LeagueTableGroup(name: visibleStageName, rows: league.rows)]
    }

    private var visibleStageName: String? {
        let stage = String(league.stageName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stage.isEmpty else { return nil }
        if stage.caseInsensitiveCompare("Regular Season") == .orderedSame {
            return nil
        }
        return stage
    }

    private var liveProvisionalNote: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.liveMatch)
                .frame(width: 7, height: 7)
            Text("Positions update live from in-progress scores and are provisional.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private var headingRow: some View {
        HStack(spacing: 6) {
            Text("")
                .frame(width: 40, alignment: .trailing)
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

    private func groupHeadingRow(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func rowView(_ row: LeagueTableRow) -> some View {
        VStack(spacing: 0) {
            Button {
                toggleExpansion(for: row.id)
            } label: {
                HStack(spacing: 6) {
                    positionCell(row)
                    TableTeamLogo(name: row.team)
                    Text(displayTeamName(for: row))
                        .font(.subheadline)
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
                .background(HighlightedTableRowBackground(isActive: highlightedRowID == row.id))
                .background(LiveTableRowBackground(isActive: row.live))
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
        .id(row.id)
    }

    private func tableSeparator(isThick: Bool) -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(isThick ? 0.45 : 0.22))
            .frame(height: isThick ? 2.5 : 1)
    }

    private func groupHeading(for group: LeagueTableGroup) -> String? {
        let name = String(group.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard let visibleStageName else { return name }
        if name.range(of: "phase", options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            return name
        }
        return "\(visibleStageName) \(name)"
    }

    private func isBenefitBoundary(in rows: [LeagueTableRow], after index: Int) -> Bool {
        guard index >= 0, index < rows.count - 1 else { return false }
        let current = normalizedRankStatus(rows[index].rankStatus)
        let next = normalizedRankStatus(rows[index + 1].rankStatus)
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
            .scaleEffect(0.7)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }

    private func positionCell(_ row: LeagueTableRow) -> some View {
        HStack(spacing: 2) {
            trendIcon(for: row)
            Text(String(row.position))
                .font(.body.monospacedDigit())
                .scaleEffect(0.7)
                .lineLimit(1)
        }
        .frame(width: 40, alignment: .trailing)
    }

    @ViewBuilder
    private func trendIcon(for row: LeagueTableRow) -> some View {
        switch row.positionTrend {
        case .up:
            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.liveMatch)
        case .down:
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.red)
        case .same:
            Image(systemName: "minus")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.secondary)
        case .none:
            EmptyView()
        }
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

    private func displayTeamName(for row: LeagueTableRow) -> String {
        let canonicalName = TeamIdentityStore.shared.canonicalName(for: row.team)
        return FantasyTeamShortNameMappingsStore.shared.resolveTeamName(for: canonicalName)
    }
}

private struct LeagueTableHero: View {
    let league: LeagueTable

    private var visibleStageName: String? {
        let stage = String(league.stageName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stage.isEmpty, stage.caseInsensitiveCompare("Regular Season") != .orderedSame else {
            return nil
        }
        return stage
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                if league.leagueName.localizedCaseInsensitiveContains("Premier League") {
                    Image("FantasyPremierLeagueLionTab")
                        .resizable()
                        .scaledToFit()
                        .padding(9)
                } else {
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 58, height: 58)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(league.leagueName)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)

                if let visibleStageName {
                    Text(visibleStageName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.76))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.21, green: 0.02, blue: 0.38),
                    Color(red: 0.35, green: 0.03, blue: 0.42),
                    Color(red: 0.08, green: 0.02, blue: 0.20)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.12), radius: 18, x: 0, y: 10)
    }
}

// Pulsing green highlight for a table row whose team is in an in-progress
// match, mirroring the live treatment used for matches on the fixtures screen.
private struct LiveTableRowBackground: View {
    let isActive: Bool

    @State private var pulsing = false

    var body: some View {
        Rectangle()
            .fill(Color.liveMatch.opacity(isActive ? (pulsing ? 0.20 : 0.07) : 0))
            .animation(
                isActive ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default,
                value: pulsing
            )
            .onAppear { pulsing = isActive }
            .onChange(of: isActive) { _, newValue in pulsing = newValue }
    }
}

// Pulsing accent highlight for the row scrolled to via a cross-tab navigation
// (e.g. tapping a team's league position chip on a match detail screen).
// Unlike the one-shot fade used elsewhere, this pulses indefinitely — it only
// moves when a new navigation target is selected, or clears via backButton.
private struct HighlightedTableRowBackground: View {
    let isActive: Bool

    @State private var pulsing = false

    var body: some View {
        Rectangle()
            .fill(Color.accentColor.opacity(isActive ? (pulsing ? 0.22 : 0.08) : 0))
            .animation(
                isActive ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default,
                value: pulsing
            )
            .onAppear { pulsing = isActive }
            .onChange(of: isActive) { _, newValue in pulsing = newValue }
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
        .frame(width: 18, height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityHidden(true)
    }
}

#Preview {
    TablesView()
        .environmentObject(PreferencesStore())
}
