import Combine
import SwiftUI

struct TablesView: View {
    @EnvironmentObject private var preferences: PreferencesStore

    @State private var leagues: [LeagueTable]
    @State private var selectedLeagueID: String
    @State private var isLoading: Bool
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    @State private var shortNameRefreshVersion = 0
    @State private var screenOpenedAt: Date?
    @State private var isVisible = false
    @State private var scrollTargetRowID: String?
    @State private var highlightedRowID: String?
    @State private var showsStats = false
    @ObservedObject private var navigationCoordinator = TablesNavigationCoordinator.shared

    // While the Tables screen is visible, refresh on a live cadence so
    // in-progress scores flow into the (server-recomputed) standings within
    // ~30s. The endpoint is cached server-side, so this stays cheap.
    private let liveRefreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private static let apiBaseURLDefaultsKey = "preferences.apiBaseURL"

    init() {
        let apiBaseURL = UserDefaults.standard.string(forKey: Self.apiBaseURLDefaultsKey)
            ?? PreferencesStore.defaultApiBaseURL
        let cachedResponse = LeagueTablesCache.load(for: apiBaseURL)?.response
        let initialLeagues = cachedResponse?.leagues ?? []

        _leagues = State(initialValue: initialLeagues)
        _selectedLeagueID = State(initialValue: Self.defaultLeagueID(from: initialLeagues))
        _isLoading = State(initialValue: initialLeagues.isEmpty)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    FootballVisualStyle.pageBackground
                        .ignoresSafeArea()

                    FootballScreenBackdrop()

                    VStack(spacing: 0) {
                        FootballHeroHeader(title: "Tables", subtitle: tablesHeaderSubtitle)

                        if navigationCoordinator.returnTabIndex != nil {
                            backToOriginButton
                        }
                        contentView
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

    private var tablesHeaderSubtitle: String? {
        guard let leagueName = leagues
            .first(where: { $0.leagueID == selectedLeagueID })?
            .leagueName
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !leagueName.isEmpty else {
            return nil
        }
        return leagueName
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
                        .tint(Color.accentColor)
                    Text("Loading tables")
                        .font(.subheadline)
                        .foregroundStyle(FootballVisualStyle.mutedText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if leagues.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "tablecells")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.accentColor)
                    Text("No tables to show")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.96))
                    Text(errorMessage ?? "League tables will appear here once available.")
                        .font(.subheadline)
                        .foregroundStyle(errorMessage == nil ? FootballVisualStyle.mutedText : Color.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    competitionCarousel
                    TabView(selection: $selectedLeagueID) {
                        ForEach(sortedLeagues) { league in
                            leaguePage(league)
                                .tag(league.leagueID)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
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

    private var competitionCarousel: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(sortedLeagues) { league in
                        Button {
                            withAnimation(.snappy) {
                                selectedLeagueID = league.leagueID
                            }
                        } label: {
                            Text(league.leagueName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .foregroundStyle(
                                    selectedLeagueID == league.leagueID
                                        ? Color.white
                                        : Color.white.opacity(0.78)
                                )
                                .background(
                                    selectedLeagueID == league.leagueID
                                        ? Color.accentColor
                                        : FootballVisualStyle.elevatedSurface.opacity(0.88),
                                    in: Capsule()
                                )
                                .overlay {
                                    Capsule()
                                        .stroke(
                                            selectedLeagueID == league.leagueID
                                                ? Color.accentColor.opacity(0.95)
                                                : FootballVisualStyle.border,
                                            lineWidth: 1
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                        .id(league.leagueID)
                        .accessibilityAddTraits(
                            selectedLeagueID == league.leagueID ? .isSelected : []
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .frame(height: 56)
            .background(FootballVisualStyle.elevatedSurface.opacity(0.66))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(FootballVisualStyle.divider)
                    .frame(height: 1)
            }
            .onAppear {
                proxy.scrollTo(selectedLeagueID, anchor: .center)
            }
            .onChange(of: selectedLeagueID) { _, newValue in
                withAnimation(.snappy) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func leaguePage(_ league: LeagueTable) -> some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(spacing: 14) {
                    statsToggle
                    LeagueTableCard(
                        league: league,
                        showsStats: showsStats,
                        highlightedRowID: highlightedRowID
                    )
                    .id("\(league.id)-\(shortNameRefreshVersion)")
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
                guard league.leagueID == selectedLeagueID, let newValue else { return }
                withAnimation {
                    scrollProxy.scrollTo(newValue, anchor: .center)
                }
                scrollTargetRowID = nil
            }
        }
    }

    private var statsToggle: some View {
        HStack(spacing: 12) {
            Text("Team")
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
            Toggle("Stats view", isOn: $showsStats)
                .font(.subheadline)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(FootballVisualStyle.elevatedSurface.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(FootballVisualStyle.border, lineWidth: 1)
        }
    }

    // Small, unobtrusive pinned bar (sits between the header and the scroll
    // content, so it never scrolls away) offering a quick way back to the
    // screen that initiated the highlighted-table navigation.
    private var backToOriginButton: some View {
        Button {
            navigationCoordinator.requestReturn()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.semibold))
                Text(navigationCoordinator.returnTitle)
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.white.opacity(0.78))
        .background(FootballVisualStyle.elevatedSurface.opacity(0.76))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FootballVisualStyle.divider)
                .frame(height: 1)
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
    let showsStats: Bool
    var highlightedRowID: String?

    private var accentColor: Color {
        CompetitionAccentRole.resolve(
            competitionID: league.leagueID,
            competitionName: league.leagueName
        ).color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if league.hasLiveRows {
                liveProvisionalNote
            }
            if league.hasRows {
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
                .background {
                    FootballCardSurface(accentColor: accentColor, showsPitchMarkings: true)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(FootballVisualStyle.border, lineWidth: 1)
                }
            } else {
                Text("This table will be populated once the season is underway.")
                    .font(.subheadline)
                    .foregroundStyle(FootballVisualStyle.mutedText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 28)
                    .background {
                        FootballCardSurface(accentColor: accentColor, showsPitchMarkings: true)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(FootballVisualStyle.border, lineWidth: 1)
                    }
            }
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
        Group {
            if showsStats {
                HStack(spacing: 0) {
                    statsHeading("#", width: 30, alignment: .leading)
                    Color.clear.frame(width: 8)
                    Color.clear.frame(width: 24)
                    statsHeading("P", width: 24)
                    statsHeading("W", width: 24)
                    statsHeading("D", width: 24)
                    statsHeading("L", width: 24)
                    statsHeading("GF", width: 27)
                    statsHeading("GA", width: 27)
                    statsHeading("GD", width: 27)
                    statsHeading("Pts", width: 30)
                    statsHeading("Form", width: 55)
                }
            } else {
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
                }
            }
        }
        .padding(.horizontal, showsStats ? 8 : 10)
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
        Group {
            if showsStats {
                HStack(spacing: 0) {
                    compactPositionCell(row)
                    Color.clear.frame(width: 8)
                    TableTeamLogo(name: row.team)
                        .frame(width: 24)
                    statsCell(row.played, width: 24)
                    statsCell(row.won, width: 24)
                    statsCell(row.drawn, width: 24)
                    statsCell(row.lost, width: 24)
                    statsCell(row.goalsFor, width: 27)
                    statsCell(row.goalsAgainst, width: 27)
                    statsCell(row.goalDifference, width: 27, signed: true)
                    statsCell(row.points, width: 30, weight: .semibold)
                    compactForm(row.form)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            } else {
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
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
        }
        .background(HighlightedTableRowBackground(isActive: highlightedRowID == row.id))
        .background(LiveTableRowBackground(isActive: row.live))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.team)
        .accessibilityValue(accessibilityStats(for: row))
        .id(row.id)
    }

    private func tableSeparator(isThick: Bool) -> some View {
        Rectangle()
            .fill(Color.white.opacity(isThick ? 0.16 : 0.075))
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

    private func statsHeading(
        _ text: String,
        width: CGFloat,
        alignment: Alignment = .center
    ) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: width, alignment: alignment)
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

    private func compactPositionCell(_ row: LeagueTableRow) -> some View {
        HStack(spacing: 1) {
            trendIcon(for: row)
            Text(String(row.position))
                .font(.caption.monospacedDigit())
                .lineLimit(1)
        }
        .frame(width: 30, alignment: .leading)
    }

    private func statsCell(
        _ value: Int,
        width: CGFloat,
        signed: Bool = false,
        weight: Font.Weight = .regular
    ) -> some View {
        Text(signed ? signedNumber(value) : String(value))
            .font(.caption.monospacedDigit().weight(weight))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: width, alignment: .center)
    }

    private func compactForm(_ form: [String]) -> some View {
        let results = Array(form.prefix(5))
        return HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { index in
                if index < results.count {
                    formSymbol(results[index])
                } else {
                    Image(systemName: "minus")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .font(.system(size: 8, weight: .bold))
        .frame(width: 55)
        .accessibilityLabel(formAccessibilityLabel(results))
    }

    private func formSymbol(_ result: String) -> some View {
        let normalized = result.uppercased()
        return Image(
            systemName: normalized == "W"
                ? "checkmark.circle.fill"
                : normalized == "L" ? "xmark.circle.fill" : "minus.circle.fill"
        )
        .foregroundStyle(
            normalized == "W" ? Color.green : normalized == "L" ? Color.red : Color.secondary
        )
    }

    private func formAccessibilityLabel(_ form: [String]) -> String {
        guard !form.isEmpty else { return "No recent form" }
        let results = form.map { result in
            switch result.uppercased() {
            case "W": return "win"
            case "L": return "loss"
            default: return "draw"
            }
        }
        return "Recent form: \(results.joined(separator: ", "))"
    }

    private func accessibilityStats(for row: LeagueTableRow) -> String {
        "Position \(row.position), played \(row.played), won \(row.won), drawn \(row.drawn), lost \(row.lost), goals for \(row.goalsFor), goals against \(row.goalsAgainst), goal difference \(signedNumber(row.goalDifference)), \(row.points) points. \(formAccessibilityLabel(Array(row.form.prefix(5))))"
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

    private func signedNumber(_ value: Int) -> String {
        if value > 0 {
            return "+\(value)"
        }
        return String(value)
    }

    private func displayTeamName(for row: LeagueTableRow) -> String {
        let canonicalName = TeamIdentityStore.shared.canonicalName(for: row.team)
        return FantasyTeamShortNameMappingsStore.shared.resolveTeamName(for: canonicalName)
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
