import Foundation

struct APIClient {
    let baseURL: URL
    let session: URLSession
    private static let defaultPastDays = 30
    private static let defaultFutureDays = 90
    private static let maxLoggedBodyLength = 240
    private static let retryDelayNanos: UInt64 = 350_000_000
    private static let retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]

    init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session = session {
            self.session = session
        } else {
            // Clear any existing URL cache from previous app runs
            URLCache.shared.removeAllCachedResponses()

            // Create a custom URLSession with caching disabled
            let config = URLSessionConfiguration.default
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            self.session = URLSession(configuration: config)
            NSLog("[APIClient] Initialized with custom URLSession (caching disabled, cleared existing cache)")
        }
    }

    func fetchMatches(preferences: PreferencesSnapshot) async throws -> MatchResponse {
        async let fixturesTask = fetchAllMatches(preferences: preferences, mode: .fixtures)
        async let resultsTask = fetchAllMatches(preferences: preferences, mode: .results)
        let fixtures = try await fixturesTask
        let results = try await resultsTask

        var merged = fixtures.matches
        var seen = Set(merged.map(\.id))
        for match in results.matches where !seen.contains(match.id) {
            seen.insert(match.id)
            merged.append(match)
        }

        let sorted = merged.sorted {
            let leftDate = $0.dateTime ?? MatchDateParser.shared.parse(date: $0.date, time: "00:00") ?? .distantFuture
            let rightDate = $1.dateTime ?? MatchDateParser.shared.parse(date: $1.date, time: "00:00") ?? .distantFuture
            if leftDate != rightDate {
                return leftDate < rightDate
            }
            let leagueCompare = $0.league.localizedCaseInsensitiveCompare($1.league)
            if leagueCompare != .orderedSame {
                return leagueCompare == .orderedAscending
            }
            let homeCompare = $0.homeTeam.localizedCaseInsensitiveCompare($1.homeTeam)
            if homeCompare != .orderedSame {
                return homeCompare == .orderedAscending
            }
            return $0.awayTeam.localizedCaseInsensitiveCompare($1.awayTeam) == .orderedAscending
        }

        let lastUpdated: Date?
        if let fixturesUpdated = fixtures.lastUpdated, let resultsUpdated = results.lastUpdated {
            lastUpdated = max(fixturesUpdated, resultsUpdated)
        } else {
            lastUpdated = fixtures.lastUpdated ?? results.lastUpdated
        }

        return MatchResponse(matches: sorted, lastUpdated: lastUpdated)
    }

    func fetchMatchesPage(
        preferences: PreferencesSnapshot,
        mode: MatchesViewMode,
        page: Int,
        pageSize: Int = 120
    ) async throws -> MatchPageResponse {
        var queryItems: [URLQueryItem] = dateRangeQueryItems(mode: mode)
        queryItems.append(URLQueryItem(name: "sort", value: mode.sortOrder))
        queryItems.append(URLQueryItem(name: "filter_mode", value: "intersection"))
        queryItems.append(URLQueryItem(name: "page", value: String(max(1, page))))
        queryItems.append(URLQueryItem(name: "page_size", value: String(max(1, pageSize))))
        if preferences.competitionFilterEnabled {
            preferences.selectedLeagues.forEach { queryItems.append(URLQueryItem(name: "league", value: $0)) }
        }
        if mode == .fixtures && preferences.channelFilterEnabled {
            ChannelSelection.apiQueryValues(from: preferences.selectedChannels).forEach {
                queryItems.append(URLQueryItem(name: "channel", value: $0))
            }
        }
        if preferences.englishPremierLeagueTeamsOnly {
            queryItems.append(URLQueryItem(name: "epl_only", value: "true"))
        }

        let request = try buildRequest(path: "matches", queryItems: queryItems)
        let (data, http) = try await performRequest(request, operation: "matches_page")
        try validateSuccess(http, data: data, operation: "matches_page")
        let matches = try decodeMatches(from: data, operation: "matches_page")

        let lastUpdated = http
            .value(forHTTPHeaderField: "X-Last-Updated")
            .flatMap { ISO8601DateFormatter().date(from: $0) }
        let totalCount = http
            .value(forHTTPHeaderField: "X-Total-Count")
            .flatMap(Int.init) ?? matches.count
        let resolvedPage = http
            .value(forHTTPHeaderField: "X-Page")
            .flatMap(Int.init) ?? max(1, page)
        let resolvedPageSize = http
            .value(forHTTPHeaderField: "X-Page-Size")
            .flatMap(Int.init) ?? max(1, pageSize)
        let hasMore = http
            .value(forHTTPHeaderField: "X-Has-More")
            .map { $0.lowercased() == "true" }
            ?? (matches.count >= resolvedPageSize)

        return MatchPageResponse(
            matches: matches,
            lastUpdated: lastUpdated,
            page: resolvedPage,
            pageSize: resolvedPageSize,
            totalCount: totalCount,
            hasMore: hasMore
        )
    }

    func fetchCompetitions() async throws -> [String] {
        let request = try buildRequest(path: "competitions", queryItems: [])
        let (data, http) = try await performRequest(request, operation: "competitions")
        try validateSuccess(http, data: data, operation: "competitions")
        return try JSONDecoder().decode([String].self, from: data)
    }

    func fetchBbcLiveMatches() async throws -> [BbcMatch] {
        let request = try buildRequest(path: "bbc/live", queryItems: [])
        let (data, http) = try await performRequest(request, operation: "bbc_live")
        try validateSuccess(http, data: data, operation: "bbc_live")
        return try JSONDecoder().decode([BbcMatch].self, from: data)
    }

    func fetchMatchDetails(matchId: String) async throws -> MatchDetailsPayload {
        guard let normalizedID = Self.normalizedMatchDetailsID(matchId) else {
            throw APIClientError.invalidMatchDetailsID(matchId)
        }
        let request = try buildRequest(path: "matches/\(normalizedID)", queryItems: [])
        let (data, http) = try await performRequest(request, operation: "match_details")
        try validateSuccess(http, data: data, operation: "match_details")
        return try JSONDecoder().decode(MatchDetailsPayload.self, from: data)
    }

    func fetchChannels() async throws -> [String] {
        let request = try buildRequest(path: "channels", queryItems: [])
        let (data, httpResponse) = try await performRequest(request, operation: "channels")

        if httpResponse.statusCode == 404 {
            Self.log("WARN", "fallback op=channels using matches page because /channels returned 404")
            return try await fetchChannelsFromMatchesFallback()
        }

        try validateSuccess(httpResponse, data: data, operation: "channels")
        let channels = try JSONDecoder().decode([String].self, from: data)
        return ChannelSelection.selectableChannels(from: channels)
    }

    func reportMissingTeamLogos(_ teamNames: [String]) async throws {
        let normalizedTeamNames = Self.normalizedTeamNames(teamNames)
        guard !normalizedTeamNames.isEmpty else { return }

        var request = try buildRequest(path: "audit/missing-team-logos", queryItems: [])
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(normalizedTeamNames)

        let (data, httpResponse) = try await performRequest(
            request,
            operation: "audit_missing_team_logos_post"
        )

        // Allow older servers to ignore this optional telemetry endpoint.
        if httpResponse.statusCode == 404 {
            Self.log("WARN", "missing_logo_audit_endpoint_unavailable op=audit_missing_team_logos_post")
            return
        }

        try validateSuccess(httpResponse, data: data, operation: "audit_missing_team_logos_post")
    }

    func fetchMissingTeamLogosAudit() async throws -> [String] {
        let request = try buildRequest(path: "audit/missing-team-logos", queryItems: [])
        let (data, httpResponse) = try await performRequest(
            request,
            operation: "audit_missing_team_logos_get"
        )
        try validateSuccess(httpResponse, data: data, operation: "audit_missing_team_logos_get")
        return try JSONDecoder().decode([String].self, from: data)
    }

    private func fetchChannelsFromMatchesFallback() async throws -> [String] {
        var queryItems = combinedDateRangeQueryItems()
        queryItems.append(URLQueryItem(name: "page_size", value: "500"))
        let request = try buildRequest(path: "matches", queryItems: queryItems)
        let (data, http) = try await performRequest(request, operation: "channels_fallback_matches")
        try validateSuccess(http, data: data, operation: "channels_fallback_matches")
        let matches = try decodeMatches(from: data, operation: "channels_fallback_matches")
        return ChannelSelection.selectableChannels(from: matches)
    }

    private func combinedDateRangeQueryItems(now: Date = Date()) -> [URLQueryItem] {
        let calendar = Calendar.current
        let startDate = calendar.date(byAdding: .day, value: -Self.defaultPastDays, to: now) ?? now
        let endDate = calendar.date(byAdding: .day, value: Self.defaultFutureDays, to: now) ?? now
        let formatter = Self.dateFormatter
        return [
            URLQueryItem(name: "start", value: formatter.string(from: startDate)),
            URLQueryItem(name: "end", value: formatter.string(from: endDate)),
        ]
    }

    private func dateRangeQueryItems(mode: MatchesViewMode, now: Date = Date()) -> [URLQueryItem] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let startDate: Date
        let endDate: Date

        switch mode {
        case .fixtures:
            startDate = today
            endDate = calendar.date(byAdding: .day, value: Self.defaultFutureDays, to: today) ?? today
        case .results:
            startDate = calendar.date(byAdding: .day, value: -Self.defaultPastDays, to: today) ?? today
            endDate = today
        }

        let formatter = Self.dateFormatter
        return [
            URLQueryItem(name: "start", value: formatter.string(from: startDate)),
            URLQueryItem(name: "end", value: formatter.string(from: endDate)),
        ]
    }

    private func fetchAllMatches(
        preferences: PreferencesSnapshot,
        mode: MatchesViewMode
    ) async throws -> MatchResponse {
        var page = 1
        var allMatches: [Match] = []
        var seen = Set<String>()
        var lastUpdated: Date?

        while true {
            let response = try await fetchMatchesPage(
                preferences: preferences,
                mode: mode,
                page: page
            )
            response.matches.forEach { match in
                if !seen.contains(match.id) {
                    seen.insert(match.id)
                    allMatches.append(match)
                }
            }

            if let updated = response.lastUpdated {
                if let current = lastUpdated {
                    lastUpdated = max(current, updated)
                } else {
                    lastUpdated = updated
                }
            }

            if !response.hasMore || response.matches.isEmpty {
                break
            }
            page += 1
        }

        return MatchResponse(matches: allMatches, lastUpdated: lastUpdated)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func buildRequest(path: String, queryItems: [URLQueryItem]) throws -> URLRequest {
        let resolvedURL = path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
            .reduce(baseURL) { partialURL, component in
                partialURL.appendingPathComponent(component)
            }
        var components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false)
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }
        guard let url = components?.url else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        DeviceIdentity.applyHeader(to: &request)
        return request
    }

    private func performRequest(
        _ request: URLRequest,
        operation: String
    ) async throws -> (Data, HTTPURLResponse) {
        let requestID = String(UUID().uuidString.prefix(8))
        let method = request.httpMethod ?? "GET"
        let urlString = request.url?.absoluteString ?? "<unknown>"
        let maxAttempts = 2

        for attempt in 1...maxAttempts {
            let startedAt = Date()
            Self.log("INFO", "start id=\(requestID) op=\(operation) attempt=\(attempt) method=\(method) url=\(urlString)")

            do {
                let (data, response) = try await session.data(for: request)
                let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)

                guard let httpResponse = response as? HTTPURLResponse else {
                    Self.log("ERROR", "failed id=\(requestID) op=\(operation) reason=invalid_http_response duration_ms=\(durationMs)")
                    throw APIClientError.invalidHTTPResponse(url: urlString)
                }

                let dataSource = httpResponse.value(forHTTPHeaderField: "X-Data-Source") ?? "-"
                let externalDependency = httpResponse.value(forHTTPHeaderField: "X-External-Dependency") ?? "-"
                Self.log(
                    "INFO",
                    "done id=\(requestID) op=\(operation) attempt=\(attempt) status=\(httpResponse.statusCode) bytes=\(data.count) duration_ms=\(durationMs) source=\(dataSource) external=\(externalDependency)"
                )

                if attempt < maxAttempts && Self.retryableStatusCodes.contains(httpResponse.statusCode) {
                    Self.log("WARN", "retrying id=\(requestID) op=\(operation) next_attempt=\(attempt + 1) reason=status_\(httpResponse.statusCode)")
                    try? await Task.sleep(nanoseconds: Self.retryDelayNanos)
                    continue
                }

                return (data, httpResponse)
            } catch {
                let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                Self.log("ERROR", "failed id=\(requestID) op=\(operation) attempt=\(attempt) error=\(error) duration_ms=\(durationMs)")

                if attempt < maxAttempts, Self.isRetryable(error: error) {
                    Self.log("WARN", "retrying id=\(requestID) op=\(operation) next_attempt=\(attempt + 1) reason=transient_error")
                    try? await Task.sleep(nanoseconds: Self.retryDelayNanos)
                    continue
                }

                throw error
            }
        }

        throw APIClientError.invalidHTTPResponse(url: urlString)
    }

    private func validateSuccess(
        _ response: HTTPURLResponse,
        data: Data,
        operation: String
    ) throws {
        if response.statusCode == 304, !data.isEmpty {
            Self.log(
                "WARN",
                "not_modified_with_body op=\(operation) status=304 bytes=\(data.count) proceeding_with_cached_body"
            )
            return
        }
        guard (200...299).contains(response.statusCode) else {
            let snippet = String(
                (String(data: data, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(Self.maxLoggedBodyLength)
            )
            let urlString = response.url?.absoluteString ?? "<unknown>"
            Self.log("ERROR", "bad_status op=\(operation) status=\(response.statusCode) url=\(urlString) body=\(snippet)")
            throw APIClientError.badStatus(
                statusCode: response.statusCode,
                url: urlString,
                bodySnippet: snippet
            )
        }
    }

    private func decodeMatches(from data: Data, operation: String) throws -> [Match] {
        do {
            return try JSONDecoder().decode([Match].self, from: data)
        } catch {
            Self.log("WARN", "decode_failed op=\(operation) strategy=lossy error=\(error)")
            return try decodeMatchesLossy(from: data, operation: operation)
        }
    }

    private func decodeMatchesLossy(from data: Data, operation: String) throws -> [Match] {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let items = root as? [Any] else {
            throw APIClientError.invalidMatchesPayload(
                operation: operation,
                reason: "Expected top-level JSON array"
            )
        }

        var decoded: [Match] = []
        decoded.reserveCapacity(items.count)
        let decoder = JSONDecoder()

        for (index, item) in items.enumerated() {
            guard JSONSerialization.isValidJSONObject(item) else {
                Self.log("WARN", "decode_skip op=\(operation) index=\(index) reason=invalid_json_object")
                continue
            }
            do {
                let itemData = try JSONSerialization.data(withJSONObject: item)
                let match = try decoder.decode(Match.self, from: itemData)
                decoded.append(match)
            } catch {
                Self.log("WARN", "decode_skip op=\(operation) index=\(index) error=\(error)")
            }
        }

        Self.log("INFO", "decode_lossy_done op=\(operation) kept=\(decoded.count) dropped=\(items.count - decoded.count)")
        return decoded
    }

    private static func log(_ level: String, _ message: String) {
        let line = "[APIClient][\(level)] \(message)"
        NSLog("%@", line)
    }

    private static func isRetryable(error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    private static func normalizedMatchDetailsID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
    }

    private static func normalizedTeamNames(_ teamNames: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for teamName in teamNames {
            let normalized = teamName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            guard !normalized.isEmpty else { continue }
            let key = normalized.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            ordered.append(normalized)
        }

        return ordered
    }
}

enum APIClientError: LocalizedError {
    case invalidHTTPResponse(url: String)
    case badStatus(statusCode: Int, url: String, bodySnippet: String)
    case invalidMatchesPayload(operation: String, reason: String)
    case invalidMatchDetailsID(String)

    var errorDescription: String? {
        switch self {
        case let .invalidHTTPResponse(url):
            return "Invalid HTTP response for request: \(url)"
        case let .badStatus(statusCode, url, bodySnippet):
            if bodySnippet.isEmpty {
                return "Request failed with status \(statusCode): \(url)"
            }
            return "Request failed with status \(statusCode): \(url) body=\(bodySnippet)"
        case let .invalidMatchesPayload(operation, reason):
            return "Invalid matches payload for \(operation): \(reason)"
        case let .invalidMatchDetailsID(matchId):
            return "Invalid match details id: \(matchId)"
        }
    }
}

struct MatchResponse {
    let matches: [Match]
    let lastUpdated: Date?
}

struct MatchPageResponse {
    let matches: [Match]
    let lastUpdated: Date?
    let page: Int
    let pageSize: Int
    let totalCount: Int
    let hasMore: Bool
}

private extension MatchesViewMode {
    var sortOrder: String {
        switch self {
        case .fixtures:
            return "asc"
        case .results:
            return "desc"
        }
    }
}

struct BbcMatch: Codable, Hashable {
    let homeTeam: String
    let awayTeam: String
    let homeScore: Int
    let awayScore: Int
    let matchTime: String
    let detailsURL: String?
    let homeGoalScorers: [MatchGoalScorer]
    let awayGoalScorers: [MatchGoalScorer]
    let homeAssists: [MatchAssistProvider]
    let awayAssists: [MatchAssistProvider]
    let homeRedCards: [MatchRedCardEvent]
    let awayRedCards: [MatchRedCardEvent]

    enum CodingKeys: String, CodingKey {
        case homeTeam = "home_team"
        case awayTeam = "away_team"
        case homeScore = "home_score"
        case awayScore = "away_score"
        case matchTime = "match_time"
        case detailsURL = "details_url"
        case homeGoalScorers = "home_goal_scorers"
        case awayGoalScorers = "away_goal_scorers"
        case homeAssists = "home_assists"
        case awayAssists = "away_assists"
        case homeRedCards = "home_red_cards"
        case awayRedCards = "away_red_cards"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        homeTeam = try container.decode(String.self, forKey: .homeTeam)
        awayTeam = try container.decode(String.self, forKey: .awayTeam)
        homeScore = try container.decode(Int.self, forKey: .homeScore)
        awayScore = try container.decode(Int.self, forKey: .awayScore)
        matchTime = try container.decode(String.self, forKey: .matchTime)
        detailsURL = try container.decodeIfPresent(String.self, forKey: .detailsURL)
        homeGoalScorers = try container.decodeIfPresent([MatchGoalScorer].self, forKey: .homeGoalScorers) ?? []
        awayGoalScorers = try container.decodeIfPresent([MatchGoalScorer].self, forKey: .awayGoalScorers) ?? []
        homeAssists = try container.decodeIfPresent([MatchAssistProvider].self, forKey: .homeAssists) ?? []
        awayAssists = try container.decodeIfPresent([MatchAssistProvider].self, forKey: .awayAssists) ?? []
        homeRedCards = try container.decodeIfPresent([MatchRedCardEvent].self, forKey: .homeRedCards) ?? []
        awayRedCards = try container.decodeIfPresent([MatchRedCardEvent].self, forKey: .awayRedCards) ?? []
    }
}
