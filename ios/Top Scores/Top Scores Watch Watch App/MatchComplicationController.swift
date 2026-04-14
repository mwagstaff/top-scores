import ClockKit
import Foundation
import UIKit

final class MatchComplicationController: NSObject, CLKComplicationDataSource {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private let closedGaugeDescriptorIdentifier = "today-matches"
    private let openGaugeDescriptorIdentifier = "today-matches-open"
    private let colorfulOpenGaugeDescriptorIdentifier = "today-matches-open-color"
    private let rectangularDescriptorIdentifier = "today-matches-rectangular"
    private let fallbackRectangularSize = CGSize(width: 300, height: 140)
    private let matchTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone.current
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    func getComplicationDescriptors(handler: @escaping ([CLKComplicationDescriptor]) -> Void) {
        let closedGaugeDescriptor = CLKComplicationDescriptor(
            identifier: closedGaugeDescriptorIdentifier,
            displayName: "Top Scores",
            supportedFamilies: [.graphicCircular]
        )
        let openGaugeDescriptor = CLKComplicationDescriptor(
            identifier: openGaugeDescriptorIdentifier,
            displayName: "Top Scores Open",
            supportedFamilies: [.graphicCircular]
        )
        let colorfulOpenGaugeDescriptor = CLKComplicationDescriptor(
            identifier: colorfulOpenGaugeDescriptorIdentifier,
            displayName: "Top Scores Color",
            supportedFamilies: [.graphicCircular]
        )
        let rectangularDescriptor = CLKComplicationDescriptor(
            identifier: rectangularDescriptorIdentifier,
            displayName: "Top Scores Rect",
            supportedFamilies: [.graphicRectangular]
        )
        handler([closedGaugeDescriptor, openGaugeDescriptor, colorfulOpenGaugeDescriptor, rectangularDescriptor])
    }

    func handleSharedComplicationDescriptors(_ complicationDescriptors: [CLKComplicationDescriptor]) {}

    func getCurrentTimelineEntry(
        for complication: CLKComplication,
        withHandler handler: @escaping (CLKComplicationTimelineEntry?) -> Void
    ) {
        handler(makeEntry(for: Date(), complication: complication))
    }

    func getTimelineStartDate(for complication: CLKComplication, withHandler handler: @escaping (Date?) -> Void) {
        handler(nil)
    }

    func getTimelineEndDate(for complication: CLKComplication, withHandler handler: @escaping (Date?) -> Void) {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())
        handler(tomorrow)
    }

    func getSupportedTimeTravelDirections(
        for complication: CLKComplication,
        withHandler handler: @escaping (CLKComplicationTimeTravelDirections) -> Void
    ) {
        handler([])
    }

    func getTimelineEntries(
        for complication: CLKComplication,
        after date: Date,
        limit: Int,
        withHandler handler: @escaping ([CLKComplicationTimelineEntry]?) -> Void
    ) {
        guard limit > 0,
              let nextMidnight = Calendar.current.nextDate(
                after: date,
                matching: DateComponents(hour: 0, minute: 0, second: 0),
                matchingPolicy: .nextTime
              ),
              let entry = makeEntry(for: nextMidnight, complication: complication)
        else {
            handler(nil)
            return
        }

        handler([entry])
    }

    func getNextRequestedUpdateDate(handler: @escaping (Date?) -> Void) {
        handler(Date().addingTimeInterval(15 * 60))
    }

    func getLocalizableSampleTemplate(
        for complication: CLKComplication,
        withHandler handler: @escaping (CLKComplicationTemplate?) -> Void
    ) {
        handler(makeTemplate(for: complication, count: 4, todaysMatches: [], date: Date()))
    }

    func getPrivacyBehavior(
        for complication: CLKComplication,
        withHandler handler: @escaping (CLKComplicationPrivacyBehavior) -> Void
    ) {
        handler(.showOnLockScreen)
    }

    private func makeEntry(for date: Date, complication: CLKComplication) -> CLKComplicationTimelineEntry? {
        let matches = loadMatches()
        let todaysMatches = todaysMatches(in: matches, on: date)
        let count = todaysMatches.count
        guard let template = makeTemplate(
            for: complication,
            count: count,
            todaysMatches: todaysMatches,
            date: date
        ) else { return nil }
        return CLKComplicationTimelineEntry(date: date, complicationTemplate: template)
    }

    private func makeTemplate(
        for complication: CLKComplication,
        count: Int,
        todaysMatches: [WatchMatch],
        date: Date
    ) -> CLKComplicationTemplate? {
        switch complication.family {
        case .graphicCircular:
            if usesColorfulOpenGaugeTemplate(for: complication) {
                return makeColorfulOpenGaugeTemplate(count: count)
            }
            if usesOpenGaugeTemplate(for: complication) {
                return makeOpenGaugeTemplate(count: count)
            }
            return makeClosedGaugeTemplate(count: count)
        case .graphicRectangular:
            return makeRectangularTemplate(count: count, todaysMatches: todaysMatches, date: date)
        default:
            return nil
        }
    }

    private func makeClosedGaugeTemplate(count: Int) -> CLKComplicationTemplateGraphicCircularClosedGaugeText {
        let clampedCount = max(0, min(10, count))
        let gaugeProvider = CLKSimpleGaugeProvider(
            style: .ring,
            gaugeColor: pitchColor(for: clampedCount),
            fillFraction: Float(clampedCount) / 10.0
        )
        let centerText = CLKSimpleTextProvider(text: footballText(for: count))
        return CLKComplicationTemplateGraphicCircularClosedGaugeText(
            gaugeProvider: gaugeProvider,
            centerTextProvider: centerText
        )
    }

    private func makeOpenGaugeTemplate(count: Int) -> CLKComplicationTemplateGraphicCircularOpenGaugeSimpleText {
        let clampedCount = max(0, min(10, count))
        let gaugeProvider = CLKSimpleGaugeProvider(
            style: .ring,
            gaugeColor: openGaugeColor(for: clampedCount),
            fillFraction: Float(clampedCount) / 10.0
        )
        let bottomFootball = CLKSimpleTextProvider(text: "\u{26BD}\u{FE0E}")
        bottomFootball.tintColor = UIColor(white: 0.97, alpha: 1.0)
        let centerText = CLKSimpleTextProvider(text: centerCountText(for: count))
        centerText.tintColor = UIColor(white: 0.97, alpha: 1.0)

        return CLKComplicationTemplateGraphicCircularOpenGaugeSimpleText(
            gaugeProvider: gaugeProvider,
            bottomTextProvider: bottomFootball,
            centerTextProvider: centerText
        )
    }

    private func makeColorfulOpenGaugeTemplate(count: Int) -> CLKComplicationTemplateGraphicCircularOpenGaugeSimpleText {
        let clampedCount = max(0, min(10, count))
        let gaugeProvider = CLKSimpleGaugeProvider(
            style: .ring,
            gaugeColors: colorfulGaugeStops(),
            gaugeColorLocations: colorfulGaugeLocations(),
            fillFraction: Float(clampedCount) / 10.0
        )
        let bottomFootball = CLKSimpleTextProvider(text: "\u{26BD}\u{FE0E}")
        let centerText = CLKSimpleTextProvider(text: centerCountText(for: count))

        return CLKComplicationTemplateGraphicCircularOpenGaugeSimpleText(
            gaugeProvider: gaugeProvider,
            bottomTextProvider: bottomFootball,
            centerTextProvider: centerText
        )
    }

    private func makeRectangularTemplate(
        count: Int,
        todaysMatches: [WatchMatch],
        date: Date
    ) -> CLKComplicationTemplateGraphicRectangularFullImage {
        let featuredMatch = featuredMatch(for: date, todaysMatches: todaysMatches)
        let image = makeRectangularComplicationImage(
            count: count,
            featuredMatch: featuredMatch
        )
        let imageProvider = CLKFullColorImageProvider(fullColorImage: image)
        return CLKComplicationTemplateGraphicRectangularFullImage(imageProvider: imageProvider)
    }

    private func loadMatches() -> [WatchMatch] {
        guard let data = loadRawPayloadData(),
              let payload = try? decoder.decode(WatchSharedMatchesPayload.self, from: data)
        else {
            return []
        }
        return payload.matches
    }

    private func todaysMatches(in matches: [WatchMatch], on date: Date) -> [WatchMatch] {
        let calendar = Calendar.current
        return matches.filter { match in
            guard let matchDate = WatchMatchDateParser.shared.parse(date: match.date, time: "00:00") else {
                return false
            }
            return calendar.isDate(matchDate, inSameDayAs: date)
        }
    }

    private func featuredMatch(for date: Date, todaysMatches: [WatchMatch]) -> WatchMatch? {
        guard !todaysMatches.isEmpty else { return nil }

        let sorted = WatchMatchGrouping.sortedMatches(todaysMatches)
        let now = date

        if let next = sorted.first(where: { match in
            guard let kickoff = match.dateTime else { return false }
            return kickoff > now && !match.isInProgress
        }) {
            return next
        }

        let allInProgress = sorted.allSatisfy(\.isInProgress)
        if allInProgress {
            return sorted.max { lhs, rhs in
                (lhs.dateTime ?? .distantPast) < (rhs.dateTime ?? .distantPast)
            }
        }

        if let inProgressLatest = sorted
            .filter(\.isInProgress)
            .max(by: { lhs, rhs in
                (lhs.dateTime ?? .distantPast) < (rhs.dateTime ?? .distantPast)
            }) {
            return inProgressLatest
        }

        return sorted.first
    }

    private func makeRectangularComplicationImage(
        count: Int,
        featuredMatch: WatchMatch?
    ) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(fallbackRectangularSize, false, 0)
        defer { UIGraphicsEndImageContext() }

        let bounds = CGRect(origin: .zero, size: fallbackRectangularSize)
        UIColor.clear.setFill()
        UIRectFill(bounds)

        drawTopRow(count: count, featuredMatch: featuredMatch, in: bounds)
        drawTeamNamesRow(featuredMatch: featuredMatch, in: bounds)
        drawBottomRow(featuredMatch: featuredMatch, in: bounds)

        return UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
    }

    private func drawTopRow(count: Int, featuredMatch: WatchMatch?, in bounds: CGRect) {
        let topY: CGFloat = 14
        let countText = centerCountText(for: count)
        let matchWord = count == 1 ? "match" : "matches"
        let topText = "\u{26BD}\u{FE0E} \(countText) \(matchWord) today"
        let tvLogos = topRowTvLogos(for: featuredMatch)
        let logoHeight: CGFloat = 18
        let logoSpacing: CGFloat = 4
        let logoCount = tvLogos.count
        let logosWidth = logoCount > 0
            ? (CGFloat(logoCount) * logoHeight) + (CGFloat(logoCount - 1) * logoSpacing)
            : 0
        let logoGapFromText: CGFloat = logoCount > 0 ? 8 : 0
        let topTextWidth = bounds.width - 32 - logosWidth - logoGapFromText

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: UIColor(white: 0.97, alpha: 1.0),
            .paragraphStyle: paragraph
        ]
        let topRect = CGRect(x: 16, y: topY, width: max(0, topTextWidth), height: 28)
        topText.draw(in: topRect, withAttributes: attrs)

        guard !tvLogos.isEmpty else { return }

        let logosStartX = bounds.width - 16 - logosWidth
        let logoY = topY + ((28 - logoHeight) / 2)
        for (index, logo) in tvLogos.enumerated() {
            let x = logosStartX + (CGFloat(index) * (logoHeight + logoSpacing))
            let frame = CGRect(x: x, y: logoY, width: logoHeight, height: logoHeight)
            drawTvLogoTile(logo, in: frame)
        }
    }

    private func drawTeamNamesRow(featuredMatch: WatchMatch?, in bounds: CGRect) {
        guard let featuredMatch else { return }

        let rowRect = CGRect(x: 16, y: 48, width: bounds.width - 32, height: 22)
        let leftRect = CGRect(x: rowRect.minX, y: rowRect.minY, width: (rowRect.width / 2) - 6, height: rowRect.height)
        let rightRect = CGRect(x: rowRect.midX + 6, y: rowRect.minY, width: (rowRect.width / 2) - 6, height: rowRect.height)

        let leftParagraph = NSMutableParagraphStyle()
        leftParagraph.alignment = .left
        leftParagraph.lineBreakMode = .byTruncatingTail
        let rightParagraph = NSMutableParagraphStyle()
        rightParagraph.alignment = .right
        rightParagraph.lineBreakMode = .byTruncatingTail

        let leftAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16, weight: .medium),
            .foregroundColor: UIColor(white: 0.90, alpha: 1.0),
            .paragraphStyle: leftParagraph
        ]
        let rightAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16, weight: .medium),
            .foregroundColor: UIColor(white: 0.90, alpha: 1.0),
            .paragraphStyle: rightParagraph
        ]

        (featuredMatch.displayHomeTeam as NSString).draw(in: leftRect, withAttributes: leftAttrs)
        (featuredMatch.displayAwayTeam as NSString).draw(in: rightRect, withAttributes: rightAttrs)
    }

    private func drawBottomRow(featuredMatch: WatchMatch?, in bounds: CGRect) {
        let rowRect = CGRect(x: 12, y: 76, width: bounds.width - 24, height: 54)
        guard let featuredMatch else {
            let emptyText = "No matches today"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20, weight: .regular),
                .foregroundColor: UIColor(white: 0.90, alpha: 1.0)
            ]
            let size = emptyText.size(withAttributes: attrs)
            let point = CGPoint(
                x: rowRect.midX - (size.width / 2),
                y: rowRect.midY - (size.height / 2)
            )
            emptyText.draw(at: point, withAttributes: attrs)
            return
        }

        let logoSize: CGFloat = 34
        let centerY = rowRect.midY
        let leftLogoFrame = CGRect(
            x: rowRect.minX + 8,
            y: centerY - (logoSize / 2),
            width: logoSize,
            height: logoSize
        )
        let rightLogoFrame = CGRect(
            x: rowRect.maxX - logoSize - 8,
            y: centerY - (logoSize / 2),
            width: logoSize,
            height: logoSize
        )

        let homeLogo = WatchTeamLogoResolver.shared.image(for: featuredMatch.homeTeam)
        let awayLogo = WatchTeamLogoResolver.shared.image(for: featuredMatch.awayTeam)
        drawLogo(homeLogo, in: leftLogoFrame)
        drawLogo(awayLogo, in: rightLogoFrame)

        let centerText = kickoffOrScoreText(for: featuredMatch)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 21, weight: .semibold),
            .foregroundColor: UIColor(white: 0.97, alpha: 1.0)
        ]
        let textSize = centerText.size(withAttributes: textAttrs)
        let textRect = CGRect(
            x: rowRect.midX - (textSize.width / 2),
            y: rowRect.midY - (textSize.height / 2),
            width: textSize.width,
            height: textSize.height
        )
        centerText.draw(in: textRect, withAttributes: textAttrs)
    }

    private func drawLogo(_ image: UIImage?, in frame: CGRect) {
        guard let image else { return }
        UIGraphicsGetCurrentContext()?.saveGState()
        let clipPath = UIBezierPath(roundedRect: frame, cornerRadius: 6)
        clipPath.addClip()
        image.draw(in: frame)
        UIGraphicsGetCurrentContext()?.restoreGState()
    }

    private func drawTvLogoTile(_ image: UIImage?, in frame: CGRect) {
        guard let image else { return }

        UIGraphicsGetCurrentContext()?.saveGState()
        let tilePath = UIBezierPath(roundedRect: frame, cornerRadius: 4)
        UIColor(white: 0.10, alpha: 0.70).setFill()
        tilePath.fill()
        tilePath.addClip()

        let insetFrame = frame.insetBy(dx: 2, dy: 2)
        let drawRect = aspectFitRect(for: image.size, in: insetFrame)
        image.draw(in: drawRect)
        UIGraphicsGetCurrentContext()?.restoreGState()
    }

    private func aspectFitRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }

        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        let x = bounds.midX - (width / 2)
        let y = bounds.midY - (height / 2)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func topRowTvLogos(for featuredMatch: WatchMatch?) -> [UIImage] {
        guard let featuredMatch else { return [] }
        let channels = uniqueSortedChannels(featuredMatch.tvChannels)
        guard !channels.isEmpty else { return [] }

        let resolved = WatchTvLogoResolver.shared.images(for: channels)
        return Array(resolved.prefix(3))
    }

    private func uniqueSortedChannels(_ channels: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []

        for value in channels {
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

    private func colorfulGaugeStops() -> [UIColor] {
        [
            UIColor(red: 0.31, green: 0.92, blue: 0.33, alpha: 1.0),
            UIColor(red: 0.98, green: 0.87, blue: 0.17, alpha: 1.0),
            UIColor(red: 0.98, green: 0.53, blue: 0.20, alpha: 1.0),
            UIColor(red: 0.92, green: 0.25, blue: 0.78, alpha: 1.0),
            UIColor(red: 0.45, green: 0.24, blue: 0.95, alpha: 1.0)
        ]
    }

    private func colorfulGaugeLocations() -> [NSNumber] {
        [0.0, 0.25, 0.5, 0.75, 1.0]
    }

    private func kickoffOrScoreText(for match: WatchMatch) -> String {
        if let scoreLine = match.scoreLine {
            return scoreLine
        }
        guard let date = match.dateTime else { return match.time }
        return matchTimeFormatter.string(from: date)
    }

    private func loadRawPayloadData() -> Data? {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: WatchAppGroupConfig.identifier)?
            .appendingPathComponent(WatchAppGroupConfig.sharedMatchesFileName)
        else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    private func footballText(for count: Int) -> String {
        let clampedCount = max(0, count)
        let footballGlyph = "\u{26BD}\u{FE0E}"
        if clampedCount == 0 {
            return "0"
        }
        if clampedCount > 9 {
            return "9+"
        }
        return "\(footballGlyph)\(clampedCount)"
    }

    private func centerCountText(for count: Int) -> String {
        let clampedCount = max(0, count)
        if clampedCount > 9 {
            return "9+"
        }
        return "\(clampedCount)"
    }

    private func usesOpenGaugeTemplate(for complication: CLKComplication) -> Bool {
        complication.identifier == openGaugeDescriptorIdentifier
    }

    private func usesColorfulOpenGaugeTemplate(for complication: CLKComplication) -> Bool {
        complication.identifier == colorfulOpenGaugeDescriptorIdentifier
    }

    private func pitchColor(for count: Int) -> UIColor {
        let value = CGFloat(max(0, min(10, count))) / 10.0
        let stops: [(CGFloat, UIColor)] = [
            (0.00, UIColor(red: 0.15, green: 0.45, blue: 0.22, alpha: 1.0)),
            (0.40, UIColor(red: 0.19, green: 0.56, blue: 0.26, alpha: 1.0)),
            (0.65, UIColor(red: 0.82, green: 0.68, blue: 0.20, alpha: 1.0)),
            (0.85, UIColor(red: 0.90, green: 0.47, blue: 0.12, alpha: 1.0)),
            (1.00, UIColor(red: 0.78, green: 0.22, blue: 0.18, alpha: 1.0))
        ]

        for index in 0..<(stops.count - 1) {
            let start = stops[index]
            let end = stops[index + 1]
            guard value >= start.0, value <= end.0 else { continue }
            let localT = (value - start.0) / (end.0 - start.0)
            return interpolateColor(from: start.1, to: end.1, progress: localT)
        }

        return stops.last?.1 ?? UIColor(red: 0.78, green: 0.22, blue: 0.18, alpha: 1.0)
    }

    private func openGaugeColor(for count: Int) -> UIColor {
        let value = CGFloat(max(0, min(10, count))) / 10.0
        let stops: [(CGFloat, UIColor)] = [
            (0.00, UIColor(red: 0.14, green: 0.56, blue: 0.24, alpha: 1.0)),
            (0.55, UIColor(red: 0.92, green: 0.94, blue: 0.92, alpha: 1.0)),
            (1.00, UIColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 1.0))
        ]

        for index in 0..<(stops.count - 1) {
            let start = stops[index]
            let end = stops[index + 1]
            guard value >= start.0, value <= end.0 else { continue }
            let localT = (value - start.0) / (end.0 - start.0)
            return interpolateColor(from: start.1, to: end.1, progress: localT)
        }

        return stops.last?.1 ?? UIColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 1.0)
    }

    private func interpolateColor(from: UIColor, to: UIColor, progress: CGFloat) -> UIColor {
        var fromRed: CGFloat = 0
        var fromGreen: CGFloat = 0
        var fromBlue: CGFloat = 0
        var fromAlpha: CGFloat = 0
        var toRed: CGFloat = 0
        var toGreen: CGFloat = 0
        var toBlue: CGFloat = 0
        var toAlpha: CGFloat = 0

        from.getRed(&fromRed, green: &fromGreen, blue: &fromBlue, alpha: &fromAlpha)
        to.getRed(&toRed, green: &toGreen, blue: &toBlue, alpha: &toAlpha)

        return UIColor(
            red: fromRed + ((toRed - fromRed) * progress),
            green: fromGreen + ((toGreen - fromGreen) * progress),
            blue: fromBlue + ((toBlue - fromBlue) * progress),
            alpha: fromAlpha + ((toAlpha - fromAlpha) * progress)
        )
    }
}
