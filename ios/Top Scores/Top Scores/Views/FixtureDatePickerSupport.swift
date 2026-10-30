import SwiftUI

struct FixtureCalendarMonth: Identifiable {
    let date: Date
    let days: [Date]
    let leadingEmptyDays: Int

    var id: String { Self.monthKey(for: date) }

    static func dateKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func monthKey(for date: Date) -> String {
        String(dateKey(for: date).prefix(7))
    }

    static func months(in range: ClosedRange<Date>, calendar: Calendar = .current) -> [Self] {
        guard var month = calendar.dateInterval(of: .month, for: range.lowerBound)?.start,
              let lastMonth = calendar.dateInterval(of: .month, for: range.upperBound)?.start else {
            return []
        }
        var result: [Self] = []
        while month <= lastMonth {
            guard let dayRange = calendar.range(of: .day, in: .month, for: month),
                  let nextMonth = calendar.date(byAdding: .month, value: 1, to: month) else { break }
            let days = dayRange.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: month) }
            result.append(Self(
                date: month,
                days: days,
                leadingEmptyDays: (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
            ))
            month = nextMonth
        }
        return result
    }
}

/// Both the day markers and its summary use the same ordered, filtered competitions.
struct FixtureCalendarIndicators {
    let competitions: [FixtureCalendarCompetitionSummary]

    var visible: [FixtureCalendarCompetitionSummary] { Array(competitions.prefix(3)) }
    var overflowCount: Int { max(0, competitions.count - 3) }
    var overflowMatchCount: Int { competitions.dropFirst(3).reduce(0) { $0 + $1.matchCount } }
    var accessibilityDescription: String {
        competitions.map { "\($0.name), \($0.matchCount) " + ($0.matchCount == 1 ? "match" : "matches") }
            .joined(separator: "; ")
    }
}

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
