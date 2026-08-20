//
//  ContentView.swift
//  Top Scores Watch Watch App
//
//  Created by Mike Wagstaff on 12/02/2026.
//

import Foundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var matchesStore: WatchMatchesStore

    private let refreshFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        NavigationStack {
            Group {
                if !matchesStore.hasData {
                    VStack(spacing: 8) {
                        Image(systemName: "sportscourt")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("Waiting for phone data")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    List {
                        if todaySections.isEmpty {
                            Section {
                                VStack(spacing: 8) {
                                    Image(systemName: "calendar.badge.exclamationmark")
                                        .font(.title3)
                                        .foregroundStyle(.secondary)
                                    Text("No matches")
                                        .font(.caption)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        } else {
                            ForEach(todaySections) { section in
                                Section(section.title) {
                                    ForEach(section.matches) { match in
                                        NavigationLink {
                                            WatchMatchDetailView(match: match)
                                        } label: {
                                            WatchMatchLozenge(match: match)
                                        }
                                        .buttonStyle(.plain)
                                        .listRowBackground(Color.clear)
                                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                                    }
                                }
                            }
                        }

                        Section {
                            NavigationLink {
                                WatchFixturesView(days: fixtureDays)
                            } label: {
                                Label("Fixtures", systemImage: "calendar")
                            }

                            NavigationLink {
                                WatchResultsView(days: resultDays)
                            } label: {
                                Label("Results", systemImage: "clock.arrow.circlepath")
                            }
                        }

                        if let lastUpdated = matchesStore.lastUpdated {
                            Section {
                                Text("Updated \(refreshFormatter.string(from: lastUpdated))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Top Scores")
        }
        .onAppear {
            matchesStore.startAutomaticRefresh()
        }
    }

    private var todaySections: [WatchFixtureSection] {
        WatchMatchCollections.todaySections(from: sourceMatches)
    }

    private var resultDays: [WatchMatchDay] {
        WatchMatchCollections.resultDays(from: sourceMatches)
    }

    private var fixtureDays: [WatchMatchDay] {
        WatchMatchCollections.fixtureDays(from: sourceMatches)
    }

    private var sourceMatches: [WatchMatch] {
        matchesStore.groupedDays.flatMap(\.matches)
    }
}

private enum WatchMatchCollections {
    static func todaySections(from matches: [WatchMatch]) -> [WatchFixtureSection] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let live = matches
            .filter { match in
                guard isSameDay(match, as: today, calendar: calendar) else { return false }
                return match.isInProgress
            }
            .sorted(by: ascendingMatchDate)

        let upcoming = matches
            .filter { match in
                guard isSameDay(match, as: today, calendar: calendar) else { return false }
                guard let date = match.dateTime ?? WatchMatchDateParser.shared.parse(date: match.date, time: "00:00") else {
                    return false
                }
                return date >= Date() && !match.isInProgress && !isFinished(match)
            }
            .sorted(by: ascendingMatchDate)

        let playedToday = matches
            .filter { match in
                isSameDay(match, as: today, calendar: calendar) && isFinished(match)
            }
            .sorted(by: ascendingMatchDate)

        return [
            WatchFixtureSection(id: "live", title: "Live", matches: live),
            WatchFixtureSection(id: "upcoming", title: "Upcoming", matches: upcoming),
            WatchFixtureSection(id: "playedToday", title: "Played Today", matches: playedToday)
        ].filter { !$0.matches.isEmpty }
    }

    static func fixtureDays(from matches: [WatchMatch]) -> [WatchMatchDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 7, to: today) ?? today
        let fixtures = matches
            .filter { match in
                guard let matchDate = day(for: match, calendar: calendar) else { return false }
                return matchDate >= start && matchDate <= end && !match.isInProgress && !isFinished(match)
            }
            .sorted(by: ascendingMatchDate)

        return groupedDays(fixtures, descending: false)
    }

    static func resultDays(from matches: [WatchMatch]) -> [WatchMatchDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let results = matches
            .filter { match in
                guard let matchDate = day(for: match, calendar: calendar) else { return false }
                return matchDate >= start && matchDate <= today && isFinished(match)
            }
            .sorted(by: descendingMatchDate)

        return groupedDays(results, descending: true)
    }

    static func isFinished(_ match: WatchMatch) -> Bool {
        guard let status = match.scoreStatus else { return false }
        let normalized = status
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: ".", with: "")
        return normalized.hasPrefix("FT") || normalized.hasPrefix("AET") || normalized == "PENS"
    }

    private static func groupedDays(_ matches: [WatchMatch], descending: Bool) -> [WatchMatchDay] {
        let byDate = Dictionary(grouping: matches) { $0.date }
        let keys = byDate.keys.sorted { lhs, rhs in
            descending ? lhs > rhs : lhs < rhs
        }

        return keys.compactMap { key in
            guard let dateMatches = byDate[key] else { return nil }
            let sortedMatches = descending
                ? dateMatches.sorted(by: descendingMatchDate)
                : dateMatches.sorted(by: ascendingMatchDate)
            let displayDate: String
            if let parsed = WatchMatchDateParser.shared.parse(date: key, time: "00:00") {
                displayDate = WatchMatchDateParser.shared.displayDateWithRelative(parsed)
            } else {
                displayDate = key
            }
            return WatchMatchDay(id: key, displayDate: displayDate, matches: sortedMatches)
        }
    }

    private static func isSameDay(_ match: WatchMatch, as day: Date, calendar: Calendar) -> Bool {
        guard let matchDay = self.day(for: match, calendar: calendar) else { return false }
        return matchDay == day
    }

    private static func day(for match: WatchMatch, calendar: Calendar) -> Date? {
        guard let date = WatchMatchDateParser.shared.parse(date: match.date, time: "00:00") else {
            return nil
        }
        return calendar.startOfDay(for: date)
    }

    private static func ascendingMatchDate(_ lhs: WatchMatch, _ rhs: WatchMatch) -> Bool {
        let leftDate = lhs.dateTime ?? WatchMatchDateParser.shared.parse(date: lhs.date, time: "00:00") ?? .distantFuture
        let rightDate = rhs.dateTime ?? WatchMatchDateParser.shared.parse(date: rhs.date, time: "00:00") ?? .distantFuture
        if leftDate != rightDate {
            return leftDate < rightDate
        }
        if lhs.competitionWeight != rhs.competitionWeight {
            return (lhs.competitionWeight ?? 0) > (rhs.competitionWeight ?? 0)
        }
        return lhs.id < rhs.id
    }

    private static func descendingMatchDate(_ lhs: WatchMatch, _ rhs: WatchMatch) -> Bool {
        let leftDate = lhs.dateTime ?? WatchMatchDateParser.shared.parse(date: lhs.date, time: "00:00") ?? .distantPast
        let rightDate = rhs.dateTime ?? WatchMatchDateParser.shared.parse(date: rhs.date, time: "00:00") ?? .distantPast
        if leftDate != rightDate {
            return leftDate > rightDate
        }
        if lhs.competitionWeight != rhs.competitionWeight {
            return (lhs.competitionWeight ?? 0) > (rhs.competitionWeight ?? 0)
        }
        return lhs.id < rhs.id
    }
}

private struct WatchFixtureSection: Identifiable {
    let id: String
    let title: String
    let matches: [WatchMatch]
}

private struct WatchFixturesView: View {
    let days: [WatchMatchDay]

    var body: some View {
        List {
            if days.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "calendar.badge.exclamationmark")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("No fixtures")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                ForEach(days) { day in
                    Section(day.displayDate) {
                        ForEach(day.matches) { match in
                            NavigationLink {
                                WatchMatchDetailView(match: match)
                            } label: {
                                WatchMatchLozenge(match: match)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Fixtures")
    }
}

private struct WatchResultsView: View {
    let days: [WatchMatchDay]

    var body: some View {
        List {
            if days.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "calendar.badge.exclamationmark")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("No results")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                ForEach(days) { day in
                    Section(day.displayDate) {
                        ForEach(day.matches) { match in
                            NavigationLink {
                                WatchMatchDetailView(match: match)
                            } label: {
                                WatchMatchLozenge(match: match)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Results")
    }
}

private enum WatchMatchStatusRules {
    static func isFinished(_ match: WatchMatch) -> Bool {
        WatchMatchCollections.isFinished(match)
    }
}

private struct WatchMatchLozenge: View {
    let match: WatchMatch

    var body: some View {
        VStack(spacing: 6) {
            WatchMatchLozengeTopRow(match: match)

            if let penaltyResult = match.penaltyResult {
                Text(penaltyResult)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Text(match.displayLeague)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.gray.opacity(0.18))
        )
        .frame(maxWidth: .infinity)
    }

}

private struct WatchMatchLozengeTopRow: View {
    let match: WatchMatch

    private var topIndicatorText: String {
        if let status = match.displayScoreStatus {
            return status
        }
        if match.hasScore {
            return "-"
        }
        return match.time
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(match.displayHomeTeam)
                    .font(.footnote)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .leading)

                WatchMatchStatusIndicatorView(text: topIndicatorText, isLive: match.isInProgress)
                    .fixedSize(horizontal: true, vertical: false)

                Text(match.displayAwayTeam)
                    .font(.footnote)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            HStack(spacing: 8) {
                WatchTeamLogo(
                    name: match.homeTeam,
                    alternateNames: [match.homeShortName].compactMap { $0 },
                    teamId: match.homeTeamId
                )

                Spacer(minLength: 0)

                if match.hasScore, isFinished {
                    Text(match.scoreLine ?? "-")
                        .font(.footnote)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                } else if match.hasScore {
                    WatchScoreText(value: match.homeScore)

                    WatchPrimaryChannelLogo(channels: match.tvChannels)

                    WatchScoreText(value: match.awayScore)
                } else {
                    WatchPrimaryChannelLogo(channels: match.tvChannels)
                }

                Spacer(minLength: 0)

                WatchTeamLogo(
                    name: match.awayTeam,
                    alternateNames: [match.awayShortName].compactMap { $0 },
                    teamId: match.awayTeamId
                )
            }
        }
    }

    private var isFinished: Bool {
        WatchMatchStatusRules.isFinished(match)
    }
}

private struct WatchScoreText: View {
    let value: Int?

    var body: some View {
        Text(value.map(String.init) ?? "-")
            .font(.footnote)
            .fontWeight(.semibold)
            .monospacedDigit()
            .frame(minWidth: 14, alignment: .center)
    }
}

private struct WatchMatchStatusIndicatorView: View {
    let text: String
    let isLive: Bool

    @State private var isPulsing = false

    private let liveTint = Color(red: 0.32, green: 0.82, blue: 0.51)

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(isLive ? .semibold : .regular)
            .foregroundStyle(isLive ? liveTint : Color.secondary)
            .monospacedDigit()
            .padding(.horizontal, isLive ? 6 : 0)
            .padding(.vertical, isLive ? 3 : 0)
            .background {
                if isLive {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(liveTint.opacity(isPulsing ? 0.14 : 0.26))
                }
            }
            .overlay {
                if isLive {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(liveTint.opacity(isPulsing ? 0.45 : 0.95), lineWidth: 1)
                        .scaleEffect(isPulsing ? 1.08 : 0.96)
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

private struct WatchMatchTopRow: View {
    let match: WatchMatch

    private var centerIndicatorText: String {
        if let status = match.displayScoreStatus {
            return status
        }
        if match.hasScore {
            return "-"
        }
        return match.time
    }

    var body: some View {
        HStack(spacing: 6) {
            WatchTeamLogo(
                name: match.homeTeam,
                alternateNames: [match.homeShortName].compactMap { $0 },
                teamId: match.homeTeamId
            )
            Text(match.displayHomeTeam)
                .font(.footnote)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            WatchMatchStatusIndicatorView(text: centerIndicatorText, isLive: match.isInProgress)
                .fixedSize(horizontal: true, vertical: false)
            Text(match.displayAwayTeam)
                .font(.footnote)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
            WatchTeamLogo(
                name: match.awayTeam,
                alternateNames: [match.awayShortName].compactMap { $0 },
                teamId: match.awayTeamId
            )
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct WatchTeamLogo: View {
    let name: String
    var alternateNames: [String] = []
    var teamId: String? = nil

    var body: some View {
        Group {
            if let image = WatchTeamLogoResolver.shared.image(for: name, teamId: teamId, alternateNames: alternateNames) {
                Image(uiImage: image)
                    .resizable()
            } else {
                Image(systemName: "shield")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .scaledToFit()
        .frame(width: 16, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

private struct WatchPrimaryChannelLogo: View {
    let channels: [String]

    var body: some View {
        if let primaryChannel = primaryChannel,
           let image = WatchTvLogoResolver.shared.image(for: primaryChannel) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(height: 12)
                .frame(minWidth: 18, idealWidth: 22)
        } else {
            Image(systemName: "tv")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, idealWidth: 22)
        }
    }

    private var primaryChannel: String? {
        channels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

private struct WatchMatchDetailView: View {
    @EnvironmentObject private var matchesStore: WatchMatchesStore

    let match: WatchMatch

    @State private var detailedMatch: WatchMatch?
    @State private var detailRefreshTask: Task<Void, Never>?
    @State private var isRefreshingLatestData = false

    private let liveDetailRefreshIntervalNanos: UInt64 = 15_000_000_000
    private let standardDetailRefreshIntervalNanos: UInt64 = 60_000_000_000
    private let finishedDetailRefreshIntervalNanos: UInt64 = 5 * 60_000_000_000

    private var activeMatch: WatchMatch {
        detailedMatch ?? match
    }

    private var sortedChannels: [String] {
        activeMatch.tvChannels.uniqueSortedCaseInsensitive()
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

    private var topIndicatorText: String {
        if let status = activeMatch.displayScoreStatus {
            return status
        }
        if activeMatch.hasScore {
            return "-"
        }
        return "vs"
    }

    private var isMatchFinished: Bool {
        WatchMatchStatusRules.isFinished(activeMatch)
    }

    private func teamEventEntries(for currentMatch: WatchMatch) -> [WatchTeamEventEntry] {
        mergedTeamTimelineEvents(
            homeGoals: currentMatch.homeGoalScorers,
            homeAssists: currentMatch.homeAssists,
            homeRedCards: currentMatch.homeRedCards,
            awayGoals: currentMatch.awayGoalScorers,
            awayAssists: currentMatch.awayAssists,
            awayRedCards: currentMatch.awayRedCards
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if isRefreshingLatestData {
                    HStack {
                        Spacer()
                        ProgressView()
                            .scaleEffect(0.55)
                            .frame(width: 12, height: 12)
                            .accessibilityLabel("Refreshing latest match data")
                    }
                    .padding(.horizontal, 4)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(activeMatch.league)
                        .font(.footnote)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)

                    Text(kickoffText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 4)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(activeMatch.displayHomeTeam)
                            .font(.footnote)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity, alignment: .trailing)

                        WatchMatchStatusIndicatorView(text: topIndicatorText, isLive: activeMatch.isInProgress)
                            .fixedSize(horizontal: true, vertical: false)

                        Text(activeMatch.displayAwayTeam)
                            .font(.footnote)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(spacing: 6) {
                        WatchTeamLogo(
                            name: activeMatch.homeTeam,
                            alternateNames: [activeMatch.homeShortName].compactMap { $0 },
                            teamId: activeMatch.homeTeamId
                        )

                        if activeMatch.hasScore {
                            HStack(spacing: 4) {
                                Text("\(activeMatch.homeScore!)")
                                    .font(.title3)
                                    .fontWeight(.semibold)
                                    .monospacedDigit()

                                Text("-")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)

                                Text("\(activeMatch.awayScore!)")
                                    .font(.title3)
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Text("-")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }

                        WatchTeamLogo(
                            name: activeMatch.awayTeam,
                            alternateNames: [activeMatch.awayShortName].compactMap { $0 },
                            teamId: activeMatch.awayTeamId
                        )
                    }

                    if let penaltyResult = activeMatch.penaltyResult {
                        Text(penaltyResult)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.gray.opacity(0.18))
                )

                WatchKeyEventsCard(match: activeMatch)
                WatchStartingLineupsSection(match: activeMatch)

                if !isMatchFinished {
                    VStack(alignment: .leading, spacing: 3) {
                        if sortedChannels.isEmpty {
                            Text("TV TBA")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(sortedChannels, id: \.self) { channel in
                                WatchTvChannelRow(channel: channel)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.gray.opacity(0.18))
                    )
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
        .navigationTitle("Match Details")
        .onAppear {
            loadCachedDetails()
            startAutomaticDetailRefresh()
        }
        .onDisappear {
            detailRefreshTask?.cancel()
            detailRefreshTask = nil
            isRefreshingLatestData = false
        }
    }

    private func startAutomaticDetailRefresh() {
        detailRefreshTask?.cancel()
        detailRefreshTask = Task {
            await refreshMatchDetails()

            while !Task.isCancelled {
                let interval = await MainActor.run {
                    detailRefreshIntervalNanos
                }
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                await refreshMatchDetails()
            }
        }
    }

    private func loadCachedDetails() {
        guard detailedMatch == nil,
              let cachedMatch = matchesStore.cachedDetails(for: match) else {
            return
        }
        detailedMatch = cachedMatch
    }

    private var detailRefreshIntervalNanos: UInt64 {
        if activeMatch.isInProgress {
            return liveDetailRefreshIntervalNanos
        }
        if isMatchFinished {
            return finishedDetailRefreshIntervalNanos
        }
        return standardDetailRefreshIntervalNanos
    }

    private func refreshMatchDetails() async {
        guard let matchID = match.matchDetailsIDValue else {
            diagnosticLog("[WatchMatchDetailView] No match details ID for %@ vs %@", match.homeTeam, match.awayTeam)
            return
        }
        let apiBaseURL = await MainActor.run {
            matchesStore.apiBaseURL
        }
        guard let baseURL = URL(string: apiBaseURL) else {
            diagnosticLog("[WatchMatchDetailView] Invalid API base URL: %@", apiBaseURL)
            return
        }

        diagnosticLog("[WatchMatchDetailView] Fetching details for match ID: %@ (baseURL: %@)", matchID, baseURL.absoluteString)

        let client = WatchAPIClient(baseURL: baseURL)
        await MainActor.run {
            isRefreshingLatestData = true
        }
        do {
            let details = try await client.fetchMatchDetails(matchId: matchID)
            diagnosticLog("[WatchMatchDetailView] Fetched details - homeGoals=%d awayGoals=%d homeAssists=%d awayAssists=%d",
                  details.homeGoalScorers.count,
                  details.awayGoalScorers.count,
                  details.homeAssists.count,
                  details.awayAssists.count)
            await MainActor.run {
                let baseMatch = detailedMatch ?? match
                let updated = baseMatch.withDetails(details)
                detailedMatch = updated
                matchesStore.cacheDetails(updated)
                isRefreshingLatestData = false
                let entries = teamEventEntries(for: updated)
                diagnosticLog("[WatchMatchDetailView] Updated detailedMatch - teamEventEntries count: %d", entries.count)
            }
        } catch {
            await MainActor.run {
                isRefreshingLatestData = false
            }
            diagnosticLog("[WatchMatchDetailView] Failed to fetch match details: %@", String(describing: error))
        }
    }

    private func mergedTeamTimelineEvents(
        homeGoals: [WatchGoalScorer],
        homeAssists: [WatchAssistProvider],
        homeRedCards: [WatchRedCardEvent],
        awayGoals: [WatchGoalScorer],
        awayAssists: [WatchAssistProvider],
        awayRedCards: [WatchRedCardEvent]
    ) -> [WatchTeamEventEntry] {
        let homeEvents = teamTimelineEvents(
            goals: homeGoals,
            assists: homeAssists,
            redCards: homeRedCards
        ).map { WatchTeamEventEntry(side: .home, event: $0) }

        let awayEvents = teamTimelineEvents(
            goals: awayGoals,
            assists: awayAssists,
            redCards: awayRedCards
        ).map { WatchTeamEventEntry(side: .away, event: $0) }

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

    private func teamTimelineEvents(
        goals: [WatchGoalScorer],
        assists: [WatchAssistProvider],
        redCards: [WatchRedCardEvent]
    ) -> [WatchTeamTimelineEvent] {
        let assistLookup = buildAssistLookup(assists)
        var events: [WatchTeamTimelineEvent] = []
        var sequence = 0

        for scorer in goals {
            let playerName = displayName(from: scorer.player)
            guard !playerName.isEmpty else { continue }

            for rawMinute in scorer.goalTimes {
                guard let minute = parseMinute(rawMinute) else { continue }
                events.append(
                    WatchTeamTimelineEvent(
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
                    WatchTeamTimelineEvent(
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
                    WatchTeamTimelineEvent(
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
                    WatchTeamTimelineEvent(
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

    private func buildAssistLookup(_ assists: [WatchAssistProvider]) -> WatchAssistLookup {
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

        return WatchAssistLookup(exact: exact, base: base)
    }

    private func parseMinute(_ rawValue: String) -> WatchParsedMinute? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "'", with: "'")
            .replacingOccurrences(of: "′", with: "'")
        guard !normalized.isEmpty else { return nil }

        let isPenalty = normalized.lowercased().contains("pen")

        let nsRange = NSRange(normalized.startIndex..., in: normalized)
        guard let match = WatchMinuteParser.regex.firstMatch(in: normalized, options: [], range: nsRange) else {
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
        return WatchParsedMinute(base: base, extra: extra, display: display, isPenalty: isPenalty)
    }

    private func displayName(from rawName: String) -> String {
        abbreviatePlayerName(rawName.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func abbreviatePlayerName(_ fullName: String) -> String {
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

private struct WatchTvInlineLogoRow: View {
    let channels: [String]

    var body: some View {
        let images = WatchTvLogoResolver.shared.images(for: channels)
        if images.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 4) {
                ForEach(images.indices, id: \.self) { index in
                    Image(uiImage: images[index])
                        .resizable()
                        .scaledToFit()
                        .frame(height: 10)
                }
            }
        }
    }
}

private struct WatchTvChannelRow: View {
    let channel: String

    var body: some View {
        HStack(spacing: 6) {
            if let image = WatchTvLogoResolver.shared.image(for: channel) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 12)
            }

            Text(channel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum WatchTeamSide {
    case home
    case away

    var sortOrder: Int {
        switch self {
        case .home: return 0
        case .away: return 1
        }
    }
}

private struct WatchTeamEventEntry {
    let side: WatchTeamSide
    let event: WatchTeamTimelineEvent
}

private struct WatchTeamEventListView: View {
    let entries: [WatchTeamEventEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                WatchTeamEventLineView(entry: entry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WatchTeamEventLineView: View {
    let entry: WatchTeamEventEntry

    var body: some View {
        HStack(spacing: 3) {
            if entry.side == .home {
                WatchEventIconView(kind: entry.event.kind)
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
                WatchEventIconView(kind: entry.event.kind)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct WatchEventIconView: View {
    let kind: WatchEventKind

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
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.red)
                        .shadow(color: .black.opacity(0.45), radius: 0.5, x: 0, y: 0)
                }
            case .disallowedGoal:
                ZStack {
                    Text("⚽️")
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 12, height: 1.6)
                        .rotationEffect(.degrees(-28))
                        .shadow(color: .black.opacity(0.35), radius: 0.4, x: 0, y: 0)
                }
            }
        }
        .font(.caption2)
        .frame(width: 14, height: 14, alignment: .center)
    }
}

private enum WatchEventKind {
    case goal
    case ownGoal
    case redCard
    case disallowedGoal
}

private struct WatchParsedMinute {
    let base: Int
    let extra: Int
    let display: String
    let isPenalty: Bool

    var lookupKey: String {
        extra > 0 ? "\(base)+\(extra)" : "\(base)"
    }
}

private struct WatchAssistLookup {
    let exact: [String: String]
    let base: [Int: String]

    func name(for minute: WatchParsedMinute) -> String? {
        if let exactName = exact[minute.lookupKey] {
            return exactName
        }
        return base[minute.base]
    }
}

private struct WatchTeamTimelineEvent {
    let kind: WatchEventKind
    let displayMinute: String
    let playerName: String
    let assistName: String?
    let minute: WatchParsedMinute
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

private enum WatchMinuteParser {
    static let regex = try! NSRegularExpression(pattern: "(\\d{1,3})(?:\\s*'\\s*)?(?:\\+\\s*(\\d{1,2}))?")
}

private struct WatchKeyEventsCard: View {
    let match: WatchMatch

    private var entries: [WatchMatchEventEntry] {
        WatchMatchEventEntry.entries(for: match)
    }

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Key Events")
                    .font(.footnote)
                    .fontWeight(.semibold)

                VStack(spacing: 6) {
                    ForEach(entries) { entry in
                        WatchKeyEventRow(entry: entry)
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.gray.opacity(0.18))
            )
        }
    }
}

private struct WatchKeyEventRow: View {
    let entry: WatchMatchEventEntry

    private var isGoal: Bool {
        entry.kind == .goal
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.minute)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                WatchTeamLogo(name: entry.sideLabel)
            }
            .frame(width: 28, alignment: .leading)
            .padding(.top, 2)

            WatchKeyEventIcon(kind: entry.kind)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                if entry.kind == .substitution,
                   let playerOff = entry.substitutionPlayerOff,
                   let playerOn = entry.substitutionPlayerOn {
                    WatchSubstitutionPlayerLine(name: playerOff, systemImage: "arrow.down", tint: .red)
                    WatchSubstitutionPlayerLine(name: playerOn, systemImage: "arrow.up", tint: .green)
                } else {
                    Text(entry.title)
                        .font(.caption)
                        .fontWeight(isGoal ? .semibold : .medium)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle = entry.subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text(entry.sideLabel)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, isGoal ? 7 : 5)
        .padding(.horizontal, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isGoal ? Color.green.opacity(0.10) : Color.gray.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isGoal ? Color.green.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct WatchSubstitutionPlayerLine: View {
    let name: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 10, alignment: .center)

            Text(name)
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WatchKeyEventIcon: View {
    let kind: WatchMatchEventEntry.Kind

    var body: some View {
        Group {
            switch kind {
            case .goal:
                ZStack {
                    Circle().fill(Color.green)
                    Image(systemName: "soccerball")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .shadow(color: Color.green.opacity(0.45), radius: 4)
            case .yellowCard:
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.yellow)
                    .frame(width: 10, height: 14)
            case .redCard:
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.red)
                    .frame(width: 10, height: 14)
            case .varEvent:
                Image(systemName: "video")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
            case .substitution:
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
    }
}

private struct WatchStartingLineupsSection: View {
    let match: WatchMatch

    var body: some View {
        if let lineups = match.teamLineups,
           let home = lineups.home,
           let away = lineups.away,
           !home.startingLineup.isEmpty,
           !away.startingLineup.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Starting Line-ups")
                    .font(.footnote)
                    .fontWeight(.semibold)

                WatchLineupList(teamName: home.team ?? match.displayHomeTeam, teamId: match.homeTeamId, lineup: home)
                WatchLineupList(teamName: away.team ?? match.displayAwayTeam, teamId: match.awayTeamId, lineup: away)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.gray.opacity(0.18))
            )
        }
    }
}

private struct WatchLineupList: View {
    let teamName: String
    let teamId: String?
    let lineup: WatchTeamLineup

    private var displayFormation: String? {
        if let collapsedFormation = collapsedOutfieldFormation {
            return collapsedFormation
        }

        guard let formation = lineup.formation, !formation.isEmpty else {
            return nil
        }
        return formation
    }

    private var collapsedOutfieldFormation: String? {
        var defenderCount = 0
        var midfielderCount = 0
        var forwardCount = 0

        for player in lineup.startingLineup {
            switch formationRole(for: player) {
            case "D":
                defenderCount += 1
            case "M":
                midfielderCount += 1
            case "F":
                forwardCount += 1
            default:
                continue
            }
        }

        guard defenderCount + midfielderCount + forwardCount == 10,
              defenderCount > 0,
              midfielderCount > 0,
              forwardCount > 0 else {
            return nil
        }

        return "\(defenderCount)-\(midfielderCount)-\(forwardCount)"
    }

    private func formationRole(for player: WatchLineupPlayer) -> String? {
        if let shortPosition = player.positionShort?.uppercased(), !shortPosition.isEmpty {
            if shortPosition.hasPrefix("D") {
                return "D"
            }
            if shortPosition.hasPrefix("M") || shortPosition == "AM" || shortPosition == "DM" {
                return "M"
            }
            if shortPosition.hasPrefix("F") || shortPosition.hasPrefix("ST") || shortPosition.hasPrefix("W") {
                return "F"
            }
            if shortPosition.hasPrefix("G") {
                return "G"
            }
        }

        let position = player.position?.lowercased() ?? ""
        if position.contains("defender") {
            return "D"
        }
        if position.contains("midfielder") {
            return "M"
        }
        if position.contains("forward") || position.contains("striker") || position.contains("winger") {
            return "F"
        }
        if position.contains("goalkeeper") {
            return "G"
        }

        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text(teamName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let formation = displayFormation {
                        Text(formation)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                WatchTeamLogo(name: teamName, teamId: teamId)
            }

            ForEach(lineup.startingLineup) { player in
                HStack(spacing: 6) {
                    Text(player.number > 0 ? "\(player.number)" : "-")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .trailing)
                    Text(player.name)
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    if let position = player.positionShort ?? player.position, !position.isEmpty {
                        Text(position)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

private struct WatchMatchEventEntry: Identifiable {
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
    let sideLabel: String
    let title: String
    let subtitle: String?
    var substitutionPlayerOff: String? = nil
    var substitutionPlayerOn: String? = nil

    var id: String {
        "\(sortMinute)|\(minute)|\(kind)|\(side)|\(title)|\(subtitle ?? "")|\(substitutionPlayerOff ?? "")|\(substitutionPlayerOn ?? "")"
    }

    static func entries(for match: WatchMatch) -> [WatchMatchEventEntry] {
        var output: [WatchMatchEventEntry] = []
        appendGoals(from: match.homeGoalScorers, assists: match.homeAssists, side: .home, sideLabel: match.displayHomeTeam, to: &output)
        appendGoals(from: match.awayGoalScorers, assists: match.awayAssists, side: .away, sideLabel: match.displayAwayTeam, to: &output)
        appendYellowCards(from: match.homeYellowCards, side: .home, sideLabel: match.displayHomeTeam, to: &output)
        appendYellowCards(from: match.awayYellowCards, side: .away, sideLabel: match.displayAwayTeam, to: &output)
        appendRedCards(from: match.homeRedCards, side: .home, sideLabel: match.displayHomeTeam, to: &output)
        appendRedCards(from: match.awayRedCards, side: .away, sideLabel: match.displayAwayTeam, to: &output)
        appendVarEvents(from: match.homeVarEvents, side: .home, sideLabel: match.displayHomeTeam, to: &output)
        appendVarEvents(from: match.awayVarEvents, side: .away, sideLabel: match.displayAwayTeam, to: &output)
        appendSubstitutions(from: match.teamLineups?.home, side: .home, sideLabel: match.displayHomeTeam, to: &output)
        appendSubstitutions(from: match.teamLineups?.away, side: .away, sideLabel: match.displayAwayTeam, to: &output)

        return output.sorted { lhs, rhs in
            if lhs.sortMinute != rhs.sortMinute {
                return lhs.sortMinute < rhs.sortMinute
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func appendGoals(
        from scorers: [WatchGoalScorer],
        assists: [WatchAssistProvider],
        side: Side,
        sideLabel: String,
        to output: inout [WatchMatchEventEntry]
    ) {
        let assistsByMinute = assistProviderByMinute(assists)
        for scorer in scorers {
            for minute in scorer.goalTimes {
                output.append(
                    WatchMatchEventEntry(
                        minute: formattedMinute(minute),
                        sortMinute: sortMinute(minute),
                        kind: .goal,
                        side: side,
                        sideLabel: sideLabel,
                        title: scorer.player,
                        subtitle: assistsByMinute[normalizedMinute(minute)].map { "Assist: \($0)" }
                    )
                )
            }
            for minute in scorer.ownGoalTimes {
                output.append(event(minute: minute, kind: .goal, side: side, sideLabel: sideLabel, title: "\(scorer.player) (OG)"))
            }
            for minute in scorer.disallowedGoalTimes {
                output.append(event(minute: minute, kind: .goal, side: side, sideLabel: sideLabel, title: "\(scorer.player) disallowed goal"))
            }
        }
    }

    private static func appendYellowCards(
        from cards: [WatchYellowCardEvent],
        side: Side,
        sideLabel: String,
        to output: inout [WatchMatchEventEntry]
    ) {
        for card in cards {
            for minute in card.yellowCardTimes {
                output.append(event(minute: minute, kind: .yellowCard, side: side, sideLabel: sideLabel, title: card.player))
            }
        }
    }

    private static func appendRedCards(
        from cards: [WatchRedCardEvent],
        side: Side,
        sideLabel: String,
        to output: inout [WatchMatchEventEntry]
    ) {
        for card in cards {
            for minute in card.redCardTimes {
                output.append(event(minute: minute, kind: .redCard, side: side, sideLabel: sideLabel, title: card.player))
            }
        }
    }

    private static func appendVarEvents(
        from events: [WatchVarEvent],
        side: Side,
        sideLabel: String,
        to output: inout [WatchMatchEventEntry]
    ) {
        for varEvent in events {
            guard let minute = varEvent.minute, !minute.isEmpty else { continue }
            output.append(
                WatchMatchEventEntry(
                    minute: formattedMinute(minute),
                    sortMinute: sortMinute(minute),
                    kind: .varEvent,
                    side: side,
                    sideLabel: sideLabel,
                    title: varEvent.player ?? varEvent.detail,
                    subtitle: varEvent.player == nil ? nil : varEvent.detail
                )
            )
        }
    }

    private static func appendSubstitutions(
        from lineup: WatchTeamLineup?,
        side: Side,
        sideLabel: String,
        to output: inout [WatchMatchEventEntry]
    ) {
        guard let lineup else { return }
        for substitution in lineup.substitutions {
            output.append(
                WatchMatchEventEntry(
                    minute: formattedMinute(substitution.minute),
                    sortMinute: sortMinute(substitution.minute),
                    kind: .substitution,
                    side: side,
                    sideLabel: sideLabel,
                    title: "Substitution",
                    subtitle: nil,
                    substitutionPlayerOff: substitution.playerOff.name,
                    substitutionPlayerOn: substitution.playerOn.name
                )
            )
        }
    }

    private static func event(
        minute: String,
        kind: Kind,
        side: Side,
        sideLabel: String,
        title: String
    ) -> WatchMatchEventEntry {
        WatchMatchEventEntry(
            minute: formattedMinute(minute),
            sortMinute: sortMinute(minute),
            kind: kind,
            side: side,
            sideLabel: sideLabel,
            title: title,
            subtitle: nil
        )
    }

    private static func assistProviderByMinute(_ assists: [WatchAssistProvider]) -> [String: String] {
        var lookup: [String: String] = [:]
        for assist in assists {
            for minute in assist.assistTimes {
                lookup[normalizedMinute(minute)] = assist.player
            }
        }
        return lookup
    }

    private static func formattedMinute(_ value: String) -> String {
        let normalized = normalizedMinute(value)
        guard !normalized.isEmpty else { return value }
        return normalized.hasSuffix("'") ? normalized : "\(normalized)'"
    }

    private static func normalizedMinute(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "′", with: "'")
            .replacingOccurrences(of: "'", with: "")
    }

    private static func sortMinute(_ value: String) -> Int {
        let normalized = normalizedMinute(value)
        return normalized
            .split { !$0.isNumber }
            .first
            .flatMap { Int($0) } ?? Int.max
    }
}

private extension Array where Element == String {
    func uniqueSortedCaseInsensitive() -> [String] {
        var seen = Set<String>()
        var output: [String] = []

        for value in self {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .lowercased()

            guard !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(trimmed)
        }

        return output.sorted { lhs, rhs in
            lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(WatchMatchesStore())
}
