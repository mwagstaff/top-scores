import SwiftUI
import UIKit

@MainActor
enum MatchAnalysisPalette {
    static func colors(_ side: String, catalog: TeamColorCatalog, homeTeam: String, awayTeam: String, colorScheme: ColorScheme) -> TeamLineupNumberColors {
        func visible(_ side: String) -> Color {
            let palette = catalog.lineupColors(for: side == "home" ? homeTeam : awayTeam,
                                             opponentTeamName: side == "home" ? awayTeam : homeTeam,
                                             isAway: side == "away")
            let components = rgb(palette.background, colorScheme: colorScheme)
            let luminance = zip(components, [0.2126, 0.7152, 0.0722]).reduce(0.0) { sum, pair in
                let linear = pair.0 <= 0.04045 ? pair.0 / 12.92 : pow((pair.0 + 0.055) / 1.055, 2.4)
                return sum + linear * pair.1
            }
            return (colorScheme == .dark ? luminance >= 0.12 : luminance <= 0.3) ? palette.background : palette.foreground
        }
        let home = visible("home")
        var fill = side == "home" ? home : visible("away")
        if side == "away", distance(home, fill, colorScheme: colorScheme) < 0.35 {
            let blue = Color(red: 0.165, green: 0.659, blue: 1)
            fill = distance(home, blue, colorScheme: colorScheme) > 0.35 ? blue : Color(red: 0.937, green: 0.706, blue: 0.235)
        }
        return TeamLineupNumberColors(background: fill, foreground: .primary.opacity(0.6), outline: nil)
    }

    private static func rgb(_ color: Color, colorScheme: ColorScheme) -> [Double] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light))
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [Double(red), Double(green), Double(blue)]
    }

    private static func distance(_ first: Color, _ second: Color, colorScheme: ColorScheme) -> Double {
        sqrt(zip(rgb(first, colorScheme: colorScheme), rgb(second, colorScheme: colorScheme)).reduce(0) { $0 + pow($1.0 - $1.1, 2) })
    }

}
