import ClockKit
import SwiftUI

struct MatchRectangularComplicationView: View {
    let match: WatchMatch?

    @ScaledMetric(relativeTo: .caption) private var nameFontSize: CGFloat = 13
    @ScaledMetric(relativeTo: .headline) private var scoreFontSize: CGFloat = 18
    @ScaledMetric(relativeTo: .caption) private var timeFontSize: CGFloat = 13

    private let homeLogo: UIImage?
    private let awayLogo: UIImage?
    private let channelLogo: UIImage?
    private let statusText: String
    private let accessibilityText: String

    init(match: WatchMatch?) {
        self.match = match
        homeLogo = match.flatMap {
            WatchTeamLogoResolver.shared.image(
                for: $0.homeTeam,
                teamId: $0.homeTeamId,
                alternateNames: [$0.homeShortName].compactMap { $0 }
            )
        }
        awayLogo = match.flatMap {
            WatchTeamLogoResolver.shared.image(
                for: $0.awayTeam,
                teamId: $0.awayTeamId,
                alternateNames: [$0.awayShortName].compactMap { $0 }
            )
        }
        let primaryBroadcast = match.flatMap {
            WatchTvLogoResolver.shared.primaryResolvedLogo(for: $0.tvChannels)
        }
        channelLogo = primaryBroadcast?.image

        if let match {
            let kickoff = match.dateTime?.formatted(date: .omitted, time: .shortened) ?? match.time
            statusText = match.displayScoreStatus.flatMap { $0.isEmpty ? nil : $0 } ?? kickoff
            let score: String
            if let homeScore = match.homeScore, let awayScore = match.awayScore {
                score = ", \(homeScore) to \(awayScore)"
            } else {
                score = ""
            }
            let broadcast = primaryBroadcast.map { ", on \($0.channel)" } ?? ""
            accessibilityText = "\(match.homeTeam) versus \(match.awayTeam)\(score), \(statusText)\(broadcast)"
        } else {
            statusText = ""
            accessibilityText = "No matches today"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            if let match {
                // Scale from the smallest complication's 150-point safe area.
                let scale = geometry.size.width / 150
                HStack(alignment: .bottom, spacing: 6 * scale) {
                    VStack(spacing: 6 * scale) {
                        HStack(spacing: 4 * scale) {
                            teamName(match.displayHomeTeam, alignment: .leading, scale: scale)
                            teamName(match.displayAwayTeam, alignment: .trailing, scale: scale)
                        }
                        .frame(height: 18 * scale)

                        HStack(spacing: 0) {
                            logo(homeLogo, width: 24 * scale, height: 26 * scale, alignment: .leading)
                            Spacer(minLength: 0)
                            score(match.homeScore, visible: match.hasScore, scale: scale)
                            logo(channelLogo, width: 20 * scale, height: 24 * scale, alignment: .center)
                                .padding(.horizontal, 2 * scale)
                            score(match.awayScore, visible: match.hasScore, scale: scale)
                            Spacer(minLength: 0)
                            logo(awayLogo, width: 24 * scale, height: 26 * scale, alignment: .trailing)
                        }
                        .frame(height: 26 * scale)
                    }

                    Text(statusText)
                        .font(.system(size: min(timeFontSize, 18) * scale, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(width: 34 * scale, height: 26 * scale, alignment: .trailing)
                }
                .frame(height: geometry.size.height)
            } else {
                Text("No matches today")
                    .font(.caption.weight(.medium))
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        // ClockKit snapshots can use a light colour scheme on a dark watch face.
        .foregroundColor(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func teamName(_ name: String, alignment: Alignment, scale: CGFloat) -> some View {
        Text(name)
            .font(.system(size: nameFontSize * scale, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func score(_ value: Int?, visible: Bool, scale: CGFloat) -> some View {
        Text(visible ? value.map(String.init) ?? "–" : "")
            .font(.system(size: min(scoreFontSize, 24) * scale, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: 18 * scale, height: 26 * scale)
    }

    private func logo(_ image: UIImage?, width: CGFloat, height: CGFloat, alignment: Alignment) -> some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: width, height: height, alignment: alignment)
    }

    // Used by the complication picker before the watch receives match data.
    static let sampleMatch = try? JSONDecoder().decode(WatchMatch.self, from: Data("""
        {
            "date": "2026-09-14", "time": "20:00", "league": "Premier League",
            "home_team": "Leeds United", "away_team": "Newcastle United",
            "home_short_name": "Leeds", "away_short_name": "Newcastle",
            "tv_channels": ["Sky Sports Main Event", "Sky Sports Football"]
        }
        """.utf8))
}

#if DEBUG
private let liveComplicationPreviewMatch = try? JSONDecoder().decode(WatchMatch.self, from: Data("""
    {
        "date": "2026-09-14", "time": "20:00", "league": "Premier League",
        "home_team": "Leeds United", "away_team": "Newcastle United",
        "home_short_name": "Leeds", "away_short_name": "Newcastle",
        "tv_channels": ["Sky Sports Main Event"],
        "home_score": 2, "away_score": 1, "score_status": "67"
    }
    """.utf8))

#Preview("Upcoming · 40 mm") {
    MatchRectangularComplicationView(match: MatchRectangularComplicationView.sampleMatch)
        .frame(width: 150, height: 57)
        .padding(6)
        .background(.black)
        .environment(\.colorScheme, .dark)
}

#Preview("ClockKit · upcoming") {
    CLKComplicationTemplateGraphicRectangularFullView(
        MatchRectangularComplicationView(match: MatchRectangularComplicationView.sampleMatch)
    ).previewContext()
}

#Preview("ClockKit · live · tinted") {
    CLKComplicationTemplateGraphicRectangularFullView(
        MatchRectangularComplicationView(match: liveComplicationPreviewMatch)
    ).previewContext(faceColor: .blue)
}

#Preview("Light snapshot environment") {
    MatchRectangularComplicationView(match: MatchRectangularComplicationView.sampleMatch)
        .frame(width: 150, height: 57)
        .padding(6)
        .background(.black)
        .environment(\.colorScheme, .light)
}

#Preview("Live · 45 mm") {
    MatchRectangularComplicationView(match: liveComplicationPreviewMatch)
        .frame(width: 179, height: 68)
        .padding(7)
        .background(.black)
        .environment(\.colorScheme, .dark)
}

#Preview("Live · larger text") {
    MatchRectangularComplicationView(match: liveComplicationPreviewMatch)
        .environment(\.dynamicTypeSize, .accessibility1)
        .frame(width: 150, height: 57)
        .padding(6)
        .background(.black)
        .environment(\.colorScheme, .dark)
}

#Preview("No matches") {
    MatchRectangularComplicationView(match: nil)
        .frame(width: 150, height: 57)
        .padding(6)
        .background(.black)
        .environment(\.colorScheme, .dark)
}
#endif
