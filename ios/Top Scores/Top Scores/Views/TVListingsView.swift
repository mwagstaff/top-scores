import Foundation
import SwiftUI

nonisolated enum TVListingsTimeline {
    enum CurrentTimeStatus: Equatable, Sendable {
        case onNow
        case nextMatch(at: Date)
        case noMoreMatches
    }

    static let currentTimeMarkerID = "tv-listings-current-time"
    static let countryCode = "GB"

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
        from matches: [Match]
    ) -> [Match] {
        matches.compactMap { match in
            guard match.date == dateKey else { return nil }
            let channels = match.tvChannels
                .filter {
                    $0.countryCode?.caseInsensitiveCompare(countryCode) == .orderedSame
                }
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
        if let firstLiveIndex = matches.firstIndex(where: { isInProgress($0, now: now) }) {
            return firstLiveIndex
        }

        return matches.firstIndex { match in
            guard let kickoff = match.dateTime else { return false }
            return kickoff > now
        } ?? matches.endIndex
    }

    static func currentTimeStatus(
        in matches: [Match],
        now: Date
    ) -> CurrentTimeStatus {
        if matches.contains(where: { isInProgress($0, now: now) }) {
            return .onNow
        }

        let nextKickoff = matches
            .compactMap(\.dateTime)
            .filter { $0 > now }
            .min()

        return nextKickoff.map { .nextMatch(at: $0) } ?? .noMoreMatches
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

    private static func isInProgress(_ match: Match, now: Date) -> Bool {
        guard let status = match.stabilizedScoreStatus(now: now) else { return false }
        return MatchStatusFormatter.isInProgress(status)
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
    @State private var selectedWatchabilityMatch: Match?

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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ukListingsNote
        }
        .sheet(item: $selectedWatchabilityMatch) { match in
            WatchabilityBreakdownSheet(match: match)
        }
    }

    private var ukListingsNote: some View {
        Label("TV listings show UK channels only.", systemImage: "info.circle")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
    }

    private func timeline(listings: [Match], now: Date) -> some View {
        let showsCurrentTime = TVListingsTimeline.isToday(selectedDateKey, now: now)
        let currentTimeIndex = showsCurrentTime
            ? TVListingsTimeline.currentTimeInsertionIndex(in: listings, now: now)
            : nil
        let currentTimeStatus = TVListingsTimeline.currentTimeStatus(in: listings, now: now)

        return GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(listings.enumerated()), id: \.element.id) { index, match in
                            if currentTimeIndex == index {
                                currentTimeMarker(now: now, status: currentTimeStatus)
                                    .id(TVListingsTimeline.currentTimeMarkerID)
                            }

                            TVListingTimelineRow(
                                match: match,
                                rowPreferences: rowPreferences,
                                fantasyContext: fantasyContext,
                                usesAccessibleLayout: dynamicTypeSize.isAccessibilitySize,
                                onSelect: onSelectMatch,
                                onSelectWatchability: { selectedWatchabilityMatch = $0 }
                            )
                        }

                        if currentTimeIndex == listings.endIndex {
                            currentTimeMarker(now: now, status: currentTimeStatus)
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

    private func currentTimeMarker(
        now: Date,
        status: TVListingsTimeline.CurrentTimeStatus
    ) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(currentTimeStatusText(status))
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

                    Text(currentTimeStatusText(status))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.red)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(currentTimeAccessibilityLabel(now: now, status: status))
    }

    private func currentTimeStatusText(
        _ status: TVListingsTimeline.CurrentTimeStatus
    ) -> String {
        switch status {
        case .onNow:
            return "ON NOW"
        case .nextMatch(let kickoff):
            return "NEXT MATCH AT \(kickoff.formatted(date: .omitted, time: .shortened))"
        case .noMoreMatches:
            return "NO MORE MATCHES TODAY"
        }
    }

    private func currentTimeAccessibilityLabel(
        now: Date,
        status: TVListingsTimeline.CurrentTimeStatus
    ) -> String {
        let currentTime = now.formatted(date: .omitted, time: .shortened)
        switch status {
        case .onNow:
            return "Current time, \(currentTime). Match on now."
        case .nextMatch(let kickoff):
            let nextTime = kickoff.formatted(date: .omitted, time: .shortened)
            return "Current time, \(currentTime). Next match at \(nextTime)."
        case .noMoreMatches:
            return "Current time, \(currentTime). No more matches today."
        }
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
                proxy.scrollTo(TVListingsTimeline.currentTimeMarkerID, anchor: .top)
            } else {
                withAnimation(.easeOut(duration: 0.28)) {
                    proxy.scrollTo(TVListingsTimeline.currentTimeMarkerID, anchor: .top)
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
    let onSelectWatchability: (Match) -> Void

    var body: some View {
        Group {
            if usesAccessibleLayout {
                VStack(alignment: .leading, spacing: 8) {
                    Text(match.time)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(match.isInProgress ? Color.liveMatch : Color.secondary)
                        .monospacedDigit()

                    matchCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
            } else {
                HStack(alignment: .center, spacing: 10) {
                    timelineTime
                    matchCard
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

    private var matchCard: some View {
        VStack(spacing: 0) {
            matchButton

            if let watchabilityIndex = match.watchabilityIndex {
                Divider()
                    .overlay(FootballVisualStyle.divider)
                    .padding(.horizontal, 16)

                Button {
                    onSelectWatchability(match)
                } label: {
                    WatchabilityIndexRow(
                        index: watchabilityIndex,
                        usesAccessibleLayout: usesAccessibleLayout
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("Show why this match received its rating")
            }
        }
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
        .frame(maxWidth: .infinity)
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
                broadcastRegionCode: TVListingsTimeline.countryCode,
                fantasyContext: fantasyContext,
                rowPreferences: rowPreferences
            )
        }
        .buttonStyle(.plain)
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

private struct WatchabilityIndexRow: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let index: MatchWatchabilityIndex
    let usesAccessibleLayout: Bool

    var body: some View {
        Group {
            if usesAccessibleLayout {
                VStack(alignment: .leading, spacing: 6) {
                    labelAndScore
                    stars
                }
            } else {
                HStack(spacing: 10) {
                    tierLabel
                        .frame(maxWidth: .infinity, alignment: .leading)

                    scoreLabel

                    stars
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 42)
        .contentShape(Rectangle())
        .animation(updateAnimation, value: index.score)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Watchability: \(tierTitle), \(index.score) out of 100, \(index.stars) out of 5 stars"
        )
    }

    private var labelAndScore: some View {
        HStack(spacing: 12) {
            tierLabel
            Spacer(minLength: 8)
            scoreLabel
        }
    }

    private var tierLabel: some View {
        Text(tierTitle.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(tierColor)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .contentTransition(.opacity)
    }

    private var scoreLabel: some View {
        Text("\(index.score)/100")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .contentTransition(.numericText(value: Double(index.score)))
            .fixedSize()
    }

    private var stars: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { position in
                Image(systemName: position <= index.stars ? "star.fill" : "star")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(position <= index.stars ? tierColor : Color.secondary.opacity(0.46))
                    .scaleEffect(accessibilityReduceMotion || position > index.stars ? 1 : 1.04)
            }
        }
        .accessibilityHidden(true)
    }

    private var updateAnimation: Animation? {
        accessibilityReduceMotion ? nil : .easeOut(duration: 0.22)
    }

    private var tierTitle: String {
        switch index.tier {
        case "must_watch": "Must Watch"
        case "highly_watchable": "Highly Watchable"
        case "good_watch": "Good Watch"
        default: "Moderate"
        }
    }

    private var tierColor: Color {
        switch index.tier {
        case "must_watch": Color(red: 0.38, green: 0.86, blue: 0.35)
        case "highly_watchable": Color(red: 0.92, green: 0.80, blue: 0.22)
        case "good_watch": Color(red: 0.98, green: 0.63, blue: 0.16)
        default: Color(red: 0.96, green: 0.47, blue: 0.16)
        }
    }
}

private struct WatchabilityBreakdownSheet: View {
    @Environment(\.dismiss) private var dismiss

    let match: Match

    private var index: MatchWatchabilityIndex? { match.watchabilityIndex }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    summary

                    if let index {
                        VStack(spacing: 18) {
                            ForEach(index.components) { component in
                                factorRow(component, accent: accentColor(for: index))
                            }
                        }
                    }

                    methodologyNote
                }
                .padding(20)
            }
            .background(FootballVisualStyle.pageBackground.ignoresSafeArea())
            .navigationTitle("Watchability Index")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var summary: some View {
        if let index {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(match.homeTeam) vs \(match.awayTeam)")
                    .font(.headline)

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(index.tier.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(accentColor(for: index))
                    Spacer(minLength: 8)
                    Text("\(index.score)")
                        .font(.title.monospacedDigit().weight(.semibold))
                        .contentTransition(.numericText(value: Double(index.score)))
                    Text("/ 100")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 5) {
                    ForEach(1...5, id: \.self) { position in
                        Image(systemName: position <= index.stars ? "star.fill" : "star")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accentColor(for: index))
                .accessibilityLabel("\(index.stars) out of 5 stars")
            }
        }
    }

    private func factorRow(
        _ component: MatchWatchabilityComponent,
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(component.label)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if component.key == "rivalry" {
                    Text("+\(component.contribution, format: .number.precision(.fractionLength(0...1)))")
                } else {
                    Text("\(component.score)/100")
                }
            }
            .foregroundStyle(.primary)

            if component.key != "rivalry" {
                ProgressView(value: Double(component.score), total: 100)
                    .tint(accent)
            }

            Text(component.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var methodologyNote: some View {
        if let index {
            VStack(alignment: .leading, spacing: 6) {
                Label("How it works", systemImage: "info.circle")
                    .font(.caption.weight(.semibold))
                Text("A universal pre-match rating based on competition strength, team Elo, competitive balance, table stakes, form, match stage and major rivalries. Live incidents do not change the score.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Model \(index.modelVersion) • \(Int((index.confidence * 100).rounded()))% data confidence")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func accentColor(for index: MatchWatchabilityIndex) -> Color {
        switch index.tier {
        case "must_watch": Color(red: 0.38, green: 0.86, blue: 0.35)
        case "highly_watchable": Color(red: 0.92, green: 0.80, blue: 0.22)
        case "good_watch": Color(red: 0.98, green: 0.63, blue: 0.16)
        default: Color(red: 0.96, green: 0.47, blue: 0.16)
        }
    }
}
