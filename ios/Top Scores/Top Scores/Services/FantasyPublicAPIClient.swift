import Foundation

struct FantasyPublicAPIClient {
    private static let noCacheSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    let session: URLSession

    init(session: URLSession = FantasyPublicAPIClient.noCacheSession) {
        self.session = session
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

    private func fetch<T: Decodable>(_ request: URLRequest, operation: String) async throws -> T {
        let (data, response) = try await session.data(for: request)
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
}

enum FantasyPublicAPIError: LocalizedError {
    case invalidURL
    case invalidHTTPResponse
    case badStatus(Int, operation: String, snippet: String)
    case decodeFailed(operation: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Fantasy Football API URL."
        case .invalidHTTPResponse:
            return "Fantasy Football API returned an invalid HTTP response."
        case let .badStatus(statusCode, operation, snippet):
            if snippet.isEmpty {
                return "Fantasy Football API request failed (\(operation), HTTP \(statusCode))."
            }
            return "Fantasy Football API request failed (\(operation), HTTP \(statusCode)): \(snippet)"
        case let .decodeFailed(operation, underlying):
            return "Failed to decode Fantasy Football API payload (\(operation)): \(underlying.localizedDescription)"
        }
    }
}
