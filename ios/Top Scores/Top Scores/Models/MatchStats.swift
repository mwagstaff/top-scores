import Foundation

nonisolated struct MatchStats: Codable, Hashable, Sendable {
    struct Row: Codable, Hashable, Identifiable, Sendable {
        let id: String
        let label: String
        let group: String
        let headline: Bool
        let home: Double?
        let away: Double?
        let homeDisplay: String
        let awayDisplay: String
        let homeEstimated: Bool
        let awayEstimated: Bool

        enum CodingKeys: String, CodingKey {
            case id, label, group, headline, home, away
            case homeDisplay = "home_display", awayDisplay = "away_display"
            case homeEstimated = "home_estimated", awayEstimated = "away_estimated"
        }

        var isValid: Bool {
            (home != nil || away != nil) && (home?.isFinite ?? true) && (away?.isFinite ?? true)
        }
        var homeShare: Double? {
            guard let home, let away, home.isFinite, away.isFinite, home >= 0, away >= 0, home + away > 0 else { return nil }
            return home / (home + away)
        }
        func display(home: Bool) -> String {
            (home ? homeDisplay : awayDisplay) + ((home ? homeEstimated : awayEstimated) ? " est." : "")
        }
    }
    struct Period: Codable, Hashable, Identifiable, Sendable {
        let id: String
        let label: String
        let rows: [Row]
    }
    let status: String
    let periods: [Period]
    let updatedAt: String?
    let refreshAfterSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case status, periods
        case updatedAt = "updated_at", refreshAfterSeconds = "refresh_after_seconds"
    }
    var availablePeriods: [Period] {
        var ids = Set<String>()
        return periods.compactMap { period in
            guard ["all", "first_half", "second_half"].contains(period.id), ids.insert(period.id).inserted else { return nil }
            var rowIDs = Set<String>()
            let rows = period.rows.filter { $0.isValid && rowIDs.insert($0.id).inserted }
            return rows.isEmpty ? nil : Period(id: period.id, label: period.label, rows: rows)
        }
    }
    var summaryRows: [Row] {
        (availablePeriods.first { $0.id == "all" }?.rows ?? []).filter { ["ball_possession", "xg", "shots_on_target"].contains($0.id) }
    }
    var updatedDate: Date? {
        guard let updatedAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: updatedAt) ?? ISO8601DateFormatter().date(from: updatedAt)
    }
}
