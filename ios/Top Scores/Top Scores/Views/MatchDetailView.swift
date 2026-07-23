import Foundation
import SwiftUI
import EventKit

struct MatchDetailView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var fantasyViewModel: FantasyViewModel
    @AppStorage(AppGroupConfig.fantasyManagerEntryIDKey) private var fantasyManagerEntryID = ""

    let match: Match
    var highlightToday: Bool = false
    var showFantasyBadge: Bool = true
    var predictionDisplay: FixturePredictionDisplayState = .hidden

    @State private var actionAlert: MatchActionAlert?
    @State private var showCalendarPicker = false
    @State private var calendarChoices: [CalendarChoice] = []
    @State private var saveCalendarAsDefault = false
    @State private var refreshedMatch: Match?
    @State private var detailedMatch: Match?
    @State private var detailsRefreshTask: Task<Void, Never>?
    @State private var detailsErrorMessage: String?
    @State private var socialItems: [MatchSocialItem] = []
    @State private var pendingEventsQuickRetry = false
    @State private var screenOpenedAt: Date?
    @State private var screenViewSent = false
    @State private var showOtherCountries = false

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
        preferences.showsFantasyDataInFixtures &&
        isEligibleFantasyFixture &&
        !fantasyManagerEntryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var fantasySquadSections: [FantasyMatchTeamSquadSection] {
        guard preferences.showFantasyExpectedPoints,
              isEligibleFantasyFixture,
              let squad = fantasyViewModel.data?.applyingExpectedPoints(
                fantasyViewModel.currentSquadExpectedPointsSection
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

    private var matchRowPreferences: MatchRowPreferences {
        MatchRowPreferences(
            preferences: preferences,
            hasFantasyManagerEntry: !fantasyManagerEntryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private var tvChannelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if localChannels.isEmpty {
                Text("Not available in your region")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(localChannels, id: \.name) { channel in
                    TvChannelRow(channel: channel)
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
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                MatchDetailScoreboardHero(
                    match: activeMatch,
                    kickoffText: kickoffText
                )
                .padding(.horizontal)

                if predictionDisplay != .hidden {
                    PredictionStripView(
                        match: activeMatch,
                        predictionDisplay: predictionDisplay,
                        isLargePresentation: true
                    )
                    .padding(.horizontal)
                }

                if let penaltyDetailSummary = activeMatch.penaltyDetailSummaryText {
                    MatchPenaltyShootoutSummary(text: penaltyDetailSummary)
                        .padding(.horizontal)
                }

                // Unconditional: shown for any match status (upcoming/live/finished)
                // whenever a tracked competition table has the team(s) — the link
                // itself renders nothing when no table/team match is found, so it
                // should never be gated on shouldShowMatchActions/isMatchFinished etc.
                MatchTeamLeaguePositionsLink(
                    match: activeMatch,
                    apiBaseURL: preferences.apiBaseURL
                )
                .padding(.horizontal)

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

                if shouldShowFantasySquadFallback {
                    FantasyMatchSquadSectionsView(sections: fantasySquadSections)
                        .padding(.horizontal)
                }

                if !activeMatch.tvChannels.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Where to watch")
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
            }
            .padding(.vertical, 12)
        }
        .task(id: "\(preferences.apiBaseURL)|\(match.matchDetailsID ?? "")") {
            await loadMatchSocial()
        }
        .refreshable {
            await refreshDetailsManually()
            await loadMatchSocial()
        }
        .navigationTitle("Match Details")
        .navigationBarTitleDisplayMode(.inline)
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
            NSLog(
                "[MatchDetail][INFO] details_load_start id=%@ cached=true goals=%ld assists=%ld red_cards=%ld",
                detailsID,
                cached.homeGoalScorers.count + cached.awayGoalScorers.count,
                cached.homeAssists.count + cached.awayAssists.count,
                cached.homeRedCards.count + cached.awayRedCards.count
            )
        } else if let detailsID {
            NSLog("[MatchDetail][INFO] details_load_start id=%@ cached=false", detailsID)
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
            NSLog("Match snapshot refresh failed date=%@ error=%@", referenceMatch.date, String(describing: error))
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
            NSLog(
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
            NSLog(
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
            NSLog("[MatchDetail][WARN] social_load_failed id=%@ error=%@", detailsID, String(describing: error))
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

            // Always return cached data — the refresh loop overwrites it with fresh data in the background.
            // Log age so we can observe how stale the cache is on open.
            if let updatedAt = cached.updatedAt {
                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let timestamp = isoFormatter.date(from: updatedAt) {
                    let age = Date().timeIntervalSince(timestamp)
                    NSLog("Cached match details id=%@ age=%.1fs goals=%ld", detailsID, age,
                          cached.homeGoalScorers.count + cached.awayGoalScorers.count)
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

// MARK: - FPL Squad Sections

private struct MatchDetailScoreboardHero: View {
    let match: Match
    let kickoffText: String

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
                teamColumn(
                    name: match.displayHomeTeam,
                    fullName: match.homeTeam,
                    teamId: match.homeTeamId,
                    alternateNames: [match.homeShortName].compactMap { $0 }
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

                teamColumn(
                    name: match.displayAwayTeam,
                    fullName: match.awayTeam,
                    teamId: match.awayTeamId,
                    alternateNames: [match.awayShortName].compactMap { $0 }
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 24)
        .background(
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.13, blue: 0.22),
                        Color(red: 0.05, green: 0.09, blue: 0.16)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [Color.accentColor.opacity(0.36), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: 260
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(0.18), radius: 22, x: 0, y: 12)
    }

    private func teamColumn(name: String, fullName: String, teamId: String? = nil, alternateNames: [String]) -> some View {
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
            .frame(width: 62, height: 62)
            .padding(10)
            .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            Text(name)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
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

    /// Neutral accent for teams TSDB has no brand colour for (~80% of teams),
    /// so every card still shows a consistent home-left / away-right stripe.
    private static let neutralAccent = Color(red: 0.42, green: 0.46, blue: 0.52)

    private var entries: [MatchEventEntry] {
        Self.entries(for: match).sorted { left, right in
            if left.sortMinute != right.sortMinute {
                return left.sortMinute < right.sortMinute
            }
            return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
        }
    }

    private var timelineEntries: [MatchEventEntry] {
        entries.filter { !$0.isOtherTimelineEvent }
    }

    private var otherEntries: [MatchEventEntry] {
        entries.filter { $0.isOtherTimelineEvent }
    }

    private var homeAccentColor: Color {
        accentColor(teamId: match.homeTeamId)
    }

    private var awayAccentColor: Color {
        accentColor(teamId: match.awayTeamId)
    }

    private func accentColor(teamId: String?) -> Color {
        // The team's real TSDB brand colour (strColour1) keyed by team id, when
        // TSDB has it; otherwise a neutral accent so the stripe is consistent.
        if let teamId, let badgeColor = TeamBadgeCache.shared.accentColor(forTeamId: teamId) {
            return badgeColor
        }
        return Self.neutralAccent
    }

    var body: some View {
        if entries.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Match Events")
                    .font(.headline)
                    .foregroundStyle(.primary)

                if !timelineEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(timelineEntries) { entry in
                            eventCard(entry)
                        }
                    }
                }

                if !otherEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Other")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(otherEntries) { entry in
                            eventCard(entry)
                        }
                    }
                    .padding(.top, timelineEntries.isEmpty ? 0 : 4)
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
    private func eventCard(_ entry: MatchEventEntry) -> some View {
        let isHome = entry.side == .home
        let isGoal = entry.kind == .goal
        let accent = isHome ? homeAccentColor : awayAccentColor

        ZStack(alignment: isHome ? .leading : .trailing) {
            // Full-height accent bar; clipped to the card shape below so it
            // fills the rounded corners on its edge.
            Rectangle()
                .fill(accent)
                .frame(width: 6)

            Group {
                if entry.kind == .substitution {
                    substitutionContent(entry, isHome: isHome)
                } else {
                    standardContent(entry, isHome: isHome, isGoal: isGoal)
                }
            }
            .padding(.vertical, isGoal ? 9 : 8)
            .padding(.horizontal, 12)
            .padding(isHome ? .leading : .trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isGoal ? Color.green.opacity(0.07) : Color(.tertiarySystemBackground))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isGoal ? Color.green.opacity(0.45) : Color.primary.opacity(0.07),
                    lineWidth: isGoal ? 1.5 : 1
                )
        )
        .shadow(color: isGoal ? Color.green.opacity(0.22) : Color.clear, radius: isGoal ? 8 : 0)
    }

    @ViewBuilder
    private func standardContent(_ entry: MatchEventEntry, isHome: Bool, isGoal: Bool) -> some View {
        let displayedPlayer = entry.isOtherTimelineEvent ? nil : entry.player

        Button {
            if let player = displayedPlayer, player.idPlayer != nil {
                selectedPlayer = player
            }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                let iconSize: CGFloat = isGoal ? 34 : 24
                if isHome {
                    minuteText(entry.minute, alignment: .leading)
                    eventIcon(entry.kind)
                        .frame(width: iconSize, height: iconSize)
                    eventText(entry, alignment: .leading, textAlignment: .leading)
                    Spacer(minLength: 8)
                    eventPortrait(displayedPlayer, kind: entry.kind)
                } else {
                    eventPortrait(displayedPlayer, kind: entry.kind)
                    Spacer(minLength: 8)
                    eventText(entry, alignment: .trailing, textAlignment: .trailing)
                    eventIcon(entry.kind)
                        .frame(width: iconSize, height: iconSize)
                    minuteText(entry.minute, alignment: .trailing)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(displayedPlayer?.idPlayer != nil)
    }

    @ViewBuilder
    private func substitutionContent(_ entry: MatchEventEntry, isHome: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if isHome {
                minuteText(entry.minute, alignment: .leading)
                VStack(spacing: 7) {
                    subLine(player: entry.playerOff, name: entry.playerOffName ?? "", isOut: true, isHome: isHome)
                    subLine(player: entry.player, name: entry.playerOnName ?? "", isOut: false, isHome: isHome)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 7) {
                    subLine(player: entry.playerOff, name: entry.playerOffName ?? "", isOut: true, isHome: isHome)
                    subLine(player: entry.player, name: entry.playerOnName ?? "", isOut: false, isHome: isHome)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                minuteText(entry.minute, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func subLine(player: MatchLineupPlayer?, name: String, isOut: Bool, isHome: Bool) -> some View {
        Button {
            if let player, player.idPlayer != nil {
                selectedPlayer = player
            }
        } label: {
            HStack(spacing: 8) {
                if isHome {
                    subPill(isOut: isOut)
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 6)
                    hiddenSubPhotoPlaceholder()
                } else {
                    hiddenSubPhotoPlaceholder()
                    Spacer(minLength: 6)
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.trailing)
                    subPill(isOut: isOut)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(player?.idPlayer != nil)
    }

    private func hiddenSubPhotoPlaceholder() -> some View {
        Color.clear
            .frame(width: 34, height: 34)
    }

    private func subPill(isOut: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: isOut ? "arrow.down" : "arrow.up")
                .font(.system(size: 9, weight: .black))
            Text(isOut ? "OUT" : "IN")
                .font(.system(size: 10, weight: .heavy))
                .frame(width: 26, alignment: .leading)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(isOut ? Color.red : Color(red: 0.13, green: 0.7, blue: 0.32))
        )
    }

    private func minuteText(_ minute: String, alignment: Alignment = .trailing) -> some View {
        Text(minute)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: 38, alignment: alignment)
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
    private func eventPortrait(_ player: MatchLineupPlayer?, kind: MatchEventEntry.Kind) -> some View {
        if let player {
            MatchLineupPlayerPortraitView(
                player: player,
                borderColor: portraitBorderColor(for: kind),
                borderLineWidth: portraitBorderLineWidth(for: kind),
                glowColor: portraitGlowColor(for: kind),
                glowRadius: portraitGlowRadius(for: kind)
            )
        } else {
            Color.clear
                .frame(width: MatchLineupPlayerPortraitView.size, height: MatchLineupPlayerPortraitView.size)
        }
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
            let player = playerForEvent(named: scorer.player, side: side, match: match)
            for minute in scorer.goalTimes {
                output.append(
                    MatchEventEntry(
                        minute: formattedMatchMinute(minute),
                        sortMinute: sortMinute(minute),
                        kind: .goal,
                        side: side,
                        title: scorer.player,
                        subtitle: assistLookup[normalizedMinute(minute)].map { "Assist: \($0)" } ?? teamName,
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
                        player: player
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
            let player = playerForEvent(named: card.player, side: side, match: match)
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
            let player = playerForEvent(named: card.player, side: side, match: match)
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
                player = playerForEvent(named: name, side: side, match: match)
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
            let player = MatchLineupPlayer(
                number: sub.playerOn.number,
                name: sub.playerOn.name,
                idPlayer: sub.playerOn.idPlayer,
                positionCategory: nil,
                cutoutURL: sub.playerOn.cutoutURL,
                formationRowIndex: nil,
                formationSlotIndex: nil,
                formationRowSize: nil
            )
            let playerOff = MatchLineupPlayer(
                number: sub.playerOff.number,
                name: sub.playerOff.name,
                idPlayer: sub.playerOff.idPlayer,
                positionCategory: nil,
                cutoutURL: sub.playerOff.cutoutURL,
                formationRowIndex: nil,
                formationSlotIndex: nil,
                formationRowSize: nil
            )
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

    private static func playerForEvent(named name: String, side: MatchEventEntry.Side, match: Match) -> MatchLineupPlayer? {
        let lineup = side == .home ? match.teamLineups?.home : match.teamLineups?.away
        let candidates = eventPlayerCandidates(from: lineup)
        let lookup = MatchPlayerNameLookup(name: name)
        return candidates.max { lhs, rhs in
            lookup.matchScore(against: MatchPlayerNameLookup(name: lhs.name)) <
                lookup.matchScore(against: MatchPlayerNameLookup(name: rhs.name))
        }.flatMap { player in
            lookup.matchScore(against: MatchPlayerNameLookup(name: player.name)) > 0 ? player : nil
        }
    }

    private static func eventPlayerCandidates(from lineup: MatchTeamLineup?) -> [MatchLineupPlayer] {
        guard let lineup else { return [] }
        var players = lineup.startingLineup + lineup.substitutes
        lineup.substitutions.forEach { substitution in
            players.append(substitution.playerOff)
            players.append(substitution.playerOn)
        }
        return players
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

    var isOtherTimelineEvent: Bool {
        sortMinute == Self.otherTimelineSortMinute && minute.isEmpty
    }

    var id: String {
        "\(sortMinute)|\(minute)|\(title)|\(subtitle ?? "")|\(kind)|\(side)"
    }
}

private struct FantasyMatchSquadSectionsView: View {
    let sections: [FantasyMatchTeamSquadSection]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text("FPL involvement")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                FantasyMatchParticipationBadge()
            }

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
            Text("Social media")
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(spacing: 8) {
                ForEach(items) { item in
                    if let url = URL(string: item.url) {
                        Link(destination: url) {
                            MatchSocialRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct MatchSocialRow: View {
    let item: MatchSocialItem

    var body: some View {
        HStack(spacing: 12) {
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
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var sourceText: String? {
        item.account?.name ?? item.account?.handle
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
        .frame(width: 92, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - TV Channel Row

private struct TvChannelRow: View {
    let channel: TvChannel

    var body: some View {
        HStack(spacing: 8) {
            if let logoURL = channel.logo.flatMap(URL.init) {
                AsyncImage(url: logoURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    if let asset = TvLogoResolver.shared.image(for: channel.name) {
                        Image(uiImage: asset).resizable().scaledToFit()
                    }
                }
                .frame(height: 16)
            } else if let image = TvLogoResolver.shared.image(for: channel.name) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 16)
            }

            Text(channel.name)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
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

                MatchLineupPitchView(
                    homeLineup: home,
                    awayLineup: away,
                    fallbackHomeTeamName: match.displayHomeTeam,
                    fallbackAwayTeamName: match.displayAwayTeam,
                    homeGoals: match.homeGoalScorers,
                    awayGoals: match.awayGoalScorers,
                    homeAssists: match.homeAssists,
                    awayAssists: match.awayAssists,
                    homeYellowCards: match.homeYellowCards,
                    awayYellowCards: match.awayYellowCards,
                    homeRedCards: match.homeRedCards,
                    awayRedCards: match.awayRedCards,
                    fantasyHighlightLookup: fantasyHighlightLookup,
                    fantasyPointsLookup: fantasyPointsLookup
                )
            }
        }
    }
}

private struct MatchLineupPitchView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @State private var selectedPlayer: MatchLineupPlayer?

    let homeLineup: MatchTeamLineup
    let awayLineup: MatchTeamLineup
    let fallbackHomeTeamName: String
    let fallbackAwayTeamName: String
    let homeGoals: [MatchGoalScorer]
    let awayGoals: [MatchGoalScorer]
    let homeAssists: [MatchAssistProvider]
    let awayAssists: [MatchAssistProvider]
    let homeYellowCards: [MatchYellowCardEvent]
    let awayYellowCards: [MatchYellowCardEvent]
    let homeRedCards: [MatchRedCardEvent]
    let awayRedCards: [MatchRedCardEvent]
    let fantasyHighlightLookup: FantasySquadMembershipLookup?
    let fantasyPointsLookup: FantasySquadMembershipLookup?

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
        homeLineup.team ?? fallbackHomeTeamName
    }

    private var awayTeamName: String {
        awayLineup.team ?? fallbackAwayTeamName
    }

    var body: some View {
        ZStack {
            MatchLineupPitchBackground()

            VStack(spacing: 0) {
                MatchLineupHalfView(
                    teamName: homeTeamName,
                    starters: homeLineup.startingLineup,
                    lookup: homeLookup,
                    side: .home,
                    onSelectPlayer: { selectedPlayer = $0 }
                )

                MatchLineupHalfView(
                    teamName: awayTeamName,
                    starters: awayLineup.startingLineup,
                    lookup: awayLookup,
                    side: .away,
                    onSelectPlayer: { selectedPlayer = $0 }
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        }
        .aspectRatio(0.62, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
        .sheet(item: $selectedPlayer) { player in
            PlayerDetailsSheet(player: player, apiBaseURL: preferences.apiBaseURL)
        }
    }
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

private struct MatchLineupHalfView: View {
    let teamName: String
    let starters: [MatchLineupPlayer]
    let lookup: MatchLineupEventLookup
    let side: MatchLineupDisplaySide
    let onSelectPlayer: (MatchLineupPlayer) -> Void

    private var groupedRows: [[MatchLineupPlayer]] {
        let rows = [
            lineupRow(.goalkeeper),
            lineupRow(.defender),
            lineupRow(.midfielder),
            lineupRow(.forward)
        ]
        if side == .home {
            return rows
        }
        return rows.reversed()
    }

    private var titleText: String {
        return teamName.uppercased()
    }

    private var titleAlignment: Alignment {
        side == .home ? .topLeading : .bottomTrailing
    }

    private func lineupRow(_ role: MatchLineupRole) -> [MatchLineupPlayer] {
        starters
            .filter { lineupRole(for: $0) == role }
            .sorted { left, right in
                if let leftSlot = left.formationSlotIndex,
                   let rightSlot = right.formationSlotIndex,
                   leftSlot != rightSlot {
                    return leftSlot < rightSlot
                }
                let leftScore = horizontalScore(for: left)
                let rightScore = horizontalScore(for: right)
                if leftScore != rightScore {
                    return leftScore < rightScore
                }
                return left.number < right.number
            }
    }

    var body: some View {
        ZStack(alignment: titleAlignment) {
            VStack(alignment: .center, spacing: 0) {
                ForEach(Array(groupedRows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(row) { player in
                            MatchLineupPlayerMarkerView(
                                player: player,
                                summary: lookup.summary(for: player),
                                replacementSummary: lookup.replacementSummary(for: player),
                                onSelectPlayer: onSelectPlayer
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .padding(.top, side == .home ? 14 : 0)
            .padding(.bottom, side == .away ? 14 : 0)

            titleView
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
            .frame(maxWidth: .infinity, alignment: side == .home ? .leading : .trailing)
    }
}

private struct MatchLineupPlayerPortraitView: View {
    static let size: CGFloat = 54

    let player: MatchLineupPlayer
    var diameter: CGFloat = MatchLineupPlayerPortraitView.size
    var borderColor: Color = Color.white.opacity(0.82)
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
                .fill(Color.black.opacity(0.28))

            if !portraitURLCandidates.isEmpty {
                MatchLineupRemotePortrait(urls: portraitURLCandidates, fallback: initialsView)
            } else {
                initialsView
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(borderColor, lineWidth: borderLineWidth)
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

    @State private var imageIndex = 0

    var body: some View {
        if let url = urls[safe: imageIndex] {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(1.42)
                        .offset(y: 7)
                case .failure:
                    fallback
                        .task(id: url) {
                            imageIndex += 1
                        }
                default:
                    fallback
                }
            }
        } else {
            fallback
        }
    }
}

private func lineupPortraitURLCandidates(for value: String) -> [URL] {
    var candidates: [String] = [value]

    if let url = URL(string: value),
       let host = url.host?.lowercased(),
       host == "www.thesportsdb.com" || host == "r2.thesportsdb.com" {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = host == "www.thesportsdb.com" ? "r2.thesportsdb.com" : "www.thesportsdb.com"
        if let fallback = components?.url?.absoluteString {
            candidates.append(fallback)
        }
    }

    var seen = Set<String>()
    return candidates.compactMap { candidate in
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
            return nil
        }
        return URL(string: trimmed)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private struct MatchLineupPlayerMarkerView: View {
    let player: MatchLineupPlayer
    let summary: MatchLineupPlayerEventSummary
    let replacementSummary: MatchLineupPlayerEventSummary?
    let onSelectPlayer: (MatchLineupPlayer) -> Void

    private var replacementPlayer: MatchLineupPlayer? {
        summary.substitution?.playerOn
    }

    private var displayName: String {
        player.name
    }

    var body: some View {
        Button {
            if player.idPlayer != nil {
                onSelectPlayer(player)
            }
        } label: {
            VStack(spacing: 4) {
                MatchLineupPlayerPortraitView(player: player)

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
        .buttonStyle(.plain)
        .allowsHitTesting(player.idPlayer != nil)
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
            let substitution = lineup.substitutions.first { $0.playerOn.number == substitute.number }
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

private struct PlayerDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let player: MatchLineupPlayer
    let apiBaseURL: String

    @State private var details: PlayerDetails?
    @State private var errorMessage: String?

    private var imageURL: URL? {
        let candidates: [String?] = [
            details?.renderURL,
            details?.cutoutURL,
            details?.thumbURL,
            player.cutoutURL
        ]

        for candidate in candidates {
            guard let value = candidate?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  let url = URL(string: value)
            else {
                continue
            }

            return url
        }

        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    hero

                    if details == nil && errorMessage == nil {
                        ProgressView("Loading player details")
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
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
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.05, green: 0.21, blue: 0.36),
                            Color(red: 0.02, green: 0.10, blue: 0.18)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(details?.position ?? player.position ?? "Position")
                        .font(.caption.weight(.black))
                        .textCase(.uppercase)
                        .foregroundStyle(Color.blue)

                    Text(details?.name ?? player.name)
                        .font(.system(size: 38, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.72)

                    if let team = details?.team, !team.isEmpty {
                        Text(team)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let imageURL {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .scaledToFit()
                        default:
                            MatchLineupPlayerPortraitView(player: player)
                        }
                    }
                    .frame(width: 150, height: 190, alignment: .bottom)
                } else {
                    MatchLineupPlayerPortraitView(player: player)
                        .frame(width: 150, height: 190, alignment: .bottom)
                }
            }
            .padding(18)
        }
        .frame(minHeight: 230)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
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
        guard let playerID = player.idPlayer else {
            errorMessage = "Player details unavailable."
            return
        }
        guard let baseURL = URL(string: apiBaseURL) else {
            errorMessage = "Player details unavailable."
            return
        }

        do {
            let client = APIClient(baseURL: baseURL)
            details = try await client.fetchPlayerDetails(playerId: playerID)
            errorMessage = nil
        } catch {
            errorMessage = "Player details unavailable."
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
            substitution: substitution(for: player)
        )
    }

    func replacementSummary(for player: MatchLineupPlayer) -> MatchLineupPlayerEventSummary? {
        guard let substitution = substitution(for: player) else {
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

    private func substitution(for player: MatchLineupPlayer) -> MatchLineupSubstitution? {
        let playerLookup = MatchPlayerNameLookup(name: player.name)
        if let nameMatch = substitutions.first(where: {
            playerLookup.matchScore(against: MatchPlayerNameLookup(name: $0.playerOff.name)) > 88
        }) {
            return nameMatch
        }

        let numberMatches = substitutions.filter { $0.playerOff.number == player.number }
        return numberMatches.count == 1 ? numberMatches[0] : nil
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
