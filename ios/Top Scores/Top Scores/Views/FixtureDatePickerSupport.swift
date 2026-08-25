import SwiftUI

enum FixtureCalendarCompetitionColor {
    static func color(competitionID: String, competitionName: String) -> Color {
        switch CompetitionAccentRole.resolve(
            competitionID: competitionID,
            competitionName: competitionName
        ) {
        case .bundesliga:
            return Color(red: 0.12, green: 0.48, blue: 0.96)
        case .standard:
            let key = competitionID.isEmpty ? competitionName : competitionID
            let hueDegrees = key.utf8.reduce(0) { partialResult, byte in
                ((partialResult * 31) + Int(byte)) % 360
            }
            return Color(
                hue: Double(hueDegrees) / 360,
                saturation: 0.78,
                brightness: 0.84
            )
        case let role:
            return role.color
        }
    }
}
