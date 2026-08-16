import Observation
import SwiftUI

struct TeamDetailsContext: Hashable, Identifiable, Sendable {
    let teamID: String?
    let teamName: String
    let displayName: String
    let alternateNames: [String]
    let originatingLeagueID: String?
    let originatingLeagueName: String
    let originatingMatch: Match?

    var id: String {
        let teamKey = teamID ?? TeamIdentityStore.normalizedKey(teamName)
        return "\(teamKey)|\(originatingLeagueID ?? originatingLeagueName)|\(originatingMatchID ?? "")"
    }

    var originatingMatchID: String? {
        originatingMatch?.matchDetailsID ?? originatingMatch?.id
    }

    var canonicalName: String {
        let canonical = TeamIdentityStore.shared.canonicalName(for: teamName)
        return canonical.isEmpty ? displayName : canonical
    }
}

struct TeamSeasonStanding: Hashable, Sendable {
    let leagueID: String
    let leagueName: String
    let groupName: String?
    let realtime: Bool
    let row: LeagueTableRow
}

enum TeamDetailsStandingResolver {
    static func resolve(
        context: TeamDetailsContext,
        response: LeagueTablesResponse
    ) -> TeamSeasonStanding? {
        var candidates: [(score: Int, order: Int, standing: TeamSeasonStanding)] = []

        for (tableIndex, table) in response.leagues.enumerated() {
            let topLevelRows = table.rows.map { (groupName: Optional<String>.none, row: $0) }
            let groupedRows = table.groups.flatMap { group in
                group.rows.map { (groupName: group.name, row: $0) }
            }

            for item in topLevelRows + groupedRows {
                guard TeamIdentityStore.shared.matches(item.row.team, context.teamName) else {
                    continue
                }

                var score = 0
                if let leagueID = context.originatingLeagueID,
                   table.leagueID.caseInsensitiveCompare(leagueID) == .orderedSame {
                    score += 2_000
                }
                if table.leagueName.localizedCaseInsensitiveCompare(context.originatingLeagueName) == .orderedSame {
                    score += 1_000
                }

                candidates.append((
                    score: score,
                    order: tableIndex,
                    standing: TeamSeasonStanding(
                        leagueID: table.leagueID,
                        leagueName: table.leagueName,
                        groupName: item.groupName,
                        realtime: table.realtime,
                        row: item.row
                    )
                ))
            }
        }

        return candidates.max { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score < rhs.score
            }
            return lhs.order > rhs.order
        }?.standing
    }
}

enum TeamDetailsSeason {
    static func startDate(containing date: Date, calendar: Calendar = .current) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let year = components.year, let month = components.month else { return date }

        var startComponents = DateComponents()
        startComponents.calendar = calendar
        startComponents.timeZone = calendar.timeZone
        startComponents.year = month >= 7 ? year : year - 1
        startComponents.month = 7
        startComponents.day = 1
        return calendar.date(from: startComponents) ?? date
    }

    static func contains(_ match: Match, asOf date: Date, calendar: Calendar = .current) -> Bool {
        guard let matchDate = match.dateTime ?? match.dateOnly else { return false }
        return matchDate >= startDate(containing: date, calendar: calendar)
    }
}

enum TeamDetailsMatchResolver {
    static func previousMatches(
        context: TeamDetailsContext,
        from matches: [Match],
        limit: Int = 20,
        now: Date = Date()
    ) -> [Match] {
        let authoritativeMatch = context.originatingMatch
        var merged = matches.filter { match in
            guard !match.isPostponed else { return false }
            guard TeamDetailsSeason.contains(match, asOf: now) else { return false }
            guard let authoritativeMatch else { return true }
            return !isSameMatch(match, as: authoritativeMatch)
        }

        if let authoritativeMatch,
           authoritativeMatch.isFinished,
           !authoritativeMatch.isPostponed,
           TeamDetailsSeason.contains(authoritativeMatch, asOf: now) {
            merged.append(authoritativeMatch)
        }

        let sorted = merged.enumerated().sorted { lhs, rhs in
            let lhsDate = lhs.element.dateTime ?? .distantPast
            let rhsDate = rhs.element.dateTime ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            if let authoritativeMatch {
                let lhsIsAuthoritative = lhs.element == authoritativeMatch
                let rhsIsAuthoritative = rhs.element == authoritativeMatch
                if lhsIsAuthoritative != rhsIsAuthoritative {
                    return lhsIsAuthoritative
                }
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        return Array(sorted.prefix(max(0, limit)))
    }

    private static func isSameMatch(_ candidate: Match, as authoritative: Match) -> Bool {
        if let candidateID = candidate.matchDetailsID,
           let authoritativeID = authoritative.matchDetailsID,
           candidateID == authoritativeID {
            return true
        }
        if candidate.id == authoritative.id {
            return true
        }
        return candidate.date == authoritative.date &&
            TeamIdentityStore.shared.matches(candidate.homeTeam, authoritative.homeTeam) &&
            TeamIdentityStore.shared.matches(candidate.awayTeam, authoritative.awayTeam)
    }
}

enum TeamDetailsFormResolver {
    static func recentForm(
        context: TeamDetailsContext,
        standing: TeamSeasonStanding,
        matches: [Match],
        now: Date = Date()
    ) -> [String] {
        let completedMatches = matches.filter { match in
            let involvesTeam = TeamIdentityStore.shared.matches(match.homeTeam, context.teamName) ||
                TeamIdentityStore.shared.matches(match.awayTeam, context.teamName)
            return involvesTeam &&
                match.isFinished &&
                match.hasScore &&
                !match.isPostponed &&
                TeamDetailsSeason.contains(match, asOf: now)
        }
        .sorted {
            ($0.dateTime ?? .distantPast) > ($1.dateTime ?? .distantPast)
        }

        let derived = completedMatches.prefix(5).compactMap { match -> String? in
            guard let homeScore = match.homeScore, let awayScore = match.awayScore else { return nil }
            if homeScore == awayScore {
                return "D"
            }
            let teamIsHome = TeamIdentityStore.shared.matches(match.homeTeam, context.teamName)
            let teamWon = teamIsHome ? homeScore > awayScore : awayScore > homeScore
            return teamWon ? "W" : "L"
        }

        if !derived.isEmpty {
            return derived
        }

        let fallbackCount = min(5, max(0, standing.row.played))
        return Array(standing.row.form.prefix(fallbackCount))
    }
}

private actor TeamResultsCatalog {
    static let shared = TeamResultsCatalog()

    private struct CacheEntry: Sendable {
        let matches: [Match]
        let fetchedAt: Date
    }

    private static let cacheTTL: TimeInterval = 5 * 60
    private var entries: [String: CacheEntry] = [:]

    func cachedResults(teamName: String, apiBaseURL: String) -> [Match]? {
        entries[cacheKey(teamName: teamName, apiBaseURL: apiBaseURL)]?.matches
    }

    func results(
        teamName: String,
        apiBaseURL: String,
        force: Bool,
        limit: Int = 21
    ) async throws -> [Match] {
        let key = cacheKey(teamName: teamName, apiBaseURL: apiBaseURL)
        if !force,
           let cached = entries[key],
           Date().timeIntervalSince(cached.fetchedAt) < Self.cacheTTL {
            return cached.matches
        }
        guard let baseURL = URL(string: apiBaseURL) else {
            throw LeagueTablesCatalogError.invalidBaseURL(apiBaseURL)
        }

        let matches = try await APIClient(baseURL: baseURL)
            .fetchTeamResults(teamName: teamName, limit: limit)
            .matches
        try Task.checkCancellation()
        entries[key] = CacheEntry(matches: matches, fetchedAt: Date())
        return matches
    }

    private func cacheKey(teamName: String, apiBaseURL: String) -> String {
        "\(apiBaseURL)|\(TeamIdentityStore.normalizedKey(teamName))"
    }
}

@MainActor
@Observable
private final class TeamDetailsViewModel {
    private(set) var standing: TeamSeasonStanding?
    private(set) var previousMatches: [Match] = []
    private(set) var isLoadingStanding = true
    private(set) var isLoadingMatches = true
    private(set) var standingErrorMessage: String?
    private(set) var matchesErrorMessage: String?

    private var activeLoadKey: String?

    func load(
        context: TeamDetailsContext,
        apiBaseURL: String,
        force: Bool = false
    ) async {
        let loadKey = "\(context.id)|\(apiBaseURL)"
        if activeLoadKey != loadKey {
            activeLoadKey = loadKey
            standing = nil
            previousMatches = TeamDetailsMatchResolver.previousMatches(
                context: context,
                from: []
            )
            standingErrorMessage = nil
            matchesErrorMessage = nil
        }

        if !force {
            if let cachedTables = await LeagueTablesCatalog.shared.cachedResponse(apiBaseURL: apiBaseURL) {
                standing = TeamDetailsStandingResolver.resolve(context: context, response: cachedTables)
            }
            if let cachedMatches = await TeamResultsCatalog.shared.cachedResults(
                teamName: context.teamName,
                apiBaseURL: apiBaseURL
            ) {
                previousMatches = TeamDetailsMatchResolver.previousMatches(
                    context: context,
                    from: cachedMatches
                )
            }
        }

        isLoadingStanding = standing == nil
        isLoadingMatches = previousMatches.isEmpty
        standingErrorMessage = nil
        matchesErrorMessage = nil

        async let standingOutcome = Self.fetchStanding(
            context: context,
            apiBaseURL: apiBaseURL,
            force: force
        )
        async let matchesOutcome = Self.fetchMatches(
            context: context,
            apiBaseURL: apiBaseURL,
            force: force
        )
        let (resolvedStanding, resolvedMatches) = await (standingOutcome, matchesOutcome)

        guard !Task.isCancelled, activeLoadKey == loadKey else { return }

        if let value = resolvedStanding.value {
            standing = value
        }
        standingErrorMessage = resolvedStanding.errorMessage
        isLoadingStanding = false

        if let value = resolvedMatches.value {
            previousMatches = value
        }
        matchesErrorMessage = resolvedMatches.errorMessage
        isLoadingMatches = false
    }

    private static func fetchStanding(
        context: TeamDetailsContext,
        apiBaseURL: String,
        force: Bool
    ) async -> StandingOutcome {
        do {
            let response = try await LeagueTablesCatalog.shared.refresh(
                apiBaseURL: apiBaseURL,
                force: force
            )
            return StandingOutcome(
                value: TeamDetailsStandingResolver.resolve(context: context, response: response),
                errorMessage: nil
            )
        } catch is CancellationError {
            return StandingOutcome(value: nil, errorMessage: nil)
        } catch {
            return StandingOutcome(value: nil, errorMessage: error.localizedDescription)
        }
    }

    private static func fetchMatches(
        context: TeamDetailsContext,
        apiBaseURL: String,
        force: Bool
    ) async -> MatchesOutcome {
        do {
            let matches = try await TeamResultsCatalog.shared.results(
                teamName: context.teamName,
                apiBaseURL: apiBaseURL,
                force: force
            )
            return MatchesOutcome(
                value: TeamDetailsMatchResolver.previousMatches(
                    context: context,
                    from: matches
                ),
                errorMessage: nil
            )
        } catch is CancellationError {
            return MatchesOutcome(value: nil, errorMessage: nil)
        } catch {
            return MatchesOutcome(value: nil, errorMessage: error.localizedDescription)
        }
    }

    private struct StandingOutcome: Sendable {
        let value: TeamSeasonStanding?
        let errorMessage: String?
    }

    private struct MatchesOutcome: Sendable {
        let value: [Match]?
        let errorMessage: String?
    }
}

struct TeamDetailsView: View {
    @EnvironmentObject private var preferences: PreferencesStore

    let context: TeamDetailsContext
    @State private var viewModel = TeamDetailsViewModel()

    private var taskKey: String {
        "\(context.id)|\(preferences.apiBaseURL)"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                teamHero
                currentSeasonSection
                previousMatchesSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Team Details")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: taskKey) {
            await viewModel.load(context: context, apiBaseURL: preferences.apiBaseURL)
        }
        .refreshable {
            await viewModel.load(
                context: context,
                apiBaseURL: preferences.apiBaseURL,
                force: true
            )
        }
    }

    private var teamHero: some View {
        VStack(spacing: 14) {
            Group {
                if let image = LogoResolver.shared.image(
                    for: context.teamName,
                    teamId: context.teamID,
                    alternateNames: context.alternateNames
                ) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.86))
                }
            }
            .frame(width: 84, height: 84)
            .padding(12)
            .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

            VStack(spacing: 5) {
                Text(context.canonicalName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(viewModel.standing?.leagueName ?? context.originatingLeagueName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.74))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .background {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.13, blue: 0.22),
                        Color(red: 0.05, green: 0.09, blue: 0.16),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [Color.accentColor.opacity(0.38), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: 260
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(0.16), radius: 18, y: 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(context.canonicalName), \(viewModel.standing?.leagueName ?? context.originatingLeagueName)")
    }

    @ViewBuilder
    private var currentSeasonSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Current season")

            if let standing = viewModel.standing {
                currentSeasonCard(standing)
            } else if viewModel.isLoadingStanding {
                loadingCard(label: "Loading current season statistics")
            } else {
                unavailableCard(
                    title: "Statistics unavailable",
                    message: "No current league table was found for \(context.canonicalName).",
                    systemImage: "chart.bar.xaxis"
                )
            }

            if let errorMessage = viewModel.standingErrorMessage, viewModel.standing != nil {
                inlineError(errorMessage)
            }
        }
    }

    private func currentSeasonCard(_ standing: TeamSeasonStanding) -> some View {
        let recentForm = TeamDetailsFormResolver.recentForm(
            context: context,
            standing: standing,
            matches: viewModel.previousMatches
        )
        let metrics = [
            TeamStatistic(label: "Position", value: Self.ordinal(standing.row.position)),
            TeamStatistic(label: "Played", value: String(standing.row.played)),
            TeamStatistic(label: "Won", value: String(standing.row.won)),
            TeamStatistic(label: "Drawn", value: String(standing.row.drawn)),
            TeamStatistic(label: "Lost", value: String(standing.row.lost)),
            TeamStatistic(label: "Goals for", value: String(standing.row.goalsFor)),
            TeamStatistic(label: "Goals against", value: String(standing.row.goalsAgainst)),
            TeamStatistic(label: "Goal difference", value: Self.signed(standing.row.goalDifference)),
            TeamStatistic(label: "Points", value: String(standing.row.points)),
        ]

        return Button {
            TablesNavigationCoordinator.shared.navigate(
                leagueID: standing.leagueID,
                teamName: context.teamName,
                returnTitle: "Back to team details"
            )
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(standing.leagueName)
                            .font(.headline)
                        if let groupName = standing.groupName, !groupName.isEmpty {
                            Text(groupName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if standing.realtime || standing.row.live {
                        Label("Live", systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.12), in: Capsule())
                    }
                    HStack(spacing: 4) {
                        Text("View table")
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 82, maximum: 130), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(metrics) { statistic in
                        TeamStatisticTile(statistic: statistic)
                    }
                }

                if !recentForm.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent form")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 7) {
                            ForEach(Array(recentForm.enumerated()), id: \.offset) { _, result in
                                TeamFormBadge(result: result)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Recent form, \(recentForm.joined(separator: ", "))")
                    }
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows \(context.canonicalName) highlighted in the league table")
    }

    @ViewBuilder
    private var previousMatchesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Previous matches")

            if viewModel.previousMatches.isEmpty && viewModel.isLoadingMatches {
                loadingCard(label: "Loading previous matches")
            } else if viewModel.previousMatches.isEmpty {
                unavailableCard(
                    title: "No previous matches",
                    message: "No completed matches were found for this team in the past year.",
                    systemImage: "calendar.badge.exclamationmark"
                )
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.previousMatches) { match in
                        previousMatchRow(match)
                    }
                }
            }

            if let errorMessage = viewModel.matchesErrorMessage, !viewModel.previousMatches.isEmpty {
                inlineError(errorMessage)
            }
        }
    }

    private func previousMatchRow(_ match: Match) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(Self.displayDate(for: match))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(match.displayLeague)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)

            NavigationLink {
                MatchDetailView(match: match, showFantasyBadge: false)
            } label: {
                HStack(spacing: 0) {
                    MatchRow(
                        match: match,
                        showLeague: false,
                        showFantasyBadge: false,
                        teamLogoScale: 1.1,
                        showsFinishedInlineAggregateBrackets: true,
                        layoutStyle: .compactFixture,
                        rowPreferences: .disabledFantasy
                    )
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Color(.tertiaryLabel))
                        .frame(width: 18)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens match details")
        }
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.bold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadingCard(label: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func unavailableCard(title: String, message: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again") {
                Task {
                    await viewModel.load(
                        context: context,
                        apiBaseURL: preferences.apiBaseURL,
                        force: true
                    )
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func inlineError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func displayDate(for match: Match) -> String {
        guard let date = match.dateOnly else { return match.date }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
    }

    private static func ordinal(_ value: Int) -> String {
        let remainder100 = value % 100
        if remainder100 >= 11 && remainder100 <= 13 {
            return "\(value)th"
        }
        switch value % 10 {
        case 1: return "\(value)st"
        case 2: return "\(value)nd"
        case 3: return "\(value)rd"
        default: return "\(value)th"
        }
    }

    private static func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : String(value)
    }
}

private struct TeamStatistic: Identifiable {
    let label: String
    let value: String

    var id: String { label }
}

private struct TeamStatisticTile: View {
    let statistic: TeamStatistic

    var body: some View {
        VStack(spacing: 3) {
            Text(statistic.value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(statistic.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 62)
        .padding(.horizontal, 6)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(statistic.label), \(statistic.value)")
    }
}

private struct TeamFormBadge: View {
    let result: String

    private var normalizedResult: String {
        String(result.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().prefix(1))
    }

    private var color: Color {
        switch normalizedResult {
        case "W": return .green
        case "D": return .gray
        case "L": return .red
        default: return .secondary
        }
    }

    var body: some View {
        Text(normalizedResult.isEmpty ? "–" : normalizedResult)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 27, height: 27)
            .background(color, in: Circle())
    }
}
