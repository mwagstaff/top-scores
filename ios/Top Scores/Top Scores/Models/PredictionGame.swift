import Foundation

nonisolated struct PredictionGameCompetition: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String

    static let premierLeague = PredictionGameCompetition(id: "1", name: "Premier League")
}

nonisolated struct PredictionGamePlayer: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let gameCenterLinked: Bool
}

nonisolated struct PredictionGameScore: Codable, Equatable, Sendable {
    var penaltyWinner: String? = nil

    let homeScore: Int
    let awayScore: Int

    var displayText: String { "\(homeScore)–\(awayScore)" }
}

nonisolated struct PredictionGameAI: Codable, Equatable, Sendable {
    var penaltyWinner: String? = nil

    let homeScore: Int
    let awayScore: Int
    let modelVersion: String
    let sourceRevision: String
    let frozenAt: Date?

    var displayText: String { "\(homeScore)–\(awayScore)" }
}

nonisolated struct PredictionGameEntry: Codable, Equatable, Sendable {
    var penaltyWinner: String? = nil

    let homeScore: Int
    let awayScore: Int
    let savedAt: Date
    let youPoints: Int?
    let aiPoints: Int?
    let outcome: String?

    var displayText: String { "\(homeScore)–\(awayScore)" }
}

nonisolated struct PredictionGameFixture: Codable, Equatable, Identifiable, Sendable {
    var isSecondLeg: Bool? = nil
    var competitionId: String? = nil
    var competitionName: String? = nil

    var resolvedCompetitionID: String { competitionId ?? "1" }
    var resolvedCompetitionName: String {
        competitionName ?? (resolvedCompetitionID == "1" ? "Premier League" : "Competition \(resolvedCompetitionID)")
    }

    let id: String
    let homeTeam: String
    let awayTeam: String
    let seasonId: String
    let seasonLabel: String
    let kickoffAt: Date
    let status: String
    let locked: Bool
    let settled: Bool
    let void: Bool
    let challengeId: String?
    let ai: PredictionGameAI?
    let prediction: PredictionGameEntry?
    let result: PredictionGameScore?

    var canPredict: Bool { !locked && !settled && !void && ai != nil }

    func predictionAvailability(at serverDate: Date) -> PredictionGameAvailability {
        if void { return .void }
        // A missing game AI snapshot must not hide an already-passed deadline.
        if locked || settled || serverDate >= kickoffAt { return .locked }
        return ai == nil ? .awaitingAI : .editable
    }

    var completedPredictionHighlight: PredictionGameCompletedHighlight? {
        guard settled, !void, result != nil,
              let prediction, let youPoints = prediction.youPoints, let aiPoints = prediction.aiPoints else {
            return nil
        }
        if youPoints == 3 { return .exactScore }
        if youPoints > aiPoints { return .userWin }
        if youPoints < aiPoints { return .aiWin }
        return nil
    }
}

nonisolated enum PredictionGameAvailability {
    case editable, locked, void, awaitingAI
}

nonisolated enum PredictionGameCompletedHighlight {
    case exactScore, userWin, aiWin
}

nonisolated struct PredictionGameSummary: Codable, Equatable, Sendable {
    let played: Int
    let youPoints: Int
    let aiPoints: Int
    let wins: Int
    let draws: Int
    let losses: Int
    let exactScores: Int
    let aiExactScores: Int
    let correctResults: Int
    let aiCorrectResults: Int
    let winPercentage: Double
    let resultAccuracy: Double
    let aiResultAccuracy: Double
    let averagePoints: Double
    let aiAveragePoints: Double

    static let empty = PredictionGameSummary(
        played: 0, youPoints: 0, aiPoints: 0, wins: 0, draws: 0, losses: 0,
        exactScores: 0, aiExactScores: 0, correctResults: 0, aiCorrectResults: 0,
        winPercentage: 0, resultAccuracy: 0, aiResultAccuracy: 0,
        averagePoints: 0, aiAveragePoints: 0
    )
}

nonisolated struct PredictionGameSeason: Codable, Equatable, Identifiable, Sendable {
    var competitionId: String? = nil
    var competitionName: String? = nil

    var resolvedCompetitionID: String { competitionId ?? "1" }
    var resolvedCompetitionName: String {
        competitionName ?? (resolvedCompetitionID == "1" ? "Premier League" : "Competition \(resolvedCompetitionID)")
    }

    let id: String
    let label: String
}

nonisolated struct PredictionGameRecentGameweek: Codable, Equatable, Identifiable, Sendable {
    var competitionId: String? = nil
    var competitionName: String? = nil
    var latestPlayedAt: Date? = nil

    var resolvedCompetitionID: String { competitionId ?? "1" }
    var resolvedCompetitionName: String {
        competitionName ?? (resolvedCompetitionID == "1" ? "Premier League" : "Competition \(resolvedCompetitionID)")
    }

    let id: String
    let label: String
    let startsAt: Date
    let youPoints: Int
    let aiPoints: Int
    let played: Int
    let predicted: Int
    let totalMatches: Int
    let completed: Bool

    var headToHeadOutcome: PredictionGameRoundOutcome {
        if youPoints > aiPoints { return .userWin }
        if youPoints < aiPoints { return .aiWin }
        return .draw
    }

    static func latestCompleted(in rounds: [Self]) -> Self? {
        rounds
            .filter { $0.completed && $0.played > 0 }
            .max { ($0.latestPlayedAt ?? $0.startsAt) < ($1.latestPlayedAt ?? $1.startsAt) }
    }
}

nonisolated enum PredictionGameRoundOutcome: Equatable, Sendable {
    case userWin, draw, aiWin
}

nonisolated struct PredictionGameInPlayRound: Codable, Equatable, Identifiable, Sendable {
    var competitionId: String? = nil
    var competitionName: String? = nil

    var resolvedCompetitionID: String { competitionId ?? "1" }
    var resolvedCompetitionName: String {
        competitionName ?? (resolvedCompetitionID == "1" ? "Premier League" : "Competition \(resolvedCompetitionID)")
    }

    let id: String
    let label: String
    let youPoints: Int
    let aiPoints: Int
    let scoredMatches: Int
    let liveMatches: Int
    let totalMatches: Int

    var headToHeadOutcome: PredictionGameRoundOutcome {
        if youPoints > aiPoints { return .userWin }
        if youPoints < aiPoints { return .aiWin }
        return .draw
    }
}

nonisolated struct PredictionGameAchievement: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let description: String
    let progress: Double
    let target: Int
    let unlocked: Bool
}

nonisolated struct PredictionGameChallenge: Codable, Equatable, Identifiable, Sendable {
    var competitionId: String? = nil
    var competitionName: String? = nil

    var resolvedCompetitionID: String { competitionId ?? "1" }
    var resolvedCompetitionName: String {
        competitionName ?? (resolvedCompetitionID == "1" ? "Premier League" : "Competition \(resolvedCompetitionID)")
    }

    let id: String
    let title: String
    let seasonId: String
    let startsAt: Date
    let endsAt: Date
    let fixtureIds: [String]
    let youPoints: Int
    let aiPoints: Int
    let completed: Bool
}

nonisolated struct PredictionGameLeaderboardRow: Codable, Equatable, Identifiable, Sendable {
    let rank: Int
    let playerId: String
    let displayName: String
    let points: Int
    let isYou: Bool

    var id: String { playerId }
}

nonisolated enum PredictionGameLeaderboardCategory: String, CaseIterable, Identifiable, Sendable {
    case weekly, season, perfect

    var id: String { rawValue }
    var title: String {
        switch self {
        case .weekly: "Weekly Challenge"
        case .season: "Season Champion"
        case .perfect: "Perfect Predictions"
        }
    }
}

nonisolated struct PredictionGamePlayerResponse: Decodable, Sendable {
    var privateSessionExpiresAt: Date? = nil
    var restoredExisting: Bool? = nil
    let player: PredictionGamePlayer
    let credential: String?
}

nonisolated struct PredictionGameStateResponse: Decodable, Sendable {
    var competitionId: String? = nil
    var competitionName: String? = nil
    var competitions: [PredictionGameCompetition]? = nil

    let player: PredictionGamePlayer
    let serverTime: Date
    let summary: PredictionGameSummary
    let seasons: [PredictionGameSeason]
    let achievements: [PredictionGameAchievement]
    let challenge: PredictionGameChallenge?
    let fixtures: [PredictionGameFixture]
    let recentGameweeks: [PredictionGameRecentGameweek]?
    let latestResult: PredictionGameRecentGameweek?
}

nonisolated struct PredictionGameStatsResponse: Decodable, Sendable {
    var competitionId: String? = nil
    var competitionName: String? = nil
    var competitions: [PredictionGameCompetition]? = nil

    let summary: PredictionGameSummary
    let seasons: [PredictionGameSeason]
    let achievements: [PredictionGameAchievement]
    let recentGameweeks: [PredictionGameRecentGameweek]?
}

nonisolated struct PredictionGameFixturesResponse: Decodable, Sendable {
    let fixtures: [PredictionGameFixture]
    let serverTime: Date
}

nonisolated struct PredictionGameInPlayResponse: Decodable, Sendable {
    let competitionId: String
    let round: PredictionGameInPlayRound?
    let serverTime: Date
}

nonisolated struct PredictionGamePredictionSet: Decodable, Equatable, Sendable {
    var competitionId: String? = nil
    var competitionName: String? = nil

    var resolvedCompetitionID: String { competitionId ?? "1" }
    var resolvedCompetitionName: String {
        competitionName ?? (resolvedCompetitionID == "1" ? "Premier League" : "Competition \(resolvedCompetitionID)")
    }

    let serverTime: Date
    let gameweekId: String?
    let gameweekLabel: String?
    let fixtures: [PredictionGameFixture]

    func orderedEditableFixtures(at serverDate: Date, excluding excludedIDs: Set<String> = []) -> [PredictionGameFixture] {
        var seen = Set<String>()
        return fixtures.filter { fixture in
            fixture.canPredict && fixture.kickoffAt > serverDate &&
                !excludedIDs.contains(fixture.id) && seen.insert(fixture.id).inserted
        }.sorted { lhs, rhs in
            if (lhs.prediction == nil) != (rhs.prediction == nil) { return lhs.prediction == nil }
            if lhs.kickoffAt != rhs.kickoffAt { return lhs.kickoffAt < rhs.kickoffAt }
            return lhs.id < rhs.id
        }
    }
}

nonisolated struct PredictionGameSaveResponse: Decodable, Sendable {
    let fixture: PredictionGameFixture
    let serverTime: Date
}

nonisolated struct PredictionGameHistoryResponse: Decodable, Sendable {
    let fixtures: [PredictionGameFixture]
    let total: Int
    let offset: Int
    let hasMore: Bool
}

nonisolated struct PredictionGameLeaderboardResponse: Decodable, Sendable {
    var competitionId: String? = nil
    var competitionName: String? = nil
    var gameCenterLeaderboardId: String? = nil

    let rows: [PredictionGameLeaderboardRow]
    let category: String
}

nonisolated struct PredictionGameCenterIdentity: Encodable, Sendable {
    let gamePlayerId: String
    let teamPlayerId: String
    let publicKeyUrl: String
    let signature: String
    let salt: String
    let timestamp: UInt64
    let displayName: String
    var restoreExisting: Bool = false
}

nonisolated enum PredictionGameFixtureID {
    static func normalized(_ id: String) -> String? {
        let value = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = value.hasPrefix("bsd:") ? String(value.dropFirst(4)) : value
        guard !candidate.isEmpty, candidate.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = UInt64(candidate), number > 0 else { return nil }
        return String(number)
    }
}
