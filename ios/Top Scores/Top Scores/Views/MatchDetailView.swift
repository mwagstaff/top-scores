import Foundation
import SwiftUI
import EventKit
import MapKit

struct MatchDetailView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var fantasyViewModel: FantasyViewModel
    @AppStorage(AppGroupConfig.fantasyManagerEntryIDKey) private var fantasyManagerEntryID = ""

    let match: Match
    var showFantasyBadge: Bool = true
    var predictionDisplay: FixturePredictionDisplayState = .hidden

    @State private var actionAlert: MatchActionAlert?
    @State private var showCalendarPicker = false
    @State private var calendarChoices: [CalendarChoice] = []
    @State private var saveCalendarAsDefault = false
    @State private var refreshedMatch: Match?
    @State private var detailedMatch: Match?
    @State private var detailsRefreshTask: Task<Void, Never>?
    @State private var fantasyHistoryTask: Task<Void, Never>?
    @State private var detailsErrorMessage: String?
    @State private var socialItems: [MatchSocialItem] = []
    @State private var pendingEventsQuickRetry = false
    @State private var screenOpenedAt: Date?
    @State private var screenViewSent = false
    @State private var showOtherCountries = false
    @State private var teamCompetitionEntries: [MatchTeamCompetitionEntry] = []

    private static let detailsRefreshIntervalNanos: UInt64 = 10_000_000_000
    private static let idleDetailsRefreshIntervalNanos: UInt64 = 30_000_000_000
    private static let pendingEventsBackfillRefreshIntervalNanos: UInt64 = 1_500_000_000
    private static let detailsCacheKeyPrefix = "match.details.cache."

    private var baseMatch: Match {
        refreshedMatch ?? match
    }

    private var activeMatch: Match {
        detailedMatch ?? baseMatch
    }

    private var teamCompetitionTaskKey: String {
        "\(preferences.apiBaseURL)|\(activeMatch.league)|\(activeMatch.homeTeam)|\(activeMatch.awayTeam)"
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

    private var localChannels: [TvChannel] {
        let code = Locale.current.region?.identifier
        guard let code else { return [] }
        return activeMatch.tvChannels.filter { broadcastCountryCode(for: $0) == code }
    }

    private var otherChannelGroups: [(country: String, channels: [TvChannel])] {
        let code = Locale.current.region?.identifier
        let others = activeMatch.tvChannels.filter { broadcastCountryCode(for: $0) != code }
        let grouped = Dictionary(grouping: others) { $0.country ?? "Other" }
        return grouped.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { (country: $0.key, channels: $0.value) }
    }

    private func broadcastCountryCode(for channel: TvChannel) -> String? {
        if let countryCode = channel.countryCode {
            return countryCode
        }
        if channel.name.localizedCaseInsensitiveContains("bbc") ||
            channel.name.localizedCaseInsensitiveContains("itv") {
            return "GB"
        }
        return nil
    }

    private func flagEmoji(for countryCode: String) -> String {
        countryCode.unicodeScalars.compactMap {
            Unicode.Scalar($0.value + 127397)
        }.map(String.init).joined()
    }

    private var shouldShowLineupPitch: Bool {
        guard let teamLineups = activeMatch.teamLineups,
              let home = teamLineups.home,
              let away = teamLineups.away
        else {
            return false
        }

        return !home.startingLineup.isEmpty && !away.startingLineup.isEmpty
    }

    private var isEligibleFantasyFixture: Bool {
        fantasyViewModel.isEligibleFantasyFixture(activeMatch)
    }

    private var fantasyHighlightLookup: FantasySquadMembershipLookup? {
        guard preferences.showFantasyFixtureLogos, isEligibleFantasyFixture else { return nil }
        return FantasySquadMembershipLookup(squad: fantasyViewModel.data)
    }

    private var fantasyPointsLookup: FantasySquadMembershipLookup? {
        guard preferences.showFantasyRealTimePoints,
              activeMatch.isInProgress,
              isEligibleFantasyFixture
        else {
            return nil
        }
        return FantasySquadMembershipLookup(squad: fantasyViewModel.data)
    }

    private var shouldLoadFantasySquad: Bool {
        activeMatch.league.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare("Premier League") == .orderedSame &&
        !fantasyManagerEntryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var fantasyMatchContext: FantasyMatchFixtureContext? {
        fantasyViewModel.matchFixtureContext(
            for: activeMatch,
            managerEntryID: fantasyManagerEntryID
        )
    }

    private func fantasySquadSections(
        in squad: FantasySquadDisplayData
    ) -> [FantasyMatchTeamSquadSection] {
        return [
            squad.matchSquadSection(forTeamName: activeMatch.homeTeam),
            squad.matchSquadSection(forTeamName: activeMatch.awayTeam)
        ]
        .compactMap { $0 }
        .filter(\.hasPlayers)
    }

    private var matchRowPreferences: MatchRowPreferences {
        MatchRowPreferences(
            preferences: preferences,
            hasFantasyManagerEntry: !fantasyManagerEntryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private var tvChannelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                Locale.current.localizedString(forRegionCode: Locale.current.region?.identifier ?? "") ?? "Your region",
                systemImage: "location.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            if localChannels.isEmpty {
                Text("Not available in your region")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 138), spacing: 8)], spacing: 8) {
                    ForEach(localChannels, id: \.name) { channel in
                        TvChannelRow(channel: channel)
                    }
                }
            }

            if !otherChannelGroups.isEmpty {
                Button {
                    showOtherCountries.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text(showOtherCountries
                            ? "Hide other countries"
                            : "Other countries (\(otherChannelGroups.count))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: showOtherCountries ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if showOtherCountries {
                    ForEach(otherChannelGroups, id: \.country) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            let flag = group.channels.first.flatMap { broadcastCountryCode(for: $0) }.map { flagEmoji(for: $0) } ?? ""
                            Text("\(flag) \(group.country)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fontWeight(.medium)
                            ForEach(group.channels, id: \.name) { channel in
                                TvChannelRow(channel: channel)
                                    .padding(.leading, 8)
                            }
                        }
                    }
                }
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                MatchDetailScoreboardHero(
                    match: activeMatch,
                    kickoffText: kickoffText,
                    predictionDisplay: predictionDisplay,
                    teamCompetitionEntries: teamCompetitionEntries
                )
                .padding(.horizontal)

                MatchTeamLeaguePositionsLink(
                    entries: teamCompetitionEntries
                )
                .padding(.horizontal)

                if let penaltyDetailSummary = activeMatch.penaltyDetailSummaryText {
                    MatchPenaltyShootoutSummary(text: penaltyDetailSummary)
                        .padding(.horizontal)
                }

                if let fantasyMatchContext {
                    let sections = fantasySquadSections(in: fantasyMatchContext.squad)
                    if !sections.isEmpty {
                        FantasyMatchPlayersSection(
                            context: fantasyMatchContext,
                            sections: sections,
                            pointsPhase: fantasyMatchPointsPhase(
                                isMatchInProgress: activeMatch.isInProgress,
                                isMatchFinished: activeMatch.isFinished,
                                squadScorePhase: fantasyMatchContext.squad.scorePhase
                            )
                        )
                        .padding(.horizontal)
                    }
                }

                MatchEventsCard(match: activeMatch)
                    .padding(.horizontal)

                if shouldShowLineupPitch {
                    MatchLineupPitchSection(
                        match: activeMatch,
                        fantasyHighlightLookup: fantasyHighlightLookup,
                        fantasyPointsLookup: fantasyPointsLookup
                    )
                        .padding(.horizontal)
                }

                if let detailsErrorMessage {
                    Text(detailsErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                if !activeMatch.tvChannels.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Follow the action")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        tvChannelSection
                    }
                    .padding(.horizontal)
                }

                if shouldShowMatchActions {
                    actionPanel
                        .padding(.horizontal)
                }

                if !socialItems.isEmpty {
                    MatchSocialSection(items: socialItems)
                        .padding(.horizontal)
                }

                if let venue = activeMatch.venueDetails {
                    MatchVenueSection(venue: venue)
                        .padding(.horizontal)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerRelativeFrame(.horizontal)
            .padding(.vertical, 12)
        }
        .task(id: "\(preferences.apiBaseURL)|\(match.matchDetailsID ?? "")") {
            await loadMatchSocial()
        }
        .task(id: teamCompetitionTaskKey) {
            teamCompetitionEntries = []
            let entries = await MatchTeamCompetitionLoader.shared.load(
                match: activeMatch,
                apiBaseURL: preferences.apiBaseURL
            )
            guard !Task.isCancelled else { return }
            teamCompetitionEntries = entries
        }
        .refreshable {
            await refreshDetailsManually()
            await loadMatchSocial()
        }
        .navigationTitle("Match Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear {
            screenOpenedAt = Date()
            screenViewSent = false
            startDetailsRefresh()
            ensureFantasySquadLoadedIfNeeded()
            reportMissingTeamLogosIfNeeded(for: activeMatch)
            AppMetricsService.shared.fireScreenView(screen: "match_detail", apiBaseURL: preferences.apiBaseURL)
        }
        .onChange(of: detailedMatch) { _, newValue in
            guard !screenViewSent, newValue != nil, let openedAt = screenOpenedAt else { return }
            screenViewSent = true
            let durationMs = Int(Date().timeIntervalSince(openedAt) * 1000)
            AppMetricsService.shared.fireActivity("match_details_loaded", screen: "match_detail", durationMs: durationMs, apiBaseURL: preferences.apiBaseURL)
        }
        .onDisappear {
            detailsRefreshTask?.cancel()
            detailsRefreshTask = nil
            fantasyHistoryTask?.cancel()
            fantasyHistoryTask = nil
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
        pendingEventsQuickRetry = false

        if match.isTestMatch == true {
            refreshedMatch = match
            detailedMatch = match
            return
        }

        refreshedMatch = nil
        detailedMatch = nil

        let detailsID = match.matchDetailsID
        let cached = detailsID.flatMap { Self.loadCachedDetails(for: $0) }
        if let detailsID, let cached {
            detailedMatch = baseMatch.withDetails(cached)
            diagnosticLog(
                "[MatchDetail][INFO] details_load_start id=%@ cached=true goals=%ld assists=%ld red_cards=%ld",
                detailsID,
                cached.homeGoalScorers.count + cached.awayGoalScorers.count,
                cached.homeAssists.count + cached.awayAssists.count,
                cached.homeRedCards.count + cached.awayRedCards.count
            )
        } else if let detailsID {
            diagnosticLog("[MatchDetail][INFO] details_load_start id=%@ cached=false", detailsID)
        }

        guard let baseURL = URL(string: preferences.apiBaseURL) else {
            detailsErrorMessage = "Invalid API base URL."
            return
        }

        launchDetailsRefreshLoop(baseURL: baseURL)
    }

    private func refreshDetailsManually() async {
        detailsRefreshTask?.cancel()
        detailsRefreshTask = nil
        detailsErrorMessage = nil

        guard let baseURL = URL(string: preferences.apiBaseURL) else {
            detailsErrorMessage = "Invalid API base URL."
            return
        }

        await refreshFromServer(baseURL: baseURL)
        launchDetailsRefreshLoop(baseURL: baseURL)
    }

    private func launchDetailsRefreshLoop(baseURL: URL) {
        detailsRefreshTask?.cancel()
        detailsRefreshTask = Task {
            while !Task.isCancelled {
                await refreshFromServer(baseURL: baseURL)
                let interval = await MainActor.run { refreshIntervalNanos(for: activeMatch) }
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    private func refreshFromServer(baseURL: URL) async {
        // Finished match scores/state never change — skip the slow snapshot fetch
        let isFinished = await MainActor.run { activeMatch.isFinished }
        let serverMatch = isFinished ? nil : await refreshMatchSnapshotOnce(baseURL: baseURL)
        let referenceMatch = await MainActor.run {
            serverMatch ?? refreshedMatch ?? match
        }

        guard let detailsID = referenceMatch.matchDetailsID else {
            await MainActor.run {
                if let serverMatch {
                    refreshedMatch = serverMatch
                }
                if detailedMatch == nil {
                    detailsErrorMessage = "Live events unavailable for this match."
                }
            }
            return
        }

        let fetched = await refreshDetailsOnce(
            detailsID: detailsID,
            baseURL: baseURL,
            fallbackMatch: serverMatch ?? referenceMatch
        )

        if fetched {
            return
        }

        await MainActor.run {
            if let serverMatch {
                refreshedMatch = serverMatch
            }
        }
    }

    private func refreshMatchSnapshotOnce(baseURL: URL) async -> Match? {
        let referenceMatch = await MainActor.run { refreshedMatch ?? match }
        let client = APIClient(baseURL: baseURL)

        do {
            let matches = try await client.fetchMatches(on: referenceMatch.date)
            if Task.isCancelled { return nil }
            let resolved = Self.bestMatchCandidate(for: referenceMatch, in: matches)
            if let resolved {
                await MainActor.run {
                    refreshedMatch = resolved
                }
            }
            return resolved
        } catch {
            if Self.isCancellationError(error) { return nil }
            diagnosticLog("Match snapshot refresh failed date=%@ error=%@", referenceMatch.date, String(describing: error))
            return nil
        }
    }

    private func refreshDetailsOnce(detailsID: String, baseURL: URL) async -> Bool {
        await refreshDetailsOnce(detailsID: detailsID, baseURL: baseURL, fallbackMatch: nil)
    }

    private func refreshDetailsOnce(
        detailsID: String,
        baseURL: URL,
        fallbackMatch: Match?
    ) async -> Bool {
        let fetchStartedAt = Date()
        let client = APIClient(baseURL: baseURL)
        do {
            let details = try await client.fetchMatchDetails(matchId: detailsID)
            if Task.isCancelled { return false }
            let hasGoals = !details.homeGoalScorers.isEmpty || !details.awayGoalScorers.isEmpty
            let hasCards = !details.homeRedCards.isEmpty || !details.awayRedCards.isEmpty
            let hasLineups = details.teamLineups?.home != nil
            let hasEvents = hasGoals || hasCards
            await MainActor.run {
                let base = fallbackMatch ?? refreshedMatch ?? match
                if let refreshed = fallbackMatch {
                    refreshedMatch = refreshed
                }
                let updated = base.withDetails(details)
                // For finished matches, don't replace populated events with empty server data (backfill race)
                let currentHasEvents = detailedMatch.map {
                    !$0.homeGoalScorers.isEmpty || !$0.awayGoalScorers.isEmpty
                    || !$0.homeRedCards.isEmpty || !$0.awayRedCards.isEmpty
                } ?? false
                if !updated.isFinished || hasEvents || !currentHasEvents {
                    detailedMatch = updated
                    detailsErrorMessage = nil
                }
                pendingEventsQuickRetry = updated.isFinished && !hasEvents
                // Stop polling once a finished match has its events and lineups — the data won't change
                if updated.isFinished && hasEvents && hasLineups {
                    detailsRefreshTask?.cancel()
                    detailsRefreshTask = nil
                }
            }
            let durationMs = Int(Date().timeIntervalSince(fetchStartedAt) * 1000)
            diagnosticLog(
                "[MatchDetail][INFO] key_events_loaded id=%@ duration_ms=%ld goals=%ld assists=%ld red_cards=%ld status=%@",
                detailsID,
                durationMs,
                details.homeGoalScorers.count + details.awayGoalScorers.count,
                details.homeAssists.count + details.awayAssists.count,
                details.homeRedCards.count + details.awayRedCards.count,
                details.scoreStatus ?? "-"
            )
            // Don't overwrite a good cache entry with regressive server data (backfill race on finished matches)
            let cachedHasEvents = Self.loadCachedDetails(for: detailsID).map {
                !$0.homeGoalScorers.isEmpty || !$0.awayGoalScorers.isEmpty
                || !$0.homeRedCards.isEmpty || !$0.awayRedCards.isEmpty
            } ?? false
            if hasEvents || !cachedHasEvents {
                Self.saveCachedDetails(details, for: detailsID)
            }
            return true
        } catch {
            if Self.isCancellationError(error) { return false }
            let durationMs = Int(Date().timeIntervalSince(fetchStartedAt) * 1000)
            diagnosticLog(
                "[MatchDetail][WARN] key_events_load_failed id=%@ duration_ms=%ld error=%@",
                detailsID, durationMs, String(describing: error)
            )
            await MainActor.run {
                detailsErrorMessage = detailedMatch == nil
                    ? "Unable to load match events."
                    : "Using latest available match events."
            }
            return false
        }
    }

    private func loadMatchSocial() async {
        guard match.isTestMatch != true else {
            await MainActor.run { socialItems = [] }
            return
        }
        guard let detailsID = match.matchDetailsID,
              let baseURL = URL(string: preferences.apiBaseURL)
        else {
            await MainActor.run { socialItems = [] }
            return
        }

        do {
            let items = try await APIClient(baseURL: baseURL).fetchMatchSocial(matchId: detailsID)
            if Task.isCancelled { return }
            await MainActor.run {
                socialItems = items
            }
        } catch {
            if Self.isCancellationError(error) { return }
            diagnosticLog("[MatchDetail][WARN] social_load_failed id=%@ error=%@", detailsID, String(describing: error))
            await MainActor.run {
                socialItems = []
            }
        }
    }

    private func refreshIntervalNanos(for match: Match) -> UInt64 {
        if match.matchDetailsID == nil || match.isInProgress {
            return Self.detailsRefreshIntervalNanos
        }
        if pendingEventsQuickRetry {
            return Self.pendingEventsBackfillRefreshIntervalNanos
        }
        return Self.idleDetailsRefreshIntervalNanos
    }

    private func ensureFantasySquadLoadedIfNeeded() {
        guard shouldLoadFantasySquad else {
            return
        }

        fantasyHistoryTask?.cancel()
        let matchToPrepare = activeMatch
        fantasyHistoryTask = Task {
            await fantasyViewModel.prepareMatchHistory(
                for: matchToPrepare,
                managerEntryID: fantasyManagerEntryID
            )

            let requestedEntryID = Int(
                fantasyManagerEntryID.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            if (fantasyViewModel.data == nil ||
                fantasyViewModel.authenticatedEntryID != requestedEntryID),
               !fantasyViewModel.isLoading,
               !fantasyViewModel.isRefreshing {
                await fantasyViewModel.refresh(
                    managerEntryID: fantasyManagerEntryID,
                    apiBaseURL: preferences.apiBaseURL,
                    rivalManagers: [],
                    trackedLeagues: []
                )
            }

            guard !Task.isCancelled else { return }
            await fantasyViewModel.prepareMatchHistory(
                for: matchToPrepare,
                managerEntryID: fantasyManagerEntryID
            )
        }
    }

    private func reportMissingTeamLogosIfNeeded(for match: Match) {
        let missingTeamNames = LogoResolver.shared.missingTeamNames(in: [
            (match.homeTeam, [match.homeShortName].compactMap { $0 }),
            (match.awayTeam, [match.awayShortName].compactMap { $0 }),
        ])
        guard !missingTeamNames.isEmpty else { return }
        guard let baseURL = URL(string: preferences.apiBaseURL) else { return }

        Task {
            let client = APIClient(baseURL: baseURL)
            do {
                try await client.reportMissingTeamLogos(missingTeamNames)
            } catch {
                diagnosticLog("Missing logo audit post failed error=%@", String(describing: error))
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
            diagnosticLog("Failed to cache match details id=%@ error=%@", detailsID, String(describing: error))
        }
    }

    private static func loadCachedDetails(for detailsID: String) -> MatchDetailsPayload? {
        guard let data = UserDefaults.standard.data(forKey: detailsCacheKey(for: detailsID)) else {
            return nil
        }
        do {
            let cached = try JSONDecoder().decode(MatchDetailsPayload.self, from: data)

            // Always return cached data — the refresh loop overwrites it with fresh data in the background.
            // Log age so we can observe how stale the cache is on open.
            if let updatedAt = cached.updatedAt {
                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let timestamp = isoFormatter.date(from: updatedAt) {
                    let age = Date().timeIntervalSince(timestamp)
                    diagnosticLog("Cached match details id=%@ age=%.1fs goals=%ld", detailsID, age,
                          cached.homeGoalScorers.count + cached.awayGoalScorers.count)
                }
            }

            return cached
        } catch {
            diagnosticLog("Failed to decode cached match details id=%@ error=%@", detailsID, String(describing: error))
            return nil
        }
    }

    private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private static func bestMatchCandidate(for target: Match, in matches: [Match]) -> Match? {
        let targetDetailsID = target.matchDetailsID

        let ranked = matches.compactMap { candidate -> (match: Match, score: Int)? in
            guard candidate.date == target.date else { return nil }
            guard TeamIdentityStore.shared.matches(candidate.homeTeam, target.homeTeam),
                  TeamIdentityStore.shared.matches(candidate.awayTeam, target.awayTeam) else {
                return nil
            }

            var score = 0
            if let targetDetailsID, candidate.matchDetailsID == targetDetailsID {
                score += 1000
            }

            if candidate.homeTeam.localizedCaseInsensitiveCompare(target.homeTeam) == .orderedSame {
                score += 50
            }
            if candidate.awayTeam.localizedCaseInsensitiveCompare(target.awayTeam) == .orderedSame {
                score += 50
            }

            if candidate.time == target.time {
                score += 30
            } else if comparableKickoffTime(candidate.time, target.time) {
                score += 15
            }

            if candidate.league.localizedCaseInsensitiveCompare(target.league) == .orderedSame {
                score += 20
            }

            if candidate.matchDetailsID != nil {
                score += 10
            }
            if candidate.detailsURL != nil {
                score += 5
            }

            return (candidate, score)
        }

        return ranked
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                if lhs.match.time != rhs.match.time {
                    return lhs.match.time < rhs.match.time
                }
                return lhs.match.league.localizedCaseInsensitiveCompare(rhs.match.league) == .orderedAscending
            }
            .first?
            .match
    }

    private static func comparableKickoffTime(_ lhs: String, _ rhs: String) -> Bool {
        guard let leftMinutes = kickoffMinutes(lhs),
              let rightMinutes = kickoffMinutes(rhs) else {
            return false
        }
        return abs(leftMinutes - rightMinutes) <= 120
    }

    private static func kickoffMinutes(_ value: String) -> Int? {
        let parts = value.split(separator: ":").map { Int($0) }
        guard parts.count == 2,
              let hours = parts[0],
              let minutes = parts[1] else {
            return nil
        }
        return (hours * 60) + minutes
    }
}

private struct MatchVenueSection: View {
    let venue: MatchVenueDetails

    private var locationText: String? {
        let parts = [venue.city, venue.country].compactMap { value -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var coordinate: CLLocationCoordinate2D? {
        guard let latitude = venue.latitude,
              let longitude = venue.longitude,
              (-90...90).contains(latitude),
              (-180...180).contains(longitude)
        else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(venue.name)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)

            if let imageURL = venue.imageURL.flatMap(URL.init(string:)) {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    case .empty:
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(.tertiarySystemFill))
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .overlay { ProgressView() }
                    case .failure:
                        EmptyView()
                    @unknown default:
                        EmptyView()
                    }
                }
                .accessibilityLabel("Photo of \(venue.name)")
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) {
                    venueFacts
                }

                VStack(alignment: .leading, spacing: 12) {
                    venueFacts
                }
            }

            if let coordinate {
                Button {
                    openInMaps(coordinate)
                } label: {
                    Label("View in Maps", systemImage: "map")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityHint("Opens the stadium location in Apple Maps")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var venueFacts: some View {
        if let locationText {
            MatchVenueFact(icon: "mappin.and.ellipse", title: "Location", value: locationText)
        }
        if let capacity = venue.capacity {
            MatchVenueFact(
                icon: "person.3.fill",
                title: "Capacity",
                value: capacity.formatted(.number.grouping(.automatic))
            )
        }
        if let builtYear = venue.builtYear {
            MatchVenueFact(icon: "building.2.fill", title: "Built", value: String(builtYear))
        }
    }

    private func openInMaps(_ coordinate: CLLocationCoordinate2D) {
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        mapItem.name = venue.name
        mapItem.openInMaps()
    }
}

private struct MatchVenueFact: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - FPL Squad Sections

private struct MatchDetailScoreboardHero: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var stadiumArtworkStore: StadiumArtworkStore
    let match: Match
    let kickoffText: String
    let predictionDisplay: FixturePredictionDisplayState
    let teamCompetitionEntries: [MatchTeamCompetitionEntry]
    @State private var artworkSelectionSeed: UInt32
    @ScaledMetric(relativeTo: .headline) private var teamNameRowHeight: CGFloat = 46

    init(
        match: Match,
        kickoffText: String,
        predictionDisplay: FixturePredictionDisplayState,
        teamCompetitionEntries: [MatchTeamCompetitionEntry]
    ) {
        self.match = match
        self.kickoffText = kickoffText
        self.predictionDisplay = predictionDisplay
        self.teamCompetitionEntries = teamCompetitionEntries
        _artworkSelectionSeed = State(initialValue: UInt32.random(in: .min ... .max))
    }

    private var showsTeamCompetitions: Bool {
        guard let home = competitionEntry(for: .home),
              let away = competitionEntry(for: .away) else {
            return false
        }
        return home.leagueID != away.leagueID
    }

    private var centerText: String {
        if let scoreLine = match.scoreLine {
            return scoreLine
        }
        return match.time
    }

    private var statusText: String {
        if match.penaltyDetailSummaryText != nil {
            return "AET"
        }
        if let displayScoreStatus = match.displayScoreStatus {
            return displayScoreStatus
        }
        return match.hasScore ? "Score" : "Kick-off"
    }

    private var metadataText: String {
        [kickoffText, match.aggregateSummaryText]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: " • ")
    }

    private var homeGoalSummaries: [MatchScoreboardGoalSummary] {
        goalSummaries(scorers: match.homeGoalScorers, assists: match.homeAssists)
    }

    private var awayGoalSummaries: [MatchScoreboardGoalSummary] {
        goalSummaries(scorers: match.awayGoalScorers, assists: match.awayAssists)
    }

    private var hasGoalSummaries: Bool {
        !homeGoalSummaries.isEmpty || !awayGoalSummaries.isEmpty
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Text(match.displayLeague)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(metadataText)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
            }

            HStack(alignment: .center, spacing: 14) {
                teamLink(
                    name: match.displayHomeTeam,
                    fullName: match.homeTeam,
                    teamId: match.homeTeamId,
                    alternateNames: [match.homeShortName].compactMap { $0 },
                    goalSummaries: homeGoalSummaries,
                    competition: competitionEntry(for: .home)
                )

                VStack(spacing: 8) {
                    Text(centerText)
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.65)
                        .lineLimit(1)

                    Text(statusText)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.82))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }
                .frame(maxWidth: 134)

                teamLink(
                    name: match.displayAwayTeam,
                    fullName: match.awayTeam,
                    teamId: match.awayTeamId,
                    alternateNames: [match.awayShortName].compactMap { $0 },
                    goalSummaries: awayGoalSummaries,
                    competition: competitionEntry(for: .away)
                )
            }

            if hasGoalSummaries {
                HStack(alignment: .top, spacing: 12) {
                    goalSummaryColumn(homeGoalSummaries, isTrailing: false)

                    Rectangle()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: 1)

                    goalSummaryColumn(awayGoalSummaries, isTrailing: true)
                }
                .padding(12)
                .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if predictionDisplay != .hidden {
                MatchDetailPredictionPanel(match: match, predictionDisplay: predictionDisplay)
            }

            if let extendedMatchStatusText = match.extendedMatchStatusText {
                Text(extendedMatchStatusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 24)
        .background(
            ZStack {
                RemoteStadiumArtworkImage(
                    asset: stadiumArtworkStore.matchAsset(
                        for: match,
                        selectionSeed: artworkSelectionSeed
                    ),
                    apiBaseURL: preferences.apiBaseURL,
                    fallbackAssetName: MatchStadiumArtworkResolver.shared.assetName(
                        for: match,
                        selectionSeed: artworkSelectionSeed
                    )
                )
                    .scaledToFill()
                    .scaleEffect(1.04)
                    .blur(radius: 3, opaque: true)
                    .accessibilityHidden(true)

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.28),
                        Color.black.opacity(0.58),
                        Color.black.opacity(0.90)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(0.18), radius: 22, x: 0, y: 12)
        .accessibilityElement(children: .contain)
    }

    private func teamLink(
        name: String,
        fullName: String,
        teamId: String? = nil,
        alternateNames: [String],
        goalSummaries: [MatchScoreboardGoalSummary],
        competition: MatchTeamCompetitionEntry?
    ) -> some View {
        NavigationLink {
            TeamDetailsView(
                context: TeamDetailsContext(
                    teamID: teamId,
                    teamName: fullName,
                    displayName: name,
                    alternateNames: alternateNames,
                    originatingLeagueID: match.leagueId,
                    originatingLeagueName: match.league,
                    originatingMatch: match
                )
            )
        } label: {
            teamColumn(
                name: name,
                fullName: fullName,
                teamId: teamId,
                alternateNames: alternateNames,
                competition: competition
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            teamAccessibilityLabel(
                fullName: fullName,
                goalSummaries: goalSummaries,
                competition: showsTeamCompetitions ? competition : nil
            )
        )
        .accessibilityHint("View team details")
    }

    private func teamColumn(
        name: String,
        fullName: String,
        teamId: String? = nil,
        alternateNames: [String],
        competition: MatchTeamCompetitionEntry?
    ) -> some View {
        VStack(spacing: 10) {
            Group {
                if let image = LogoResolver.shared.image(for: fullName, teamId: teamId, alternateNames: alternateNames) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.82))
                }
            }
            .frame(width: 72, height: 72)
            .shadow(color: .black.opacity(0.36), radius: 6, x: 0, y: 3)

            HStack(spacing: 5) {
                Text(name)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.62))
                    .accessibilityHidden(true)
            }
            .frame(height: showsTeamCompetitions ? teamNameRowHeight : nil, alignment: .top)

            if showsTeamCompetitions, let competition {
                HStack(spacing: 5) {
                    MatchTeamCompetitionBadge(
                        competitionID: competition.competitionID,
                        competitionName: competition.competitionName
                    )

                    Text(competition.competitionName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, minHeight: 18, alignment: .center)
            }

        }
        .frame(maxWidth: .infinity)
    }

    private func competitionEntry(for side: MatchCompetitionTeamSide) -> MatchTeamCompetitionEntry? {
        teamCompetitionEntries.first { $0.side == side }
    }

    private func goalSummaryColumn(
        _ summaries: [MatchScoreboardGoalSummary],
        isTrailing: Bool
    ) -> some View {
        let alignment: HorizontalAlignment = isTrailing ? .trailing : .leading
        return VStack(alignment: alignment, spacing: 9) {
            ForEach(summaries) { summary in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if !isTrailing {
                        Image(systemName: "soccerball")
                            .font(.caption2)
                    }

                    VStack(alignment: alignment, spacing: 2) {
                        HStack(spacing: 5) {
                            if isTrailing {
                                goalMinute(summary.minute)
                                goalScorer(summary.scorer)
                            } else {
                                goalScorer(summary.scorer)
                                goalMinute(summary.minute)
                            }
                        }

                        if let assister = summary.assister {
                            Text("Assist: \(assister)")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.68))
                                .lineLimit(1)
                        }
                    }

                    if isTrailing {
                        Image(systemName: "soccerball")
                            .font(.caption2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: isTrailing ? .trailing : .leading)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: isTrailing ? .trailing : .leading)
    }

    private func goalScorer(_ scorer: String) -> some View {
        Text(scorer)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
    }

    private func goalMinute(_ minute: String) -> some View {
        Text(minute)
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white.opacity(0.72))
    }

    private func goalSummaries(
        scorers: [MatchGoalScorer],
        assists: [MatchAssistProvider]
    ) -> [MatchScoreboardGoalSummary] {
        guard match.isInProgress || match.isFinished else { return [] }
        return MatchScoreboardGoalSummary.make(scorers: scorers, assists: assists)
    }

    private func teamAccessibilityLabel(
        fullName: String,
        goalSummaries: [MatchScoreboardGoalSummary],
        competition: MatchTeamCompetitionEntry?
    ) -> String {
        var sections = [fullName]
        if let competition {
            sections.append(competition.competitionName)
        }
        if !goalSummaries.isEmpty {
            sections.append("Goals: \(goalSummaries.map(\.accessibilityText).joined(separator: ", "))")
        }
        return sections.joined(separator: ". ")
    }
}

private struct MatchTeamCompetitionBadge: View {
    let competitionID: String?
    let competitionName: String
    @State private var cacheVersion = 0

    var body: some View {
        let _ = cacheVersion
        Group {
            if let image = CompetitionBadgeCache.shared.image(
                competitionID: competitionID,
                competitionName: competitionName
            ) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
            }
        }
        .frame(width: 14, height: 14)
        .onReceive(NotificationCenter.default.publisher(for: CompetitionBadgeCache.badgesUpdatedNotification)) { _ in
            cacheVersion &+= 1
        }
        .accessibilityHidden(true)
    }
}

private enum MatchPredictionHelpTopic: String, Identifiable {
    case score
    case chances

    var id: String { rawValue }

    var title: String {
        switch self {
        case .score: "How the predicted score works"
        case .chances: "How predicted chances work"
        }
    }

    var message: String {
        switch self {
        case .score:
            "The predicted score is sampled from the model’s expected-goals estimate for each team. It is generated once for the fixture and then kept unchanged, so it can be compared fairly with the final result."
        case .chances:
            "Home win, draw and away win percentages come from the model’s outcome probabilities and are normalised to total 100%. They are estimates, not betting odds or guarantees."
        }
    }
}

private struct MatchDetailPredictionPanel: View {
    let match: Match
    let predictionDisplay: FixturePredictionDisplayState

    @State private var helpTopic: MatchPredictionHelpTopic?

    var body: some View {
        Group {
            switch predictionDisplay {
            case .hidden:
                EmptyView()
            case .pending:
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("Calculating prediction…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.82))
                }
                .frame(maxWidth: .infinity, minHeight: 66)
            case let .available(homeGoals, awayGoals, homeWin, draw, awayWin):
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        helpLabel("Predicted", topic: .score)
                        HStack(spacing: 6) {
                            if match.isFinished, predictionWasCorrect(homeGoals: homeGoals, awayGoals: awayGoals) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.caption.weight(.bold))
                            }
                            Text("\(homeGoals) – \(awayGoals)")
                                .font(.title2.monospacedDigit().weight(.bold))
                        }
                        .foregroundStyle(predictionAccent(homeGoals: homeGoals, awayGoals: awayGoals))
                        .accessibilityLabel(predictionAccessibilityLabel(homeGoals: homeGoals, awayGoals: awayGoals))
                    }
                    .frame(width: 112, alignment: .leading)

                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 1, height: 70)

                    VStack(alignment: .leading, spacing: 8) {
                        helpLabel("Predicted chances", topic: .chances)

                        HStack(spacing: 10) {
                            chance(title: "Home", value: homeWin, color: .predictedScore)
                            chance(title: "Draw", value: draw, color: Color.white.opacity(0.72))
                            chance(title: "Away", value: awayWin, color: .predictedAwayWin)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(14)
        .background(Color.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
        .sheet(item: $helpTopic) { topic in
            NavigationStack {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: topic == .score ? "scope" : "chart.bar.xaxis")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(topic == .score ? Color.predictedScore : Color.predictedAwayWin)

                    Text(topic.title)
                        .font(.title2.weight(.bold))

                    Text(topic.message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { helpTopic = nil }
                    }
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    private func helpLabel(_ title: String, topic: MatchPredictionHelpTopic) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.70))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Button {
                helpTopic = topic
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About \(title.lowercased())")
        }
        .frame(height: 44, alignment: .center)
    }

    private func chance(title: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.58))
            Text("\(Int((value * 100).rounded()))%")
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(color)
            Capsule()
                .fill(Color.white.opacity(0.14))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(color)
                            .frame(width: proxy.size.width * max(0, min(1, value)))
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(Int((value * 100).rounded())) percent")
    }

    private func predictionWasCorrect(homeGoals: Int, awayGoals: Int) -> Bool {
        match.homeScore == homeGoals && match.awayScore == awayGoals
    }

    private func predictionAccent(homeGoals: Int, awayGoals: Int) -> Color {
        guard match.isFinished else { return .predictedScore }
        return predictionWasCorrect(homeGoals: homeGoals, awayGoals: awayGoals)
            ? .liveMatch
            : Color.white.opacity(0.62)
    }

    private func predictionAccessibilityLabel(homeGoals: Int, awayGoals: Int) -> String {
        let base = "Predicted score \(homeGoals) to \(awayGoals)"
        guard match.isFinished else { return base }
        return predictionWasCorrect(homeGoals: homeGoals, awayGoals: awayGoals)
            ? "\(base), correct"
            : "\(base), final score was different"
    }
}

private struct MatchScoreboardGoalSummary: Identifiable {
    let id: String
    let minute: String
    let scorer: String
    let assister: String?
    let sortOrder: Int

    var text: String {
        "\(minute) \(scorer)" + (assister.map { " (\($0))" } ?? "")
    }

    var accessibilityText: String {
        let base = "\(minute.replacingOccurrences(of: "'", with: " minutes")) \(scorer)"
        return base + (assister.map { ", assisted by \($0)" } ?? "")
    }

    static func make(
        scorers: [MatchGoalScorer],
        assists: [MatchAssistProvider]
    ) -> [MatchScoreboardGoalSummary] {
        let assistLookup = assists.reduce(into: [String: String]()) { lookup, assist in
            for minute in assist.assistTimes {
                lookup[minuteKey(minute)] = lastName(assist.player)
            }
        }
        var summaries: [MatchScoreboardGoalSummary] = []

        for (scorerIndex, scorer) in scorers.enumerated() {
            let scorerName = lastName(scorer.player)
            for (minuteIndex, minute) in scorer.goalTimes.enumerated() {
                summaries.append(
                    MatchScoreboardGoalSummary(
                        id: "goal-\(scorerIndex)-\(minuteIndex)-\(minute)",
                        minute: displayMinute(minute),
                        scorer: scorerName,
                        assister: assistLookup[minuteKey(minute)],
                        sortOrder: minuteSortOrder(minute)
                    )
                )
            }
            for (minuteIndex, minute) in scorer.ownGoalTimes.enumerated() {
                summaries.append(
                    MatchScoreboardGoalSummary(
                        id: "own-goal-\(scorerIndex)-\(minuteIndex)-\(minute)",
                        minute: displayMinute(minute),
                        scorer: "\(scorerName) (OG)",
                        assister: nil,
                        sortOrder: minuteSortOrder(minute)
                    )
                )
            }
        }

        return summaries.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder {
                return lhs.sortOrder < rhs.sortOrder
            }
            return lhs.id < rhs.id
        }
    }

    private static func lastName(_ fullName: String) -> String {
        let trimmed = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? trimmed
    }

    private static func displayMinute(_ rawMinute: String) -> String {
        let minute = minuteKey(rawMinute)
        return minute.isEmpty ? "-" : "\(minute)'"
    }

    private static func minuteKey(_ rawMinute: String) -> String {
        rawMinute
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix { $0.isNumber || $0 == "+" }
            .description
    }

    private static func minuteSortOrder(_ rawMinute: String) -> Int {
        let parts = minuteKey(rawMinute).split(separator: "+", maxSplits: 1).compactMap { Int($0) }
        guard let minute = parts.first else { return Int.max }
        return (minute * 100) + (parts.count > 1 ? parts[1] : 0)
    }
}

private struct MatchPenaltyShootoutSummary: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .accessibilityLabel(text)
    }
}

private struct MatchEventsCard: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @State private var selectedPlayer: MatchLineupPlayer?

    let match: Match

    private var entries: [MatchEventEntry] {
        Self.entries(for: match).sorted { left, right in
            if left.sortMinute != right.sortMinute {
                return left.sortMinute < right.sortMinute
            }
            return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
        }
    }

    var body: some View {
        if entries.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Match Events")
                    .font(.headline)
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        eventCard(
                            entry,
                            isFirst: index == entries.startIndex,
                            isLast: index == entries.index(before: entries.endIndex)
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .sheet(item: $selectedPlayer) { player in
                PlayerDetailsSheet(player: player, apiBaseURL: preferences.apiBaseURL)
            }
        }
    }

    @ViewBuilder
    private func eventCard(_ entry: MatchEventEntry, isFirst: Bool, isLast: Bool) -> some View {
        let isHome = entry.side == .home
        let isGoal = entry.kind == .goal
        let player = entry.player

        Button {
            if let player, player.idPlayer != nil {
                selectedPlayer = player
            }
        } label: {
            HStack(spacing: 0) {
                minuteText(entry.minute, isGoal: isGoal)

                timelineRail(
                    entry: entry,
                    showsEventIcon: isGoal || isHome,
                    isFirst: isFirst,
                    isLast: isLast
                )

                if entry.kind == .substitution {
                    substitutionEventContent(entry, isHome: isHome)
                } else if !isHome && !isGoal {
                    Spacer(minLength: 6)
                    eventText(entry, alignment: .trailing, textAlignment: .trailing)
                    eventIcon(entry.kind)
                        .frame(width: 30, height: 30)
                        .padding(.leading, 8)
                    eventPortrait(player, entry: entry)
                        .padding(.leading, 10)
                } else {
                    eventText(entry, alignment: .leading, textAlignment: .leading)
                    Spacer(minLength: 8)
                    eventPortrait(player, entry: entry)
                }
            }
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: entry.kind == .substitution ? 104 : 88)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(player?.idPlayer != nil)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isGoal ? Color.green.opacity(0.12) : Color(.tertiarySystemBackground))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isGoal ? Color.green.opacity(0.55) : Color.primary.opacity(0.06),
                    lineWidth: isGoal ? 1.2 : 1
                )
        )
    }

    @ViewBuilder
    private func substitutionEventContent(_ entry: MatchEventEntry, isHome: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if isHome {
                substitutionNames(entry, isTrailing: false)
                Spacer(minLength: 8)
                eventPortrait(entry.player, entry: entry)
            } else {
                Spacer(minLength: 8)
                substitutionNames(entry, isTrailing: true)
                eventIcon(.substitution)
                    .frame(width: 30, height: 30)
                eventPortrait(entry.player, entry: entry)
            }
        }
    }

    @ViewBuilder
    private func substitutionNames(_ entry: MatchEventEntry, isTrailing: Bool) -> some View {
        let alignment: HorizontalAlignment = isTrailing ? .trailing : .leading
        VStack(alignment: alignment, spacing: 5) {
            HStack(spacing: 5) {
                if isTrailing { Spacer(minLength: 0) }
                Image(systemName: "arrow.down")
                    .foregroundStyle(.red)
                Text(entry.playerOffName ?? "Player off")
                if !isTrailing { Spacer(minLength: 0) }
            }

            HStack(spacing: 5) {
                if isTrailing { Spacer(minLength: 0) }
                Image(systemName: "arrow.up")
                    .foregroundStyle(.green)
                Text(entry.playerOnName ?? entry.title)
                    .fontWeight(.semibold)
                if !isTrailing { Spacer(minLength: 0) }
            }
        }
        .font(.caption)
        .foregroundStyle(.primary)
        .multilineTextAlignment(isTrailing ? .trailing : .leading)
    }

    private func minuteText(_ minute: String, isGoal: Bool) -> some View {
        Text(minute)
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(isGoal ? Color.green : Color.primary)
            .frame(width: 50, alignment: .center)
    }

    private func timelineRail(
        entry: MatchEventEntry,
        showsEventIcon: Bool,
        isFirst: Bool,
        isLast: Bool
    ) -> some View {
        GeometryReader { proxy in
            let midpoint = proxy.size.height / 2
            Path { path in
                path.move(to: CGPoint(x: proxy.size.width / 2, y: isFirst ? midpoint : 0))
                path.addLine(to: CGPoint(x: proxy.size.width / 2, y: isLast ? midpoint : proxy.size.height))
            }
            .stroke(Color.secondary.opacity(0.52), lineWidth: 1.2)

            Group {
                if showsEventIcon {
                    eventIcon(entry.kind)
                        .frame(width: entry.kind == .goal ? 36 : 28, height: entry.kind == .goal ? 36 : 28)
                } else {
                    Circle()
                        .fill(Color.secondary.opacity(0.75))
                        .frame(width: 7, height: 7)
                }
            }
            .position(x: proxy.size.width / 2, y: midpoint)
        }
        .frame(width: 44)
    }

    private func eventText(_ entry: MatchEventEntry, alignment: HorizontalAlignment, textAlignment: TextAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(entry.title)
                .font(.subheadline.weight(entry.kind == .goal ? .bold : .medium))
                .foregroundStyle(.primary)
            if let subtitle = entry.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(textAlignment)
    }

    @ViewBuilder
    private func eventPortrait(_ player: MatchLineupPlayer?, entry: MatchEventEntry) -> some View {
        if let player {
            MatchLineupPlayerPortraitView(
                player: player,
                borderColor: portraitBorderColor(for: entry.kind),
                borderLineWidth: portraitBorderLineWidth(for: entry.kind),
                glowColor: portraitGlowColor(for: entry.kind),
                glowRadius: portraitGlowRadius(for: entry.kind)
            )
        } else {
            ZStack {
                Circle().fill(Color.black.opacity(0.24))
                Text(eventInitials(entry.title))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
            }
            .frame(width: MatchLineupPlayerPortraitView.size, height: MatchLineupPlayerPortraitView.size)
            .overlay {
                Circle().stroke(portraitBorderColor(for: entry.kind), lineWidth: 2)
            }
        }
    }

    private func eventInitials(_ value: String) -> String {
        let initials = value.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
        return initials.isEmpty ? "?" : initials.uppercased()
    }

    private func portraitBorderColor(for kind: MatchEventEntry.Kind) -> Color {
        switch kind {
        case .goal:
            return Color.green
        case .yellowCard:
            return Color.yellow
        case .redCard:
            return Color.red
        case .varEvent, .substitution:
            return Color.white.opacity(0.82)
        }
    }

    private func portraitBorderLineWidth(for kind: MatchEventEntry.Kind) -> CGFloat {
        switch kind {
        case .goal, .yellowCard, .redCard:
            return 2
        case .varEvent, .substitution:
            return 1.4
        }
    }

    private func portraitGlowColor(for kind: MatchEventEntry.Kind) -> Color {
        kind == .goal ? Color.green.opacity(0.7) : Color.clear
    }

    private func portraitGlowRadius(for kind: MatchEventEntry.Kind) -> CGFloat {
        kind == .goal ? 8 : 0
    }

    @ViewBuilder
    private func eventIcon(_ kind: MatchEventEntry.Kind) -> some View {
        switch kind {
        case .goal:
            ZStack {
                Circle()
                    .fill(Color.green)
                Image(systemName: "soccerball")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: Color.green.opacity(0.55), radius: 6, x: 0, y: 0)
        case .yellowCard:
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.yellow)
                .frame(width: 13, height: 18)
        case .redCard:
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.red)
                .frame(width: 13, height: 18)
        case .varEvent:
            Image(systemName: "theatermask.and.paintbrush")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.orange)
        case .substitution:
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private static func entries(for match: Match) -> [MatchEventEntry] {
        var output: [MatchEventEntry] = []

        appendGoals(
            from: match.homeGoalScorers,
            assists: match.homeAssists,
            teamName: match.displayHomeTeam,
            side: .home,
            match: match,
            to: &output
        )
        appendGoals(
            from: match.awayGoalScorers,
            assists: match.awayAssists,
            teamName: match.displayAwayTeam,
            side: .away,
            match: match,
            to: &output
        )
        appendCards(from: match.homeYellowCards, teamName: match.displayHomeTeam, kind: .yellowCard, side: .home, match: match, to: &output)
        appendCards(from: match.awayYellowCards, teamName: match.displayAwayTeam, kind: .yellowCard, side: .away, match: match, to: &output)
        appendCards(from: match.homeRedCards, teamName: match.displayHomeTeam, kind: .redCard, side: .home, match: match, to: &output)
        appendCards(from: match.awayRedCards, teamName: match.displayAwayTeam, kind: .redCard, side: .away, match: match, to: &output)
        appendVarEvents(from: match.homeVarEvents, side: .home, match: match, to: &output)
        appendVarEvents(from: match.awayVarEvents, side: .away, match: match, to: &output)
        appendSubstitutions(from: match.teamLineups?.home, side: .home, to: &output)
        appendSubstitutions(from: match.teamLineups?.away, side: .away, to: &output)

        return output
    }

    private static func appendGoals(
        from scorers: [MatchGoalScorer],
        assists: [MatchAssistProvider],
        teamName: String,
        side: MatchEventEntry.Side,
        match: Match,
        to output: inout [MatchEventEntry]
    ) {
        let assistLookup = assistProviderByMinute(assists)
        for scorer in scorers {
            let player = playerForEvent(
                idPlayer: scorer.idPlayer,
                named: scorer.player,
                side: side,
                match: match
            )
            for minute in scorer.goalTimes {
                output.append(
                    MatchEventEntry(
                        minute: formattedMatchMinute(minute),
                        sortMinute: sortMinute(minute),
                        kind: .goal,
                        side: side,
                        title: scorer.player,
                        subtitle: assistLookup[normalizedMinute(minute)]
                            .map { "\(teamName)\nAssist: \($0)" }
                            ?? teamName,
                        player: player
                    )
                )
            }
            for minute in scorer.ownGoalTimes {
                output.append(
                    MatchEventEntry(
                        minute: formattedMatchMinute(minute),
                        sortMinute: sortMinute(minute),
                        kind: .goal,
                        side: side,
                        title: "\(scorer.player) (OG)",
                        subtitle: teamName,
                        player: playerForEvent(
                            idPlayer: scorer.idPlayer,
                            named: scorer.player,
                            side: side,
                            match: match
                        )
                    )
                )
            }
            for minute in scorer.disallowedGoalTimes {
                output.append(
                    MatchEventEntry(
                        minute: formattedMatchMinute(minute),
                        sortMinute: sortMinute(minute),
                        kind: .goal,
                        side: side,
                        title: "\(scorer.player) disallowed goal",
                        subtitle: teamName,
                        player: player
                    )
                )
            }
        }
    }

    private static func appendCards(
        from cards: [MatchYellowCardEvent],
        teamName: String,
        kind: MatchEventEntry.Kind,
        side: MatchEventEntry.Side,
        match: Match,
        to output: inout [MatchEventEntry]
    ) {
        for card in cards {
            let player = playerForEvent(
                idPlayer: card.idPlayer,
                named: card.player,
                side: side,
                match: match
            )
            for minute in card.yellowCardTimes {
                output.append(
                    MatchEventEntry(
                        minute: formattedMatchMinute(minute),
                        sortMinute: sortMinute(minute),
                        kind: kind,
                        side: side,
                        title: card.player,
                        subtitle: teamName,
                        player: player
                    )
                )
            }
        }
    }

    private static func appendCards(
        from cards: [MatchRedCardEvent],
        teamName: String,
        kind: MatchEventEntry.Kind,
        side: MatchEventEntry.Side,
        match: Match,
        to output: inout [MatchEventEntry]
    ) {
        for card in cards {
            let player = playerForEvent(
                idPlayer: card.idPlayer,
                named: card.player,
                side: side,
                match: match
            )
            for minute in card.redCardTimes {
                output.append(
                    MatchEventEntry(
                        minute: formattedMatchMinute(minute),
                        sortMinute: sortMinute(minute),
                        kind: kind,
                        side: side,
                        title: card.player,
                        subtitle: teamName,
                        player: player
                    )
                )
            }
        }
    }

    private static func appendVarEvents(
        from varEvents: [MatchVarEvent],
        side: MatchEventEntry.Side,
        match: Match,
        to output: inout [MatchEventEntry]
    ) {
        for event in varEvents {
            guard let minute = event.minute, !minute.isEmpty else { continue }
            let player: MatchLineupPlayer?
            if let cutoutURL = event.cutoutURL, !cutoutURL.isEmpty {
                player = MatchLineupPlayer(
                    number: 0,
                    name: event.player ?? "",
                    idPlayer: event.idPlayer,
                    positionCategory: nil,
                    cutoutURL: cutoutURL,
                    formationRowIndex: nil,
                    formationSlotIndex: nil,
                    formationRowSize: nil
                )
            } else if let name = event.player, !name.isEmpty {
                player = playerForEvent(
                    idPlayer: event.idPlayer,
                    named: name,
                    side: side,
                    match: match
                )
            } else {
                player = nil
            }
            let title = event.player.map { $0 } ?? event.detail
            let subtitle = event.player != nil ? event.detail : nil
            output.append(
                MatchEventEntry(
                    minute: formattedMatchMinute(minute),
                    sortMinute: sortMinute(minute),
                    kind: .varEvent,
                    side: side,
                    title: title,
                    subtitle: subtitle,
                    player: player
                )
            )
        }
    }

    private static func appendSubstitutions(
        from lineup: MatchTeamLineup?,
        side: MatchEventEntry.Side,
        to output: inout [MatchEventEntry]
    ) {
        guard let lineup else { return }
        for sub in lineup.substitutions {
            let player = preferredLineupPlayer(matching: sub.playerOn, in: lineup)
            let playerOff = preferredLineupPlayer(matching: sub.playerOff, in: lineup)
            output.append(
                MatchEventEntry(
                    minute: formattedMatchMinute(sub.minute),
                    sortMinute: sortMinute(sub.minute),
                    kind: .substitution,
                    side: side,
                    title: "\(sub.playerOff.name) ▸ \(sub.playerOn.name)",
                    subtitle: nil,
                    player: player,
                    playerOff: playerOff,
                    playerOffName: sub.playerOff.name,
                    playerOnName: sub.playerOn.name
                )
            )
        }
    }

    private static func playerForEvent(
        idPlayer: String?,
        named name: String,
        side: MatchEventEntry.Side,
        match: Match
    ) -> MatchLineupPlayer? {
        let primaryLineup = side == .home ? match.teamLineups?.home : match.teamLineups?.away
        let secondaryLineup = side == .home ? match.teamLineups?.away : match.teamLineups?.home
        return preferredMatchEventLineupPlayer(
            named: name,
            idPlayer: idPlayer,
            primaryLineup: primaryLineup,
            secondaryLineup: secondaryLineup
        )
    }

    private static func assistProviderByMinute(_ assists: [MatchAssistProvider]) -> [String: String] {
        var lookup: [String: String] = [:]
        for assist in assists {
            for minute in assist.assistTimes {
                lookup[normalizedMinute(minute)] = assist.player
            }
        }
        return lookup
    }

    private static func normalizedMinute(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "'", with: "")
    }

    private static func sortMinute(_ value: String) -> Int {
        if isOtherMatchTimelineMinute(value) {
            return MatchEventEntry.otherTimelineSortMinute
        }

        let minuteParts = normalizedMinute(value)
            .split(separator: "+", maxSplits: 1)
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        if minuteParts.count == 2 {
            return minuteParts[0] * 100 + minuteParts[1]
        }

        return minuteParts.first.map { $0 * 100 } ?? Int.max
    }
}

private struct MatchEventEntry: Identifiable {
    enum Side {
        case home
        case away
    }

    enum Kind {
        case goal
        case yellowCard
        case redCard
        case varEvent
        case substitution
    }

    let minute: String
    let sortMinute: Int
    let kind: Kind
    let side: Side
    let title: String
    let subtitle: String?
    let player: MatchLineupPlayer?
    var playerOff: MatchLineupPlayer? = nil
    var playerOffName: String? = nil
    var playerOnName: String? = nil

    static let otherTimelineSortMinute = Int.max

    var id: String {
        "\(sortMinute)|\(minute)|\(title)|\(subtitle ?? "")|\(kind)|\(side)"
    }
}

enum FantasyMatchPointsPhase: Equatable, Sendable {
    case expected
    case provisional
    case final

    var columnTitle: String {
        "Points"
    }

    var statusTitle: String {
        switch self {
        case .expected:
            return "Expected"
        case .provisional:
            return "Provisional"
        case .final:
            return "Final"
        }
    }
}

func fantasyMatchPointsPhase(
    isMatchInProgress: Bool,
    isMatchFinished: Bool,
    squadScorePhase: FantasySquadDisplayData.ScorePhase
) -> FantasyMatchPointsPhase {
    if isMatchFinished, squadScorePhase == .final {
        return .final
    }
    if isMatchInProgress || isMatchFinished {
        return .provisional
    }
    return .expected
}

func fantasyMatchPointsValue(
    phase: FantasyMatchPointsPhase,
    expectedPoints: Double?,
    points: Int
) -> Double? {
    switch phase {
    case .expected:
        return expectedPoints
    case .provisional, .final:
        return Double(points)
    }
}

func fantasyMatchPointsTotal(_ values: [Double?]) -> Double? {
    guard !values.isEmpty else { return nil }
    let availableValues = values.compactMap { $0 }
    guard availableValues.count == values.count else { return nil }
    return availableValues.reduce(0, +)
}

func fantasyMatchShortPlayerName(
    displayName: String,
    fullName: String
) -> String {
    let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedFullName = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
    let baseName = trimmedDisplayName.isEmpty ? trimmedFullName : trimmedDisplayName
    let parts = baseName.split(whereSeparator: \.isWhitespace).map(String.init)
    guard let firstCharacter = parts.first?.first else {
        return baseName
    }
    if parts.count == 1 {
        let fullNameParts = trimmedFullName.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fullNameParts.count > 1,
              fullNameParts[0].localizedCaseInsensitiveCompare(baseName) != .orderedSame,
              let givenNameInitial = fullNameParts[0].first else {
            return baseName
        }
        return "\(givenNameInitial). \(baseName)"
    }

    let surnameParticles: Set<String> = [
        "da", "de", "del", "den", "der", "di", "dos", "du", "la", "le", "van", "von"
    ]
    if surnameParticles.contains(parts[0].lowercased()) {
        let fullNameParts = trimmedFullName.split(whereSeparator: \.isWhitespace)
        if let givenNameInitial = fullNameParts.first?.first {
            return "\(givenNameInitial). \(baseName)"
        }
    }

    return "\(firstCharacter). \(parts.dropFirst().joined(separator: " "))"
}

func fantasyMatchPlayerPrecedes(
    _ lhs: FantasyDisplayPlayer,
    points lhsPoints: Double?,
    _ rhs: FantasyDisplayPlayer,
    points rhsPoints: Double?
) -> Bool {
    switch (lhsPoints, rhsPoints) {
    case let (lhsPoints?, rhsPoints?) where lhsPoints != rhsPoints:
        return lhsPoints > rhsPoints
    case (_?, nil):
        return true
    case (nil, _?):
        return false
    default:
        if lhs.pickPosition != rhs.pickPosition {
            return lhs.pickPosition < rhs.pickPosition
        }
        return lhs.elementID < rhs.elementID
    }
}

private extension FantasyMatchPointsPhase {
    var tint: Color {
        switch self {
        case .expected:
            return Color(red: 0.67, green: 0.23, blue: 0.91)
        case .provisional:
            return Color(red: 0.91, green: 0.48, blue: 0.12)
        case .final:
            return Color(red: 0.16, green: 0.56, blue: 0.98)
        }
    }

    var accessibilityPointsDescription: String {
        switch self {
        case .expected:
            return "expected points"
        case .provisional:
            return "provisional points"
        case .final:
            return "final points"
        }
    }
}

private struct FantasyMatchPlayersSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var fantasyViewModel: FantasyViewModel
    @State private var selectedPlayer: FantasySelectedPlayerSelection?

    let context: FantasyMatchFixtureContext
    let sections: [FantasyMatchTeamSquadSection]
    let pointsPhase: FantasyMatchPointsPhase

    private var entries: [FantasyMatchPlayerTableEntry] {
        let entries = sections.flatMap { section in
            (section.starters + section.bench).map {
                FantasyMatchPlayerTableEntry(teamName: section.teamName, player: $0)
            }
        }
        return entries.sorted {
            fantasyMatchPlayerPrecedes(
                $0.player,
                points: points(for: $0.player),
                $1.player,
                points: points(for: $1.player)
            )
        }
    }

    private var total: Double? {
        fantasyMatchPointsTotal(entries.map { points(for: $0.player) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                FantasyMatchParticipationBadge(
                    diameter: 26,
                    iconSize: 13,
                    iconScale: 1.08,
                    shadowOpacity: 0.14
                )

                Text("FPL")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(context.squad.gameweekTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(pointsPhase.statusTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(pointsPhase.tint.opacity(0.13), in: Capsule(style: .continuous))
            }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Color.clear
                        .frame(width: dynamicTypeSize.isAccessibilitySize ? 28 : 34)
                        .accessibilityHidden(true)
                    Text("Player")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(pointsPhase.columnTitle)
                        .frame(minWidth: 58, alignment: .trailing)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.bottom, 6)

                Divider()

                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    FantasyMatchPlayerTableRow(
                        context: context,
                        entry: entry,
                        pointsPhase: pointsPhase,
                        onSelect: {
                            selectedPlayer = FantasySelectedPlayerSelection(
                                player: entry.player,
                                gameweekID: context.squad.gameweekID,
                                seasonKey: context.seasonKey
                            )
                        }
                    )

                    if index < entries.count - 1 {
                        Divider()
                    }
                }
            }

            Divider()

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your total for this game")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(pointsPhase.accessibilityPointsDescription.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(totalText)
                    .font(.title3.monospacedDigit().weight(.bold))
                    .foregroundStyle(total == nil ? Color.secondary : Color.primary)
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .sheet(item: $selectedPlayer) { selection in
            FantasyPlayerDetailsSheet(
                selection: selection,
                apiBaseURL: preferences.apiBaseURL,
                fantasyViewModel: fantasyViewModel
            )
            .presentationDragIndicator(.visible)
        }
    }

    private var totalText: String {
        guard let total else { return "–" }
        switch pointsPhase {
        case .expected:
            return String(format: "%.1f xP", total)
        case .provisional, .final:
            let points = Int(total)
            return "\(points) pt\(points == 1 ? "" : "s")"
        }
    }

    private func points(for player: FantasyDisplayPlayer) -> Double? {
        fantasyMatchPointsValue(
            phase: pointsPhase,
            expectedPoints: context.expectedPoints(for: player),
            points: context.points(for: player)
        )
    }
}

private struct FantasyMatchPlayerTableEntry: Identifiable {
    let teamName: String
    let player: FantasyDisplayPlayer

    var id: Int {
        player.elementID
    }
}

private struct FantasyMatchPlayerTableRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let context: FantasyMatchFixtureContext
    let entry: FantasyMatchPlayerTableEntry
    let pointsPhase: FantasyMatchPointsPhase
    let onSelect: () -> Void

    private var name: String {
        fantasyMatchShortPlayerName(
            displayName: entry.player.displayName,
            fullName: entry.player.fullName
        )
    }

    private var points: Double? {
        fantasyMatchPointsValue(
            phase: pointsPhase,
            expectedPoints: context.expectedPoints(for: entry.player),
            points: context.points(for: entry.player)
        )
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                FantasyMatchTeamLogo(
                    teamName: entry.teamName,
                    size: dynamicTypeSize.isAccessibilitySize ? 28 : 34
                )
                .frame(width: dynamicTypeSize.isAccessibilitySize ? 28 : 34)

                playerImage
                playerName
                    .frame(maxWidth: .infinity, alignment: .leading)
                pointsPill
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("View player details")
    }

    private var playerImage: some View {
        FantasyPlayerProfileImage(
            url: entry.player.profileImageURL,
            size: 34,
            height: 34
        )
    }

    private var playerName: some View {
        Text(name)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var pointsPill: some View {
        Text(pointsText)
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .foregroundStyle(points == nil ? Color.secondary : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minWidth: 58)
            .background(
                pointsPhase.tint.opacity(points == nil ? 0.06 : 0.13),
                in: Capsule(style: .continuous)
            )
    }

    private var pointsText: String {
        guard let points else { return "–" }
        switch pointsPhase {
        case .expected:
            return String(format: "%.1f", points)
        case .provisional, .final:
            return "\(Int(points))"
        }
    }

    private var accessibilityLabel: String {
        guard let points else {
            return "\(entry.teamName), \(name), \(pointsPhase.accessibilityPointsDescription) unavailable"
        }
        switch pointsPhase {
        case .expected:
            return String(
                format: "%@, %@, %.1f expected points",
                entry.teamName,
                name,
                points
            )
        case .provisional, .final:
            return "\(entry.teamName), \(name), \(Int(points)) \(pointsPhase.accessibilityPointsDescription)"
        }
    }
}

private struct FantasyMatchTeamLogo: View {
    let teamName: String
    let size: CGFloat

    var body: some View {
        let resolvedTeamName = FantasyTeamShortNameMappingsStore.shared.resolveTeamName(for: teamName)
        Group {
            if let logo = LogoResolver.shared.image(for: resolvedTeamName)
                ?? LogoResolver.shared.image(for: teamName) {
                Image(uiImage: logo)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "shield")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(size * 0.16)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Match Actions

private struct MatchActionAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct CalendarChoice: Identifiable {
    let id: String
    let title: String
}

// MARK: - Social Media

private struct MatchSocialSection: View {
    let items: [MatchSocialItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Highlights & Social")
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(spacing: 8) {
                ForEach(items) { item in
                    if let url = validExternalURL(item.url) {
                        Link(destination: url) {
                            MatchSocialRow(item: item)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens in another app")
                    }
                }
            }
        }
    }

    private func validExternalURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else {
            return nil
        }
        return url
    }
}

private struct MatchSocialRow: View {
    let item: MatchSocialItem

    var body: some View {
        HStack(spacing: 12) {
            platformIcon
            MatchSocialThumbnail(urlString: item.thumbnail)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)

                if let sourceText {
                    Text(sourceText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private var sourceText: String? {
        let account = item.account?.name ?? item.account?.handle
        let timestamp = relativeTimestamp
        let parts = [account, timestamp].compactMap { value -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private var relativeTimestamp: String? {
        guard let publishedAt = item.publishedAt else { return nil }
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: publishedAt) ?? {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: publishedAt)
        }()
        guard let date else { return nil }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder
    private var platformIcon: some View {
        let descriptor = (item.type ?? item.url).lowercased()
        if descriptor.contains("youtube") || descriptor.contains("youtu") {
            Image(systemName: "play.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 22)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else if descriptor.contains("twitter") || descriptor.contains("x.com") {
            Text("X")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
        } else {
            Image(systemName: "link")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
    }
}

private struct MatchSocialThumbnail: View {
    let urlString: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.tertiarySystemFill))

            if let url = urlString.flatMap(URL.init) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "play.rectangle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: "link")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 72, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - TV Channel Row

private struct TvChannelRow: View {
    let channel: TvChannel

    var body: some View {
        HStack(spacing: 9) {
            if let logoURL = channel.logo.flatMap(URL.init) {
                AsyncImage(url: logoURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    if let asset = TvLogoResolver.shared.image(for: channel.name) {
                        Image(uiImage: asset).resizable().scaledToFit()
                    }
                }
                .frame(width: 44, height: 24)
            } else if let image = TvLogoResolver.shared.image(for: channel.name) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 24)
            } else {
                Image(systemName: "tv")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 24)
            }

            Text(channel.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.horizontal, 10)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Lineup Pitch

private struct MatchLineupPitchSection: View {
    let match: Match
    let fantasyHighlightLookup: FantasySquadMembershipLookup?
    let fantasyPointsLookup: FantasySquadMembershipLookup?

    var body: some View {
        if let teamLineups = match.teamLineups,
           let home = teamLineups.home,
           let away = teamLineups.away,
           !home.startingLineup.isEmpty,
           !away.startingLineup.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Starting Line-ups")
                    .font(.headline)
                    .foregroundStyle(.primary)

                MatchLineupTeamPanelsView(
                    homeLineup: home,
                    awayLineup: away,
                    fallbackHomeTeamName: match.displayHomeTeam,
                    fallbackAwayTeamName: match.displayAwayTeam,
                    homeTeamID: match.homeTeamId,
                    awayTeamID: match.awayTeamId,
                    homeGoals: match.homeGoalScorers,
                    awayGoals: match.awayGoalScorers,
                    homeAssists: match.homeAssists,
                    awayAssists: match.awayAssists,
                    homeYellowCards: match.homeYellowCards,
                    awayYellowCards: match.awayYellowCards,
                    homeRedCards: match.homeRedCards,
                    awayRedCards: match.awayRedCards
                )
            }
        }
    }
}

private struct MatchLineupTeamPanelsView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @ObservedObject private var teamColorCatalog = TeamColorCatalog.shared
    @State private var selectedPlayer: MatchLineupPlayer?

    let homeLineup: MatchTeamLineup
    let awayLineup: MatchTeamLineup
    let fallbackHomeTeamName: String
    let fallbackAwayTeamName: String
    let homeTeamID: String?
    let awayTeamID: String?
    let homeGoals: [MatchGoalScorer]
    let awayGoals: [MatchGoalScorer]
    let homeAssists: [MatchAssistProvider]
    let awayAssists: [MatchAssistProvider]
    let homeYellowCards: [MatchYellowCardEvent]
    let awayYellowCards: [MatchYellowCardEvent]
    let homeRedCards: [MatchRedCardEvent]
    let awayRedCards: [MatchRedCardEvent]

    private var homeTeamName: String { homeLineup.team ?? fallbackHomeTeamName }
    private var awayTeamName: String { awayLineup.team ?? fallbackAwayTeamName }

    private var homeTeamColors: TeamLineupNumberColors {
        teamColorCatalog.lineupColors(
            for: homeTeamName,
            opponentTeamName: awayTeamName,
            isAway: false,
            fallbackColors: TeamLineupNumberColors(
                background: .yellow,
                foreground: .black,
                outline: nil
            )
        )
    }

    private var awayTeamColors: TeamLineupNumberColors {
        teamColorCatalog.lineupColors(
            for: awayTeamName,
            opponentTeamName: homeTeamName,
            isAway: true,
            fallbackColors: TeamLineupNumberColors(
                background: .red,
                foreground: .black,
                outline: nil
            )
        )
    }

    private var homeLookup: MatchLineupMarkerLookup {
        MatchLineupMarkerLookup(
            goals: homeGoals,
            assists: homeAssists,
            yellowCards: homeYellowCards,
            redCards: homeRedCards,
            substitutions: homeLineup.substitutions
        )
    }

    private var awayLookup: MatchLineupMarkerLookup {
        MatchLineupMarkerLookup(
            goals: awayGoals,
            assists: awayAssists,
            yellowCards: awayYellowCards,
            redCards: awayRedCards,
            substitutions: awayLineup.substitutions
        )
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                teamHeader(
                    lineup: homeLineup,
                    teamName: homeTeamName,
                    teamID: homeTeamID,
                    side: .home
                )

                GeometryReader { proxy in
                    ZStack {
                        Image("MatchLineupPitchTexture")
                            .resizable()
                            .frame(width: proxy.size.width, height: proxy.size.height)

                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.18),
                                Color.clear,
                                Color.black.opacity(0.16)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )

                        VStack(spacing: 0) {
                            MatchLineupCombinedFormationHalf(
                                lineup: homeLineup,
                                side: .home,
                                lookup: homeLookup,
                                teamColors: homeTeamColors,
                                onSelectPlayer: { selectedPlayer = $0 }
                            )

                            MatchLineupCombinedFormationHalf(
                                lineup: awayLineup,
                                side: .away,
                                lookup: awayLookup,
                                teamColors: awayTeamColors,
                                onSelectPlayer: { selectedPlayer = $0 }
                            )
                        }
                        .padding(.horizontal, 16)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                }
                // The two stacked formations need more vertical room than a
                // regulation-pitch ratio once portraits and incidents are shown.
                .aspectRatio(6.0 / 11.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()

                teamHeader(
                    lineup: awayLineup,
                    teamName: awayTeamName,
                    teamID: awayTeamID,
                    side: .away
                )

                if !homeLineup.substitutions.isEmpty {
                    substitutes(
                        lineup: homeLineup,
                        teamName: homeTeamName,
                        lookup: homeLookup,
                        teamColors: homeTeamColors
                    )
                }

                if !awayLineup.substitutions.isEmpty {
                    substitutes(
                        lineup: awayLineup,
                        teamName: awayTeamName,
                        lookup: awayLookup,
                        teamColors: awayTeamColors
                    )
                }
            }
            .background(Color(.secondarySystemBackground))
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            }

            MatchLineupMarkerLegend()
        }
        .sheet(item: $selectedPlayer) { player in
            PlayerDetailsSheet(player: player, apiBaseURL: preferences.apiBaseURL)
        }
    }

    private func teamHeader(
        lineup: MatchTeamLineup,
        teamName: String,
        teamID: String?,
        side: MatchLineupDisplaySide
    ) -> some View {
        let accentColor = side == .home ? homeTeamColors.background : awayTeamColors.background
        return HStack(spacing: 10) {
            Group {
                if let logo = LogoResolver.shared.image(for: teamName, teamId: teamID) {
                    Image(uiImage: logo).resizable().scaledToFit()
                } else {
                    Image(systemName: "shield.fill")
                        .foregroundStyle(accentColor)
                        .overlay {
                            Image(systemName: "shield")
                                .foregroundStyle(Color.primary.opacity(0.72))
                        }
                }
            }
            .frame(width: 28, height: 28)

            Text(teamName.uppercased())
                .font(.subheadline.weight(.black))
                .tracking(0.4)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .layoutPriority(1)

            Spacer()

            Text(lineup.formation ?? "Formation")
                .font(.subheadline.monospacedDigit().weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func substitutes(
        lineup: MatchTeamLineup,
        teamName: String,
        lookup: MatchLineupMarkerLookup,
        teamColors: TeamLineupNumberColors
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(teamName.uppercased()) SUBSTITUTES USED")
                .font(.caption2.weight(.bold))
                .tracking(0.5)
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 76, maximum: 110), spacing: 8, alignment: .top)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(lineup.substitutions) { substitution in
                    let playerOn = preferredLineupPlayer(
                        matching: substitution.playerOn,
                        in: lineup
                    )
                    Button {
                        if playerOn.idPlayer != nil {
                            selectedPlayer = playerOn
                        }
                    } label: {
                        VStack(spacing: 5) {
                            MatchLineupPlayerPortraitView(
                                player: playerOn,
                                diameter: 40,
                                borderColor: teamColors.background,
                                borderOutlineColor: teamColors.foreground
                            )

                            Text(condensedLineupPlayerName(playerOn.name))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)

                            MatchLineupBadgeFlowLayout(spacing: 2) {
                                MatchLineupInlineMarker(kind: .subIn, minute: substitution.minute)
                                ForEach(lookup.markers(for: playerOn)) { marker in
                                    MatchLineupInlineMarker(kind: marker.kind, minute: marker.minute)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .allowsHitTesting(playerOn.idPlayer != nil)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground))
    }
}

private struct MatchLineupCombinedFormationHalf: View {
    let lineup: MatchTeamLineup
    let side: MatchLineupDisplaySide
    let lookup: MatchLineupMarkerLookup
    let teamColors: TeamLineupNumberColors
    let onSelectPlayer: (MatchLineupPlayer) -> Void

    private var rows: [[MatchLineupPlayer]] {
        let playersWithRows = lineup.startingLineup.filter { $0.formationRowIndex != nil }
        let ordered: [[MatchLineupPlayer]]

        if playersWithRows.count >= 8 {
            ordered = Dictionary(grouping: lineup.startingLineup) { $0.formationRowIndex ?? Int.max }
                .sorted { $0.key < $1.key }
                .map { _, players in players.sorted(by: playerOrder) }
        } else {
            ordered = [
                lineupRow(.goalkeeper),
                lineupRow(.defender),
                lineupRow(.midfielder),
                lineupRow(.forward)
            ]
        }

        return side == .home ? ordered : Array(ordered.reversed())
    }

    private func lineupRow(_ role: MatchLineupRole) -> [MatchLineupPlayer] {
        lineup.startingLineup.filter { lineupRole(for: $0) == role }.sorted(by: playerOrder)
    }

    private func playerOrder(_ left: MatchLineupPlayer, _ right: MatchLineupPlayer) -> Bool {
        if let leftSlot = left.formationSlotIndex,
           let rightSlot = right.formationSlotIndex,
           leftSlot != rightSlot {
            return leftSlot < rightSlot
        }
        let leftPosition = horizontalScore(for: left)
        let rightPosition = horizontalScore(for: right)
        if leftPosition != rightPosition { return leftPosition < rightPosition }
        return (left.number ?? Int.max) < (right.number ?? Int.max)
    }

    private var portraitDiameter: CGFloat {
        rows.count >= 5 ? 48 : 52
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    let columnWidth = proxy.size.width / CGFloat(max(row.count, 1))
                    let nameMaxWidth = nameLabelWidth(
                        columnWidth: columnWidth,
                        playerCount: row.count
                    )
                    HStack(alignment: .center, spacing: 0) {
                        ForEach(row) { player in
                            MatchLineupPlayerTacticalMarker(
                                player: player,
                                markers: lookup.markers(for: player),
                                teamColors: teamColors,
                                portraitDiameter: portraitDiameter,
                                nameMaxWidth: nameMaxWidth,
                                onSelectPlayer: onSelectPlayer
                            )
                            .frame(width: columnWidth)
                        }
                    }
                    .frame(width: proxy.size.width)
                    // Names extend below their marker frame, so upper rows must
                    // win the paint order if a very narrow layout still overlaps.
                    .zIndex(Double(rows.count - index))
                    .position(
                        x: proxy.size.width / 2,
                        y: rowPosition(
                            index: index,
                            height: proxy.size.height
                        )
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func nameLabelWidth(columnWidth: CGFloat, playerCount: Int) -> CGFloat {
        let preferredMaximum: CGFloat
        switch playerCount {
        case 1:
            preferredMaximum = 132
        case 2:
            preferredMaximum = 120
        case 3:
            preferredMaximum = 108
        default:
            preferredMaximum = 92
        }

        let cellGutter: CGFloat = playerCount >= 4 ? 4 : 8
        return max(
            portraitDiameter,
            min(preferredMaximum, max(columnWidth - cellGutter, portraitDiameter))
        )
    }

    private func rowPosition(index: Int, height: CGFloat) -> CGFloat {
        let topInset = min(40, height * 0.11)
        let bottomInset = side == .away ? min(72, height * 0.22) : topInset
        guard rows.count > 1 else { return height / 2 }
        let availableHeight = max(0, height - topInset - bottomInset)
        let progress = lineupRowProgress(
            rowCounts: rows.map(\.count),
            index: index,
            availableHeight: availableHeight,
            portraitDiameter: portraitDiameter
        )
        return topInset + (availableHeight * progress)
    }
}

private struct MatchLineupPlayerTacticalMarker: View {
    let player: MatchLineupPlayer
    let markers: [MatchLineupMarker]
    let teamColors: TeamLineupNumberColors
    let portraitDiameter: CGFloat
    let nameMaxWidth: CGFloat
    let onSelectPlayer: (MatchLineupPlayer) -> Void

    var body: some View {
        Button {
            if player.idPlayer != nil { onSelectPlayer(player) }
        } label: {
            ZStack(alignment: .top) {
                ZStack(alignment: .topLeading) {
                    MatchLineupPlayerPortraitView(
                        player: player,
                        diameter: portraitDiameter,
                        borderColor: teamColors.background,
                        borderOutlineColor: teamColors.foreground,
                        borderLineWidth: 2
                    )

                    if let number = player.number {
                        Text("\(number)")
                            .font(.system(size: 9.5, weight: .black, design: .rounded))
                            .foregroundStyle(teamColors.foreground)
                            .frame(width: 20, height: 20)
                            .background(teamColors.background, in: Circle())
                            .overlay {
                                Circle().stroke(
                                    teamColors.outline ?? teamColors.foreground.opacity(0.55),
                                    lineWidth: 1
                                )
                            }
                            .offset(x: -4, y: -2)
                    }
                }

                MatchLineupPlayerNameLabel(
                    name: condensedLineupPlayerName(player.name),
                    markers: markers,
                    maxWidth: nameMaxWidth
                )
                .offset(y: portraitDiameter)
            }
            .frame(height: portraitDiameter, alignment: .top)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(player.idPlayer != nil)
        .accessibilityElement(children: .combine)
    }
}

private struct MatchLineupPlayerNameLabel: View {
    let name: String
    let markers: [MatchLineupMarker]
    let maxWidth: CGFloat

    var body: some View {
        ViewThatFits(in: .horizontal) {
            label(fontSize: 10)
                .fixedSize(horizontal: true, vertical: false)

            label(fontSize: 9)
                .fixedSize(horizontal: true, vertical: false)

            label(fontSize: 9)
                .minimumScaleFactor(0.78)
        }
        .frame(width: maxWidth)
    }

    private func label(fontSize: CGFloat) -> some View {
        HStack(spacing: 3) {
            Text(name)
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .layoutPriority(1)

            if !markers.isEmpty {
                HStack(spacing: 2) {
                    ForEach(markers) { marker in
                        MatchLineupMarkerIcon(kind: marker.kind)
                    }
                }
                .fixedSize(horizontal: true, vertical: true)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(
            Color.black.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 3, style: .continuous)
        )
    }
}

private struct MatchLineupBadgeFlowLayout: Layout {
    let spacing: CGFloat

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = makeRows(sizes: sizes, maxWidth: proposal.width ?? .infinity)
        return CGSize(
            width: rows.map(\.width).max() ?? 0,
            height: rows.reduce(0) { $0 + $1.height }
                + (CGFloat(max(rows.count - 1, 0)) * spacing)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = makeRows(sizes: sizes, maxWidth: bounds.width)
        var y = bounds.minY

        for row in rows {
            var x = bounds.midX - (row.width / 2)
            for index in row.indices {
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: .unspecified
                )
                x += sizes[index].width + spacing
            }
            y += row.height + spacing
        }
    }

    private func makeRows(sizes: [CGSize], maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for (index, size) in sizes.enumerated() {
            let candidateWidth = current.indices.isEmpty
                ? size.width
                : current.width + spacing + size.width

            if !current.indices.isEmpty, candidateWidth > maxWidth {
                rows.append(current)
                current = Row()
            }

            if !current.indices.isEmpty {
                current.width += spacing
            }
            current.indices.append(index)
            current.width += size.width
            current.height = max(current.height, size.height)
        }

        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}

private struct MatchLineupInlineMarker: View {
    let kind: MatchLineupMarker.Kind
    let minute: String

    var body: some View {
        HStack(spacing: 2) {
            MatchLineupMarkerIcon(kind: kind)
            if !minute.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(formattedMatchMinute(minute))
                    .font(.system(size: 7.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(Color.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        .fixedSize(horizontal: true, vertical: true)
    }
}

private struct MatchLineupMarkerIcon: View {
    let kind: MatchLineupMarker.Kind

    @ViewBuilder
    var body: some View {
        switch kind {
        case .goal:
            Image(systemName: "soccerball")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
        case .assist:
            Text("A")
                .font(.system(size: 6, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 9, height: 9)
                .background(Color.blue, in: Circle())
        case .yellowCard:
            RoundedRectangle(cornerRadius: 1).fill(Color.yellow).frame(width: 6, height: 9)
        case .redCard:
            RoundedRectangle(cornerRadius: 1).fill(Color.red).frame(width: 6, height: 9)
        case .subIn:
            Image(systemName: "arrow.up")
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(.green)
        case .subOut:
            Image(systemName: "arrow.down")
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(.red)
        }
    }
}

private struct MatchLineupMarkerLegend: View {
    private let markers: [(MatchLineupMarker.Kind, String)] = [
        (.goal, "Goal"), (.assist, "Assist"), (.yellowCard, "Yellow"),
        (.redCard, "Red"), (.subIn, "Sub in"), (.subOut, "Sub out")
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
                    HStack(spacing: 4) {
                        MatchLineupInlineMarker(kind: marker.0, minute: "")
                            .accessibilityHidden(true)
                        Text(marker.1)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Line-up markers: goal, assist, yellow card, red card, substitute in, substitute out")
    }
}

private struct MatchLineupMarker: Identifiable {
    enum Kind {
        case goal
        case assist
        case yellowCard
        case redCard
        case subIn
        case subOut
    }

    let kind: Kind
    let minute: String

    var id: String { "\(kind)-\(minute)" }
}

private struct MatchLineupMarkerLookup {
    private let goals: [MatchNamedMinutes]
    private let assists: [MatchNamedMinutes]
    private let yellowCards: [MatchNamedMinutes]
    private let redCards: [MatchNamedMinutes]
    private let substitutions: [MatchLineupSubstitution]

    init(
        goals: [MatchGoalScorer],
        assists: [MatchAssistProvider],
        yellowCards: [MatchYellowCardEvent],
        redCards: [MatchRedCardEvent],
        substitutions: [MatchLineupSubstitution]
    ) {
        self.goals = goals.map {
            MatchNamedMinutes(idPlayer: $0.idPlayer, name: $0.player, minutes: $0.goalTimes)
        }
        self.assists = assists.map { MatchNamedMinutes(name: $0.player, minutes: $0.assistTimes) }
        self.yellowCards = yellowCards.map {
            MatchNamedMinutes(idPlayer: $0.idPlayer, name: $0.player, minutes: $0.yellowCardTimes)
        }
        self.redCards = redCards.map {
            MatchNamedMinutes(idPlayer: $0.idPlayer, name: $0.player, minutes: $0.redCardTimes)
        }
        self.substitutions = substitutions
    }

    func markers(for player: MatchLineupPlayer) -> [MatchLineupMarker] {
        var result: [MatchLineupMarker] = []
        result += minutes(for: player, in: goals).map { MatchLineupMarker(kind: .goal, minute: $0) }
        result += minutes(for: player, in: assists).map { MatchLineupMarker(kind: .assist, minute: $0) }
        result += minutes(for: player, in: yellowCards).map { MatchLineupMarker(kind: .yellowCard, minute: $0) }
        result += minutes(for: player, in: redCards).map { MatchLineupMarker(kind: .redCard, minute: $0) }

        if let substitution = substitution(for: player) {
            result.append(MatchLineupMarker(kind: .subOut, minute: substitution.minute))
        }

        return result.sorted { matchMinuteSortValue($0.minute) < matchMinuteSortValue($1.minute) }
    }

    private func minutes(for player: MatchLineupPlayer, in entries: [MatchNamedMinutes]) -> [String] {
        if let playerID = player.idPlayer?.trimmingCharacters(in: .whitespacesAndNewlines),
           !playerID.isEmpty,
           let idMatch = entries.first(where: {
               $0.idPlayer?.trimmingCharacters(in: .whitespacesAndNewlines) == playerID
           }) {
            return idMatch.minutes
        }

        let playerLookup = MatchPlayerNameLookup(name: player.name)
        let best = entries.max { left, right in
            playerLookup.matchScore(against: left.lookup) < playerLookup.matchScore(against: right.lookup)
        }
        guard let best, playerLookup.matchScore(against: best.lookup) > 0 else { return [] }
        return best.minutes
    }

    private func substitution(for player: MatchLineupPlayer) -> MatchLineupSubstitution? {
        if let playerID = player.idPlayer?.trimmingCharacters(in: .whitespacesAndNewlines),
           !playerID.isEmpty,
           let idMatch = substitutions.first(where: {
               $0.playerOff.idPlayer?.trimmingCharacters(in: .whitespacesAndNewlines) == playerID
           }) {
            return idMatch
        }

        let lookup = MatchPlayerNameLookup(name: player.name)
        if let nameMatch = substitutions.first(where: {
            lookup.matchScore(against: MatchPlayerNameLookup(name: $0.playerOff.name)) > 1
        }) {
            return nameMatch
        }

        guard let number = player.number else { return nil }
        let numberMatches = substitutions.filter { $0.playerOff.number == number }
        return numberMatches.count == 1 ? numberMatches[0] : nil
    }
}

private struct MatchNamedMinutes {
    let idPlayer: String?
    let lookup: MatchPlayerNameLookup
    let minutes: [String]

    init(idPlayer: String? = nil, name: String, minutes: [String]) {
        self.idPlayer = idPlayer
        lookup = MatchPlayerNameLookup(name: name)
        self.minutes = minutes
    }
}

private func matchMinuteSortValue(_ rawValue: String) -> Int {
    let parts = rawValue
        .replacingOccurrences(of: "'", with: "")
        .split(separator: "+", maxSplits: 1)
        .compactMap { Int($0) }
    guard let minute = parts.first else { return Int.max }
    return minute * 100 + (parts.count > 1 ? parts[1] : 0)
}

private enum MatchLineupDisplaySide {
    case home
    case away
}

private enum MatchLineupRole {
    case goalkeeper
    case defender
    case midfielder
    case forward
}

func lineupRowProgress(
    rowCounts: [Int],
    index: Int,
    availableHeight: CGFloat,
    portraitDiameter: CGFloat
) -> CGFloat {
    guard rowCounts.count > 1 else { return 0.5 }
    guard index > 0 else { return 0 }
    guard index < rowCounts.count - 1 else { return 1 }
    guard availableHeight > 0 else {
        return CGFloat(index) / CGFloat(rowCounts.count - 1)
    }

    let minimumGaps = zip(rowCounts, rowCounts.dropFirst()).map { upperCount, lowerCount in
        let collisionRisk = lineupRowCollisionRisk(
            upperCount: upperCount,
            lowerCount: lowerCount
        )
        // The label sits immediately below the portrait and is about 14 points
        // tall. Staggered rows can safely sit closer than aligned player lanes.
        let staggeredGap = portraitDiameter * 0.6
        let alignedGap = portraitDiameter + 14
        return staggeredGap + ((alignedGap - staggeredGap) * collisionRisk)
    }
    let minimumTotal = minimumGaps.reduce(0, +)
    let gaps: [CGFloat]
    if minimumTotal <= availableHeight {
        let extraPerGap = (availableHeight - minimumTotal) / CGFloat(minimumGaps.count)
        gaps = minimumGaps.map { $0 + extraPerGap }
    } else {
        let scale = availableHeight / minimumTotal
        gaps = minimumGaps.map { $0 * scale }
    }
    return gaps.prefix(index).reduce(0, +) / availableHeight
}

private func lineupRowCollisionRisk(upperCount: Int, lowerCount: Int) -> CGFloat {
    guard upperCount > 0, lowerCount > 0 else { return 0 }

    let upperCenters = (0..<upperCount).map { (CGFloat($0) + 0.5) / CGFloat(upperCount) }
    let lowerCenters = (0..<lowerCount).map { (CGFloat($0) + 0.5) / CGFloat(lowerCount) }
    let closestLaneDistance = upperCenters.flatMap { upperCenter in
        lowerCenters.map { abs(upperCenter - $0) }
    }.min() ?? 0.25
    return max(0, 1 - (closestLaneDistance / 0.25))
}

private func lineupRole(for player: MatchLineupPlayer) -> MatchLineupRole? {
    switch player.positionShort?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
    case "G":
        return .goalkeeper
    case "D":
        return .defender
    case "M":
        return .midfielder
    case "F":
        return .forward
    default:
        break
    }

    switch player.positionCategory?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "goalkeeper":
        return .goalkeeper
    case "defender":
        return .defender
    case "midfielder":
        return .midfielder
    case "attacker":
        return .forward
    default:
        return nil
    }
}

private func horizontalScore(for player: MatchLineupPlayer) -> Int {
    let position = String(player.position ?? "")
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        .lowercased()

    if position.contains("left") {
        return 0
    }
    if position.contains("right") {
        return 2
    }
    return 1
}

private struct MatchLineupPlayerPortraitView: View {
    static let size: CGFloat = 54

    let player: MatchLineupPlayer
    var diameter: CGFloat = MatchLineupPlayerPortraitView.size
    var borderColor: Color = Color.white.opacity(0.82)
    var borderOutlineColor: Color?
    var borderLineWidth: CGFloat = 1.4
    var glowColor: Color = .clear
    var glowRadius: CGFloat = 0

    private var portraitURLCandidates: [URL] {
        guard let value = player.cutoutURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return []
        }
        return lineupPortraitURLCandidates(for: value)
    }

    private var initials: String {
        let parts = player.name
            .replacingOccurrences(of: "(c)", with: "", options: .caseInsensitive)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let first = parts.first?.first.map(String.init) ?? ""
        let last = parts.dropFirst().last?.first.map(String.init) ?? ""
        let value = first + last
        return value.isEmpty ? "?" : value.uppercased()
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            borderColor.opacity(0.28),
                            Color.black.opacity(0.34)
                        ],
                        center: .top,
                        startRadius: 1,
                        endRadius: diameter * 0.72
                    )
                )

            if !portraitURLCandidates.isEmpty {
                MatchLineupRemotePortrait(urls: portraitURLCandidates, fallback: initialsView)
            } else {
                initialsView
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay {
            ZStack {
                if let borderOutlineColor {
                    Circle()
                        .stroke(borderOutlineColor.opacity(0.72), lineWidth: borderLineWidth + 1.5)
                }

                Circle()
                    .stroke(borderColor, lineWidth: borderLineWidth)
            }
        }
        .shadow(color: glowColor, radius: glowRadius, x: 0, y: 0)
        .shadow(color: .black.opacity(0.20), radius: 4, x: 0, y: 2)
    }

    private var initialsView: some View {
        Text(initials)
            .font(.system(size: diameter * 0.24, weight: .black, design: .rounded))
            .foregroundStyle(.white)
    }
}

private struct MatchLineupRemotePortrait<Fallback: View>: View {
    let urls: [URL]
    let fallback: Fallback

    var body: some View {
        RemotePlayerPortraitImage(urls: urls) { image in
            image
                .resizable()
                .scaledToFill()
                .scaleEffect(1.08, anchor: .top)
        } placeholder: {
            fallback
        }
    }
}

private func lineupPortraitURLCandidates(for value: String) -> [URL] {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return URL(string: trimmed).map { [$0] } ?? []
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
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
    let fantasyPointsLookup: FantasySquadMembershipLookup?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MatchLineupSubstitutesTable(lineup: homeLineup, fantasyPointsLookup: fantasyPointsLookup)
            MatchLineupSubstitutesTable(lineup: awayLineup, fantasyPointsLookup: fantasyPointsLookup)
        }
    }
}

private struct MatchLineupSubstitutesTable: View {
    let lineup: MatchTeamLineup
    let fantasyPointsLookup: FantasySquadMembershipLookup?

    private var rows: [MatchLineupSubstituteRow] {
        lineup.substitutes.map { substitute in
            let substitution = lineup.substitutions.first {
                guard let playerOnNumber = $0.playerOn.number,
                      let substituteNumber = substitute.number
                else { return false }
                return playerOnNumber == substituteNumber
            }
            return MatchLineupSubstituteRow(
                player: substitute,
                substitution: substitution,
                fantasyPoints: fantasyPointsLookup?.points(
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
                        Text(row.player.number.map { String($0) } ?? "–")
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

private struct PlayerDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let player: MatchLineupPlayer
    let apiBaseURL: String

    @State private var details: PlayerDetails?
    @State private var errorMessage: String?
    @State private var isLoadingDetails = false
    @State private var heroIsPresented = false

    private var imageURLs: [URL] {
        let candidates: [String?] = [
            player.cutoutURL,
            details?.cutoutURL,
            details?.renderURL,
            details?.thumbURL
        ]

        var seen = Set<URL>()
        return candidates.compactMap { candidate in
            guard let value = candidate?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  let url = URL(string: value)
            else {
                return nil
            }
            return seen.insert(url).inserted ? url : nil
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    hero

                    if isLoadingDetails {
                        ProgressView("Loading more player details")
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }

                    if let errorMessage {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(errorMessage)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Button("Try Again") {
                                Task { await loadDetails() }
                            }
                            .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(cardBackground)
                    }

                    if let details {
                        factStrip(details)
                        aboutCard(details)
                        informationCard(details)
                    }
                }
                .padding()
            }
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.02, green: 0.11, blue: 0.19),
                        Color(red: 0.01, green: 0.05, blue: 0.10)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .navigationTitle("Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: player.idPlayer) {
            await loadDetails()
        }
    }

    private var hero: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                heroBackdrop
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                heroCopy
                    .frame(width: proxy.size.width * 0.44, alignment: .leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.leading, 20)

                heroPortrait
                    .frame(width: proxy.size.width * 0.58, height: proxy.size.height, alignment: .trailing)
                    .padding(.trailing, 2)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomTrailing)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.19),
                                Color.blue.opacity(0.10),
                                Color.black.opacity(0.22)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .overlay(alignment: .top) {
                Capsule()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 1)
                    .padding(.horizontal, 28)
                    .blur(radius: 0.4)
            }
            .shadow(color: .black.opacity(0.28), radius: 14, y: 8)
        }
        .frame(height: 264)
        .onAppear {
            guard !heroIsPresented else { return }
            if reduceMotion {
                heroIsPresented = true
            } else {
                withAnimation(.easeOut(duration: 0.35)) {
                    heroIsPresented = true
                }
            }
        }
    }

    private var heroBackdrop: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.055, green: 0.22, blue: 0.37),
                            Color(red: 0.025, green: 0.115, blue: 0.20),
                            Color(red: 0.012, green: 0.065, blue: 0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Ellipse()
                .fill(Color.blue.opacity(0.045))
                .frame(width: 330, height: 420)
                .rotationEffect(.degrees(24))
                .offset(x: -145, y: 110)

            Circle()
                .trim(from: 0.06, to: 0.62)
                .stroke(Color.white.opacity(0.045), lineWidth: 1)
                .frame(width: 310, height: 310)
                .rotationEffect(.degrees(-22))
                .offset(x: 108, y: -112)

            Circle()
                .stroke(Color.blue.opacity(0.055), lineWidth: 16)
                .frame(width: 235, height: 235)
                .blur(radius: 13)
                .offset(x: 108, y: -88)

            LinearGradient(
                colors: [
                    Color.white.opacity(0.055),
                    Color.clear,
                    Color.black.opacity(0.10)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(details?.position ?? player.position ?? "Position")
                .font(.system(size: 11, weight: .black, design: .rounded))
                .tracking(1.0)
                .textCase(.uppercase)
                .foregroundStyle(Color(red: 0.23, green: 0.58, blue: 1.0))
                .padding(.bottom, 12)

            Text(details?.name ?? player.name)
                .font(.system(size: 38, weight: .black, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.98))
                .lineLimit(3)
                .minimumScaleFactor(0.68)
                .padding(.bottom, 14)

            if let team = details?.team, !team.isEmpty {
                HStack(spacing: 8) {
                    if let logo = LogoResolver.shared.image(for: team) {
                        Image(uiImage: logo)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                            .saturation(0.76)
                            .shadow(color: .black.opacity(0.28), radius: 3, y: 2)
                    }

                    Text(team)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.78))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
        }
    }

    private var heroPortrait: some View {
        ZStack(alignment: .bottom) {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.blue.opacity(0.24),
                            Color(red: 0.01, green: 0.08, blue: 0.15).opacity(0.32)
                        ],
                        center: .center,
                        startRadius: 8,
                        endRadius: 98
                    )
                )
                .frame(width: 196, height: 196)
                .overlay {
                    Circle()
                        .stroke(Color.blue.opacity(0.48), lineWidth: 1.25)
                }
                .shadow(color: Color.blue.opacity(0.14), radius: 15)
                .opacity(heroIsPresented ? 1 : 0)

            if !imageURLs.isEmpty {
                RemotePlayerPortraitImage(urls: imageURLs) { image in
                    image
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(1.12, anchor: .bottom)
                        .offset(y: 15)
                        .compositingGroup()
                        .shadow(color: Color.blue.opacity(0.26), radius: 3)
                        .shadow(color: .black.opacity(0.44), radius: 10, y: 6)
                } placeholder: {
                    heroPortraitPlaceholder
                }
                .frame(width: 176, height: 228, alignment: .bottom)
            } else {
                heroPortraitPlaceholder
            }
        }
        .frame(width: 218, height: 250, alignment: .bottom)
        .scaleEffect(heroIsPresented ? 1 : 0.96, anchor: .bottomTrailing)
        .opacity(heroIsPresented ? 1 : 0)
        .offset(x: 10, y: -4)
    }

    private var heroPortraitPlaceholder: some View {
        MatchLineupPlayerPortraitView(
            player: player,
            diameter: 112,
            borderColor: Color.blue.opacity(0.70),
            borderLineWidth: 1.5,
            glowColor: Color.blue.opacity(0.30),
            glowRadius: 8
        )
    }

    private func factStrip(_ details: PlayerDetails) -> some View {
        HStack(spacing: 0) {
            PlayerDetailsFact(title: "Age", value: ageText(from: details.born), subtitle: bornDateText(from: details.born))
            Divider().background(Color.white.opacity(0.12))
            PlayerDetailsFact(title: "Side", value: details.side ?? "Unknown", subtitle: nil)
            Divider().background(Color.white.opacity(0.12))
            PlayerDetailsFact(title: "Position", value: details.position ?? "Unknown", subtitle: nil)
        }
        .padding(.vertical, 12)
        .background(cardBackground)
    }

    @ViewBuilder
    private func aboutCard(_ details: PlayerDetails) -> some View {
        if let description = details.description?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("About \(details.name)")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)

                ForEach(description.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, id: \.self) { paragraph in
                    Text(paragraph)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(cardBackground)
        }
    }

    private func informationCard(_ details: PlayerDetails) -> some View {
        VStack(spacing: 0) {
            PlayerDetailsInfoRow(title: "Position", value: details.position ?? "Unknown")
            Divider().background(Color.white.opacity(0.12))
            PlayerDetailsInfoRow(title: "Preferred Foot", value: details.side ?? "Unknown")
            Divider().background(Color.white.opacity(0.12))
            PlayerDetailsInfoRow(title: "Birth Location", value: details.birthLocation ?? "Unknown")
        }
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }
    }

    private func loadDetails() async {
        if details == nil {
            details = fallbackDetails
        }
        errorMessage = nil
        isLoadingDetails = true
        defer { isLoadingDetails = false }

        guard let playerID = player.idPlayer else {
            errorMessage = "Some player information is temporarily unavailable."
            return
        }
        guard let baseURL = URL(string: apiBaseURL) else {
            errorMessage = "Some player information is temporarily unavailable."
            return
        }

        do {
            let client = APIClient(baseURL: baseURL)
            details = try await client.fetchPlayerDetails(playerId: playerID)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            errorMessage = "Some player information is temporarily unavailable."
        }
    }

    private var fallbackDetails: PlayerDetails {
        return PlayerDetails(
            id: player.idPlayer ?? player.id,
            name: player.name,
            team: nil,
            born: nil,
            description: nil,
            side: nil,
            position: fallbackPosition,
            birthLocation: nil,
            cutoutURL: player.cutoutURL,
            thumbURL: nil,
            renderURL: nil
        )
    }

    private var fallbackPosition: String? {
        switch player.positionCategory?.lowercased() {
        case "goalkeeper": return "Goalkeeper"
        case "defender": return "Defender"
        case "midfielder": return "Midfielder"
        case "attacker": return "Forward"
        default: return player.position ?? player.positionShort
        }
    }

    private func ageText(from born: String?) -> String {
        guard let date = playerBirthDate(from: born) else { return "Unknown" }
        let years = Calendar.current.dateComponents([.year], from: date, to: Date()).year
        return years.map(String.init) ?? "Unknown"
    }

    private func bornDateText(from born: String?) -> String? {
        guard let date = playerBirthDate(from: born) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    private func playerBirthDate(from value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}

private struct PlayerDetailsFact: View {
    let title: String
    let value: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.black))
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.55))
            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }
}

private struct PlayerDetailsInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
        }
        .padding(16)
    }
}

// MARK: - Lineup Support Types

private func formattedMatchMinute(_ rawValue: String) -> String {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "-" }
    if isOtherMatchTimelineMinute(trimmed) {
        return ""
    }
    if trimmed.contains("'") {
        return trimmed
    }
    return "\(trimmed)'"
}

private func isOtherMatchTimelineMinute(_ rawValue: String) -> Bool {
    rawValue.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-")
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

private func preferredLineupPlayer(
    matching player: MatchLineupPlayer,
    in lineup: MatchTeamLineup
) -> MatchLineupPlayer {
    preferredLineupPlayer(
        named: player.name,
        idPlayer: player.idPlayer,
        in: lineup
    ) ?? player
}

func preferredMatchEventLineupPlayer(
    named name: String,
    idPlayer: String?,
    primaryLineup: MatchTeamLineup?,
    secondaryLineup: MatchTeamLineup?
) -> MatchLineupPlayer? {
    let normalizedID = idPlayer?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let normalizedID, !normalizedID.isEmpty {
        for lineup in [primaryLineup, secondaryLineup].compactMap({ $0 }) {
            let matches = lineupPlayerCandidates(from: lineup).filter { candidate in
                candidate.idPlayer?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedID
            }
            if let portraitMatch = matches.first(where: hasLineupPortrait) {
                return portraitMatch
            }
            if let match = matches.first {
                return match
            }
        }
    }

    return preferredLineupPlayer(named: name, in: primaryLineup)
        ?? preferredLineupPlayer(named: name, in: secondaryLineup)
}

func preferredLineupPlayer(
    named name: String,
    idPlayer: String? = nil,
    in lineup: MatchTeamLineup?
) -> MatchLineupPlayer? {
    guard let lineup else { return nil }
    let candidates = lineupPlayerCandidates(from: lineup)
    let normalizedID = idPlayer?.trimmingCharacters(in: .whitespacesAndNewlines)
    let idMatches = candidates.filter { candidate in
        guard let normalizedID, !normalizedID.isEmpty else { return false }
        return candidate.idPlayer?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedID
    }

    if !idMatches.isEmpty {
        if let portraitMatch = idMatches.first(where: hasLineupPortrait) {
            return portraitMatch
        }

        let nameLookup = MatchPlayerNameLookup(name: name)
        if let portraitMatch = candidates.first(where: { candidate in
            hasLineupPortrait(candidate) &&
                nameLookup.matchScore(against: MatchPlayerNameLookup(name: candidate.name)) == 3
        }) {
            return portraitMatch
        }
        return idMatches[0]
    }

    let nameLookup = MatchPlayerNameLookup(name: name)
    let scored = candidates.map { candidate in
        (
            player: candidate,
            score: nameLookup.matchScore(against: MatchPlayerNameLookup(name: candidate.name))
        )
    }
    let matches = scored.filter { $0.score > 0 }
    guard !matches.isEmpty else { return nil }
    let portraitMatches = matches.filter { hasLineupPortrait($0.player) }
    let preferredMatches = portraitMatches.isEmpty ? matches : portraitMatches
    return preferredMatches.max { $0.score < $1.score }?.player
}

private func lineupPlayerCandidates(from lineup: MatchTeamLineup) -> [MatchLineupPlayer] {
    var players = lineup.startingLineup + lineup.substitutes
    lineup.substitutions.forEach { substitution in
        players.append(substitution.playerOff)
        players.append(substitution.playerOn)
    }
    return players
}

private func hasLineupPortrait(_ player: MatchLineupPlayer) -> Bool {
    guard let value = player.cutoutURL?.trimmingCharacters(in: .whitespacesAndNewlines) else {
        return false
    }
    return !value.isEmpty
}
