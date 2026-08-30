import Foundation
import SwiftUI

nonisolated enum TVListingsTimeline {
    static let currentTimeMarkerID = "tv-listings-current-time"

    static func isAvailable(
        for dateKey: String?,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        guard let dateKey,
              let date = date(from: dateKey, calendar: calendar) else {
            return false
        }
        return calendar.startOfDay(for: date) >= calendar.startOfDay(for: now)
    }

    static func isToday(
        _ dateKey: String,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        guard let date = date(from: dateKey, calendar: calendar) else { return false }
        return calendar.isDate(date, inSameDayAs: now)
    }

    static func title(
        for dateKey: String,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        guard let date = date(from: dateKey, calendar: calendar) else {
            return "TV Listings"
        }
        if calendar.isDate(date, inSameDayAs: now) {
            return "TV Today"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "TV Tomorrow"
        }
        return "TV Listings"
    }

    static func matches(
        for dateKey: String,
        from matches: [Match],
        regionCode: String? = Locale.current.region?.identifier
    ) -> [Match] {
        matches.compactMap { match in
            guard match.date == dateKey else { return nil }
            let channels = localeFilteredChannels(match.tvChannels, regionCode: regionCode)
                .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !channels.isEmpty else { return nil }
            return match.withTvChannels(channels)
        }
        .sorted(by: chronologicalOrder)
    }

    static func currentTimeInsertionIndex(
        in matches: [Match],
        now: Date
    ) -> Int {
        matches.firstIndex { match in
            guard let kickoff = match.dateTime else { return false }
            return kickoff > now
        } ?? matches.endIndex
    }

    private static func chronologicalOrder(_ lhs: Match, _ rhs: Match) -> Bool {
        switch (lhs.dateTime, rhs.dateTime) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }

        if lhs.time != rhs.time {
            return lhs.time.localizedStandardCompare(rhs.time) == .orderedAscending
        }
        let leagueComparison = lhs.league.localizedCaseInsensitiveCompare(rhs.league)
        if leagueComparison != .orderedSame {
            return leagueComparison == .orderedAscending
        }
        let homeComparison = lhs.homeTeam.localizedCaseInsensitiveCompare(rhs.homeTeam)
        if homeComparison != .orderedSame {
            return homeComparison == .orderedAscending
        }
        return lhs.awayTeam.localizedCaseInsensitiveCompare(rhs.awayTeam) == .orderedAscending
    }

    private static func date(from dateKey: String, calendar: Calendar) -> Date? {
        let parts = dateKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2])
        )
    }
}

struct TVListingsView: View {
    let matches: [Match]
    let selectedDateKey: String
    let isLoading: Bool
    let errorMessage: String?
    let rowPreferences: MatchRowPreferences
    let fantasyContext: FantasyMatchRowContext
    let onSelectMatch: (Match) -> Void
    let onRefresh: () async -> Void

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var autoScrolledDateKey: String?

    var body: some View {
        let listings = TVListingsTimeline.matches(
            for: selectedDateKey,
            from: matches
        )

        Group {
            if listings.isEmpty && isLoading {
                loadingState
            } else if listings.isEmpty {
                emptyState
            } else {
                TimelineView(.everyMinute) { context in
                    timeline(listings: listings, now: context.date)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func timeline(listings: [Match], now: Date) -> some View {
        let showsCurrentTime = TVListingsTimeline.isToday(selectedDateKey, now: now)
        let currentTimeIndex = showsCurrentTime
            ? TVListingsTimeline.currentTimeInsertionIndex(in: listings, now: now)
            : nil

        return GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(listings.enumerated()), id: \.element.id) { index, match in
                            if currentTimeIndex == index {
                                currentTimeMarker(now: now)
                                    .id(TVListingsTimeline.currentTimeMarkerID)
                            }

                            TVListingTimelineRow(
                                match: match,
                                rowPreferences: rowPreferences,
                                fantasyContext: fantasyContext,
                                usesAccessibleLayout: dynamicTypeSize.isAccessibilitySize,
                                onSelect: onSelectMatch
                            )
                        }

                        if currentTimeIndex == listings.endIndex {
                            currentTimeMarker(now: now)
                                .id(TVListingsTimeline.currentTimeMarkerID)
                        }

                        Color.clear
                            .frame(height: showsCurrentTime ? geometry.size.height * 0.52 : 96)
                            .accessibilityHidden(true)
                    }
                    .padding(.top, 4)
                }
                .scrollIndicators(.hidden)
                .refreshable {
                    await onRefresh()
                }
                .onAppear {
                    scrollToCurrentTimeIfNeeded(
                        proxy: proxy,
                        listings: listings,
                        now: now
                    )
                }
                .onChange(of: selectedDateKey) { _, _ in
                    autoScrolledDateKey = nil
                    scrollToCurrentTimeIfNeeded(
                        proxy: proxy,
                        listings: listings,
                        now: now
                    )
                }
                .onChange(of: listings.map(\.id)) { _, _ in
                    scrollToCurrentTimeIfNeeded(
                        proxy: proxy,
                        listings: listings,
                        now: now
                    )
                }
            }
        }
    }

    private func currentTimeMarker(now: Date) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ON NOW")
                        .font(.caption.weight(.bold))
                    Text(now.formatted(date: .omitted, time: .shortened))
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(Color.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            } else {
                HStack(spacing: 12) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 11, height: 11)
                            .shadow(color: Color.red.opacity(0.46), radius: 5)

                        Text(now.formatted(date: .omitted, time: .shortened))
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(Color.red)
                    .frame(width: 72, alignment: .leading)

                    Text("ON NOW")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.red)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Current time, \(now.formatted(date: .omitted, time: .shortened))")
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text("Loading TV listings")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: errorMessage == nil ? "tv" : "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text(errorMessage == nil ? "No televised matches" : "Unable to load TV listings")
                .font(.title3)

            Text(errorMessage ?? "There are no televised matches for this date.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if errorMessage != nil {
                Button("Try Again") {
                    Task { await onRefresh() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scrollToCurrentTimeIfNeeded(
        proxy: ScrollViewProxy,
        listings: [Match],
        now: Date
    ) {
        guard !listings.isEmpty,
              autoScrolledDateKey != selectedDateKey,
              TVListingsTimeline.isToday(selectedDateKey, now: now) else {
            return
        }
        autoScrolledDateKey = selectedDateKey

        Task { @MainActor in
            await Task.yield()
            if accessibilityReduceMotion {
                proxy.scrollTo(TVListingsTimeline.currentTimeMarkerID, anchor: .center)
            } else {
                withAnimation(.easeOut(duration: 0.28)) {
                    proxy.scrollTo(TVListingsTimeline.currentTimeMarkerID, anchor: .center)
                }
            }
        }
    }
}

private struct TVListingTimelineRow: View {
    let match: Match
    let rowPreferences: MatchRowPreferences
    let fantasyContext: FantasyMatchRowContext
    let usesAccessibleLayout: Bool
    let onSelect: (Match) -> Void

    var body: some View {
        Group {
            if usesAccessibleLayout {
                VStack(alignment: .leading, spacing: 8) {
                    Text(match.time)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(match.isInProgress ? Color.liveMatch : Color.secondary)
                        .monospacedDigit()

                    matchButton
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
            } else {
                HStack(alignment: .center, spacing: 10) {
                    timelineTime
                    matchButton
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
            }
        }
    }

    private var timelineTime: some View {
        ZStack {
            Rectangle()
                .fill(FootballVisualStyle.divider)
                .frame(width: 1)
                .frame(maxHeight: .infinity)

            HStack(spacing: 7) {
                Circle()
                    .fill(match.isInProgress ? Color.liveMatch : Color.white.opacity(0.86))
                    .frame(width: 8, height: 8)

                Text(match.time)
                    .font(.caption)
                    .foregroundStyle(match.isInProgress ? Color.liveMatch : FootballVisualStyle.mutedText)
                    .monospacedDigit()
            }
            .padding(.vertical, 5)
            .background(FootballVisualStyle.pageBackground)
        }
        .frame(width: 72)
        .accessibilityHidden(true)
    }

    private var matchButton: some View {
        Button {
            onSelect(match)
        } label: {
            MatchRow(
                match: match,
                showLeague: true,
                showBroadcastDetails: true,
                showFantasyBadge: false,
                teamLogoScale: 1.12,
                presentationStyle: .embedded,
                fantasyContext: fantasyContext,
                rowPreferences: rowPreferences
            )
            .footballTintedSurface(
                accentColor: competitionAccentColor,
                cornerRadius: 18,
                accentOpacity: 0.24
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        match.isInProgress ? Color.liveMatch.opacity(0.88) : .clear,
                        lineWidth: 1.5
                    )
            }
            .shadow(
                color: match.isInProgress
                    ? Color.liveMatch.opacity(0.26)
                    : competitionAccentColor.opacity(0.12),
                radius: match.isInProgress ? 9 : 7,
                y: 2
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("View match details")
    }

    private var accessibilityLabel: String {
        let channels = match.tvChannels.map(\.name).joined(separator: ", ")
        return "\(match.time), \(match.displayLeague), \(match.homeTeam) versus \(match.awayTeam), on \(channels)"
    }

    private var competitionAccentColor: Color {
        CompetitionAccentRole.resolve(
            competitionID: match.leagueId,
            competitionName: match.league
        ).color
    }
}
