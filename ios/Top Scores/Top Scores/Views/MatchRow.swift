import Foundation
import SwiftUI
import EventKit

struct MatchRow: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @AppStorage(AppGroupConfig.fantasyManagerEntryIDKey) private var fantasyManagerEntryID = ""

    let match: Match
    var highlightToday: Bool = false
    var showTeamEvents: Bool = false
    var showLeague: Bool = false
    var showBroadcastDetails: Bool = true
    var showFantasyBadge: Bool = true
    var showFantasyPlayerContributions: Bool = false
    var centerFooterText: String? = nil
    var centerFooterColor: Color = .secondary
    var isLargePresentation: Bool = false
    var teamLogoScale: CGFloat = 1.0
    var fantasyContext: FantasyMatchRowContext = .empty

    var body: some View {
        matchCard
    }

    private var matchCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showLeague {
                Text(match.displayLeague)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 10) {
                    TeamLogo(name: match.homeTeam, size: logoSize)

                    HStack(alignment: .center, spacing: 8) {
                        Text(match.homeTeam)
                            .font(teamNameFont)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .layoutPriority(1)

                        scoreAndStatusRow

                        Text(match.awayTeam)
                            .font(teamNameFont)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
                    }
                    .frame(maxWidth: .infinity)

                    TeamLogo(name: match.awayTeam, size: logoSize)
                }
                .frame(maxWidth: .infinity)

                if let winnerSummaryText = match.winnerSummaryText {
                    Text(winnerSummaryText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 2)
                } else if let aggregateSummaryText = match.aggregateSummaryText {
                    Text("(\(aggregateSummaryText))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                if match.winnerSummaryText == nil, let penaltyResult = match.penaltyResult {
                    Text(penaltyResult)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 2)
                }

                if showTeamEvents && hasTeamMatchEvents {
                    MatchTeamEventListView(entries: teamEventEntries)
                        .padding(.top, 4)
                }

                if let centerFooterText, !centerFooterText.isEmpty {
                    Text(centerFooterText)
                        .font(centerFooterFont)
                        .fontWeight(.semibold)
                        .foregroundStyle(centerFooterColor)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 4)
                }
            }

            if shouldShowFooterRow {
                footerRow
            }
        }
        .padding(cardPadding)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .stroke(highlightToday ? Color(.systemYellow).opacity(0.35) : .clear, lineWidth: 1)
        )
    }

    private var homeScoreText: String? {
        match.homeScore.map(String.init)
    }

    private var awayScoreText: String? {
        match.awayScore.map(String.init)
    }

    private var centerStatusText: String {
        if let status = match.displayScoreStatus {
            return status
        }
        if match.hasScore {
            return "-"
        }
        return match.time
    }

    private var isMatchFinished: Bool {
        match.isFinished
    }

    private var fantasyBadgeMode: FantasyMatchParticipationBadge.Mode? {
        guard showFantasyBadge,
              !fantasyManagerEntryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              preferences.showFantasyMatchPills,
              fantasyContext.isEligibleFixture(match),
              let lookup = fantasyContext.lookup
        else {
            return nil
        }

        let participationCount = lookup.participationCount(in: match)
        guard participationCount > 0 else { return nil }

        if match.isUpcomingScorelessFixture {
            return .upcoming
        }

        return .score(lookup.effectiveScore(in: match))
    }

    private var fantasyPlayerContributions: [FantasyMatchContributionDisplay] {
        guard showFantasyPlayerContributions,
              fantasyBadgeMode != nil,
              !fantasyManagerEntryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              preferences.showFantasyMatchPills,
              fantasyContext.isEligibleFixture(match),
              let lookup = fantasyContext.lookup
        else {
            return []
        }

        return lookup.involvedPlayers(
            in: match,
            preferExpectedPoints: match.isUpcomingScorelessFixture && lookup.hasExpectedPoints
        )
    }

    private var shouldShowFooterRow: Bool {
        (showBroadcastDetails && !isMatchFinished) || fantasyBadgeMode != nil
    }

    @ViewBuilder
    private var footerRow: some View {
        HStack(alignment: .center, spacing: 8) {
            footerLeadingContent

            if showBroadcastDetails && !isMatchFinished {
                TvLogoRow(channels: match.tvChannels)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if let fantasyBadgeMode {
                FantasyMatchParticipationBadge(mode: fantasyBadgeMode)
                    .padding(.leading, showBroadcastDetails && !isMatchFinished ? 4 : 0)
            }
        }
    }

    @ViewBuilder
    private var footerLeadingContent: some View {
        if !fantasyPlayerContributions.isEmpty {
            FantasyMatchContributionStrip(contributions: fantasyPlayerContributions)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
        } else if showBroadcastDetails && !isMatchFinished {
            Text(match.tvChannels.isEmpty ? "TV TBA" : match.tvChannels.joined(separator: " • "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
        } else {
            Spacer(minLength: 0)
        }
    }

    private var scoreAndStatusRow: some View {
        HStack(spacing: 8) {
            if let homeScoreText {
                Text(homeScoreText)
                    .font(scoreFont)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .frame(minWidth: 14, alignment: .trailing)
            }

            MatchTimeStatusView(
                text: centerStatusText,
                isLive: match.isInProgress,
                isLargePresentation: isLargePresentation
            )
            .fixedSize(horizontal: true, vertical: false)

            if let awayScoreText {
                Text(awayScoreText)
                    .font(scoreFont)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .frame(minWidth: 14, alignment: .leading)
            }
        }
    }

    private var teamNameFont: Font {
        isLargePresentation ? .caption : .subheadline
    }

    private var centerFooterFont: Font {
        isLargePresentation ? .caption : .caption2
    }

    private var scoreFont: Font {
        isLargePresentation ? .caption : .headline
    }

    private var logoSize: CGFloat {
        let baseSize: CGFloat = isLargePresentation ? 34 : 22
        return baseSize * teamLogoScale
    }

    private var cardPadding: CGFloat {
        isLargePresentation ? 16 : 12
    }

    private var cardCornerRadius: CGFloat {
        isLargePresentation ? 18 : 14
    }

    private var homeTeamEvents: [MatchTeamTimelineEvent] {
        MatchTimelineBuilder.teamTimelineEvents(
            goals: match.homeGoalScorers,
            assists: match.homeAssists,
            redCards: match.homeRedCards
        )
    }

    private var awayTeamEvents: [MatchTeamTimelineEvent] {
        MatchTimelineBuilder.teamTimelineEvents(
            goals: match.awayGoalScorers,
            assists: match.awayAssists,
            redCards: match.awayRedCards
        )
    }

    private var hasTeamMatchEvents: Bool {
        !homeTeamEvents.isEmpty || !awayTeamEvents.isEmpty
    }

    private var teamEventEntries: [MatchTeamEventEntry] {
        MatchTimelineBuilder.mergedTeamTimelineEvents(
            homeGoals: match.homeGoalScorers,
            homeAssists: match.homeAssists,
            homeRedCards: match.homeRedCards,
            awayGoals: match.awayGoalScorers,
            awayAssists: match.awayAssists,
            awayRedCards: match.awayRedCards
        )
    }
}

private struct FantasyMatchParticipationBadge: View {
    enum Mode {
        case upcoming
        case score(Int)
    }

    let mode: Mode

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.95, green: 0.20, blue: 0.66),
                            Color(red: 1.0, green: 0.29, blue: 0.29)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)

            switch mode {
            case .upcoming:
                FantasyLionIconView(size: 14, scale: 1.10)
                    .foregroundStyle(.white)
            case .score(let score):
                Text("\(score)")
                    .font(.system(size: score >= 10 ? 11 : 12, weight: .black, design: .rounded))
                    .foregroundStyle(Color.white)
                    .minimumScaleFactor(0.8)
            }
        }
            .frame(width: 28, height: 28)
            .shadow(color: Color.red.opacity(0.18), radius: 3, x: 0, y: 1)
            .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch mode {
        case .upcoming:
            return "Fantasy players involved"
        case .score(let score):
            return "\(score) fantasy points involved"
        }
    }
}

struct FantasyMatchContributionDisplay: Identifiable, Hashable {
    enum PointsDisplay: Hashable {
        case actual(Int)
        case expected(Int)

        var value: Int {
            switch self {
            case .actual(let value), .expected(let value):
                return value
            }
        }

        var text: String {
            switch self {
            case .actual(let value):
                return "\(value)"
            case .expected(let value):
                return "xP: \(value)"
            }
        }

        var accessibilityText: String {
            switch self {
            case .actual(let value):
                return "\(value) points"
            case .expected(let value):
                return "expected \(value) points"
            }
        }
    }

    let elementID: Int
    let displayName: String
    let pointsDisplay: PointsDisplay
    let teamOrder: Int
    let pickPosition: Int
    let isRealMatchSubstitute: Bool

    var isStarter: Bool {
        pickPosition <= 11
    }

    var id: Int {
        elementID
    }
}

private struct FantasyMatchContributionStrip: View {
    let contributions: [FantasyMatchContributionDisplay]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(contributions) { contribution in
                    FantasyMatchContributionChip(contribution: contribution)
                }
            }
            .padding(.vertical, 1)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct FantasyMatchContributionChip: View {
    let contribution: FantasyMatchContributionDisplay

    private var textOpacity: Double {
        contribution.isStarter ? 1.0 : 0.6
    }

    private var pillOpacity: Double {
        contribution.isStarter ? 0.92 : 0.55
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(contribution.displayName)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .opacity(textOpacity)
                .lineLimit(1)

            if contribution.isRealMatchSubstitute {
                MatchLineupFantasySubstituteWarningIcon()
                    .opacity(textOpacity)
            }

            if !contribution.isStarter {
                Text("(bench)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .opacity(0.5)
            }

            Text(contribution.pointsDisplay.text)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(fantasyPointsHeatmapColor(contribution.pointsDisplay.value).opacity(pillOpacity))
                )
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(
            contribution.isStarter
                ? contributionAccessibilityLabel(role: "starter")
                : contributionAccessibilityLabel(role: "bench")
        )
    }

    private func contributionAccessibilityLabel(role: String) -> String {
        if contribution.isRealMatchSubstitute {
            return "\(contribution.displayName), listed as substitute in real match, \(role), \(contribution.pointsDisplay.accessibilityText)"
        }
        return "\(contribution.displayName), \(role), \(contribution.pointsDisplay.accessibilityText)"
    }
}

struct MatchDetailView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var fantasyViewModel: FantasyViewModel
    @AppStorage(AppGroupConfig.fantasyManagerEntryIDKey) private var fantasyManagerEntryID = ""

    let match: Match
    var highlightToday: Bool = false
    var showFantasyBadge: Bool = true

    @State private var actionAlert: MatchActionAlert?
    @State private var showCalendarPicker = false
    @State private var calendarChoices: [CalendarChoice] = []
    @State private var saveCalendarAsDefault = false
    @State private var detailedMatch: Match?
    @State private var detailsRefreshTask: Task<Void, Never>?
    @State private var detailsErrorMessage: String?

    private static let detailsRefreshIntervalNanos: UInt64 = 10_000_000_000
    private static let detailsCacheKeyPrefix = "match.details.cache."

    private var activeMatch: Match {
        detailedMatch ?? match
    }

    private var kickoffText: String {
        if let kickoff = activeMatch.dateTime {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE d MMM, HH:mm"
            return formatter.string(from: kickoff)
        }

        return "\(activeMatch.date) \(activeMatch.time)"
    }

    private var shouldShowMatchActions: Bool {
        guard let kickoff = activeMatch.dateTime else { return false }
        return kickoff > Date()
    }

    private var isMatchFinished: Bool {
        activeMatch.isFinished
    }

    private var sortedChannels: [String] {
        activeMatch.tvChannels.sorted { lhs, rhs in
            lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    private var shouldShowLineupPitch: Bool {
        guard let teamLineups = activeMatch.teamLineups,
              let home = teamLineups.home,
              let away = teamLineups.away
        else {
            return false
        }

        return home.startingLineup.count == 11 && away.startingLineup.count == 11
    }

    private var isEligibleFantasyFixture: Bool {
        fantasyViewModel.isEligibleFantasyFixture(activeMatch)
    }

    private var fantasyHighlightLookup: FantasySquadMembershipLookup? {
        guard isEligibleFantasyFixture else { return nil }
        return FantasySquadMembershipLookup(squad: fantasyViewModel.data)
    }

    private var shouldLoadFantasySquad: Bool {
        isEligibleFantasyFixture &&
        !fantasyManagerEntryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var fantasySquadSections: [FantasyMatchTeamSquadSection] {
        guard isEligibleFantasyFixture,
              let squad = fantasyViewModel.data?.applyingExpectedPoints(
                fantasyViewModel.assistantManagerPreview?.expectedPoints
              )
        else {
            return []
        }

        return [
            squad.matchSquadSection(forTeamName: activeMatch.homeTeam),
            squad.matchSquadSection(forTeamName: activeMatch.awayTeam)
        ]
        .compactMap { $0 }
        .filter(\.hasPlayers)
    }

    private var shouldShowFantasySquadFallback: Bool {
        !shouldShowLineupPitch && !fantasySquadSections.isEmpty
    }

    private var tvChannelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sortedChannels.isEmpty {
                Text("TV TBA")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sortedChannels, id: \.self) { channel in
                    TvChannelRow(channel: channel)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(activeMatch.displayLeague)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(kickoffText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                MatchRow(
                    match: activeMatch,
                    highlightToday: highlightToday,
                    showTeamEvents: true,
                    showFantasyBadge: showFantasyBadge,
                    fantasyContext: fantasyViewModel.matchRowContext
                )
                    .padding(.horizontal)

                if let detailsErrorMessage {
                    Text(detailsErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                if shouldShowLineupPitch {
                    MatchLineupPitchSection(
                        match: activeMatch,
                        fantasyHighlightLookup: fantasyHighlightLookup
                    )
                        .padding(.horizontal)
                }

                if shouldShowFantasySquadFallback {
                    FantasyMatchSquadSectionsView(sections: fantasySquadSections)
                        .padding(.horizontal)
                }

                if !isMatchFinished {
                    tvChannelSection
                        .padding(.horizontal)
                }

                if shouldShowMatchActions {
                    actionPanel
                        .padding(.horizontal)
                }
            }
            .padding(.vertical, 12)
        }
        .navigationTitle("Match Details")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            startDetailsRefresh()
            ensureFantasySquadLoadedIfNeeded()
            reportMissingTeamLogosIfNeeded(for: activeMatch)
        }
        .onDisappear {
            detailsRefreshTask?.cancel()
            detailsRefreshTask = nil
        }
        .onChange(of: preferences.apiBaseURL) { _, _ in
            startDetailsRefresh()
            ensureFantasySquadLoadedIfNeeded()
        }
        .onChange(of: fantasyManagerEntryID) { _, _ in
            ensureFantasySquadLoadedIfNeeded()
        }
        .alert(item: $actionAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
        .sheet(isPresented: $showCalendarPicker) {
            NavigationStack {
                List {
                    Section("Calendars") {
                        ForEach(calendarChoices) { choice in
                            Button {
                                selectCalendar(choice)
                            } label: {
                                Text(choice.title)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    Section {
                        Toggle("Use as default", isOn: $saveCalendarAsDefault)
                    }
                }
                .navigationTitle("Add to Calendar")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            showCalendarPicker = false
                        }
                    }
                }
            }
        }
    }

    private var actionPanel: some View {
        HStack(spacing: 12) {
            Button {
                addEvent()
            } label: {
                Label("Add to Calendar", systemImage: "calendar.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Menu {
                Button("15 minutes before") {
                    addReminder(leadTime: 15 * 60, label: "15 minutes")
                }
                Button("30 minutes before") {
                    addReminder(leadTime: 30 * 60, label: "30 minutes")
                }
                Button("1 hour before") {
                    addReminder(leadTime: 60 * 60, label: "1 hour")
                }
            } label: {
                Label("Add Reminder", systemImage: "bell.badge")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private func addEvent() {
        Task { @MainActor in
            do {
                let calendars = try await MatchSchedulingService.shared.eventCalendars()
                if let savedId = MatchSchedulingService.shared.defaultEventCalendarIdentifier,
                   calendars.contains(where: { $0.calendarIdentifier == savedId }) {
                    try await MatchSchedulingService.shared.addEvent(for: activeMatch, calendarIdentifier: savedId)
                    actionAlert = MatchActionAlert(title: "Added to Calendar", message: "This match has been added to your calendar.")
                    return
                }

                if calendars.count <= 1 {
                    let calendarId = calendars.first?.calendarIdentifier
                    try await MatchSchedulingService.shared.addEvent(for: activeMatch, calendarIdentifier: calendarId)
                    actionAlert = MatchActionAlert(title: "Added to Calendar", message: "This match has been added to your calendar.")
                    return
                }

                calendarChoices = calendars.map { CalendarChoice(id: $0.calendarIdentifier, title: $0.title) }
                saveCalendarAsDefault = false
                showCalendarPicker = true
            } catch {
                actionAlert = MatchActionAlert(title: "Unable to Add Event", message: error.localizedDescription)
            }
        }
    }

    private func addReminder(leadTime: TimeInterval, label: String) {
        Task { @MainActor in
            do {
                try await MatchSchedulingService.shared.addReminder(for: activeMatch, leadTime: leadTime)
                actionAlert = MatchActionAlert(title: "Reminder Set", message: "We'll remind you \(label) before kickoff.")
            } catch {
                actionAlert = MatchActionAlert(title: "Unable to Add Reminder", message: error.localizedDescription)
            }
        }
    }

    private func selectCalendar(_ choice: CalendarChoice) {
        showCalendarPicker = false
        Task { @MainActor in
            do {
                try await MatchSchedulingService.shared.addEvent(for: activeMatch, calendarIdentifier: choice.id)
                if saveCalendarAsDefault {
                    MatchSchedulingService.shared.defaultEventCalendarIdentifier = choice.id
                }
                actionAlert = MatchActionAlert(title: "Added to Calendar", message: "This match has been added to your calendar.")
            } catch {
                actionAlert = MatchActionAlert(title: "Unable to Add Event", message: error.localizedDescription)
            }
        }
    }

    private func startDetailsRefresh() {
        detailsRefreshTask?.cancel()
        detailsRefreshTask = nil
        detailsErrorMessage = nil

        guard let detailsID = match.matchDetailsID else {
            if match.isTestMatch == true {
                detailedMatch = match
                return
            }
            NSLog(
                "Match details id missing for %@ vs %@ (league=%@ date=%@ time=%@)",
                match.homeTeam,
                match.awayTeam,
                match.league,
                match.date,
                match.time
            )
            detailsErrorMessage = "Live events unavailable for this match."
            detailedMatch = match
            return
        }

        if let cached = Self.loadCachedDetails(for: detailsID) {
            detailedMatch = match.withDetails(cached)
        } else {
            detailedMatch = match
        }

        guard let baseURL = URL(string: preferences.apiBaseURL) else {
            detailsErrorMessage = "Invalid API base URL."
            return
        }

        detailsRefreshTask = Task {
            while !Task.isCancelled {
                let fetched = await refreshDetailsOnce(detailsID: detailsID, baseURL: baseURL)
                if fetched {
                    let isLive = await MainActor.run { activeMatch.isInProgress }
                    if !isLive { break }
                }
                try? await Task.sleep(nanoseconds: Self.detailsRefreshIntervalNanos)
            }
        }
    }

    private func refreshDetailsOnce(detailsID: String, baseURL: URL) async -> Bool {
        let client = APIClient(baseURL: baseURL)
        do {
            let details = try await client.fetchMatchDetails(matchId: detailsID)
            if Task.isCancelled { return false }
            NSLog(
                "Match details updated id=%@ homeGoals=%ld awayGoals=%ld homeAssists=%ld awayAssists=%ld status=%@",
                detailsID,
                details.homeGoalScorers.count,
                details.awayGoalScorers.count,
                details.homeAssists.count,
                details.awayAssists.count,
                details.scoreStatus ?? "-"
            )
            await MainActor.run {
                detailedMatch = activeMatch.withDetails(details)
                detailsErrorMessage = nil
            }
            Self.saveCachedDetails(details, for: detailsID)
            return true
        } catch {
            if Self.isCancellationError(error) { return false }
            NSLog("Match details refresh failed id=%@ error=%@", detailsID, String(describing: error))
            await MainActor.run {
                detailsErrorMessage = detailedMatch == nil
                    ? "Unable to load match events."
                    : "Using cached match events."
            }
            return false
        }
    }

    private func ensureFantasySquadLoadedIfNeeded() {
        guard shouldLoadFantasySquad,
              fantasyViewModel.data == nil,
              !fantasyViewModel.isLoading,
              !fantasyViewModel.isRefreshing
        else {
            return
        }

        Task {
            await fantasyViewModel.refresh(
                managerEntryID: fantasyManagerEntryID,
                apiBaseURL: preferences.apiBaseURL,
                rivalManagers: [],
                trackedLeagues: []
            )
        }
    }

    private func reportMissingTeamLogosIfNeeded(for match: Match) {
        let missingTeamNames = LogoResolver.shared.missingTeamNames(in: [match.homeTeam, match.awayTeam])
        guard !missingTeamNames.isEmpty else { return }
        guard let baseURL = URL(string: preferences.apiBaseURL) else { return }

        Task {
            let client = APIClient(baseURL: baseURL)
            do {
                try await client.reportMissingTeamLogos(missingTeamNames)
            } catch {
                NSLog("Missing logo audit post failed error=%@", String(describing: error))
            }
        }
    }

    private static func detailsCacheKey(for detailsID: String) -> String {
        "\(detailsCacheKeyPrefix)\(detailsID)"
    }

    private static func saveCachedDetails(_ details: MatchDetailsPayload, for detailsID: String) {
        do {
            let encoded = try JSONEncoder().encode(details)
            UserDefaults.standard.set(encoded, forKey: detailsCacheKey(for: detailsID))
        } catch {
            NSLog("Failed to cache match details id=%@ error=%@", detailsID, String(describing: error))
        }
    }

    private static func loadCachedDetails(for detailsID: String) -> MatchDetailsPayload? {
        guard let data = UserDefaults.standard.data(forKey: detailsCacheKey(for: detailsID)) else {
            return nil
        }
        do {
            let cached = try JSONDecoder().decode(MatchDetailsPayload.self, from: data)

            // Check if cached data is stale (older than 30 seconds)
            if let updatedAt = cached.updatedAt {
                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let timestamp = isoFormatter.date(from: updatedAt) {
                    let age = Date().timeIntervalSince(timestamp)
                    if age > 30 {
                        NSLog("Cached match details stale id=%@ age=%.1fs, clearing cache", detailsID, age)
                        UserDefaults.standard.removeObject(forKey: detailsCacheKey(for: detailsID))
                        return nil
                    }
                }
            }

            return cached
        } catch {
            NSLog("Failed to decode cached match details id=%@ error=%@", detailsID, String(describing: error))
            return nil
        }
    }

    private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

private struct FantasyMatchSquadSectionsView: View {
    let sections: [FantasyMatchTeamSquadSection]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FPL involvement")
                .font(.headline)
                .foregroundStyle(.primary)

            ForEach(sections) { section in
                FantasyMatchSquadTeamSectionView(section: section)
            }
        }
    }
}

private struct FantasyMatchSquadTeamSectionView: View {
    let section: FantasyMatchTeamSquadSection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.teamName)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)

            if !section.starters.isEmpty {
                FantasyMatchSquadBucketView(
                    title: "Starting XI",
                    tint: Color(red: 0.95, green: 0.20, blue: 0.66),
                    players: section.starters
                )
            }

            if !section.bench.isEmpty {
                FantasyMatchSquadBucketView(
                    title: "Bench",
                    tint: .secondary,
                    players: section.bench
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

private struct FantasyMatchSquadBucketView: View {
    let title: String
    let tint: Color
    let players: [FantasyDisplayPlayer]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(players) { player in
                    FantasyMatchSquadPlayerRow(
                        name: playerDisplayName(player),
                        expectedPoints: player.expectedPointsThisGameweek
                    )
                }
            }
        }
    }

    private func playerDisplayName(_ player: FantasyDisplayPlayer) -> String {
        let preferred = player.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferred.isEmpty {
            return preferred
        }
        return player.displayName
    }
}

private struct FantasyMatchSquadPlayerRow: View {
    let name: String
    let expectedPoints: Int?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(name)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Text(expectedPointsLabel)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(expectedPointsForegroundColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(expectedPointsBackgroundColor)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(expectedPoints == nil ? Color.black.opacity(0.08) : .clear, lineWidth: 1)
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(expectedPointsAccessibilityLabel)")
    }

    private var expectedPointsLabel: String {
        if let expectedPoints {
            return "xP \(expectedPoints)"
        }
        return "xP -"
    }

    private var expectedPointsAccessibilityLabel: String {
        if let expectedPoints {
            return "expected \(expectedPoints) points"
        }
        return "expected points unavailable"
    }

    private var expectedPointsForegroundColor: Color {
        guard let expectedPoints else {
            return Color(red: 0.36, green: 0.36, blue: 0.39)
        }
        return expectedPoints >= 3 ? Color.black.opacity(0.82) : .white
    }

    private var expectedPointsBackgroundColor: Color {
        guard let expectedPoints else {
            return Color(red: 0.90, green: 0.90, blue: 0.92)
        }

        switch expectedPoints {
        case ..<1:
            return Color(red: 0.78, green: 0.16, blue: 0.14)
        case 1...2:
            return Color(red: 0.91, green: 0.37, blue: 0.15)
        case 3...4:
            return Color(red: 0.95, green: 0.68, blue: 0.16)
        case 5...7:
            return Color(red: 0.29, green: 0.71, blue: 0.27)
        default:
            return Color.green
        }
    }
}

private enum MatchTeamSide {
    case home
    case away

    var sortOrder: Int {
        switch self {
        case .home: return 0
        case .away: return 1
        }
    }
}

private struct MatchTeamEventEntry {
    let side: MatchTeamSide
    let event: MatchTeamTimelineEvent
}

private struct MatchTeamEventListView: View {
    let entries: [MatchTeamEventEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                MatchTeamEventLineView(entry: entry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MatchTeamEventLineView: View {
    let entry: MatchTeamEventEntry

    var body: some View {
        HStack(spacing: 4) {
            if entry.side == .home {
                MatchEventIconView(kind: entry.event.kind)
                Text(entry.event.displayMinute)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(entry.event.homePlayerAssistText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                Text(entry.event.awayPlayerAssistText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(entry.event.displayMinute)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                MatchEventIconView(kind: entry.event.kind)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MatchEventIconView: View {
    let kind: MatchEventKind

    var body: some View {
        Group {
            switch kind {
            case .goal:
                Text("⚽️")
            case .redCard:
                Text("🟥")
            case .ownGoal:
                ZStack {
                    Text("⚽️")
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.red)
                        .shadow(color: .black.opacity(0.45), radius: 0.5, x: 0, y: 0)
                }
            case .disallowedGoal:
                ZStack {
                    Text("⚽️")
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 16, height: 1.8)
                        .rotationEffect(.degrees(-28))
                        .shadow(color: .black.opacity(0.35), radius: 0.4, x: 0, y: 0)
                }
            }
        }
        .font(.caption2)
        .frame(width: 18, height: 18, alignment: .center)
    }
}

private enum MatchEventKind {
    case goal
    case ownGoal
    case redCard
    case disallowedGoal
}

private struct ParsedMinute {
    let base: Int
    let extra: Int
    let display: String
    let isPenalty: Bool

    var lookupKey: String {
        extra > 0 ? "\(base)+\(extra)" : "\(base)"
    }
}

private struct MatchAssistLookup {
    let exact: [String: String]
    let base: [Int: String]

    func name(for minute: ParsedMinute) -> String? {
        if let exactName = exact[minute.lookupKey] {
            return exactName
        }
        return base[minute.base]
    }
}

private struct MatchTeamTimelineEvent {
    let kind: MatchEventKind
    let displayMinute: String
    let playerName: String
    let assistName: String?
    let minute: ParsedMinute
    let sequence: Int

    var awayPlayerAssistText: String {
        if kind == .ownGoal {
            return "\(playerName) (OG)"
        }
        if kind == .disallowedGoal {
            var result = "Goal disallowed for \(playerName)"
            if minute.isPenalty {
                result += " (pen)"
            } else if let assistName, !assistName.isEmpty {
                result += " (\(assistName))"
            }
            return result
        }
        guard kind == .goal else {
            return playerName
        }

        var result = playerName
        if minute.isPenalty {
            result += " (pen)"
        } else if let assistName, !assistName.isEmpty {
            result += " (\(assistName))"
        }
        return result
    }

    var homePlayerAssistText: String {
        awayPlayerAssistText
    }
}

private enum MatchMinuteParser {
    static let regex = try! NSRegularExpression(pattern: "(\\d{1,3})(?:\\s*'\\s*)?(?:\\+\\s*(\\d{1,2}))?")
}

private enum MatchTimelineBuilder {
    static func mergedTeamTimelineEvents(
        homeGoals: [MatchGoalScorer],
        homeAssists: [MatchAssistProvider],
        homeRedCards: [MatchRedCardEvent],
        awayGoals: [MatchGoalScorer],
        awayAssists: [MatchAssistProvider],
        awayRedCards: [MatchRedCardEvent]
    ) -> [MatchTeamEventEntry] {
        let homeEvents = teamTimelineEvents(
            goals: homeGoals,
            assists: homeAssists,
            redCards: homeRedCards
        ).map { MatchTeamEventEntry(side: .home, event: $0) }

        let awayEvents = teamTimelineEvents(
            goals: awayGoals,
            assists: awayAssists,
            redCards: awayRedCards
        ).map { MatchTeamEventEntry(side: .away, event: $0) }

        return (homeEvents + awayEvents).sorted { lhs, rhs in
            if lhs.event.minute.base != rhs.event.minute.base {
                return lhs.event.minute.base < rhs.event.minute.base
            }
            if lhs.event.minute.extra != rhs.event.minute.extra {
                return lhs.event.minute.extra < rhs.event.minute.extra
            }
            if lhs.event.sequence != rhs.event.sequence {
                return lhs.event.sequence < rhs.event.sequence
            }
            return lhs.side.sortOrder < rhs.side.sortOrder
        }
    }

    static func teamTimelineEvents(
        goals: [MatchGoalScorer],
        assists: [MatchAssistProvider],
        redCards: [MatchRedCardEvent]
    ) -> [MatchTeamTimelineEvent] {
        let assistLookup = buildAssistLookup(assists)
        var events: [MatchTeamTimelineEvent] = []
        var sequence = 0

        for scorer in goals {
            let playerName = displayName(from: scorer.player)
            guard !playerName.isEmpty else { continue }

            for rawMinute in scorer.goalTimes {
                guard let minute = parseMinute(rawMinute) else { continue }
                events.append(
                    MatchTeamTimelineEvent(
                        kind: .goal,
                        displayMinute: minute.display,
                        playerName: playerName,
                        assistName: assistLookup.name(for: minute),
                        minute: minute,
                        sequence: sequence
                    )
                )
                sequence += 1
            }

            for rawMinute in scorer.ownGoalTimes {
                guard let minute = parseMinute(rawMinute) else { continue }
                events.append(
                    MatchTeamTimelineEvent(
                        kind: .ownGoal,
                        displayMinute: minute.display,
                        playerName: playerName,
                        assistName: nil,
                        minute: minute,
                        sequence: sequence
                    )
                )
                sequence += 1
            }

            for rawMinute in scorer.disallowedGoalTimes {
                guard let minute = parseMinute(rawMinute) else { continue }
                events.append(
                    MatchTeamTimelineEvent(
                        kind: .disallowedGoal,
                        displayMinute: minute.display,
                        playerName: playerName,
                        assistName: assistLookup.name(for: minute),
                        minute: minute,
                        sequence: sequence
                    )
                )
                sequence += 1
            }
        }

        for redCard in redCards {
            let playerName = displayName(from: redCard.player)
            guard !playerName.isEmpty else { continue }

            for rawMinute in redCard.redCardTimes {
                guard let minute = parseMinute(rawMinute) else { continue }
                events.append(
                    MatchTeamTimelineEvent(
                        kind: .redCard,
                        displayMinute: minute.display,
                        playerName: playerName,
                        assistName: nil,
                        minute: minute,
                        sequence: sequence
                    )
                )
                sequence += 1
            }
        }

        return events.sorted { lhs, rhs in
            if lhs.minute.base != rhs.minute.base {
                return lhs.minute.base < rhs.minute.base
            }
            if lhs.minute.extra != rhs.minute.extra {
                return lhs.minute.extra < rhs.minute.extra
            }
            return lhs.sequence < rhs.sequence
        }
    }

    private static func buildAssistLookup(_ assists: [MatchAssistProvider]) -> MatchAssistLookup {
        var exact: [String: String] = [:]
        var base: [Int: String] = [:]
        var conflictingBaseMinutes = Set<Int>()

        for assist in assists {
            let assisterName = displayName(from: assist.player)
            guard !assisterName.isEmpty else { continue }

            for rawMinute in assist.assistTimes {
                guard let minute = parseMinute(rawMinute) else { continue }
                exact[minute.lookupKey] = assisterName

                if let existing = base[minute.base], existing != assisterName {
                    conflictingBaseMinutes.insert(minute.base)
                    base.removeValue(forKey: minute.base)
                } else if !conflictingBaseMinutes.contains(minute.base) {
                    base[minute.base] = assisterName
                }
            }
        }

        return MatchAssistLookup(exact: exact, base: base)
    }

    private static func parseMinute(_ rawValue: String) -> ParsedMinute? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "'", with: "'")
            .replacingOccurrences(of: "′", with: "'")
        guard !normalized.isEmpty else { return nil }

        let isPenalty = normalized.lowercased().contains("pen")

        let nsRange = NSRange(normalized.startIndex..., in: normalized)
        guard let match = MatchMinuteParser.regex.firstMatch(in: normalized, options: [], range: nsRange) else {
            return nil
        }

        guard let baseRange = Range(match.range(at: 1), in: normalized),
              let base = Int(normalized[baseRange])
        else {
            return nil
        }

        var extra = 0
        if let extraRange = Range(match.range(at: 2), in: normalized),
           let parsedExtra = Int(normalized[extraRange]) {
            extra = parsedExtra
        }

        let display = extra > 0 ? "\(base)+\(extra)'" : "\(base)'"
        return ParsedMinute(base: base, extra: extra, display: display, isPenalty: isPenalty)
    }

    private static func displayName(from rawName: String) -> String {
        abbreviatePlayerName(rawName.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func abbreviatePlayerName(_ fullName: String) -> String {
        let components = fullName.split(separator: " ").map(String.init)
        guard components.count > 1 else { return fullName }

        let abbreviated = components.dropLast().map { component in
            guard let firstChar = component.first else { return "" }
            return "\(firstChar)."
        }

        let lastName = components.last ?? ""
        return (abbreviated + [lastName]).joined(separator: " ")
    }
}

private struct MatchActionAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct MatchTimeStatusView: View {
    let text: String
    let isLive: Bool
    var isLargePresentation: Bool = false

    @State private var isPulsing = false

    var body: some View {
        Text(text)
            .font(statusFont)
            .fontWeight(isLive ? .semibold : .regular)
            .foregroundStyle(isLive ? Color.red : Color.secondary)
            .monospacedDigit()
            .padding(.horizontal, isLive ? 8 : 0)
            .padding(.vertical, isLive ? 5 : 0)
            .frame(minWidth: isLive ? 28 : nil)
            .background {
                if isLive {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.red.opacity(isPulsing ? 0.14 : 0.26))
                }
            }
            .overlay {
                if isLive {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.red.opacity(isPulsing ? 0.45 : 0.95), lineWidth: 1)
                        .scaleEffect(isPulsing ? 1.08 : 1.0)
                }
            }
            .animation(
                isLive ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                value: isPulsing
            )
            .onAppear {
                isPulsing = isLive
            }
            .onChange(of: isLive) { _, newValue in
                isPulsing = newValue
            }
    }

    private var statusFont: Font {
        isLargePresentation ? .subheadline : .caption
    }
}

private struct MatchLineupPitchSection: View {
    let match: Match
    let fantasyHighlightLookup: FantasySquadMembershipLookup?

    var body: some View {
        if let teamLineups = match.teamLineups,
           let home = teamLineups.home,
           let away = teamLineups.away,
           home.startingLineup.count == 11,
           away.startingLineup.count == 11 {
            VStack(alignment: .leading, spacing: 10) {
                Text("Starting Line-ups")
                    .font(.headline)
                    .foregroundStyle(.primary)

                MatchLineupPitchView(
                    homeLineup: home,
                    awayLineup: away,
                    homeGoals: match.homeGoalScorers,
                    awayGoals: match.awayGoalScorers,
                    homeAssists: match.homeAssists,
                    awayAssists: match.awayAssists,
                    homeYellowCards: match.homeYellowCards,
                    awayYellowCards: match.awayYellowCards,
                    homeRedCards: match.homeRedCards,
                    awayRedCards: match.awayRedCards,
                    fantasyHighlightLookup: fantasyHighlightLookup
                )

                MatchLineupSubstitutesSection(
                    homeLineup: home,
                    awayLineup: away,
                    fantasyHighlightLookup: fantasyHighlightLookup
                )
            }
        }
    }
}

private struct MatchLineupPitchView: View {
    let homeLineup: MatchTeamLineup
    let awayLineup: MatchTeamLineup
    let homeGoals: [MatchGoalScorer]
    let awayGoals: [MatchGoalScorer]
    let homeAssists: [MatchAssistProvider]
    let awayAssists: [MatchAssistProvider]
    let homeYellowCards: [MatchYellowCardEvent]
    let awayYellowCards: [MatchYellowCardEvent]
    let homeRedCards: [MatchRedCardEvent]
    let awayRedCards: [MatchRedCardEvent]
    let fantasyHighlightLookup: FantasySquadMembershipLookup?

    private var homeLookup: MatchLineupEventLookup {
        MatchLineupEventLookup(
            goals: homeGoals,
            assists: homeAssists,
            yellowCards: homeYellowCards,
            redCards: homeRedCards,
            substitutions: homeLineup.substitutions
        )
    }

    private var awayLookup: MatchLineupEventLookup {
        MatchLineupEventLookup(
            goals: awayGoals,
            assists: awayAssists,
            yellowCards: awayYellowCards,
            redCards: awayRedCards,
            substitutions: awayLineup.substitutions
        )
    }

    private var homeTeamName: String {
        homeLineup.team ?? "Home"
    }

    private var awayTeamName: String {
        awayLineup.team ?? "Away"
    }

    var body: some View {
        ZStack {
            MatchLineupPitchBackground()

            VStack(spacing: 0) {
                MatchLineupHalfView(
                    teamName: homeTeamName,
                    opponentTeamName: awayTeamName,
                    formation: homeLineup.formation,
                    starters: homeLineup.startingLineup,
                    lookup: homeLookup,
                    fantasyHighlightLookup: fantasyHighlightLookup,
                    side: .home
                )

                MatchLineupHalfView(
                    teamName: awayTeamName,
                    opponentTeamName: homeTeamName,
                    formation: awayLineup.formation,
                    starters: awayLineup.startingLineup,
                    lookup: awayLookup,
                    fantasyHighlightLookup: fantasyHighlightLookup,
                    side: .away
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 18)
        }
        .aspectRatio(0.62, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct MatchLineupHalfView: View {
    @ObservedObject private var teamColorCatalog = TeamColorCatalog.shared
    let teamName: String
    let opponentTeamName: String
    let formation: String?
    let starters: [MatchLineupPlayer]
    let lookup: MatchLineupEventLookup
    let fantasyHighlightLookup: FantasySquadMembershipLookup?
    let side: MatchLineupDisplaySide

    private var groupedRows: [[MatchLineupPlayer]] {
        let playersWithFormationRows = starters.filter { $0.formationRowIndex != nil && $0.formationSlotIndex != nil }
        if playersWithFormationRows.count == starters.count {
            let groupedByIndex = Dictionary(grouping: starters) { $0.formationRowIndex ?? 0 }
            let grouped = groupedByIndex.keys.sorted().compactMap { rowIndex in
                groupedByIndex[rowIndex]?.sorted {
                    let leftSlot = $0.formationSlotIndex ?? 0
                    let rightSlot = $1.formationSlotIndex ?? 0
                    if leftSlot != rightSlot {
                        return leftSlot < rightSlot
                    }
                    return $0.number < $1.number
                }
            }
            if side == .home {
                return grouped
            }
            return Array(grouped.reversed())
        }

        let goalkeepers = starters.filter { $0.positionCategory == "goalkeeper" }
        let defenders = starters.filter { $0.positionCategory == "defender" }
        let midfielders = starters.filter { $0.positionCategory == "midfielder" }
        let attackers = starters.filter { $0.positionCategory == "attacker" }

        if side == .home {
            return [goalkeepers, defenders, midfielders, attackers].filter { !$0.isEmpty }
        }
        return [attackers, midfielders, defenders, goalkeepers].filter { !$0.isEmpty }
    }

    private var titleText: String {
        return teamName.uppercased()
    }

    private var numberColors: TeamLineupNumberColors {
        teamColorCatalog.lineupColors(
            for: teamName,
            opponentTeamName: opponentTeamName,
            isAway: side == .away
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if side == .away {
                Spacer(minLength: 0)
            }

            if side == .home {
                titleView
            }

            ForEach(Array(groupedRows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 8) {
                    ForEach(row) { player in
                        MatchLineupPlayerMarkerView(
                            player: player,
                            summary: lookup.summary(for: player),
                            replacementSummary: lookup.replacementSummary(for: player),
                            isFantasyHighlighted: fantasyHighlightLookup?.contains(player: player, teamName: teamName) ?? false,
                            fantasyPoints: fantasyHighlightLookup?.points(for: player, teamName: teamName),
                            replacementFantasyPoints: lookup.summary(for: player).substitution.flatMap { substitution in
                                fantasyHighlightLookup?.points(for: substitution.playerOn, teamName: teamName)
                            },
                            numberColors: numberColors
                        )
                    }
                }
            }

            if side == .home {
                Spacer(minLength: 0)
            } else {
                titleView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var titleView: some View {
        Text(titleText)
            .font(.system(size: 15, weight: .black, design: .rounded))
            .tracking(0.4)
            .foregroundStyle(Color.white.opacity(0.96))
            .shadow(color: .black.opacity(0.18), radius: 1, x: 0, y: 1)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

private struct MatchLineupPlayerMarkerView: View {
    let player: MatchLineupPlayer
    let summary: MatchLineupPlayerEventSummary
    let replacementSummary: MatchLineupPlayerEventSummary?
    let isFantasyHighlighted: Bool
    let fantasyPoints: Int?
    let replacementFantasyPoints: Int?
    let numberColors: TeamLineupNumberColors

    private var circleFill: AnyShapeStyle {
        if isFantasyHighlighted {
            return AnyShapeStyle(LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.20, blue: 0.66),
                    Color(red: 1.0, green: 0.29, blue: 0.29)
                ],
                startPoint: .leading,
                endPoint: .trailing
            ))
        }
        return AnyShapeStyle(numberColors.background)
    }

    private var circleText: Color {
        if isFantasyHighlighted {
            return Color.white
        }
        return numberColors.foreground
    }

    private var replacementPlayer: MatchLineupPlayer? {
        summary.substitution?.playerOn
    }

    private var displayName: String {
        condensedLineupPlayerName(player.name)
    }

    private var markerLabel: String {
        lineupPlayerMarkerLabel(name: player.name, fantasyPoints: fantasyPoints)
    }

    private var showsReplacementFantasySubstituteWarning: Bool {
        shouldShowFantasySubstituteWarning(fantasyPoints: replacementFantasyPoints)
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(circleFill)
                    .frame(width: 44, height: 44)
                    .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)

                LineupPlayerMarkerText(
                    label: markerLabel,
                    textColor: circleText,
                    outlineColor: numberColors.outline
                )
            }

            if summary.hasStatBadges {
                MatchLineupEventBadgeRow(summary: summary)
            }

            VStack(spacing: 2) {
                HStack(spacing: 3) {
                    if summary.substitution != nil {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color(red: 0.95, green: 0.14, blue: 0.46))
                    }

                    Text(displayName)
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.96))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)

                if let replacementPlayer {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color(red: 0.21, green: 0.83, blue: 0.39))

                        Text("\(condensedLineupPlayerName(replacementPlayer.name)) (\(summary.substitution?.minute ?? ""))")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.92))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        if showsReplacementFantasySubstituteWarning {
                            MatchLineupFantasySubstituteWarningIcon()
                        }

                        if let replacementFantasyPoints {
                            MatchLineupFantasyPointsBadge(points: replacementFantasyPoints, compact: true)
                        }
                    }
                    .multilineTextAlignment(.center)

                    if let replacementSummary, replacementSummary.hasStatBadges {
                        MatchLineupEventBadgeRow(summary: replacementSummary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct LineupPlayerMarkerText: View {
    let label: String
    let textColor: Color
    let outlineColor: Color?

    private var fontSize: CGFloat {
        switch label.count {
        case ...2:
            return 14
        case 3:
            return 12
        default:
            return 10
        }
    }

    var body: some View {
        ZStack {
            if let outlineColor {
                outlinedText(offsetX: -0.7, offsetY: 0, color: outlineColor)
                outlinedText(offsetX: 0.7, offsetY: 0, color: outlineColor)
                outlinedText(offsetX: 0, offsetY: -0.7, color: outlineColor)
                outlinedText(offsetX: 0, offsetY: 0.7, color: outlineColor)
                outlinedText(offsetX: -0.6, offsetY: -0.6, color: outlineColor)
                outlinedText(offsetX: 0.6, offsetY: -0.6, color: outlineColor)
                outlinedText(offsetX: -0.6, offsetY: 0.6, color: outlineColor)
                outlinedText(offsetX: 0.6, offsetY: 0.6, color: outlineColor)
            }

            Text(label)
                .font(.system(size: fontSize, weight: .black, design: .rounded))
                .foregroundStyle(textColor)
        }
    }

    private func outlinedText(offsetX: CGFloat, offsetY: CGFloat, color: Color) -> some View {
        Text(label)
            .font(.system(size: fontSize, weight: .black, design: .rounded))
            .foregroundStyle(color)
            .offset(x: offsetX, y: offsetY)
    }
}

private struct MatchLineupEventBadgeRow: View {
    let summary: MatchLineupPlayerEventSummary

    var body: some View {
        HStack(spacing: 4) {
            if summary.goals > 0 {
                MatchLineupEventBadge(icon: .system("soccerball"), tint: .white, count: summary.goals)
            }
            if summary.assists > 0 {
                MatchLineupEventBadge(icon: .emoji("🅰️"), tint: .mint, count: summary.assists)
            }
            if summary.yellowCards > 0 {
                MatchLineupEventBadge(icon: .card(Color.yellow, .black), tint: .black, count: summary.yellowCards)
            }
            if summary.redCards > 0 {
                MatchLineupEventBadge(icon: .card(Color.red, .white), tint: .white, count: summary.redCards)
            }
        }
    }
}

private struct MatchLineupFantasyPointsBadge: View {
    let points: Int
    var compact = false

    var body: some View {
        Text("\(points)")
            .font(.system(size: compact ? 8 : 9, weight: .black, design: .rounded))
            .foregroundStyle(Color.white)
            .padding(.horizontal, compact ? 5 : 6)
            .padding(.vertical, compact ? 2 : 3)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.95, green: 0.20, blue: 0.66),
                                Color(red: 1.0, green: 0.29, blue: 0.29)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
    }
}

private struct MatchLineupSubstitutesSection: View {
    let homeLineup: MatchTeamLineup
    let awayLineup: MatchTeamLineup
    let fantasyHighlightLookup: FantasySquadMembershipLookup?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MatchLineupSubstitutesTable(lineup: homeLineup, fantasyHighlightLookup: fantasyHighlightLookup)
            MatchLineupSubstitutesTable(lineup: awayLineup, fantasyHighlightLookup: fantasyHighlightLookup)
        }
    }
}

private struct MatchLineupSubstitutesTable: View {
    let lineup: MatchTeamLineup
    let fantasyHighlightLookup: FantasySquadMembershipLookup?

    private var rows: [MatchLineupSubstituteRow] {
        lineup.substitutes.map { substitute in
            let substitution = lineup.substitutions.first { $0.playerOn.number == substitute.number }
            return MatchLineupSubstituteRow(
                player: substitute,
                substitution: substitution,
                fantasyPoints: fantasyHighlightLookup?.points(
                    for: substitute,
                    teamName: lineup.team ?? "Team"
                )
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(lineup.team ?? "Team") subs")
                .font(.system(size: 12, weight: .black, design: .rounded))
                .tracking(0.3)
                .foregroundStyle(.white.opacity(0.92))

            VStack(spacing: 0) {
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(row.player.number)")
                            .font(.system(size: 11, weight: .black, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.96))
                            .frame(width: 18, alignment: .leading)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(condensedLineupPlayerName(row.player.name))
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.white.opacity(0.96))

                                if row.showsFantasySubstituteWarning {
                                    MatchLineupFantasySubstituteWarningIcon()
                                }

                                if let fantasyPoints = row.fantasyPoints {
                                    MatchLineupFantasyPointsBadge(points: fantasyPoints, compact: true)
                                }
                            }

                            if let substitution = row.substitution {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Color(red: 0.21, green: 0.83, blue: 0.39))

                                    Text("\(formattedMatchMinute(substitution.minute)) for \(condensedLineupPlayerName(substitution.playerOff.name))")
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.white.opacity(0.78))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7)

                    if row.id != rows.last?.id {
                        Divider()
                            .overlay(Color.white.opacity(0.12))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.20))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct MatchLineupSubstituteRow: Identifiable {
    let player: MatchLineupPlayer
    let substitution: MatchLineupSubstitution?
    let fantasyPoints: Int?

    var id: String {
        player.id
    }

    var showsFantasySubstituteWarning: Bool {
        shouldShowFantasySubstituteWarning(fantasyPoints: fantasyPoints)
    }
}

private struct MatchLineupFantasySubstituteWarningIcon: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.19))
            .accessibilityLabel("Fantasy player listed as substitute")
            .accessibilityHint("This player is on the bench in the real match lineup")
    }
}

private struct MatchLineupEventBadge: View {
    enum IconStyle {
        case system(String)
        case emoji(String)
        case card(Color, Color)
    }

    let icon: IconStyle
    let tint: Color
    let count: Int?

    var body: some View {
        HStack(spacing: 3) {
            switch icon {
            case .system(let name):
                Image(systemName: name)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tint)
            case .emoji(let value):
                Text(value)
                    .font(.system(size: 10))
            case .card(let fill, _):
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(fill)
                    .frame(width: 7, height: 10)
            }

            if let count, count > 1 {
                Text("\(count)")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.42))
        )
    }
}

private struct MatchLineupPitchBackground: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.37, green: 0.50, blue: 0.10),
                        Color(red: 0.31, green: 0.44, blue: 0.08),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { index in
                        Rectangle()
                            .fill(index.isMultiple(of: 2) ? Color.white.opacity(0.04) : Color.clear)
                    }
                }

                Path { path in
                    let width = proxy.size.width
                    let height = proxy.size.height
                    let inset: CGFloat = 14

                    let pitchRect = CGRect(
                        x: inset,
                        y: inset,
                        width: width - (inset * 2),
                        height: height - (inset * 2)
                    )

                    path.addRoundedRect(in: pitchRect, cornerSize: CGSize(width: 8, height: 8))

                    let halfwayY = pitchRect.midY
                    path.move(to: CGPoint(x: pitchRect.minX, y: halfwayY))
                    path.addLine(to: CGPoint(x: pitchRect.maxX, y: halfwayY))

                    let centerCircleRadius: CGFloat = min(42, width * 0.15)
                    path.addEllipse(
                        in: CGRect(
                            x: pitchRect.midX - centerCircleRadius,
                            y: halfwayY - centerCircleRadius,
                            width: centerCircleRadius * 2,
                            height: centerCircleRadius * 2
                        )
                    )

                    let centerSpotRadius: CGFloat = 3.5
                    path.addEllipse(
                        in: CGRect(
                            x: pitchRect.midX - centerSpotRadius,
                            y: halfwayY - centerSpotRadius,
                            width: centerSpotRadius * 2,
                            height: centerSpotRadius * 2
                        )
                    )

                    let penaltyWidth = pitchRect.width * 0.50
                    let penaltyDepth = pitchRect.height * 0.10
                    path.addRect(
                        CGRect(
                            x: pitchRect.midX - (penaltyWidth / 2),
                            y: pitchRect.minY,
                            width: penaltyWidth,
                            height: penaltyDepth
                        )
                    )
                    path.addRect(
                        CGRect(
                            x: pitchRect.midX - (penaltyWidth / 2),
                            y: pitchRect.maxY - penaltyDepth,
                            width: penaltyWidth,
                            height: penaltyDepth
                        )
                    )

                    let sixYardWidth = penaltyWidth * 0.44
                    let sixYardDepth = penaltyDepth * 0.42
                    path.addRect(
                        CGRect(
                            x: pitchRect.midX - (sixYardWidth / 2),
                            y: pitchRect.minY,
                            width: sixYardWidth,
                            height: sixYardDepth
                        )
                    )
                    path.addRect(
                        CGRect(
                            x: pitchRect.midX - (sixYardWidth / 2),
                            y: pitchRect.maxY - sixYardDepth,
                            width: sixYardWidth,
                            height: sixYardDepth
                        )
                    )
                }
                .stroke(Color.white.opacity(0.50), lineWidth: 2)
            }
        }
    }
}

private func formattedMatchMinute(_ rawValue: String) -> String {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "-" }
    if trimmed.contains("'") {
        return trimmed
    }
    return "\(trimmed)'"
}

private struct MatchLineupPlayerEventSummary {
    let goals: Int
    let assists: Int
    let yellowCards: Int
    let redCards: Int
    let substitution: MatchLineupSubstitution?

    var hasStatBadges: Bool {
        goals > 0 || assists > 0 || yellowCards > 0 || redCards > 0
    }

    var hasCardOrBallStats: Bool {
        hasStatBadges
    }
}

private struct MatchLineupEventLookup {
    private let goalEntries: [MatchPlayerStatEntry]
    private let assistEntries: [MatchPlayerStatEntry]
    private let yellowCardEntries: [MatchPlayerStatEntry]
    private let redCardEntries: [MatchPlayerStatEntry]
    private let substitutions: [MatchLineupSubstitution]

    init(
        goals: [MatchGoalScorer],
        assists: [MatchAssistProvider],
        yellowCards: [MatchYellowCardEvent],
        redCards: [MatchRedCardEvent],
        substitutions: [MatchLineupSubstitution]
    ) {
        goalEntries = goals.map {
            MatchPlayerStatEntry(playerName: $0.player, count: $0.goalTimes.count)
        }
        assistEntries = assists.map {
            MatchPlayerStatEntry(playerName: $0.player, count: $0.assistTimes.count)
        }
        yellowCardEntries = yellowCards.map {
            MatchPlayerStatEntry(playerName: $0.player, count: $0.yellowCardTimes.count)
        }
        redCardEntries = redCards.map {
            MatchPlayerStatEntry(playerName: $0.player, count: $0.redCardTimes.count)
        }
        self.substitutions = substitutions
    }

    func summary(for player: MatchLineupPlayer) -> MatchLineupPlayerEventSummary {
        MatchLineupPlayerEventSummary(
            goals: bestCount(for: player.name, entries: goalEntries),
            assists: bestCount(for: player.name, entries: assistEntries),
            yellowCards: bestCount(for: player.name, entries: yellowCardEntries),
            redCards: bestCount(for: player.name, entries: redCardEntries),
            substitution: substitutions.first { $0.playerOff.number == player.number }
        )
    }

    func replacementSummary(for player: MatchLineupPlayer) -> MatchLineupPlayerEventSummary? {
        guard let substitution = substitutions.first(where: { $0.playerOff.number == player.number }) else {
            return nil
        }

        return MatchLineupPlayerEventSummary(
            goals: bestCount(for: substitution.playerOn.name, entries: goalEntries),
            assists: bestCount(for: substitution.playerOn.name, entries: assistEntries),
            yellowCards: bestCount(for: substitution.playerOn.name, entries: yellowCardEntries),
            redCards: bestCount(for: substitution.playerOn.name, entries: redCardEntries),
            substitution: nil
        )
    }

    private func bestCount(for playerName: String, entries: [MatchPlayerStatEntry]) -> Int {
        let playerLookup = MatchPlayerNameLookup(name: playerName)
        let bestEntry = entries.max { lhs, rhs in
            let leftScore = playerLookup.matchScore(against: lhs.lookup)
            let rightScore = playerLookup.matchScore(against: rhs.lookup)
            if leftScore == rightScore {
                return lhs.count < rhs.count
            }
            return leftScore < rightScore
        }

        guard let bestEntry else { return 0 }
        return playerLookup.matchScore(against: bestEntry.lookup) > 0 ? bestEntry.count : 0
    }
}

private struct MatchPlayerStatEntry {
    let count: Int
    let lookup: MatchPlayerNameLookup

    init(playerName: String, count: Int) {
        self.count = count
        self.lookup = MatchPlayerNameLookup(name: playerName)
    }
}

private struct MatchPlayerNameLookup {
    let full: String
    let initialAndLast: String
    let last: String

    init(name: String) {
        let cleaned = name
            .replacingOccurrences(of: "(c)", with: "", options: .caseInsensitive)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let tokens = cleaned
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }

        full = tokens.joined(separator: " ")
        let first = tokens.first ?? ""
        let lastToken = tokens.last ?? ""
        last = lastToken
        if !first.isEmpty, !lastToken.isEmpty {
            initialAndLast = "\(String(first.prefix(1))) \(lastToken)"
        } else {
            initialAndLast = full
        }
    }

    func matchScore(against other: MatchPlayerNameLookup) -> Int {
        guard !full.isEmpty, !other.full.isEmpty else { return 0 }
        if full == other.full { return 3 }
        if !initialAndLast.isEmpty, initialAndLast == other.initialAndLast { return 2 }
        if !last.isEmpty, last == other.last { return 1 }
        return 0
    }
}

// MARK: - FantasyMatchRowContext

/// A stable, Equatable snapshot of the fantasy state needed to render a MatchRow.
/// Built once in FantasyViewModel when its underlying data changes, then passed as a
/// value parameter to MatchRow so rows only re-render when the fantasy data actually changes.
struct FantasyMatchRowContext: Equatable {
    let lookup: FantasySquadMembershipLookup?
    /// Normalised team name keys for every EPL team from the bootstrap, used to
    /// determine whether a match is an eligible fantasy fixture without accessing FantasyViewModel.
    let eligibleLeagueTeamKeys: Set<String>
    /// Monotonically-increasing version bumped whenever the underlying data changes.
    /// Used as the Equatable key so SwiftUI can skip re-rendering rows whose context
    /// is unchanged even if FantasyViewModel publishes unrelated state (isLoading, etc.).
    private let version: Int

    static func == (lhs: FantasyMatchRowContext, rhs: FantasyMatchRowContext) -> Bool {
        lhs.version == rhs.version
    }

    static let empty = FantasyMatchRowContext(lookup: nil, eligibleLeagueTeamKeys: [], version: 0)

    init(lookup: FantasySquadMembershipLookup?, eligibleLeagueTeamKeys: Set<String>, version: Int) {
        self.lookup = lookup
        self.eligibleLeagueTeamKeys = eligibleLeagueTeamKeys
        self.version = version
    }

    func isEligibleFixture(_ match: Match) -> Bool {
        guard match.league.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare("Premier League") == .orderedSame
        else { return false }
        guard !eligibleLeagueTeamKeys.isEmpty else { return true }
        let homeKeys = TeamIdentityStore.shared.normalizedKeys(for: match.homeTeam)
        let awayKeys = TeamIdentityStore.shared.normalizedKeys(for: match.awayTeam)
        return !homeKeys.isDisjoint(with: eligibleLeagueTeamKeys) &&
               !awayKeys.isDisjoint(with: eligibleLeagueTeamKeys)
    }
}

// MARK: - FantasySquadMembershipLookup

struct FantasySquadMembershipLookup {
    private struct SquadPlayerSummary {
        let elementID: Int
        let displayName: String
        let fullName: String
        let pickPosition: Int
    }

    private let memberKeys: Set<String>
    private let teamCounts: [String: Int]
    private let fixtureScoresByTeam: [String: Int]
    private let fixturePointsByKey: [String: Int]
    private let fixturePointsByElementID: [Int: Int]
    private let expectedPointsByElementID: [Int: Int]
    private let playersByTeam: [String: [SquadPlayerSummary]]

    var hasExpectedPoints: Bool { !expectedPointsByElementID.isEmpty }

    init?(squad: FantasySquadDisplayData?, expectedPointsByElementID: [Int: Int] = [:]) {
        guard let squad else { return nil }

        var keys = Set<String>()
        var counts: [String: Int] = [:]
        var fixtureScores: [String: Int] = [:]
        var fixturePoints: [String: Int] = [:]
        var fixturePointsByElementID: [Int: Int] = [:]
        var playersByTeam: [String: [SquadPlayerSummary]] = [:]
        for player in squad.allPlayers {
            let teamKey = Self.normalizeTeamName(player.teamName)
            counts[teamKey, default: 0] += 1
            fixtureScores[teamKey, default: 0] += player.rawPoints
            fixturePointsByElementID[player.elementID] = player.rawPoints
            playersByTeam[teamKey, default: []].append(
                SquadPlayerSummary(
                    elementID: player.elementID,
                    displayName: player.displayName,
                    fullName: player.fullName,
                    pickPosition: player.pickPosition
                )
            )
            for nameVariant in Self.nameVariants(
                fullName: player.fullName,
                displayName: player.displayName
            ) {
                let key = "\(teamKey)|\(nameVariant)"
                keys.insert(key)
                fixturePoints[key] = player.rawPoints
            }
        }
        memberKeys = keys
        teamCounts = counts
        fixtureScoresByTeam = fixtureScores
        fixturePointsByKey = fixturePoints
        self.fixturePointsByElementID = fixturePointsByElementID
        self.expectedPointsByElementID = expectedPointsByElementID
        self.playersByTeam = playersByTeam
    }

    func contains(player: MatchLineupPlayer, teamName: String) -> Bool {
        let teamKeys = fantasyTeamLookupKeys(teamName)
        let candidateKeys = Self.nameVariants(
            fullName: player.name,
            displayName: condensedLineupPlayerName(player.name)
        )
        return matchingMemberKeys(teamKeys: teamKeys, nameKeys: candidateKeys).isEmpty == false
    }

    func participationCount(in match: Match) -> Int {
        let homeCount = fantasyTeamLookupKeys(match.homeTeam).reduce(0) { partialResult, teamKey in
            partialResult + teamCounts[teamKey, default: 0]
        }
        let awayCount = fantasyTeamLookupKeys(match.awayTeam).reduce(0) { partialResult, teamKey in
            partialResult + teamCounts[teamKey, default: 0]
        }
        return homeCount + awayCount
    }

    func effectiveScore(in match: Match) -> Int {
        let homeScore = effectiveScore(for: match.homeTeam)
        let awayScore = effectiveScore(for: match.awayTeam)
        return homeScore + awayScore
    }

    func points(for player: MatchLineupPlayer, teamName: String) -> Int? {
        let candidateKeys = Self.nameVariants(
            fullName: player.name,
            displayName: condensedLineupPlayerName(player.name)
        )
        let memberKeys = matchingMemberKeys(
            teamKeys: fantasyTeamLookupKeys(teamName),
            nameKeys: candidateKeys
        )

        guard !memberKeys.isEmpty else {
            return nil
        }

        return memberKeys.compactMap { fixturePointsByKey[$0] }.max() ?? 0
    }

    func involvedPlayers(
        in match: Match,
        preferExpectedPoints: Bool = false
    ) -> [FantasyMatchContributionDisplay] {
        var output: [FantasyMatchContributionDisplay] = []
        var seenElementIDs = Set<Int>()
        let substituteMemberKeys = self.substituteMemberKeys(in: match)

        appendPlayers(
            for: match.homeTeam,
            teamOrder: 0,
            preferExpectedPoints: preferExpectedPoints,
            substituteMemberKeys: substituteMemberKeys,
            output: &output,
            seenElementIDs: &seenElementIDs
        )
        appendPlayers(
            for: match.awayTeam,
            teamOrder: 1,
            preferExpectedPoints: preferExpectedPoints,
            substituteMemberKeys: substituteMemberKeys,
            output: &output,
            seenElementIDs: &seenElementIDs
        )

        return output.sorted { lhs, rhs in
            if lhs.pointsDisplay.value != rhs.pointsDisplay.value {
                return lhs.pointsDisplay.value > rhs.pointsDisplay.value
            }
            if lhs.teamOrder != rhs.teamOrder {
                return lhs.teamOrder < rhs.teamOrder
            }
            if lhs.pickPosition != rhs.pickPosition {
                return lhs.pickPosition < rhs.pickPosition
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func appendPlayers(
        for teamName: String,
        teamOrder: Int,
        preferExpectedPoints: Bool,
        substituteMemberKeys: Set<String>,
        output: inout [FantasyMatchContributionDisplay],
        seenElementIDs: inout Set<Int>
    ) {
        for teamKey in fantasyTeamLookupKeys(teamName) {
            for player in playersByTeam[teamKey] ?? [] {
                guard seenElementIDs.insert(player.elementID).inserted else { continue }
                let playerMemberKeys = matchingMemberKeys(
                    teamKeys: fantasyTeamLookupKeys(teamName),
                    nameKeys: Self.nameVariants(
                        fullName: player.fullName,
                        displayName: player.displayName
                    )
                )
                let pointsDisplay: FantasyMatchContributionDisplay.PointsDisplay = {
                    if preferExpectedPoints {
                        return .expected(expectedPointsByElementID[player.elementID] ?? 0)
                    }
                    return .actual(fixturePointsByElementID[player.elementID] ?? 0)
                }()
                output.append(
                    FantasyMatchContributionDisplay(
                        elementID: player.elementID,
                        displayName: player.displayName,
                        pointsDisplay: pointsDisplay,
                        teamOrder: teamOrder,
                        pickPosition: player.pickPosition,
                        isRealMatchSubstitute: playerMemberKeys.contains(where: substituteMemberKeys.contains)
                    )
                )
            }
        }
    }

    private func effectiveScore(for teamName: String) -> Int {
        fantasyTeamLookupKeys(teamName).reduce(0) { partialResult, teamKey in
            partialResult + fixtureScoresByTeam[teamKey, default: 0]
        }
    }

    private static func nameVariants(fullName: String, displayName: String) -> Set<String> {
        var variants = Set<String>()
        for candidate in [
            fullName,
            displayName,
            condensedLineupPlayerName(fullName),
            condensedLineupPlayerName(displayName)
        ] {
            let normalized = normalizeName(candidate)
            if !normalized.isEmpty {
                variants.insert(normalized)
            }
        }
        return variants
    }

    private static func normalizeTeamName(_ value: String) -> String {
        normalizeName(TeamIdentityStore.shared.canonicalName(for: value))
    }

    private func matchingMemberKeys(teamKeys: Set<String>, nameKeys: Set<String>) -> [String] {
        teamKeys.flatMap { teamKey in
            nameKeys.map { "\(teamKey)|\($0)" }
        }
        .filter { memberKeys.contains($0) }
    }

    private func substituteMemberKeys(in match: Match) -> Set<String> {
        var keys = Set<String>()

        func append(lineup: MatchTeamLineup?, fallbackTeamName: String) {
            guard let lineup else { return }
            let teamKeys = fantasyTeamLookupKeys(lineup.team ?? fallbackTeamName)
            for player in lineup.substitutes {
                let nameKeys = Self.nameVariants(
                    fullName: player.name,
                    displayName: condensedLineupPlayerName(player.name)
                )
                for teamKey in teamKeys {
                    for nameKey in nameKeys {
                        keys.insert("\(teamKey)|\(nameKey)")
                    }
                }
            }
        }

        append(lineup: match.teamLineups?.home, fallbackTeamName: match.homeTeam)
        append(lineup: match.teamLineups?.away, fallbackTeamName: match.awayTeam)

        return keys
    }

    private static func normalizeName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "(c)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .joined(separator: " ")
    }
}

private func fantasyPointsHeatmapColor(_ points: Int) -> Color {
    switch points {
    case ..<1:
        return Color(red: 0.78, green: 0.16, blue: 0.14)
    case 1...2:
        return Color(red: 0.91, green: 0.37, blue: 0.15)
    case 3...4:
        return Color(red: 0.95, green: 0.68, blue: 0.16)
    case 5...7:
        return Color(red: 0.29, green: 0.71, blue: 0.27)
    default:
        return Color.green
    }
}

func fantasyTeamLookupKeys(_ value: String) -> Set<String> {
    let candidates = TeamIdentityStore.shared.names(for: value) + BundledTeamIdentityCatalog.shared.names(for: value)
    return Set(candidates.compactMap { candidate in
        let normalized = normalizeFantasyLookupName(candidate)
        return normalized.isEmpty ? nil : normalized
    })
}

private func normalizeFantasyLookupName(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "(c)", with: "", options: .caseInsensitive)
        .replacingOccurrences(of: ".", with: "")
        .replacingOccurrences(of: "-", with: " ")
        .lowercased()
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .map(String.init)
        .joined(separator: " ")
}

private func condensedLineupPlayerName(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }

    let hasCaptainSuffix = trimmed.range(of: "(c)", options: .caseInsensitive) != nil
    let baseName = trimmed.replacingOccurrences(of: "(c)", with: "", options: .caseInsensitive)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = baseName.split(separator: " ").map(String.init)
    guard let last = parts.last else {
        return trimmed
    }
    let particles = Set([
        "al", "bin", "bint", "da", "de", "del", "della", "den", "der", "di", "dos", "du",
        "el", "la", "le", "st", "ten", "ter", "van", "von"
    ])

    var surnameParts = [last]
    var index = parts.count - 2
    while index >= 0 {
        let candidate = parts[index].lowercased().trimmingCharacters(in: .punctuationCharacters)
        if particles.contains(candidate) {
            surnameParts.insert(parts[index], at: 0)
            index -= 1
            continue
        }
        break
    }

    let condensed = surnameParts.joined(separator: " ")
    return hasCaptainSuffix ? "\(condensed) (c)" : condensed
}

func lineupPlayerMarkerLabel(name: String, fantasyPoints: Int?) -> String {
    if let fantasyPoints {
        return "\(fantasyPoints)"
    }
    return lineupPlayerInitials(name)
}

func shouldShowFantasySubstituteWarning(fantasyPoints: Int?) -> Bool {
    fantasyPoints != nil
}

func lineupPlayerInitials(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "?" }

    let baseName = trimmed
        .replacingOccurrences(of: "(c)", with: "", options: .caseInsensitive)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = baseName
        .split(whereSeparator: { $0.isWhitespace })
        .map(String.init)

    guard let firstPart = parts.first else { return "?" }

    let surname = condensedLineupPlayerName(baseName)
        .replacingOccurrences(of: "(c)", with: "", options: .caseInsensitive)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let particles = Set([
        "al", "bin", "bint", "da", "de", "del", "della", "den", "der", "di", "dos", "du",
        "el", "la", "le", "st", "ten", "ter", "van", "von"
    ])

    let firstInitial = lineupInitialFragment(from: firstPart, lowercaseParticles: false, particles: particles)
    guard parts.count > 1 else {
        return firstInitial.isEmpty ? "?" : firstInitial
    }
    let surnameInitials = surname
        .split(whereSeparator: { $0.isWhitespace })
        .map(String.init)
        .map { lineupInitialFragment(from: $0, lowercaseParticles: true, particles: particles) }
        .joined()

    let initials = firstInitial + surnameInitials
    if initials.isEmpty {
        return "?"
    }
    return initials
}

private func lineupInitialFragment(from value: String, lowercaseParticles: Bool, particles: Set<String>) -> String {
    let cleaned = value.trimmingCharacters(in: .punctuationCharacters)
    guard !cleaned.isEmpty else { return "" }

    let segments = cleaned
        .split(whereSeparator: { $0 == "-" || $0 == "‑" || $0 == "–" || $0 == "—" })
        .map(String.init)

    return segments.map { segment in
        let normalized = segment.trimmingCharacters(in: .punctuationCharacters)
        guard let first = normalized.first else { return "" }
        if lowercaseParticles && particles.contains(normalized.lowercased()) {
            return String(first).lowercased()
        }
        return String(first).uppercased()
    }
    .joined()
}

private enum MatchLineupDisplaySide {
    case home
    case away
}

private struct CalendarChoice: Identifiable {
    let id: String
    let title: String
}

private struct TvLogoRow: View {
    let channels: [String]

    var body: some View {
        let images = TvLogoResolver.shared.images(for: channels)
        if images.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 6) {
                ForEach(images.indices, id: \.self) { index in
                    Image(uiImage: images[index])
                        .resizable()
                        .scaledToFit()
                        .frame(height: 16)
                }
            }
        }
    }
}

private struct TeamLogo: View {
    let name: String
    var size: CGFloat = 22

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
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityHidden(true)
    }
}

private struct TvChannelRow: View {
    let channel: String

    var body: some View {
        HStack(spacing: 8) {
            if let image = TvLogoResolver.shared.image(for: channel) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 16)
            }

            Text(channel)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }
}

#Preview {
    MatchRow(match: Match(date: "2026-02-11", time: "19:45", homeTeam: "Arsenal", awayTeam: "Chelsea", league: "Premier League", tvChannels: ["NBC", "Peacock"]))
        .environmentObject(PreferencesStore())
        .environmentObject(FantasyViewModel())
        .padding()
}
