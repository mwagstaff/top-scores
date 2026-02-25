import Foundation

struct LeagueTablesEnvelope: Codable, Hashable {
    let updatedAt: String?
    let count: Int?
    let leagues: [LeagueTable]

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case count
        case leagues
    }
}

struct LeagueTable: Identifiable, Codable, Hashable {
    let leagueID: String
    let leagueName: String
    let stageName: String?
    let sourceURL: String?
    let updatedAt: String?
    let rows: [LeagueTableRow]

    var id: String {
        leagueID
    }

    enum CodingKeys: String, CodingKey {
        case leagueID = "league_id"
        case leagueName = "league_name"
        case stageName = "stage_name"
        case sourceURL = "source_url"
        case updatedAt = "updated_at"
        case rows
    }
}

struct LeagueTableRow: Identifiable, Codable, Hashable {
    let position: Int
    let team: String
    let played: Int
    let won: Int
    let drawn: Int
    let lost: Int
    let goalsFor: Int
    let goalsAgainst: Int
    let goalDifference: Int
    let points: Int
    let form: [String]
    let rankStatus: String?

    var id: String {
        "\(position)-\(team)"
    }

    enum CodingKeys: String, CodingKey {
        case position
        case team
        case played
        case won
        case drawn
        case lost
        case goalsFor = "goals_for"
        case goalsAgainst = "goals_against"
        case goalDifference = "goal_difference"
        case points
        case form
        case rankStatus = "rank_status"
    }
}
