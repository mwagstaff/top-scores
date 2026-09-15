import Foundation
import OSLog

struct WatchAPIClient {
    let baseURL: URL
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func fetchMatches(on date: String) async throws -> [WatchMatch] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("matches"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "start", value: date),
            URLQueryItem(name: "end", value: date),
            URLQueryItem(name: "time_zone", value: TimeZone.current.identifier),
            URLQueryItem(name: "page_size", value: "200")
        ]
        guard let url = components?.url else {
            throw WatchAPIClientError.invalidHTTPResponse
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        let maxAttempts = 3
        let requestStart = DispatchTime.now()
        for attempt in 1...maxAttempts {
            do {
                let (data, response) = try await Self.session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw WatchAPIClientError.invalidHTTPResponse
                }
                guard (200...299).contains(httpResponse.statusCode) else {
                    throw WatchAPIClientError.badStatus(statusCode: httpResponse.statusCode)
                }
                let matches = try JSONDecoder().decode([WatchMatch].self, from: data)
                WatchPerformanceDiagnostics.logger.notice(
                    "Matches request completed: status=\(httpResponse.statusCode, privacy: .public) bytes=\(data.count, privacy: .public) matches=\(matches.count, privacy: .public) duration=\(WatchPerformanceDiagnostics.milliseconds(since: requestStart), privacy: .public) ms attempts=\(attempt, privacy: .public)"
                )
                return matches
            } catch {
                guard attempt < maxAttempts, isRetryable(error) else {
                    WatchPerformanceDiagnostics.logger.error(
                        "Matches request failed: duration=\(WatchPerformanceDiagnostics.milliseconds(since: requestStart), privacy: .public) ms attempt=\(attempt, privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                    throw error
                }
                WatchPerformanceDiagnostics.logger.warning(
                    "Matches request retrying: attempt=\(attempt, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                try await Task.sleep(nanoseconds: UInt64(1 << (attempt - 1)) * 500_000_000)
            }
        }

        throw WatchAPIClientError.invalidHTTPResponse
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
        let requestStart = DispatchTime.now()
        for attempt in 1...maxAttempts {
            do {
                let details = try await fetchMatchDetails(request: request)
                WatchPerformanceDiagnostics.logger.notice(
                    "Match details request completed: duration=\(WatchPerformanceDiagnostics.milliseconds(since: requestStart), privacy: .public) ms attempts=\(attempt, privacy: .public)"
                )
                return details
            } catch {
                guard attempt < maxAttempts, isRetryable(error) else {
                    WatchPerformanceDiagnostics.logger.error(
                        "Match details request failed: duration=\(WatchPerformanceDiagnostics.milliseconds(since: requestStart), privacy: .public) ms attempt=\(attempt, privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                    throw error
                }
                WatchPerformanceDiagnostics.logger.warning(
                    "Match details request retrying: attempt=\(attempt, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                try await Task.sleep(nanoseconds: UInt64(1 << (attempt - 1)) * 500_000_000)
            }
        }

        throw WatchAPIClientError.invalidHTTPResponse
    }

    private func fetchMatchDetails(request: URLRequest) async throws -> WatchMatchDetailsPayload {
        let (data, response) = try await Self.session.data(for: request)

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
            return statusCode == 429 || statusCode == 502 || statusCode == 503 || statusCode == 504
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
    func mergingLatestSummary(_ latest: WatchMatch) -> WatchMatch {
        WatchMatch(
            date: latest.date,
            time: latest.time,
            homeTeam: latest.homeTeam,
            awayTeam: latest.awayTeam,
            homeShortName: homeShortName ?? latest.homeShortName,
            awayShortName: awayShortName ?? latest.awayShortName,
            league: latest.league,
            leagueSubcategory: latest.leagueSubcategory ?? leagueSubcategory,
            competitionWeight: latest.competitionWeight ?? competitionWeight,
            watchabilityIndex: latest.watchabilityIndex ?? watchabilityIndex,
            matchDetailsIDValue: latest.matchDetailsIDValue ?? matchDetailsIDValue,
            tvChannels: latest.tvChannels.isEmpty ? tvChannels : latest.tvChannels,
            homeScore: latest.homeScore,
            awayScore: latest.awayScore,
            scoreStatus: latest.scoreStatus,
            homeGoalScorers: homeGoalScorers,
            awayGoalScorers: awayGoalScorers,
            homeAssists: homeAssists,
            awayAssists: awayAssists,
            homeYellowCards: homeYellowCards,
            awayYellowCards: awayYellowCards,
            homeRedCards: homeRedCards,
            awayRedCards: awayRedCards,
            homeVarEvents: homeVarEvents,
            awayVarEvents: awayVarEvents,
            teamLineups: teamLineups,
            penaltyResult: latest.penaltyResult ?? penaltyResult,
            homeTeamId: latest.homeTeamId ?? homeTeamId,
            awayTeamId: latest.awayTeamId ?? awayTeamId
        )
    }

    func withDetails(_ details: WatchMatchDetailsPayload) -> WatchMatch {
        WatchMatch(
            date: details.date ?? date,
            time: details.time ?? time,
            homeTeam: details.homeTeam ?? homeTeam,
            awayTeam: details.awayTeam ?? awayTeam,
            homeShortName: homeShortName ?? details.homeShortName,
            awayShortName: awayShortName ?? details.awayShortName,
            league: details.league ?? league,
            leagueSubcategory: leagueSubcategory,
            competitionWeight: competitionWeight,
            watchabilityIndex: watchabilityIndex,
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
    }
}
