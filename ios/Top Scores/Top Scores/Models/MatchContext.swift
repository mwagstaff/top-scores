import Foundation

nonisolated struct MatchContext: Codable, Hashable, Sendable {
    let kickoffAt: String?
    let isUpcoming: Bool
    let lineupStatus: String
    let lineupUpdatedAt: String?
    let headToHead: MatchHeadToHead?
    let matchPreview: MatchPreviewContent?
    let funFacts: [String]
    let refreshAfterSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case kickoffAt = "kickoff_at", isUpcoming = "is_upcoming"
        case lineupStatus = "lineup_status", lineupUpdatedAt = "lineup_updated_at"
        case headToHead = "head_to_head", matchPreview = "match_preview"
        case funFacts = "fun_facts", refreshAfterSeconds = "refresh_after_seconds"
    }

    var kickoffDate: Date? { Self.parseDate(kickoffAt) }

    func isPrematch(at date: Date = Date()) -> Bool {
        isUpcoming && (kickoffDate.map { $0 > date } ?? false)
    }

    static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
}

nonisolated struct MatchPreviewContent: Codable, Hashable, Sendable {
    let text: String
    let generatedAt: String?
    enum CodingKeys: String, CodingKey { case text, generatedAt = "generated_at" }
}

nonisolated struct MatchHeadToHead: Codable, Hashable, Sendable {
    let totalMatches: Int
    let homeWins: Int?
    let draws: Int?
    let awayWins: Int?
    let recentMatches: [MatchHeadToHeadMeeting]
    enum CodingKeys: String, CodingKey {
        case totalMatches = "total_matches", homeWins = "home_wins", draws, awayWins = "away_wins"
        case recentMatches = "recent_matches"
    }
}

nonisolated struct MatchHeadToHeadMeeting: Codable, Hashable, Identifiable, Sendable {
    let eventID: String?
    let matchID: String?
    let date: String
    let homeTeam: String
    let awayTeam: String
    let homeTeamID: String?
    let awayTeamID: String?
    let homeScore: Int?
    let awayScore: Int?
    var id: String { eventID ?? "\(date)|\(homeTeamID ?? homeTeam)|\(awayTeamID ?? awayTeam)" }
    var scoreText: String {
        guard let homeScore, let awayScore, homeScore >= 0, awayScore >= 0 else { return "–" }
        return "\(homeScore)–\(awayScore)"
    }
    enum CodingKeys: String, CodingKey {
        case eventID = "event_id", matchID = "match_id", date
        case homeTeam = "home_team", awayTeam = "away_team"
        case homeTeamID = "home_team_id", awayTeamID = "away_team_id"
        case homeScore = "home_score", awayScore = "away_score"
    }

    var match: Match? {
        guard let matchID, !matchID.isEmpty, MatchContext.parseDate(date) != nil else { return nil }
        return Match(date: String(date.prefix(10)), time: "", homeTeam: homeTeam, awayTeam: awayTeam,
                     homeTeamId: homeTeamID, awayTeamId: awayTeamID, kickoffAt: date,
                     league: "", matchDetailsID: matchID, tvChannels: [],
                     homeScore: homeScore, awayScore: awayScore,
                     scoreStatus: homeScore != nil && awayScore != nil ? "FT" : nil)
    }
}
