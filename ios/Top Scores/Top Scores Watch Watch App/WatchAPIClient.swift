import Foundation

struct WatchAPIClient {
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: config)
    }

    func fetchMatchDetails(matchId: String) async throws -> WatchMatchDetailsPayload {
        guard let normalizedID = normalizedMatchDetailsID(matchId) else {
            throw WatchAPIClientError.invalidMatchDetailsID(matchId)
        }

        let url = baseURL
            .appendingPathComponent("matches")
            .appendingPathComponent(normalizedID)

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WatchAPIClientError.invalidHTTPResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WatchAPIClientError.badStatus(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(WatchMatchDetailsPayload.self, from: data)
    }

    private func normalizedMatchDetailsID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
    }
}

enum WatchAPIClientError: LocalizedError {
    case invalidHTTPResponse
    case badStatus(statusCode: Int)
    case invalidMatchDetailsID(String)

    var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            return "Invalid HTTP response"
        case let .badStatus(statusCode):
            return "Request failed with status \(statusCode)"
        case let .invalidMatchDetailsID(matchId):
            return "Invalid match details id: \(matchId)"
        }
    }
}

struct WatchMatchDetailsPayload: Codable {
    let id: String
    let date: String?
    let time: String?
    let league: String?
    let homeTeam: String?
    let awayTeam: String?
    let homeShortName: String?
    let awayShortName: String?
    let homeScore: Int?
    let awayScore: Int?
    let scoreStatus: String?
    let homeGoalScorers: [WatchGoalScorer]
    let awayGoalScorers: [WatchGoalScorer]
    let homeAssists: [WatchAssistProvider]
    let awayAssists: [WatchAssistProvider]
    let homeRedCards: [WatchRedCardEvent]
    let awayRedCards: [WatchRedCardEvent]
    let penaltyResult: String?

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case time
        case league
        case homeTeam = "home_team"
        case awayTeam = "away_team"
        case homeShortName = "home_short_name"
        case awayShortName = "away_short_name"
        case homeScore = "home_score"
        case awayScore = "away_score"
        case scoreStatus = "score_status"
        case homeGoalScorers = "home_goal_scorers"
        case awayGoalScorers = "away_goal_scorers"
        case homeAssists = "home_assists"
        case awayAssists = "away_assists"
        case homeRedCards = "home_red_cards"
        case awayRedCards = "away_red_cards"
        case penaltyResult = "penalty_result"
    }
}

extension WatchMatch {
    func withDetails(_ details: WatchMatchDetailsPayload) -> WatchMatch {
        var updatedMatch = self
        updatedMatch = WatchMatch(
            date: details.date ?? date,
            time: details.time ?? time,
            homeTeam: details.homeTeam ?? homeTeam,
            awayTeam: details.awayTeam ?? awayTeam,
            homeShortName: details.homeShortName ?? homeShortName,
            awayShortName: details.awayShortName ?? awayShortName,
            league: details.league ?? league,
            matchDetailsIDValue: matchDetailsIDValue,
            tvChannels: tvChannels,
            homeScore: details.homeScore ?? homeScore,
            awayScore: details.awayScore ?? awayScore,
            scoreStatus: details.scoreStatus ?? scoreStatus,
            homeGoalScorers: details.homeGoalScorers,
            awayGoalScorers: details.awayGoalScorers,
            homeAssists: details.homeAssists,
            awayAssists: details.awayAssists,
            homeRedCards: details.homeRedCards,
            awayRedCards: details.awayRedCards,
            penaltyResult: details.penaltyResult ?? penaltyResult
        )
        return updatedMatch
    }
}

private extension WatchMatch {
    init(
        date: String,
        time: String,
        homeTeam: String,
        awayTeam: String,
        homeShortName: String?,
        awayShortName: String?,
        league: String,
        matchDetailsIDValue: String?,
        tvChannels: [String],
        homeScore: Int?,
        awayScore: Int?,
        scoreStatus: String?,
        homeGoalScorers: [WatchGoalScorer],
        awayGoalScorers: [WatchGoalScorer],
        homeAssists: [WatchAssistProvider],
        awayAssists: [WatchAssistProvider],
        homeRedCards: [WatchRedCardEvent],
        awayRedCards: [WatchRedCardEvent],
        penaltyResult: String?
    ) {
        var dict: [String: Any] = [
            "date": date,
            "time": time,
            "home_team": homeTeam,
            "away_team": awayTeam,
            "league": league,
            "tv_channels": tvChannels,
            "home_goal_scorers": homeGoalScorers.map { scorer in
                [
                    "player": scorer.player,
                    "goal_times": scorer.goalTimes,
                    "own_goal_times": scorer.ownGoalTimes,
                    "disallowed_goal_times": scorer.disallowedGoalTimes,
                ]
            },
            "away_goal_scorers": awayGoalScorers.map { scorer in
                [
                    "player": scorer.player,
                    "goal_times": scorer.goalTimes,
                    "own_goal_times": scorer.ownGoalTimes,
                    "disallowed_goal_times": scorer.disallowedGoalTimes,
                ]
            },
            "home_assists": homeAssists.map { assist in
                ["player": assist.player, "assist_times": assist.assistTimes]
            },
            "away_assists": awayAssists.map { assist in
                ["player": assist.player, "assist_times": assist.assistTimes]
            },
            "home_red_cards": homeRedCards.map { card in
                ["player": card.player, "red_card_times": card.redCardTimes]
            },
            "away_red_cards": awayRedCards.map { card in
                ["player": card.player, "red_card_times": card.redCardTimes]
            }
        ]

        if let homeShortName {
            dict["home_short_name"] = homeShortName
        }
        if let awayShortName {
            dict["away_short_name"] = awayShortName
        }

        if let matchDetailsIDValue = matchDetailsIDValue {
            dict["match_details_id"] = matchDetailsIDValue
        }
        if let homeScore = homeScore {
            dict["home_score"] = homeScore
        }
        if let awayScore = awayScore {
            dict["away_score"] = awayScore
        }
        if let scoreStatus = scoreStatus {
            dict["score_status"] = scoreStatus
        }
        if let penaltyResult = penaltyResult {
            dict["penalty_result"] = penaltyResult
        }

        let data = try! JSONSerialization.data(withJSONObject: dict)
        self = try! JSONDecoder().decode(WatchMatch.self, from: data)
    }
}
