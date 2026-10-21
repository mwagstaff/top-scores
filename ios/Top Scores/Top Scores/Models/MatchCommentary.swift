import Foundation

nonisolated struct MatchCommentaryPayload: Decodable, Sendable {
    let eventID: Int
    let status: String?
    let hasPlayByPlay: Bool
    let commentary: [MatchCommentaryLine]
    let updatedAt: String?
    let stale: Bool
    let refreshAfterSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case status, commentary, stale
        case hasPlayByPlay = "has_play_by_play"
        case updatedAt = "updated_at"
        case refreshAfterSeconds = "refresh_after_seconds"
    }

    var isWaitingForKickoff: Bool {
        ["notstarted", "not_started", "upcoming"].contains(status ?? "")
    }

    func entries(importantOnly: Bool) -> [MatchCommentaryLine] {
        commentary.reversed().filter { !importantOnly || $0.important }
    }
}

nonisolated struct MatchCommentaryLine: Decodable, Identifiable, Sendable {
    let id: String
    let period: Int
    let minute: Int
    let addedTime: Int?
    let second: Int?
    // Retain unknown types so a new BSD event never breaks the whole feed.
    let type: String
    let team: String?
    let player: Player?
    let relatedPlayer: Player?
    let text: String
    let important: Bool
    let score: Score?

    nonisolated struct Player: Decodable, Sendable {
        let id: Int?
        let name: String?
    }

    nonisolated struct Score: Decodable, Sendable {
        let home: Int?
        let away: Int?
    }

    enum CodingKeys: String, CodingKey {
        case id, period, minute, second, type, team, player, text, important, score
        case addedTime = "added_time"
        case relatedPlayer = "related_player"
    }

    var minuteText: String {
        if let addedTime, addedTime > 0 { return "\(minute)+\(addedTime)′" }
        return "\(minute)′"
    }

    var accessibilityText: String {
        let time = addedTime.map { $0 > 0 ? "\(minute) minutes plus \($0)" : "\(minute) minutes" }
            ?? "\(minute) minutes"
        return "\(time). \(important ? "Key moment. " : "")\(text)"
    }
}
