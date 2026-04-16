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

    @State private var actionAlert: MatchActionAlert?
    @State private var showCalendarPicker = false
    @State private var calendarChoices: [CalendarChoice] = []
    @State private var saveCalendarAsDefault = false
    @State private var refreshedMatch: Match?
    @State private var detailedMatch: Match?
    @State private var detailsRefreshTask: Task<Void, Never>?
    @State private var detailsErrorMessage: String?
    @State private var pendingEventsQuickRetry = false

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
                    showBroadcastDetails: false,
                    showFantasyBadge: false,
                    fantasyContext: fantasyViewModel.matchRowContext,
                    rowPreferences: matchRowPreferences
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
                        fantasyHighlightLookup: fantasyHighlightLookup,
                        fantasyPointsLookup: fantasyPointsLookup
                    )
                        .padding(.horizontal)
                }

                if shouldShowFantasySquadFallback {
                    FantasyMatchSquadSectionsView(sections: fantasySquadSections)
                        .padding(.horizontal)
                }

                if !isMatchFinished {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("TV listings")
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
            }
            .padding(.vertical, 12)
        }
        .refreshable {
            await refreshDetailsManually()
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

// MARK: - TV Channel Row

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

// MARK: - Lineup Pitch

private struct MatchLineupPitchSection: View {
    let match: Match
    let fantasyHighlightLookup: FantasySquadMembershipLookup?
    let fantasyPointsLookup: FantasySquadMembershipLookup?

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
                    fantasyHighlightLookup: fantasyHighlightLookup,
                    fantasyPointsLookup: fantasyPointsLookup
                )

                MatchLineupSubstitutesSection(
                    homeLineup: home,
                    awayLineup: away,
                    fantasyPointsLookup: fantasyPointsLookup
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
                    fantasyPointsLookup: fantasyPointsLookup,
                    side: .home
                )

                MatchLineupHalfView(
                    teamName: awayTeamName,
                    opponentTeamName: homeTeamName,
                    formation: awayLineup.formation,
                    starters: awayLineup.startingLineup,
                    lookup: awayLookup,
                    fantasyHighlightLookup: fantasyHighlightLookup,
                    fantasyPointsLookup: fantasyPointsLookup,
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

private enum MatchLineupDisplaySide {
    case home
    case away
}

private struct MatchLineupHalfView: View {
    @ObservedObject private var teamColorCatalog = TeamColorCatalog.shared
    let teamName: String
    let opponentTeamName: String
    let formation: String?
    let starters: [MatchLineupPlayer]
    let lookup: MatchLineupEventLookup
    let fantasyHighlightLookup: FantasySquadMembershipLookup?
    let fantasyPointsLookup: FantasySquadMembershipLookup?
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
                            fantasyPoints: fantasyPointsLookup?.points(for: player, teamName: teamName),
                            replacementFantasyPoints: lookup.summary(for: player).substitution.flatMap { substitution in
                                fantasyPointsLookup?.points(for: substitution.playerOn, teamName: teamName)
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
