import Foundation

nonisolated enum PredictionMiniLeagueScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case round, season
    var id: String { rawValue }
    var title: String { self == .round ? "This Round" : "Season" }
}

nonisolated struct PredictionMiniLeague: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let competitionId: String
    let competitionName: String
    let ownerMemberId: String
    let myMemberId: String
    let isOwner: Bool
    let showAI: Bool
    let status: String
    let memberCount: Int
    let position: Int?
    let points: Int
    let gapToLeader: Int
    let currentRound: PredictionMiniLeagueRound?
    let startsFrom: String?
    let createdAt: Date
}

nonisolated struct PredictionMiniLeagueRound: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let seasonId: String
    let seasonLabel: String
    let startsAt: Date
    let opensAt: Date
    let fixtureCount: Int
    let completed: Bool
}

nonisolated struct PredictionMiniLeagueMember: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let isYou: Bool
    let isOwner: Bool
    let status: String
    let startsFrom: String?
}

nonisolated struct PredictionMiniLeagueStanding: Decodable, Identifiable, Equatable, Sendable {
    let memberId: String
    let displayName: String
    let rank: Int
    let points: Int
    let exactScores: Int
    let correctResults: Int
    let predicted: Int
    let played: Int
    let isYou: Bool
    let isAI: Bool
    let status: String
    var id: String { memberId }
}

nonisolated struct PredictionMiniLeagueListResponse: Decodable, Sendable {
    let leagues: [PredictionMiniLeague]
    let serverTime: Date
}
nonisolated struct PredictionMiniLeagueResponse: Decodable, Sendable {
    let league: PredictionMiniLeague
    let serverTime: Date
}
nonisolated struct PredictionMiniLeagueDetailResponse: Decodable, Sendable {
    let league: PredictionMiniLeague
    let rounds: [PredictionMiniLeagueRound]
    let members: [PredictionMiniLeagueMember]
    let serverTime: Date
}
nonisolated struct PredictionMiniLeagueStandingsResponse: Decodable, Sendable {
    let leagueId: String
    let scope: PredictionMiniLeagueScope
    let roundId: String?
    let seasonId: String?
    let rows: [PredictionMiniLeagueStanding]
    let serverTime: Date
}
nonisolated struct PredictionMiniLeagueSharedAI: Decodable, Sendable {
    let fixtureId: String
    let ai: PredictionGameAI
}
nonisolated struct PredictionMiniLeagueFixtureResponse: Decodable, Sendable {
    var scoringEligible: Bool? = nil
    let fixtures: [PredictionGameFixture]
    let sharedAI: [PredictionMiniLeagueSharedAI]
    let round: PredictionMiniLeagueRound?
    let serverTime: Date
}
nonisolated struct PredictionMiniLeagueInvitation: Decodable, Identifiable, Sendable {
    let id: String
    let code: String
    let url: URL
    let expiresAt: Date
}
nonisolated struct PredictionMiniLeagueInvitationResponse: Decodable, Sendable {
    let invitation: PredictionMiniLeagueInvitation
    let serverTime: Date
}
nonisolated struct PredictionMiniLeagueInvitationRecord: Decodable, Identifiable, Sendable {
    let id: String
    let expiresAt: Date
    let revokedAt: Date?
    let createdAt: Date
}
nonisolated struct PredictionMiniLeagueInvitationsResponse: Decodable, Sendable {
    let invitations: [PredictionMiniLeagueInvitationRecord]
    let serverTime: Date
}
nonisolated struct PredictionMiniLeagueInvitationPreview: Decodable, Sendable {
    let leagueId: String
    let leagueName: String
    let competitionName: String
    let memberCount: Int
    let expiresAt: Date
    let alreadyMember: Bool
    let startsFrom: String?
}
nonisolated struct PredictionMiniLeagueInvitationPreviewResponse: Decodable, Sendable {
    let invitation: PredictionMiniLeagueInvitationPreview
    let serverTime: Date
}
nonisolated struct PredictionMiniLeagueActionResponse: Decodable, Sendable {
    let ok: Bool
    let serverTime: Date
}

nonisolated enum PredictionMiniLeagueError: LocalizedError {
    case gameCenterRequired, multiplayerRestricted, finishingPrediction, invalidIdentifier
    var errorDescription: String? {
        switch self {
        case .gameCenterRequired: "Game Center is needed for private leagues. Sign-in happens automatically when you open Beat the AI."
        case .multiplayerRestricted: "Private leagues are unavailable because multiplayer games are restricted in Screen Time. You can still make your own predictions."
        case .finishingPrediction: "Finish your current prediction to open your Game Center leagues."
        case .invalidIdentifier: "This league or invitation is unavailable."
        }
    }
}
