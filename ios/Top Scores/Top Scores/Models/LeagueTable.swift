import Foundation

struct LeagueTablesEnvelope: Codable, Hashable {
    let updatedAt: String?
    let count: Int?
    let leagues: [LeagueTable]

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case count
        case leagues
    }
}

struct LeagueTable: Identifiable, Codable, Hashable {
    let leagueID: String
    let leagueName: String
    let stageName: String?
    let sourceURL: String?
    let updatedAt: String?
    let rows: [LeagueTableRow]

    var id: String {
        leagueID
    }

    enum CodingKeys: String, CodingKey {
        case leagueID = "league_id"
        case leagueName = "league_name"
        case stageName = "stage_name"
        case sourceURL = "source_url"
        case updatedAt = "updated_at"
        case rows
    }
}

struct LeagueTableRow: Identifiable, Codable, Hashable {
    let position: Int
    let team: String
    let played: Int
    let won: Int
    let drawn: Int
    let lost: Int
    let goalsFor: Int
    let goalsAgainst: Int
    let goalDifference: Int
    let points: Int
    let form: [String]
    let rankStatus: String?

    var id: String {
        "\(position)-\(team)"
    }

    enum CodingKeys: String, CodingKey {
        case position
        case team
        case played
        case won
        case drawn
        case lost
        case goalsFor = "goals_for"
        case goalsAgainst = "goals_against"
        case goalDifference = "goal_difference"
        case points
        case form
        case rankStatus = "rank_status"
    }
}

struct LeagueTablesCachePayload: Codable, Sendable {
    let fetchedAt: Date
    let response: LeagueTablesResponse

    nonisolated init(fetchedAt: Date, response: LeagueTablesResponse) {
        self.fetchedAt = fetchedAt
        self.response = response
    }
}

enum LeagueTablesCache {
    nonisolated static func load(for apiBaseURL: String) -> LeagueTablesCachePayload? {
        guard let data = try? Data(contentsOf: cacheURL(for: apiBaseURL)) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LeagueTablesCachePayload.self, from: data)
    }

    nonisolated static func save(response: LeagueTablesResponse, fetchedAt: Date, apiBaseURL: String) {
        let payload = LeagueTablesCachePayload(
            fetchedAt: fetchedAt,
            response: response
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }

        try? data.write(to: cacheURL(for: apiBaseURL), options: [.atomic])
    }

    private nonisolated static func cacheURL(for apiBaseURL: String) -> URL {
        let fileManager = FileManager.default
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("TopScores", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(cacheFileName(for: apiBaseURL))
    }

    private nonisolated static func cacheFileName(for apiBaseURL: String) -> String {
        let slug = apiBaseURL
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        let resolvedSlug = slug.isEmpty ? "default" : String(slug.prefix(80))
        return "league-tables-\(resolvedSlug).json"
    }
}

enum LeagueTablesCatalogError: LocalizedError {
    case invalidBaseURL(String)

    var errorDescription: String? {
        switch self {
        case let .invalidBaseURL(value):
            return "Invalid API base URL: \(value)"
        }
    }
}

actor LeagueTablesCatalog {
    static let shared = LeagueTablesCatalog()

    private static let cacheTTL: TimeInterval = 6 * 60 * 60

    private var loadedBaseURLs: Set<String> = []
    private var cachedResponses: [String: LeagueTablesResponse] = [:]
    private var cachedFetchedAt: [String: Date] = [:]
    private var refreshTasks: [String: Task<LeagueTablesResponse, Error>] = [:]

    private init() {}

    func cachedResponse(apiBaseURL: String) -> LeagueTablesResponse? {
        loadCacheIfNeeded(apiBaseURL: apiBaseURL)
        return cachedResponses[apiBaseURL]
    }

    func prefetch(apiBaseURL: String, force: Bool = false) async {
        _ = try? await refresh(apiBaseURL: apiBaseURL, force: force)
    }

    @discardableResult
    func refresh(apiBaseURL: String, force: Bool = false) async throws -> LeagueTablesResponse {
        loadCacheIfNeeded(apiBaseURL: apiBaseURL)

        if !force,
           let cached = cachedResponses[apiBaseURL],
           !shouldRefresh(now: Date(), apiBaseURL: apiBaseURL) {
            return cached
        }

        if let inFlight = refreshTasks[apiBaseURL] {
            return try await inFlight.value
        }

        guard let baseURL = URL(string: apiBaseURL) else {
            throw LeagueTablesCatalogError.invalidBaseURL(apiBaseURL)
        }

        let task = Task<LeagueTablesResponse, Error> {
            let client = APIClient(baseURL: baseURL)
            return try await client.fetchLeagueTables()
        }

        refreshTasks[apiBaseURL] = task
        defer { refreshTasks[apiBaseURL] = nil }

        let response = try await task.value
        guard !response.leagues.isEmpty else {
            if let cached = cachedResponses[apiBaseURL] {
                log("League tables refresh returned an empty payload; keeping cached tables.")
                return cached
            }
            return response
        }

        store(response: response, fetchedAt: Date(), apiBaseURL: apiBaseURL)
        return response
    }

    private func shouldRefresh(now: Date, apiBaseURL: String) -> Bool {
        guard let fetchedAt = cachedFetchedAt[apiBaseURL] else {
            return true
        }
        return now.timeIntervalSince(fetchedAt) >= Self.cacheTTL
            || (cachedResponses[apiBaseURL]?.leagues.isEmpty ?? true)
    }

    private func loadCacheIfNeeded(apiBaseURL: String) {
        guard loadedBaseURLs.insert(apiBaseURL).inserted else { return }
        guard let payload = LeagueTablesCache.load(for: apiBaseURL) else { return }

        cachedResponses[apiBaseURL] = payload.response
        cachedFetchedAt[apiBaseURL] = payload.fetchedAt
    }

    private func store(response: LeagueTablesResponse, fetchedAt: Date, apiBaseURL: String) {
        cachedResponses[apiBaseURL] = response
        cachedFetchedAt[apiBaseURL] = fetchedAt
        LeagueTablesCache.save(response: response, fetchedAt: fetchedAt, apiBaseURL: apiBaseURL)
    }

    private func log(_ message: String) {
        NSLog("[LeagueTablesCatalog] %@", message)
    }
}
