import Foundation

struct APIClient {
    let baseURL: URL
    let session: URLSession
    private static let defaultPastDays = 30
    private static let defaultFutureDays = 90
    private static let maxLoggedBodyLength = 240
    private static let retryDelayNanos: UInt64 = 350_000_000
    private static let retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]
    private static let sharedNoCacheSession: URLSession = {
        URLCache.shared.removeAllCachedResponses()
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session = session {
            self.session = session
        } else {
            self.session = Self.sharedNoCacheSession
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
        let matches = try await hydrateMatchStates(
            try decodeMatches(from: data, operation: "matches_page")
        )

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

    func fetchCacheState() async throws -> CacheGenerationSnapshot {
        let request = try buildRequest(path: "cache-state", queryItems: [])
        let (data, http) = try await performRequest(request, operation: "cache_state")
        try validateSuccess(http, data: data, operation: "cache_state")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(CacheStateResponse.self, from: data)
        return payload.generations
    }

    func fetchBbcLiveMatches() async throws -> [BbcMatch] {
        let request = try buildRequest(path: "bbc/live", queryItems: [])
        let (data, http) = try await performRequest(request, operation: "bbc_live")
        try validateSuccess(http, data: data, operation: "bbc_live")
        return try JSONDecoder().decode([BbcMatch].self, from: data)
    }

    func fetchLeagueTables() async throws -> LeagueTablesResponse {
        let request = try buildRequest(path: "tables", queryItems: [])
        let (data, http) = try await performRequest(request, operation: "league_tables")
        try validateSuccess(http, data: data, operation: "league_tables")
        let payload = try JSONDecoder().decode(LeagueTablesEnvelope.self, from: data)

        let formatter = ISO8601DateFormatter()
        let headerUpdatedAt = http
            .value(forHTTPHeaderField: "X-Last-Updated")
            .flatMap { formatter.date(from: $0) }
        let bodyUpdatedAt = payload.updatedAt.flatMap { formatter.date(from: $0) }

        return LeagueTablesResponse(
            leagues: payload.leagues,
            lastUpdated: headerUpdatedAt ?? bodyUpdatedAt
        )
    }

    func fetchFantasyCurrentGameweek() async throws -> FantasyGameweek {
        let request = try buildRequest(path: "fantasy/gameweek/current", queryItems: [])
        let (data, http) = try await performRequest(request, operation: "fantasy_gameweek_current")
        try validateSuccess(http, data: data, operation: "fantasy_gameweek_current")
        return try JSONDecoder().decode(FantasyGameweek.self, from: data)
    }

    func fetchFantasyBootstrapLookup() async throws -> FantasyBootstrapLookup {
        let request = try buildRequest(path: "fantasy/bootstrap/lookup", queryItems: [])
        let (data, http) = try await performRequest(request, operation: "fantasy_bootstrap_lookup")
        try validateSuccess(http, data: data, operation: "fantasy_bootstrap_lookup")
        return try JSONDecoder().decode(FantasyBootstrapLookup.self, from: data)
    }

    func fetchFantasyTeamShortNameMappings() async throws -> FantasyTeamShortNameMappingsResponse {
        let request = try buildRequest(path: "fantasy/team-short-name-mappings", queryItems: [])
        let (data, http) = try await performRequest(
            request,
            operation: "fantasy_team_short_name_mappings"
        )
        try validateSuccess(http, data: data, operation: "fantasy_team_short_name_mappings")
        return try JSONDecoder().decode(FantasyTeamShortNameMappingsResponse.self, from: data)
    }

    func fetchFantasyLoadingMessages() async throws -> FantasyLoadingMessagesResponse {
        let request = try buildRequest(path: "fantasy/loading-messages", queryItems: [])
        let (data, http) = try await performRequest(
            request,
            operation: "fantasy_loading_messages"
        )
        try validateSuccess(http, data: data, operation: "fantasy_loading_messages")
        return try JSONDecoder().decode(FantasyLoadingMessagesResponse.self, from: data)
    }

    func fetchFantasyTransferRecommendations(
        elementID: Int,
        valueWindowMillions: Double = 1.5,
        budgetDiscountFraction: Double = 0.30,
        limit: Int = 10
    ) async throws -> FantasyTransferRecommendationsResponse {
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "value_window_millions", value: String(valueWindowMillions)),
            URLQueryItem(name: "budget_discount_fraction", value: String(budgetDiscountFraction)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        let request = try buildRequest(
            path: "fantasy/transfers/recommendations/\(elementID)",
            queryItems: queryItems
        )
        let (data, http) = try await performRequest(
            request,
            operation: "fantasy_transfer_recommendations"
        )
        try validateSuccess(http, data: data, operation: "fantasy_transfer_recommendations")
        return try JSONDecoder().decode(FantasyTransferRecommendationsResponse.self, from: data)
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

    func fetchMatchStates(matchIDs: [String]) async throws -> [String: MatchDetailsPayload] {
        let normalizedIDs = Array(
            Set(matchIDs.compactMap { Self.normalizedMatchDetailsID($0) })
        ).sorted()
        guard !normalizedIDs.isEmpty else { return [:] }

        var request = try buildRequest(path: "matches/states", queryItems: [])
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(MatchStatesRequestBody(ids: normalizedIDs))

        let (data, http) = try await performRequest(request, operation: "match_states")
        try validateSuccess(http, data: data, operation: "match_states")
        let payloads = try JSONDecoder().decode([MatchDetailsPayload].self, from: data)

        var byID: [String: MatchDetailsPayload] = [:]
        payloads.forEach { payload in
            byID[payload.id] = payload
        }
        return byID
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

    func fetchTeamRanking(teamName: String, type: String? = "club") async throws -> TeamRankingEntry? {
        let trimmedTeamName = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTeamName.isEmpty else { return nil }

        var queryItems: [URLQueryItem] = []
        if let type, !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "type", value: type))
        }

        // Defensive normalization for path components that may contain separators.
        let sanitizedPathTeamName = trimmedTeamName.replacingOccurrences(of: "/", with: " ")
        let request = try buildRequest(path: "teams/\(sanitizedPathTeamName)", queryItems: queryItems)
        let (data, http) = try await performRequest(request, operation: "team_ranking_lookup")
        if http.statusCode == 404 {
            return nil
        }
        try validateSuccess(http, data: data, operation: "team_ranking_lookup")
        return try JSONDecoder().decode(TeamRankingEntry.self, from: data)
    }

    func fetchTeamRankings(type: String? = "club") async throws -> [TeamRankingEntry] {
        var queryItems: [URLQueryItem] = []
        if let type, !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "type", value: type))
        }

        let request = try buildRequest(path: "teams", queryItems: queryItems)
        let (data, http) = try await performRequest(request, operation: "team_rankings")
        try validateSuccess(http, data: data, operation: "team_rankings")
        return try JSONDecoder().decode([TeamRankingEntry].self, from: data)
    }

    func fetchTeamRankingSettings() async throws -> TeamRankingSettingsResponse {
        let request = try buildRequest(path: "teams/config", queryItems: [])
        let (data, http) = try await performRequest(request, operation: "team_ranking_settings")
        try validateSuccess(http, data: data, operation: "team_ranking_settings")
        return try JSONDecoder().decode(TeamRankingSettingsResponse.self, from: data)
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

    private func hydrateMatchStates(_ matches: [Match]) async throws -> [Match] {
        let ids = matches.compactMap(\.matchDetailsID)
        guard !ids.isEmpty else { return matches }

        let statesByID = try await fetchMatchStates(matchIDs: ids)
        guard !statesByID.isEmpty else { return matches }

        return matches.map { match in
            guard let matchDetailsID = match.matchDetailsID,
                  let details = statesByID[matchDetailsID] else {
                return match
            }
            return match.withDetails(details)
        }
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

private struct MatchStatesRequestBody: Encodable {
    let ids: [String]
}

private struct CacheStateResponse: Decodable {
    let updatedAt: Date?
    let domains: CacheStateDomainsResponse

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case domains
    }

    var generations: CacheGenerationSnapshot {
        CacheGenerationSnapshot(
            matches: domains.matches?.generation ?? 0,
            matchDetails: domains.matchDetails?.generation ?? 0,
            bbcLive: domains.bbcLive?.generation ?? 0,
            updatedAt: updatedAt
        )
    }
}

private struct CacheStateDomainsResponse: Decodable {
    let matches: CacheStateDomainResponse?
    let matchDetails: CacheStateDomainResponse?
    let bbcLive: CacheStateDomainResponse?

    enum CodingKeys: String, CodingKey {
        case matches
        case matchDetails = "match_details"
        case bbcLive = "bbc_live"
    }
}

private struct CacheStateDomainResponse: Decodable {
    let generation: Int
}

struct LeagueTablesResponse: Codable, Hashable {
    let leagues: [LeagueTable]
    let lastUpdated: Date?
}

struct TeamRankingEntry: Codable, Hashable {
    let name: String
    let points: Double?
    let aliases: [String]

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case nameLower = "name"
        case points = "Points"
        case pointsLower = "points"
        case elo = "elo"
        case rating = "rating"
        case aliases = "aliases"
        case aliasesUpper = "Aliases"
    }

    init(name: String, points: Double?, aliases: [String]) {
        self.name = name
        self.points = points
        self.aliases = aliases
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let primaryName = try container.decodeIfPresent(String.self, forKey: .name) {
            name = primaryName
        } else if let fallbackName = try container.decodeIfPresent(String.self, forKey: .nameLower) {
            name = fallbackName
        } else {
            name = ""
        }

        if let numericPoints = try container.decodeIfPresent(Double.self, forKey: .points) {
            points = numericPoints
        } else if let numericPoints = try container.decodeIfPresent(Double.self, forKey: .pointsLower) {
            points = numericPoints
        } else if let numericPoints = try container.decodeIfPresent(Double.self, forKey: .elo) {
            points = numericPoints
        } else if let numericPoints = try container.decodeIfPresent(Double.self, forKey: .rating) {
            points = numericPoints
        } else if let stringPoints = try container.decodeIfPresent(String.self, forKey: .points),
                  let parsed = Double(stringPoints) {
            points = parsed
        } else if let stringPoints = try container.decodeIfPresent(String.self, forKey: .pointsLower),
                  let parsed = Double(stringPoints) {
            points = parsed
        } else if let stringPoints = try container.decodeIfPresent(String.self, forKey: .elo),
                  let parsed = Double(stringPoints) {
            points = parsed
        } else if let stringPoints = try container.decodeIfPresent(String.self, forKey: .rating),
                  let parsed = Double(stringPoints) {
            points = parsed
        } else {
            points = nil
        }

        if let primaryAliases = try container.decodeIfPresent([String].self, forKey: .aliases) {
            aliases = primaryAliases
        } else if let fallbackAliases = try container.decodeIfPresent([String].self, forKey: .aliasesUpper) {
            aliases = fallbackAliases
        } else {
            aliases = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(points, forKey: .points)
        try container.encode(aliases, forKey: .aliases)
    }
}

struct TeamRankingSettingsResponse: Codable, Hashable {
    let defaultElo: Double
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case defaultElo = "default_elo"
        case updatedAt = "updated_at"
    }

    init(defaultElo: Double, updatedAt: Date?) {
        self.defaultElo = defaultElo
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let numericValue = try container.decodeIfPresent(Double.self, forKey: .defaultElo) {
            defaultElo = numericValue
        } else if let stringValue = try container.decodeIfPresent(String.self, forKey: .defaultElo),
                  let parsed = Double(stringValue) {
            defaultElo = parsed
        } else {
            defaultElo = TeamRankingSettings.defaultDefaultElo
        }

        if let updatedAtString = try container.decodeIfPresent(String.self, forKey: .updatedAt) {
            updatedAt = ISO8601DateFormatter().date(from: updatedAtString)
        } else {
            updatedAt = nil
        }
    }
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
    let aggregateHomeScore: Int?
    let aggregateAwayScore: Int?
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
        case aggregateHomeScore = "aggregate_home_score"
        case aggregateAwayScore = "aggregate_away_score"
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
        aggregateHomeScore = try container.decodeIfPresent(Int.self, forKey: .aggregateHomeScore)
        aggregateAwayScore = try container.decodeIfPresent(Int.self, forKey: .aggregateAwayScore)
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
