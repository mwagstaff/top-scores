import Foundation

struct FantasyPublicAPIClient {
    private static let gameUpdatingNeedle = "the game is being updated"

    private static func makeNoCacheSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }

    let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? Self.makeNoCacheSession()
    }

    func fetchPicks(entryID: Int, eventID: Int) async throws -> FantasyPicksResponse {
        guard let url = URL(
            string: "https://fantasy.premierleague.com/api/entry/\(entryID)/event/\(eventID)/picks/"
        ) else {
            throw FantasyPublicAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await fetch(request, operation: "fpl_picks")
    }

    func fetchEventLive(eventID: Int) async throws -> FantasyEventLiveResponse {
        guard let url = URL(
            string: "https://fantasy.premierleague.com/api/event/\(eventID)/live/"
        ) else {
            throw FantasyPublicAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await fetch(request, operation: "fpl_event_live")
    }

    func fetchEventFixtures(eventID: Int) async throws -> [FantasyFixture] {
        guard let url = URL(
            string: "https://fantasy.premierleague.com/api/fixtures/?event=\(eventID)"
        ) else {
            throw FantasyPublicAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await fetch(request, operation: "fpl_event_fixtures")
    }

    func fetchAllFixtures() async throws -> [FantasyFixture] {
        guard let url = URL(
            string: "https://fantasy.premierleague.com/api/fixtures/"
        ) else {
            throw FantasyPublicAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await fetch(request, operation: "fpl_all_fixtures")
    }

    func fetchEntryProfile(entryID: Int) async throws -> FantasyEntryProfile {
        guard let url = URL(
            string: "https://fantasy.premierleague.com/api/entry/\(entryID)/"
        ) else {
            throw FantasyPublicAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await fetch(request, operation: "fpl_entry_profile")
    }

    func fetchElementSummary(elementID: Int) async throws -> FantasyElementSummaryResponse {
        guard let url = URL(
            string: "https://fantasy.premierleague.com/api/element-summary/\(elementID)/"
        ) else {
            throw FantasyPublicAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await fetch(request, operation: "fpl_element_summary")
    }

    func fetchBootstrapStatic() async throws -> FantasyBootstrapLookup {
        guard let url = URL(
            string: "https://fantasy.premierleague.com/api/bootstrap-static/"
        ) else {
            throw FantasyPublicAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await fetch(request, operation: "fpl_bootstrap_static")
    }

    func fetchLeagueStandings(leagueID: Int, page: Int = 1) async throws -> FantasyLeagueStandingsResponse {
        guard let url = URL(
            string: "https://fantasy.premierleague.com/api/leagues-classic/\(leagueID)/standings/?page_standings=\(page)"
        ) else {
            throw FantasyPublicAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await fetch(request, operation: "fpl_league_standings")
    }

    private func fetch<T: Decodable>(_ request: URLRequest, operation: String) async throws -> T {
        let (data, response) = try await session.data(for: request)
        if let gameUpdatingMessage = Self.extractGameUpdatingMessage(from: data) {
            throw FantasyPublicAPIError.gameUpdating(
                operation: operation,
                message: gameUpdatingMessage
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw FantasyPublicAPIError.invalidHTTPResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let snippet = String((String(data: data, encoding: .utf8) ?? "").prefix(240))
            throw FantasyPublicAPIError.badStatus(http.statusCode, operation: operation, snippet: snippet)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw FantasyPublicAPIError.decodeFailed(operation: operation, underlying: error)
        }
    }

    private static func extractGameUpdatingMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        if let payload = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if let message = messageIfGameUpdating(from: payload) {
                return message
            }
        }

        guard let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        let unquoted = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard containsGameUpdatingText(unquoted) else { return nil }
        return unquoted
    }

    private static func messageIfGameUpdating(from payload: Any) -> String? {
        if let stringPayload = payload as? String {
            let trimmed = stringPayload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard containsGameUpdatingText(trimmed) else { return nil }
            return trimmed
        }

        guard let objectPayload = payload as? [String: Any] else { return nil }
        let candidateKeys = ["error", "message", "detail"]
        for key in candidateKeys {
            guard let value = objectPayload[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard containsGameUpdatingText(trimmed) else { continue }
            return trimmed
        }

        return nil
    }

    private static func containsGameUpdatingText(_ value: String) -> Bool {
        let normalized = value
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.contains(gameUpdatingNeedle)
    }
}

enum FantasyPublicAPIError: LocalizedError {
    case invalidURL
    case invalidHTTPResponse
    case badStatus(Int, operation: String, snippet: String)
    case decodeFailed(operation: String, underlying: Error)
    case gameUpdating(operation: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Fantasy Premier League API URL."
        case .invalidHTTPResponse:
            return "Fantasy Premier League API returned an invalid HTTP response."
        case let .badStatus(statusCode, operation, snippet):
            if snippet.isEmpty {
                return "Fantasy Premier League API request failed (\(operation), HTTP \(statusCode))."
            }
            return "Fantasy Premier League API request failed (\(operation), HTTP \(statusCode)): \(snippet)"
        case let .decodeFailed(operation, underlying):
            return "Failed to decode Fantasy Premier League API payload (\(operation)): \(underlying.localizedDescription)"
        case .gameUpdating:
            return "Fantasy Premier League data is temporarily unavailable while the official game is being updated. Please try again in a few minutes."
        }
    }
}
