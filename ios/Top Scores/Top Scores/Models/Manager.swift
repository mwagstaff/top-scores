import Foundation

struct TeamManager: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let shortName: String?
    let country: String?
    let tacticalProfile: String?
    let preferredFormation: String?
    let currentTeamID: String?
    let matchesTotal: Int?
    let wins: Int?
    let draws: Int?
    let losses: Int?
    let winPercentage: Double?
    let drawPercentage: Double?
    let lossPercentage: Double?
    let averageGoalsScored: Double?
    let averageGoalsConceded: Double?
    let averagePossession: Double?
    let cleanSheetPercentage: Double?
    let imageURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case shortName = "short_name"
        case country
        case tacticalProfile = "tactical_profile"
        case preferredFormation = "preferred_formation"
        case currentTeamID = "current_team_id"
        case matchesTotal = "matches_total"
        case wins
        case draws
        case losses
        case winPercentage = "win_pct"
        case drawPercentage = "draw_pct"
        case lossPercentage = "loss_pct"
        case averageGoalsScored = "avg_goals_scored"
        case averageGoalsConceded = "avg_goals_conceded"
        case averagePossession = "avg_possession"
        case cleanSheetPercentage = "clean_sheet_pct"
        case imageURL = "image_url"
    }
}

struct ManagerCareerResponse: Codable, Hashable, Sendable {
    let managerID: String
    let count: Int
    let tenures: [ManagerTenure]

    enum CodingKeys: String, CodingKey {
        case managerID = "manager_id"
        case count
        case tenures
    }

    func previousClubs(excluding currentTeamID: String?) -> [ManagerTenure] {
        tenures.filter { tenure in
            tenure.hasValidDateRange && tenure.teamID != currentTeamID
        }
    }

    func appointmentEffect(for currentTeamID: String?) -> ManagerAppointmentEffect? {
        guard let currentTeamID, !currentTeamID.isEmpty else { return nil }
        return tenures.first {
            $0.teamID == currentTeamID && $0.hasValidDateRange && $0.appointmentEffect != nil
        }?.appointmentEffect
    }

    func currentTenure(for currentTeamID: String?) -> ManagerTenure? {
        guard let currentTeamID, !currentTeamID.isEmpty else { return nil }
        let matches = tenures.filter {
            $0.teamID == currentTeamID && $0.hasValidDateRange
        }
        return matches.first { $0.dateTo == nil } ?? matches.first
    }
}

struct ManagerTenure: Codable, Hashable, Identifiable, Sendable {
    let teamID: String
    let teamName: String
    let teamLogoURL: String?
    let dateFrom: String?
    let dateTo: String?
    let matches: Int?
    let wins: Int?
    let draws: Int?
    let losses: Int?
    let winPercentage: Double?
    let points: Int?
    let pointsPerMatch: Double?
    let goalsFor: Int?
    let goalsAgainst: Int?
    let goalDifference: Int?
    let appointmentEffect: ManagerAppointmentEffect?

    var id: String {
        "\(teamID)|\(dateFrom ?? "")|\(dateTo ?? "")"
    }

    var hasValidDateRange: Bool {
        guard dateFrom != nil, dateTo != nil else { return true }
        guard let from = PlayerDatePresentation.date(from: dateFrom),
              let to = PlayerDatePresentation.date(from: dateTo) else { return false }
        return from <= to
    }

    enum CodingKeys: String, CodingKey {
        case teamID = "team_id"
        case teamName = "team_name"
        case teamLogoURL = "team_logo_url"
        case dateFrom = "date_from"
        case dateTo = "date_to"
        case matches
        case wins
        case draws
        case losses
        case winPercentage = "win_pct"
        case points
        case pointsPerMatch = "ppm"
        case goalsFor = "goals_for"
        case goalsAgainst = "goals_against"
        case goalDifference = "goal_diff"
        case appointmentEffect = "appointment_effect"
    }
}

struct ManagerAppointmentEffect: Codable, Hashable, Sendable {
    let window: Int?
    let before: ManagerImpactStats
    let after: ManagerImpactStats
    let pointsPerMatchChange: Double?

    enum CodingKeys: String, CodingKey {
        case window
        case before
        case after
        case pointsPerMatchChange = "ppm_change"
    }
}

struct ManagerImpactStats: Codable, Hashable, Sendable {
    let matches: Int?
    let wins: Int?
    let draws: Int?
    let losses: Int?
    let points: Int?
    let pointsPerMatch: Double?
    let winPercentage: Double?
    let goalsFor: Int?
    let goalsAgainst: Int?
    let goalDifference: Int?
    let matchesLedByManager: Int?

    enum CodingKeys: String, CodingKey {
        case matches
        case wins
        case draws
        case losses
        case points
        case pointsPerMatch = "ppm"
        case winPercentage = "win_pct"
        case goalsFor = "goals_for"
        case goalsAgainst = "goals_against"
        case goalDifference = "goal_diff"
        case matchesLedByManager = "matches_led_by_manager"
    }
}

enum ManagerImpactTrendDirection: Hashable, Sendable {
    case up
    case down
    case unchanged
}

enum ManagerImpactTrendOutcome: Hashable, Sendable {
    case improvement
    case decline
    case unchanged
}

struct ManagerImpactTrend: Hashable, Sendable {
    let direction: ManagerImpactTrendDirection
    let outcome: ManagerImpactTrendOutcome

    static func compare(
        before: Double?,
        after: Double?,
        lowerIsBetter: Bool = false
    ) -> ManagerImpactTrend? {
        guard let before, let after else { return nil }
        let difference = after - before
        guard abs(difference) > 0.000_001 else {
            return ManagerImpactTrend(direction: .unchanged, outcome: .unchanged)
        }

        let direction: ManagerImpactTrendDirection = difference > 0 ? .up : .down
        let improved = lowerIsBetter ? difference < 0 : difference > 0
        return ManagerImpactTrend(
            direction: direction,
            outcome: improved ? .improvement : .decline
        )
    }
}
