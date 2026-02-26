import Foundation
import SwiftUI
import EventKit

struct MatchRow: View {
    let match: Match
    var highlightToday: Bool = false
    var showTeamEvents: Bool = false
    var showLeague: Bool = false

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
                    TeamLogo(name: match.homeTeam)

                    HStack(alignment: .center, spacing: 8) {
                        Text(match.homeTeam)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .layoutPriority(1)

                        scoreAndStatusRow

                        Text(match.awayTeam)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
                    }
                    .frame(maxWidth: .infinity)

                    TeamLogo(name: match.awayTeam)
                }
                .frame(maxWidth: .infinity)

                if let aggregateSummaryText = match.aggregateSummaryText {
                    Text("(\(aggregateSummaryText))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                if let penaltyResult = match.penaltyResult {
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
            }

            if !isMatchFinished {
                HStack(alignment: .center, spacing: 8) {
                    Text(match.tvChannels.isEmpty ? "TV TBA" : match.tvChannels.joined(separator: " • "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)

                    Spacer(minLength: 8)

                    TvLogoRow(channels: match.tvChannels)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
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

    private var scoreAndStatusRow: some View {
        HStack(spacing: 8) {
            if let homeScoreText {
                Text(homeScoreText)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .frame(minWidth: 14, alignment: .trailing)
            }

            MatchTimeStatusView(
                text: centerStatusText,
                isLive: match.isInProgress
            )
            .fixedSize(horizontal: true, vertical: false)

            if let awayScoreText {
                Text(awayScoreText)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .frame(minWidth: 14, alignment: .leading)
            }
        }
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

struct MatchDetailView: View {
    @EnvironmentObject private var preferences: PreferencesStore

    let match: Match
    var highlightToday: Bool = false

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
        guard let status = activeMatch.scoreStatus?.uppercased() else { return false }
        return status == "FT" || status == "AET"
    }

    private var sortedChannels: [String] {
        activeMatch.tvChannels.sorted { lhs, rhs in
            lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
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

                MatchRow(match: activeMatch, highlightToday: highlightToday, showTeamEvents: true)
                    .padding(.horizontal)

                if let detailsErrorMessage {
                    Text(detailsErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
            reportMissingTeamLogosIfNeeded(for: activeMatch)
        }
        .onDisappear {
            detailsRefreshTask?.cancel()
            detailsRefreshTask = nil
        }
        .onChange(of: preferences.apiBaseURL) { _, _ in
            startDetailsRefresh()
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
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(entry.event.homePlayerAssistText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                Text(entry.event.awayPlayerAssistText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(entry.event.displayMinute)
                    .font(.caption2)
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
            }
        }
        .font(.caption2)
        .frame(width: 16, height: 16, alignment: .center)
    }
}

private enum MatchEventKind {
    case goal
    case ownGoal
    case redCard
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

    @State private var isPulsing = false

    var body: some View {
        Text(text)
            .font(.caption)
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
        .frame(width: 22, height: 22)
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
        .padding()
}
