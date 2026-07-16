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

        let matchURL = baseURL
            .appendingPathComponent("matches")
            .appendingPathComponent(normalizedID)
        var components = URLComponents(url: matchURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "time_zone", value: TimeZone.current.identifier)]
        guard let url = components?.url else {
            throw WatchAPIClientError.invalidHTTPResponse
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            do {
                return try await fetchMatchDetails(request: request)
            } catch {
                guard attempt < maxAttempts, isRetryable(error) else {
                    throw error
                }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
            }
        }

        throw WatchAPIClientError.invalidHTTPResponse
    }

    private func fetchMatchDetails(request: URLRequest) async throws -> WatchMatchDetailsPayload {
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WatchAPIClientError.invalidHTTPResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WatchAPIClientError.badStatus(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(WatchMatchDetailsPayload.self, from: data)
    }

    private func isRetryable(_ error: Error) -> Bool {
        if let apiError = error as? WatchAPIClientError {
            return apiError.isRetryable
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
                return true
            default:
                return false
            }
        }

        return false
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

    var isRetryable: Bool {
        switch self {
        case let .badStatus(statusCode):
            return statusCode == 502 || statusCode == 503 || statusCode == 504
        case .invalidHTTPResponse, .invalidMatchDetailsID:
            return false
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
    let homeYellowCards: [WatchYellowCardEvent]
    let awayYellowCards: [WatchYellowCardEvent]
    let homeRedCards: [WatchRedCardEvent]
    let awayRedCards: [WatchRedCardEvent]
    let homeVarEvents: [WatchVarEvent]
    let awayVarEvents: [WatchVarEvent]
    let teamLineups: WatchTeamLineups?
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
        case homeYellowCards = "home_yellow_cards"
        case awayYellowCards = "away_yellow_cards"
        case homeRedCards = "home_red_cards"
        case awayRedCards = "away_red_cards"
        case homeVarEvents = "home_var_events"
        case awayVarEvents = "away_var_events"
        case teamLineups = "team_lineups"
        case penaltyResult = "penalty_result"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        date = try container.decodeIfPresent(String.self, forKey: .date)
        time = try container.decodeIfPresent(String.self, forKey: .time)
        league = try container.decodeIfPresent(String.self, forKey: .league)
        homeTeam = try container.decodeIfPresent(String.self, forKey: .homeTeam)
        awayTeam = try container.decodeIfPresent(String.self, forKey: .awayTeam)
        homeShortName = try container.decodeIfPresent(String.self, forKey: .homeShortName)
        awayShortName = try container.decodeIfPresent(String.self, forKey: .awayShortName)
        homeScore = try container.decodeIfPresent(Int.self, forKey: .homeScore)
        awayScore = try container.decodeIfPresent(Int.self, forKey: .awayScore)
        scoreStatus = try container.decodeIfPresent(String.self, forKey: .scoreStatus)
        homeGoalScorers = try container.decodeIfPresent([WatchGoalScorer].self, forKey: .homeGoalScorers) ?? []
        awayGoalScorers = try container.decodeIfPresent([WatchGoalScorer].self, forKey: .awayGoalScorers) ?? []
        homeAssists = try container.decodeIfPresent([WatchAssistProvider].self, forKey: .homeAssists) ?? []
        awayAssists = try container.decodeIfPresent([WatchAssistProvider].self, forKey: .awayAssists) ?? []
        homeYellowCards = try container.decodeIfPresent([WatchYellowCardEvent].self, forKey: .homeYellowCards) ?? []
        awayYellowCards = try container.decodeIfPresent([WatchYellowCardEvent].self, forKey: .awayYellowCards) ?? []
        homeRedCards = try container.decodeIfPresent([WatchRedCardEvent].self, forKey: .homeRedCards) ?? []
        awayRedCards = try container.decodeIfPresent([WatchRedCardEvent].self, forKey: .awayRedCards) ?? []
        homeVarEvents = try container.decodeIfPresent([WatchVarEvent].self, forKey: .homeVarEvents) ?? []
        awayVarEvents = try container.decodeIfPresent([WatchVarEvent].self, forKey: .awayVarEvents) ?? []
        teamLineups = try container.decodeIfPresent(WatchTeamLineups.self, forKey: .teamLineups)
        penaltyResult = try container.decodeIfPresent(String.self, forKey: .penaltyResult)
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
            leagueSubcategory: leagueSubcategory,
            competitionWeight: competitionWeight,
            matchDetailsIDValue: matchDetailsIDValue,
            tvChannels: tvChannels,
            homeScore: details.homeScore ?? homeScore,
            awayScore: details.awayScore ?? awayScore,
            scoreStatus: details.scoreStatus ?? scoreStatus,
            homeGoalScorers: details.homeGoalScorers,
            awayGoalScorers: details.awayGoalScorers,
            homeAssists: details.homeAssists,
            awayAssists: details.awayAssists,
            homeYellowCards: details.homeYellowCards,
            awayYellowCards: details.awayYellowCards,
            homeRedCards: details.homeRedCards,
            awayRedCards: details.awayRedCards,
            homeVarEvents: details.homeVarEvents,
            awayVarEvents: details.awayVarEvents,
            teamLineups: details.teamLineups,
            penaltyResult: details.penaltyResult ?? penaltyResult,
            homeTeamId: homeTeamId,
            awayTeamId: awayTeamId
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
        leagueSubcategory: String?,
        competitionWeight: Double?,
        matchDetailsIDValue: String?,
        tvChannels: [String],
        homeScore: Int?,
        awayScore: Int?,
        scoreStatus: String?,
        homeGoalScorers: [WatchGoalScorer],
        awayGoalScorers: [WatchGoalScorer],
        homeAssists: [WatchAssistProvider],
        awayAssists: [WatchAssistProvider],
        homeYellowCards: [WatchYellowCardEvent],
        awayYellowCards: [WatchYellowCardEvent],
        homeRedCards: [WatchRedCardEvent],
        awayRedCards: [WatchRedCardEvent],
        homeVarEvents: [WatchVarEvent],
        awayVarEvents: [WatchVarEvent],
        teamLineups: WatchTeamLineups?,
        penaltyResult: String?,
        homeTeamId: String?,
        awayTeamId: String?
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
            "home_yellow_cards": homeYellowCards.map { card in
                ["player": card.player, "yellow_card_times": card.yellowCardTimes]
            },
            "away_yellow_cards": awayYellowCards.map { card in
                ["player": card.player, "yellow_card_times": card.yellowCardTimes]
            },
            "home_red_cards": homeRedCards.map { card in
                ["player": card.player, "red_card_times": card.redCardTimes]
            },
            "away_red_cards": awayRedCards.map { card in
                ["player": card.player, "red_card_times": card.redCardTimes]
            },
            "home_var_events": homeVarEvents.map(Self.varEventDictionary),
            "away_var_events": awayVarEvents.map(Self.varEventDictionary)
        ]

        if let teamLineups,
           let lineupsData = try? JSONEncoder().encode(teamLineups),
           let lineupsObject = try? JSONSerialization.jsonObject(with: lineupsData) {
            dict["team_lineups"] = lineupsObject
        }

        if let homeShortName {
            dict["home_short_name"] = homeShortName
        }
        if let awayShortName {
            dict["away_short_name"] = awayShortName
        }
        if let leagueSubcategory {
            dict["league_subcategory"] = leagueSubcategory
        }
        if let competitionWeight {
            dict["competition_weight"] = competitionWeight
        }

        if let matchDetailsIDValue = matchDetailsIDValue {
            dict["match_details_id"] = matchDetailsIDValue
        }
        if let homeTeamId {
            dict["home_team_id"] = homeTeamId
        }
        if let awayTeamId {
            dict["away_team_id"] = awayTeamId
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

    static func varEventDictionary(_ event: WatchVarEvent) -> [String: Any] {
        var dict: [String: Any] = ["detail": event.detail]
        if let player = event.player {
            dict["player"] = player
        }
        if let minute = event.minute {
            dict["minute"] = minute
        }
        return dict
    }
}
