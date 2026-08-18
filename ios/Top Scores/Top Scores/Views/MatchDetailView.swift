import Foundation
import SwiftUI
import EventKit

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
              let squad = fantasyViewModel.data
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
                    predictionDisplay: predictionDisplay
                )
                .padding(.horizontal)

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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerRelativeFrame(.horizontal)
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
    let predictionDisplay: FixturePredictionDisplayState
    @State private var artworkSelectionSeed: UInt32

    init(
        match: Match,
        kickoffText: String,
        predictionDisplay: FixturePredictionDisplayState
    ) {
        self.match = match
        self.kickoffText = kickoffText
        self.predictionDisplay = predictionDisplay
        _artworkSelectionSeed = State(initialValue: UInt32.random(in: .min ... .max))
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
                    goalSummaries: homeGoalSummaries
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
                    goalSummaries: awayGoalSummaries
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
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 24)
        .background(
            ZStack {
                Image(
                    MatchStadiumArtworkResolver.shared.assetName(
                        for: match,
                        selectionSeed: artworkSelectionSeed
                    )
                )
                    .resizable()
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
        goalSummaries: [MatchScoreboardGoalSummary]
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
                alternateNames: alternateNames
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(teamAccessibilityLabel(fullName: fullName, goalSummaries: goalSummaries))
        .accessibilityHint("View team details")
    }

    private func teamColumn(
        name: String,
        fullName: String,
        teamId: String? = nil,
        alternateNames: [String]
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

        }
        .frame(maxWidth: .infinity)
    }

    private func goalSummaryColumn(
        _ summaries: [MatchScoreboardGoalSummary],
        isTrailing: Bool
    ) -> some View {
        let alignment: HorizontalAlignment = isTrailing ? .trailing : .leading
        return VStack(alignment: alignment, spacing: 9) {
            ForEach(summaries) { summary in
                VStack(alignment: alignment, spacing: 2) {
                    HStack(spacing: 5) {
                        if isTrailing { Spacer(minLength: 0) }
                        Image(systemName: "soccerball")
                            .font(.caption2)
                        Text(summary.scorer)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(summary.minute)
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white.opacity(0.72))
                        if !isTrailing { Spacer(minLength: 0) }
                    }

                    if let assister = summary.assister {
                        Text("Assist: \(assister)")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(1)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: isTrailing ? .trailing : .leading)
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
        goalSummaries: [MatchScoreboardGoalSummary]
    ) -> String {
        guard !goalSummaries.isEmpty else { return fullName }
        return "\(fullName). Goals: \(goalSummaries.map(\.accessibilityText).joined(separator: ", "))"
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
            let player = playerForEvent(named: scorer.player, side: side, match: match)
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
                        player: player
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
    let player: FantasyDisplayPlayer

    private var name: String {
        let preferred = player.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        return preferred.isEmpty ? player.displayName : preferred
    }

    private var expectedPoints: Double? {
        player.expectedPointsThisGameweek
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            FantasyPlayerProfileImage(url: player.profileImageURL, size: 28)
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
            return String(format: "xP %.1f", expectedPoints)
        }
        return "xP -"
    }

    private var expectedPointsAccessibilityLabel: String {
        if let expectedPoints {
            return String(format: "expected %.1f points", expectedPoints)
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
                            .scaledToFill()

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
                                accentColor: teamAccentColor(teamID: homeTeamID, side: .home),
                                onSelectPlayer: { selectedPlayer = $0 }
                            )

                            MatchLineupCombinedFormationHalf(
                                lineup: awayLineup,
                                side: .away,
                                lookup: awayLookup,
                                accentColor: teamAccentColor(teamID: awayTeamID, side: .away),
                                onSelectPlayer: { selectedPlayer = $0 }
                            )
                        }
                        .padding(.horizontal, 5)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                }
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
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
                        accentColor: teamAccentColor(teamID: homeTeamID, side: .home)
                    )
                }

                if !awayLineup.substitutions.isEmpty {
                    substitutes(
                        lineup: awayLineup,
                        teamName: awayTeamName,
                        lookup: awayLookup,
                        accentColor: teamAccentColor(teamID: awayTeamID, side: .away)
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

    private func teamAccentColor(teamID: String?, side: MatchLineupDisplaySide) -> Color {
        if let teamID, let color = TeamBadgeCache.shared.accentColor(forTeamId: teamID) {
            return color
        }
        return side == .home ? Color.yellow : Color.red
    }

    private func teamHeader(
        lineup: MatchTeamLineup,
        teamName: String,
        teamID: String?,
        side: MatchLineupDisplaySide
    ) -> some View {
        let accentColor = teamAccentColor(teamID: teamID, side: side)
        return HStack(spacing: 10) {
            Group {
                if let logo = LogoResolver.shared.image(for: teamName, teamId: teamID) {
                    Image(uiImage: logo).resizable().scaledToFit()
                } else {
                    Image(systemName: "shield.fill").foregroundStyle(accentColor)
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
        accentColor: Color
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
                    Button {
                        if substitution.playerOn.idPlayer != nil {
                            selectedPlayer = substitution.playerOn
                        }
                    } label: {
                        VStack(spacing: 5) {
                            MatchLineupPlayerPortraitView(
                                player: substitution.playerOn,
                                diameter: 40,
                                borderColor: accentColor
                            )

                            Text(condensedLineupPlayerName(substitution.playerOn.name))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)

                            HStack(spacing: 2) {
                                MatchLineupInlineMarker(kind: .subIn, minute: substitution.minute)
                                ForEach(lookup.markers(for: substitution.playerOn).prefix(2)) { marker in
                                    MatchLineupInlineMarker(kind: marker.kind, minute: marker.minute)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .allowsHitTesting(substitution.playerOn.idPlayer != nil)
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
    let accentColor: Color
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

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    let columnWidth = proxy.size.width / CGFloat(max(row.count, 1))
                    HStack(alignment: .center, spacing: 0) {
                        ForEach(row) { player in
                            MatchLineupPlayerTacticalMarker(
                                player: player,
                                markers: lookup.markers(for: player),
                                accentColor: accentColor,
                                onSelectPlayer: onSelectPlayer
                            )
                            .frame(width: columnWidth)
                        }
                    }
                    .frame(width: proxy.size.width)
                    .position(
                        x: proxy.size.width / 2,
                        y: rowPosition(
                            index: index,
                            count: rows.count,
                            height: proxy.size.height
                        )
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rowPosition(index: Int, count: Int, height: CGFloat) -> CGFloat {
        let safeInset = min(32, height * 0.11)
        guard count > 1 else { return height / 2 }
        let availableHeight = max(0, height - (safeInset * 2))
        let progress: CGFloat
        if count == 5 {
            // A 4-2-3-1 has consecutive central players in its final two lines.
            // Reserve more room between those lines without pushing either team
            // across halfway or beyond its own goal line.
            let homeProgress: [CGFloat] = [0, 0.21, 0.45, 0.68, 1]
            let awayProgress: [CGFloat] = [0, 0.32, 0.55, 0.79, 1]
            progress = (side == .home ? homeProgress : awayProgress)[index]
        } else {
            progress = CGFloat(index) / CGFloat(count - 1)
        }
        return safeInset + (availableHeight * progress)
    }
}

private struct MatchLineupPlayerTacticalMarker: View {
    let player: MatchLineupPlayer
    let markers: [MatchLineupMarker]
    let accentColor: Color
    let onSelectPlayer: (MatchLineupPlayer) -> Void

    var body: some View {
        Button {
            if player.idPlayer != nil { onSelectPlayer(player) }
        } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .bottom) {
                    ZStack(alignment: .topLeading) {
                        MatchLineupPlayerPortraitView(
                            player: player,
                            diameter: 40,
                            borderColor: accentColor,
                            borderLineWidth: 2
                        )

                        if let number = player.number {
                            Text("\(number)")
                                .font(.system(size: 9.5, weight: .black, design: .rounded))
                                .foregroundStyle(.black)
                                .frame(width: 18, height: 18)
                                .background(accentColor, in: Circle())
                                .overlay(Circle().stroke(Color.black.opacity(0.30), lineWidth: 1))
                                .offset(x: -4, y: -2)
                        }
                    }

                    Text(condensedLineupPlayerName(player.name))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                if !markers.isEmpty {
                    HStack(spacing: 2) {
                        ForEach(markers.prefix(3)) { marker in
                            MatchLineupInlineMarker(kind: marker.kind, minute: marker.minute)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(player.idPlayer != nil)
        .accessibilityElement(children: .combine)
    }
}

private struct MatchLineupInlineMarker: View {
    let kind: MatchLineupMarker.Kind
    let minute: String

    var body: some View {
        HStack(spacing: 3) {
            markerIcon
            if !minute.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(formattedMatchMinute(minute))
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    @ViewBuilder
    private var markerIcon: some View {
        switch kind {
        case .goal:
            Image(systemName: "soccerball")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
        case .assist:
            Text("A")
                .font(.system(size: 7, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 11, height: 11)
                .background(Color.blue, in: Circle())
        case .yellowCard:
            RoundedRectangle(cornerRadius: 1).fill(Color.yellow).frame(width: 7, height: 10)
        case .redCard:
            RoundedRectangle(cornerRadius: 1).fill(Color.red).frame(width: 7, height: 10)
        case .subIn:
            Image(systemName: "arrow.up")
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(.green)
        case .subOut:
            Image(systemName: "arrow.down")
                .font(.system(size: 8, weight: .black))
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
        self.goals = goals.map { MatchNamedMinutes(name: $0.player, minutes: $0.goalTimes) }
        self.assists = assists.map { MatchNamedMinutes(name: $0.player, minutes: $0.assistTimes) }
        self.yellowCards = yellowCards.map { MatchNamedMinutes(name: $0.player, minutes: $0.yellowCardTimes) }
        self.redCards = redCards.map { MatchNamedMinutes(name: $0.player, minutes: $0.redCardTimes) }
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
        let playerLookup = MatchPlayerNameLookup(name: player.name)
        let best = entries.max { left, right in
            playerLookup.matchScore(against: left.lookup) < playerLookup.matchScore(against: right.lookup)
        }
        guard let best, playerLookup.matchScore(against: best.lookup) > 0 else { return [] }
        return best.minutes
    }

    private func substitution(for player: MatchLineupPlayer) -> MatchLineupSubstitution? {
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
    let lookup: MatchPlayerNameLookup
    let minutes: [String]

    init(name: String, minutes: [String]) {
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

    let player: MatchLineupPlayer
    let apiBaseURL: String

    @State private var details: PlayerDetails?
    @State private var errorMessage: String?
    @State private var isLoadingDetails = false

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
