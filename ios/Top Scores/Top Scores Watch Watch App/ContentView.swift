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
    @State private var selectedScope: WatchMatchScope = .fixtures

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
                        Section {
                            Picker("View", selection: $selectedScope) {
                                ForEach(WatchMatchScope.allCases) { scope in
                                    Text(scope.title).tag(scope)
                                }
                            }
                        }

                        if let lastUpdated = matchesStore.lastUpdated {
                            Section {
                                Text("Updated \(refreshFormatter.string(from: lastUpdated))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if scopedDays.isEmpty {
                            Section {
                                VStack(spacing: 8) {
                                    Image(systemName: "calendar.badge.exclamationmark")
                                        .font(.title3)
                                        .foregroundStyle(.secondary)
                                    Text(selectedScope.isResultsView ? "No results" : "No matches")
                                        .font(.caption)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        } else {
                            ForEach(scopedDays) { day in
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
                }
            }
            .navigationTitle("Top Scores")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        matchesStore.refresh(requestPhoneSync: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh from phone")
                }
            }
        }
        .onAppear {
            matchesStore.refresh(requestPhoneSync: true)
        }
    }

    private var scopedDays: [WatchMatchDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let sourceDays = matchesStore.groupedDays

        let filtered = sourceDays.compactMap { day -> WatchMatchDay? in
            guard let parsedDay = WatchMatchDateParser.shared.parse(date: day.id, time: "00:00") else {
                if selectedScope.isResultsView {
                    return nil
                }
                let unresolvedMatches = day.matches.filter { match in
                    !(isMatchFinished(match) && !match.isInProgress)
                }
                guard !unresolvedMatches.isEmpty else { return nil }
                return WatchMatchDay(id: day.id, displayDate: day.displayDate, matches: unresolvedMatches)
            }
            let dayStart = calendar.startOfDay(for: parsedDay)

            if selectedScope.isResultsView {
                // Results view: show previous days, plus today's matches that are in progress or finished
                if dayStart < today {
                    return day
                } else if dayStart == today {
                    let filteredMatches = day.matches.filter { match in
                        match.isInProgress || isMatchFinished(match)
                    }
                    guard !filteredMatches.isEmpty else { return nil }
                    return WatchMatchDay(id: day.id, displayDate: day.displayDate, matches: filteredMatches)
                } else {
                    return nil
                }
            } else {
                // Fixtures view: show today onwards
                return dayStart >= today ? day : nil
            }
        }

        return selectedScope.isResultsView ? filtered.reversed() : filtered
    }

    private func isMatchFinished(_ match: WatchMatch) -> Bool {
        guard let status = match.scoreStatus else { return false }
        let normalized = status
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: ".", with: "")
        return normalized.hasPrefix("FT") || normalized.hasPrefix("AET")
    }
}

private enum WatchMatchScope: String, CaseIterable, Identifiable {
    case fixtures
    case results

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fixtures:
            return "Fixtures"
        case .results:
            return "Results"
        }
    }

    var isResultsView: Bool {
        switch self {
        case .results:
            return true
        case .fixtures:
            return false
        }
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

            if !isMatchFinished {
                WatchChannelLogoRow(channels: match.tvChannels)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.gray.opacity(0.18))
        )
        .frame(maxWidth: .infinity)
    }

    private var isMatchFinished: Bool {
        guard let status = match.scoreStatus?.uppercased() else { return false }
        return status == "FT" || status == "AET"
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

    private var centeredValue: String {
        match.scoreLine ?? match.time
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

            ZStack {
                Text(centeredValue)
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .center)

                HStack(spacing: 8) {
                    WatchTeamLogo(
                        name: match.homeTeam,
                        alternateNames: [match.homeShortName].compactMap { $0 }
                    )
                    Spacer(minLength: 0)
                    WatchTeamLogo(
                        name: match.awayTeam,
                        alternateNames: [match.awayShortName].compactMap { $0 }
                    )
                }
            }
        }
    }
}

private struct WatchMatchStatusIndicatorView: View {
    let text: String
    let isLive: Bool

    @State private var isPulsing = false

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(isLive ? .semibold : .regular)
            .foregroundStyle(isLive ? Color.red : Color.secondary)
            .monospacedDigit()
            .padding(.horizontal, isLive ? 6 : 0)
            .padding(.vertical, isLive ? 3 : 0)
            .background {
                if isLive {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.red.opacity(isPulsing ? 0.14 : 0.26))
                }
            }
            .overlay {
                if isLive {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.red.opacity(isPulsing ? 0.45 : 0.95), lineWidth: 1)
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
                alternateNames: [match.homeShortName].compactMap { $0 }
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
                alternateNames: [match.awayShortName].compactMap { $0 }
            )
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct WatchTeamLogo: View {
    let name: String
    var alternateNames: [String] = []

    var body: some View {
        Group {
            if let image = WatchTeamLogoResolver.shared.image(for: name, alternateNames: alternateNames) {
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

private struct WatchChannelLogoRow: View {
    let channels: [String]

    var body: some View {
        let sortedChannels = channels.uniqueSortedCaseInsensitive()
        let images = WatchTvLogoResolver.shared.images(for: sortedChannels)

        if images.isEmpty {
            Text("TV TBA")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            HStack(spacing: 6) {
                ForEach(images.indices, id: \.self) { index in
                    Image(uiImage: images[index])
                        .resizable()
                        .scaledToFit()
                        .frame(height: 14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

private struct WatchMatchDetailView: View {
    @EnvironmentObject private var matchesStore: WatchMatchesStore

    let match: WatchMatch

    @State private var detailedMatch: WatchMatch?

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
        guard let status = activeMatch.scoreStatus?.uppercased() else { return false }
        return status == "FT" || status == "AET"
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
                            alternateNames: [activeMatch.homeShortName].compactMap { $0 }
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
                            alternateNames: [activeMatch.awayShortName].compactMap { $0 }
                        )
                    }

                    if let penaltyResult = activeMatch.penaltyResult {
                        Text(penaltyResult)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

                    let entries = teamEventEntries(for: activeMatch)
                    if !entries.isEmpty {
                        WatchTeamEventListView(entries: entries)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.gray.opacity(0.18))
                )

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
            fetchMatchDetails()
        }
    }

    private func fetchMatchDetails() {
        guard let matchID = match.matchDetailsIDValue else {
            NSLog("[WatchMatchDetailView] No match details ID for %@ vs %@", match.homeTeam, match.awayTeam)
            return
        }
        guard let baseURL = URL(string: matchesStore.apiBaseURL) else {
            NSLog("[WatchMatchDetailView] Invalid API base URL: %@", matchesStore.apiBaseURL)
            return
        }

        NSLog("[WatchMatchDetailView] Fetching details for match ID: %@ (baseURL: %@)", matchID, baseURL.absoluteString)

        Task {
            let client = WatchAPIClient(baseURL: baseURL)
            do {
                let details = try await client.fetchMatchDetails(matchId: matchID)
                NSLog("[WatchMatchDetailView] Fetched details - homeGoals=%d awayGoals=%d homeAssists=%d awayAssists=%d",
                      details.homeGoalScorers.count,
                      details.awayGoalScorers.count,
                      details.homeAssists.count,
                      details.awayAssists.count)
                await MainActor.run {
                    let updated = match.withDetails(details)
                    detailedMatch = updated
                    let entries = teamEventEntries(for: updated)
                    NSLog("[WatchMatchDetailView] Updated detailedMatch - teamEventEntries count: %d", entries.count)
                }
            } catch {
                NSLog("[WatchMatchDetailView] Failed to fetch match details: %@", String(describing: error))
            }
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
