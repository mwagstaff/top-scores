import Foundation

nonisolated struct NextGoal: Codable, Hashable, Sendable {
    enum Status: String, Codable { case available, updating, warmingUp = "warming_up", settled }
    struct Probabilities: Codable, Hashable {
        let home: Double
        let no_goal: Double?
        let away: Double
    }
    struct Evidence: Codable, Hashable {
        let shots_home_10m: Int?
        let shots_away_10m: Int?
    }
    struct Score: Codable, Hashable { let home: Int; let away: Int }
    struct Call: Codable, Hashable { let summary: String }
    let status: Status
    let message: String?
    let score: Score?
    let minute: Int?
    let probabilities: Probabilities?
    let evidence: Evidence?
    let calls: [Call]?
    let lastSeenAt: String?
    let refreshAfterSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case status, message, score, minute, probabilities, evidence, calls
        case lastSeenAt = "last_seen_at"
        case refreshAfterSeconds = "refresh_after_seconds"
    }

    struct Share: Identifiable {
        let id: String
        let label: String
        let value: Double
        var percent: String { "\(Int((value * 100).rounded()))%" }
    }

    func shares(home: String, away: String) -> [Share] {
        guard let p = probabilities, status == .available || status == .updating else { return [] }
        let total = p.home + (p.no_goal ?? 0) + p.away
        guard total > 0, [p.home, p.away, p.no_goal ?? 0].allSatisfy({ (0...1).contains($0) }),
              p.no_goal == nil || abs(total - 1) <= 0.01 else { return [] }
        var shares = [Share(id: "home", label: home, value: p.home / total)]
        if let noGoal = p.no_goal {
            shares.append(Share(id: "no_goal", label: "No further goal", value: noGoal / total))
        }
        shares.append(Share(id: "away", label: away, value: p.away / total))
        return shares
    }

    var expiresAt: Date? {
        guard status == .available, let lastSeenAt,
              let seen = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(lastSeenAt) else { return nil }
        return seen.addingTimeInterval(180)
    }

    func note(updating: Bool) -> String? {
        if updating, let minute { return "Last estimate · \(minute)′" }
        guard let home = evidence?.shots_home_10m, let away = evidence?.shots_away_10m,
              home >= 0, away >= 0 else { return nil }
        return "Shots, last 10′: \(home)–\(away)"
    }
}
