import Foundation
import SwiftUI
import EventKit

enum MatchRowLayoutStyle {
    case standard
    case compactFixture
}

struct MatchRowPreferences: Equatable {
    let hasFantasyManagerEntry: Bool
    let showFantasyExpectedPoints: Bool
    let showFantasyRealTimePoints: Bool
    let showFantasyFixtureLogos: Bool
    let showCompactFixtureFantasyLogo: Bool
    let showCompactFixtureTvLogo: Bool

    init(preferences: PreferencesStore, hasFantasyManagerEntry: Bool) {
        self.hasFantasyManagerEntry = hasFantasyManagerEntry
        showFantasyExpectedPoints = preferences.showFantasyExpectedPoints
        showFantasyRealTimePoints = preferences.showFantasyRealTimePoints
        showFantasyFixtureLogos = preferences.showFantasyFixtureLogos
        showCompactFixtureFantasyLogo = preferences.showCompactFixtureFantasyLogo
        showCompactFixtureTvLogo = preferences.showCompactFixtureTvLogo
    }

    static let disabledFantasy = MatchRowPreferences(
        hasFantasyManagerEntry: false,
        showFantasyExpectedPoints: false,
        showFantasyRealTimePoints: false,
        showFantasyFixtureLogos: false,
        showCompactFixtureFantasyLogo: false,
        showCompactFixtureTvLogo: false
    )

    private init(
        hasFantasyManagerEntry: Bool,
        showFantasyExpectedPoints: Bool,
        showFantasyRealTimePoints: Bool,
        showFantasyFixtureLogos: Bool,
        showCompactFixtureFantasyLogo: Bool,
        showCompactFixtureTvLogo: Bool
    ) {
        self.hasFantasyManagerEntry = hasFantasyManagerEntry
        self.showFantasyExpectedPoints = showFantasyExpectedPoints
        self.showFantasyRealTimePoints = showFantasyRealTimePoints
        self.showFantasyFixtureLogos = showFantasyFixtureLogos
        self.showCompactFixtureFantasyLogo = showCompactFixtureFantasyLogo
        self.showCompactFixtureTvLogo = showCompactFixtureTvLogo
    }
}

struct MatchRow: View {
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
    var showsFinishedInlineAggregateBrackets: Bool = false
    var layoutStyle: MatchRowLayoutStyle = .standard
    var fantasyContext: FantasyMatchRowContext = .empty
    var rowPreferences: MatchRowPreferences = .disabledFantasy
    var body: some View {
        matchCard
            .opacity(match.isPostponed ? 0.5 : 1.0)
    }

    private var matchCard: some View {
        Group {
            switch layoutStyle {
            case .standard:
                standardMatchCard
            case .compactFixture:
                compactFixtureMatchCard
            }
        }
    }

    private var standardMatchCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showLeague {
                Text(match.displayLeague)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 10) {
                    TeamLogo(
                        name: match.homeTeam,
                        alternateNames: [match.homeShortName].compactMap { $0 },
                        size: logoSize
                    )

                    HStack(alignment: .center, spacing: 8) {
                        Text(match.displayHomeTeam)
                            .font(teamNameFont)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .layoutPriority(1)

                        scoreAndStatusRow

                        Text(match.displayAwayTeam)
                            .font(teamNameFont)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
                    }
                    .frame(maxWidth: .infinity)

                    TeamLogo(
                        name: match.awayTeam,
                        alternateNames: [match.awayShortName].compactMap { $0 },
                        size: logoSize
                    )
                }
                .frame(maxWidth: .infinity)

                if !shouldShowInlineAggregateBrackets, let winnerSummaryText = match.winnerSummaryText {
                    Text(winnerSummaryText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 2)
                } else if !shouldShowInlineAggregateBrackets,
                          let aggregateSummaryText = match.aggregateSummaryText {
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

                if let footerLabel = resolvedCenterFooterText, !footerLabel.isEmpty {
                    Text(footerLabel)
                        .font(centerFooterFont)
                        .fontWeight(.semibold)
                        .foregroundStyle(resolvedCenterFooterColor)
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

    private var compactFixtureMatchCard: some View {
        VStack(alignment: .leading, spacing: compactFixtureVerticalSpacing) {
            if showLeague {
                Text(match.displayLeague)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .center, spacing: compactFixtureHorizontalSpacing) {
                TeamLogo(
                    name: match.homeTeam,
                    alternateNames: [match.homeShortName].compactMap { $0 },
                    size: logoSize
                )

                Text(match.displayHomeTeam)
                    .font(teamNameFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .layoutPriority(1)

                compactFixtureCenterContent

                Text(match.displayAwayTeam)
                    .font(teamNameFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                TeamLogo(
                    name: match.awayTeam,
                    alternateNames: [match.awayShortName].compactMap { $0 },
                    size: logoSize
                )

                compactFixtureTrailingAccessory
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
        if match.isPostponed {
            return "P"
        }
        return match.homeScore.map(String.init)
    }

    private var awayScoreText: String? {
        if match.isPostponed {
            return "P"
        }
        return match.awayScore.map(String.init)
    }

    private var centerStatusText: String {
        if match.isPostponed {
            return match.time
        }
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

    private var shouldShowFantasyParticipationBadge: Bool {
        fantasyParticipationBadgeVisibility(
            for: match,
            showFantasyBadge: showFantasyBadge,
            layoutStyle: layoutStyle,
            rowPreferences: rowPreferences,
            fantasyContext: fantasyContext
        )
    }

    private var fantasyPlayerContributions: [FantasyMatchContributionDisplay] {
        guard showFantasyPlayerContributions,
              !match.isPostponed,
              rowPreferences.hasFantasyManagerEntry,
              fantasyContext.isEligibleFixture(match),
              let lookup = fantasyContext.lookup
        else {
            return []
        }

        let shouldShowExpectedPoints = match.isUpcomingScorelessFixture &&
            rowPreferences.showFantasyExpectedPoints &&
            lookup.hasExpectedPoints
        let shouldShowRealTimePoints = match.isInProgress && rowPreferences.showFantasyRealTimePoints

        guard shouldShowExpectedPoints || shouldShowRealTimePoints else {
            return []
        }

        return lookup.involvedPlayers(
            in: match,
            preferExpectedPoints: shouldShowExpectedPoints
        )
    }

    private var shouldShowFooterRow: Bool {
        if match.isPostponed {
            return false
        }
        return (showBroadcastDetails && !isMatchFinished) ||
        shouldShowFantasyParticipationBadge ||
        !fantasyPlayerContributions.isEmpty
    }

    private var resolvedCenterFooterText: String? {
        if match.isPostponed {
            return "Match postponed"
        }
        return centerFooterText
    }

    private var resolvedCenterFooterColor: Color {
        match.isPostponed ? .secondary : centerFooterColor
    }

    @ViewBuilder
    private var footerRow: some View {
        HStack(alignment: .center, spacing: 8) {
            footerLeadingContent

            if showBroadcastDetails && !isMatchFinished {
                TvLogoRow(channels: match.tvChannels)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if shouldShowFantasyParticipationBadge {
                FantasyMatchParticipationBadge()
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
            if let aggregateHomeBracketText {
                Text(aggregateHomeBracketText)
                    .font(aggregateBracketFont)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }

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

            if let aggregateAwayBracketText {
                Text(aggregateAwayBracketText)
                    .font(aggregateBracketFont)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var aggregateHomeBracketText: String? {
        guard shouldShowInlineAggregateBrackets,
              let aggregateHomeScore = match.resolvedAggregateHomeScore else {
            return nil
        }
        return "(\(aggregateHomeScore))"
    }

    private var aggregateAwayBracketText: String? {
        guard shouldShowInlineAggregateBrackets,
              let aggregateAwayScore = match.resolvedAggregateAwayScore else {
            return nil
        }
        return "(\(aggregateAwayScore))"
    }

    static func shouldShowInlineAggregateBrackets(
        match: Match,
        layoutStyle: MatchRowLayoutStyle,
        showsFinishedInlineAggregateBrackets: Bool
    ) -> Bool {
        if match.shouldShowAggregateBracketScoresInline {
            return true
        }

        return (layoutStyle == .compactFixture || showsFinishedInlineAggregateBrackets) &&
        (match.isFinished || match.isInProgress) &&
        match.hasDisplayableAggregateScore
    }

    private var shouldShowInlineAggregateBrackets: Bool {
        Self.shouldShowInlineAggregateBrackets(
            match: match,
            layoutStyle: layoutStyle,
            showsFinishedInlineAggregateBrackets: showsFinishedInlineAggregateBrackets
        )
    }

    private var teamNameFont: Font {
        if isLargePresentation {
            return .caption
        }
        switch layoutStyle {
        case .standard:
            return .subheadline
        case .compactFixture:
            return .subheadline
        }
    }

    private var centerFooterFont: Font {
        isLargePresentation ? .caption : .caption2
    }

    private var scoreFont: Font {
        if isLargePresentation {
            return .caption
        }
        switch layoutStyle {
        case .standard:
            return .headline
        case .compactFixture:
            return .headline
        }
    }

    private var aggregateBracketFont: Font {
        if isLargePresentation {
            return .caption2
        }
        switch layoutStyle {
        case .standard:
            return .caption
        case .compactFixture:
            return .caption
        }
    }

    private var logoSize: CGFloat {
        let baseSize: CGFloat
        if isLargePresentation {
            baseSize = 34
        } else {
            switch layoutStyle {
            case .standard:
                baseSize = 22
            case .compactFixture:
                baseSize = 20
            }
        }
        return baseSize * teamLogoScale
    }

    private var cardPadding: CGFloat {
        if isLargePresentation {
            return 16
        }
        switch layoutStyle {
        case .standard:
            return 12
        case .compactFixture:
            return 8
        }
    }

    private var cardCornerRadius: CGFloat {
        isLargePresentation ? 18 : 14
    }

    private var primaryBroadcastLogo: UIImage? {
        TvLogoResolver.shared.images(for: match.tvChannels).first
    }

    private var compactBroadcastLogoHeight: CGFloat {
        isLargePresentation ? 16 : 13
    }

    private var compactBroadcastLogoWidth: CGFloat {
        isLargePresentation ? 26 : 22
    }

    private var compactAccessorySlotWidth: CGFloat {
        20
    }

    private var compactAccessorySlotHeight: CGFloat {
        20
    }

    private var compactBroadcastAccessorySlot: some View {
        ZStack {
            if let compactPrimaryBroadcastLogo {
                Image(uiImage: compactPrimaryBroadcastLogo)
                    .resizable()
                    .scaledToFit()
                    .frame(width: compactBroadcastLogoWidth, height: compactBroadcastLogoHeight)
                    .opacity(compactBroadcastLogoOpacity)
                    .layoutPriority(2)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
        }
        .frame(
            width: compactPrimaryBroadcastLogo == nil ? 0 : compactAccessorySlotWidth,
            height: compactAccessorySlotHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    private var compactFixtureCenterContent: some View {
        if shouldPlaceCompactKickoffInTrailingAccessory {
            if match.isPostponed {
                compactPostponedCenterAccessory
            } else if match.isInProgress {
                compactInProgressCenterAccessory
            } else if match.isFinished {
                compactFinishedCenterAccessory
            } else {
                compactUpcomingCenterAccessory
            }
        } else {
            scoreAndStatusRow
        }
    }

    @ViewBuilder
    private var compactFixtureTrailingAccessory: some View {
        if shouldPlaceCompactKickoffInTrailingAccessory {
            compactStatusAccessorySlot
        } else {
            compactBroadcastAccessorySlot
        }
    }

    private var compactUpcomingCenterAccessory: some View {
        HStack(spacing: 4) {
            if let aggregateHomeBracketText {
                Text(aggregateHomeBracketText)
                    .font(aggregateBracketFont)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }

            compactCenteredBroadcastAccessory

            if let aggregateAwayBracketText {
                Text(aggregateAwayBracketText)
                    .font(aggregateBracketFont)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var compactCenteredBroadcastAccessory: some View {
        ZStack {
            if let compactPrimaryBroadcastLogo {
                Image(uiImage: compactPrimaryBroadcastLogo)
                    .resizable()
                    .scaledToFit()
                    .frame(width: compactBroadcastLogoWidth, height: compactBroadcastLogoHeight)
                    .opacity(compactBroadcastLogoOpacity)
                    .layoutPriority(2)
                    .fixedSize()
                    .accessibilityHidden(true)
            } else {
                Text("vs")
                    .font(compactCenterPlaceholderFont)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary.opacity(0.7))
                    .textCase(.lowercase)
                    .fixedSize()
            }
        }
        .frame(minWidth: compactBroadcastLogoWidth, minHeight: compactAccessorySlotHeight, alignment: .center)
    }

    private var compactBroadcastLogoOpacity: Double {
        match.isFinished ? 0.4 : 1.0
    }

    private var compactStatusAccessorySlot: some View {
        Group {
            if match.isInProgress {
                MatchTimeStatusView(
                    text: centerStatusText,
                    isLive: true,
                    isLargePresentation: false
                )
                .fixedSize(horizontal: true, vertical: false)
            } else {
                Text(compactTrailingAccessoryText)
                    .font(compactKickoffAccessoryFont)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(width: compactStatusAccessoryWidth, alignment: compactStatusAccessoryAlignment)
        .frame(height: compactAccessorySlotHeight, alignment: compactStatusAccessoryAlignment)
        .layoutPriority(2)
    }

    private var compactInProgressCenterAccessory: some View {
        HStack(spacing: 8) {
            if let aggregateHomeBracketText {
                Text(aggregateHomeBracketText)
                    .font(aggregateBracketFont)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }

            if let homeScoreText {
                Text(homeScoreText)
                    .font(scoreFont)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .frame(minWidth: 14, alignment: .trailing)
            }

            compactCenteredBroadcastAccessory

            if let awayScoreText {
                Text(awayScoreText)
                    .font(scoreFont)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .frame(minWidth: 14, alignment: .leading)
            }

            if let aggregateAwayBracketText {
                Text(aggregateAwayBracketText)
                    .font(aggregateBracketFont)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var compactFinishedCenterAccessory: some View {
        HStack(spacing: 8) {
            if let aggregateHomeBracketText {
                Text(aggregateHomeBracketText)
                    .font(aggregateBracketFont)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }

            if let homeScoreText {
                Text(homeScoreText)
                    .font(scoreFont)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .frame(minWidth: 14, alignment: .trailing)
            }

            Text("-")
                .font(compactCenterScoreSeparatorFont)
                .fontWeight(.medium)
                .foregroundStyle(.secondary.opacity(0.65))
                .fixedSize()

            if let awayScoreText {
                Text(awayScoreText)
                    .font(scoreFont)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .frame(minWidth: 14, alignment: .leading)
            }

            if let aggregateAwayBracketText {
                Text(aggregateAwayBracketText)
                    .font(aggregateBracketFont)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var compactPostponedCenterAccessory: some View {
        HStack(spacing: 8) {
            if let homeScoreText {
                Text(homeScoreText)
                    .font(scoreFont)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .frame(minWidth: 14, alignment: .trailing)
            }

            compactCenteredBroadcastAccessory

            if let awayScoreText {
                Text(awayScoreText)
                    .font(scoreFont)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .frame(minWidth: 14, alignment: .leading)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var compactTrailingAccessoryText: String {
        if match.isFinished {
            return match.displayScoreStatus ?? match.time
        }
        return match.time
    }

    private var compactPrimaryBroadcastLogo: UIImage? {
        guard rowPreferences.showCompactFixtureTvLogo else { return nil }
        return primaryBroadcastLogo
    }

    static func shouldPlaceCompactKickoffInTrailingAccessory(
        match: Match,
        hasCompactBroadcastLogo: Bool
    ) -> Bool {
        let _ = hasCompactBroadcastLogo
        if match.isPostponed || match.isFinished || match.isInProgress {
            return true
        }

        // Keep compact fixture rows stable even when kickoff metadata is incomplete
        // or the upstream status token is unknown. Upcoming no-score matches should
        // still reserve the center slot for TV branding and the trailing slot for kickoff.
        return !match.hasScore
    }

    private var shouldPlaceCompactKickoffInTrailingAccessory: Bool {
        Self.shouldPlaceCompactKickoffInTrailingAccessory(
            match: match,
            hasCompactBroadcastLogo: compactPrimaryBroadcastLogo != nil
        )
    }

    private var compactFixtureVerticalSpacing: CGFloat {
        8
    }

    private var compactFixtureHorizontalSpacing: CGFloat {
        6
    }

    private var compactStatusAccessoryWidth: CGFloat {
        62
    }

    private var compactStatusAccessoryAlignment: Alignment {
        match.isFinished ? .center : .trailing
    }

    private var compactCenterPlaceholderFont: Font {
        .caption2
    }

    private var compactCenterScoreSeparatorFont: Font {
        .caption
    }

    private var compactKickoffAccessoryFont: Font {
        .caption
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

func fantasyParticipationBadgeVisibility(
    for match: Match,
    showFantasyBadge: Bool,
    layoutStyle: MatchRowLayoutStyle,
    rowPreferences: MatchRowPreferences,
    fantasyContext: FantasyMatchRowContext
) -> Bool {
    guard showFantasyBadge,
          !match.isPostponed,
          rowPreferences.hasFantasyManagerEntry,
          isFantasyBadgeEnabled(
            for: layoutStyle,
            rowPreferences: rowPreferences
          ),
          fantasyContext.isEligibleFixture(match),
          let lookup = fantasyContext.lookup
    else {
        return false
    }

    return lookup.participationCount(in: match) > 0
}

func isFantasyBadgeEnabled(
    for layoutStyle: MatchRowLayoutStyle,
    rowPreferences: MatchRowPreferences
) -> Bool {
    switch layoutStyle {
    case .standard:
        return rowPreferences.showFantasyFixtureLogos
    case .compactFixture:
        return rowPreferences.showCompactFixtureFantasyLogo
    }
}

struct FantasyMatchParticipationBadge: View {
    var diameter: CGFloat = 28
    var iconSize: CGFloat = 14
    var iconScale: CGFloat = 1.10
    var shadowOpacity: Double = 0.18

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

            FantasyLionIconView(size: iconSize, scale: iconScale)
                .foregroundStyle(.white)
        }
            .frame(width: diameter, height: diameter)
            .shadow(color: Color.red.opacity(shadowOpacity), radius: 3, x: 0, y: 1)
            .accessibilityLabel("Fantasy players involved")
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
            .lineLimit(1)
            .minimumScaleFactor(0.9)
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


struct MatchLineupFantasySubstituteWarningIcon: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.19))
            .accessibilityLabel("Fantasy player listed as substitute")
            .accessibilityHint("This player is on the bench in the real match lineup")
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
        let homeKeys = fantasyTeamLookupKeys(match.homeTeam)
        let awayKeys = fantasyTeamLookupKeys(match.awayTeam)
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
    let cacheKey = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() as NSString
    if let cached = FantasyTeamLookupKeyCache.cache.object(forKey: cacheKey) {
        return Set(cached.allObjects.compactMap { $0 as? String })
    }

    let candidates = TeamIdentityStore.shared.names(for: value) + BundledTeamIdentityCatalog.shared.names(for: value)
    let resolved = Set(candidates.compactMap { candidate in
        let normalized = normalizeFantasyLookupName(candidate)
        return normalized.isEmpty ? nil : normalized
    })
    FantasyTeamLookupKeyCache.cache.setObject(resolved as NSSet, forKey: cacheKey)
    return resolved
}

private enum FantasyTeamLookupKeyCache {
    static let cache: NSCache<NSString, NSSet> = {
        let cache = NSCache<NSString, NSSet>()
        cache.countLimit = 256
        return cache
    }()
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

func condensedLineupPlayerName(_ value: String) -> String {
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
    var alternateNames: [String] = []
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let image = LogoResolver.shared.image(for: name, alternateNames: alternateNames) {
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


#Preview {
    MatchRow(match: Match(date: "2026-02-11", time: "19:45", homeTeam: "Arsenal", awayTeam: "Chelsea", league: "Premier League", tvChannels: ["NBC", "Peacock"]))
        .environmentObject(PreferencesStore())
        .environmentObject(FantasyViewModel())
        .padding()
}
