import Foundation

struct LeagueTablesEnvelope: Codable, Hashable, Sendable {
    let updatedAt: String?
    let count: Int?
    let leagues: [LeagueTable]

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case count
        case leagues
    }

    nonisolated init(updatedAt: String?, count: Int?, leagues: [LeagueTable]) {
        self.updatedAt = updatedAt
        self.count = count
        self.leagues = leagues
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        count = try container.decodeIfPresent(Int.self, forKey: .count)
        leagues = try container.decodeIfPresent([LeagueTable].self, forKey: .leagues) ?? []
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(count, forKey: .count)
        try container.encode(leagues, forKey: .leagues)
    }
}

struct LeagueTable: Identifiable, Codable, Hashable, Sendable {
    let leagueID: String
    let leagueName: String
    let stageName: String?
    let sourceURL: String?
    let updatedAt: String?
    let groups: [LeagueTableGroup]
    let rows: [LeagueTableRow]

    nonisolated var id: String {
        leagueID
    }

    enum CodingKeys: String, CodingKey {
        case leagueID = "league_id"
        case leagueName = "league_name"
        case stageName = "stage_name"
        case sourceURL = "source_url"
        case updatedAt = "updated_at"
        case groups
        case rows
    }

    nonisolated init(
        leagueID: String,
        leagueName: String,
        stageName: String?,
        sourceURL: String?,
        updatedAt: String?,
        groups: [LeagueTableGroup] = [],
        rows: [LeagueTableRow]
    ) {
        self.leagueID = leagueID
        self.leagueName = leagueName
        self.stageName = stageName
        self.sourceURL = sourceURL
        self.updatedAt = updatedAt
        self.groups = groups
        self.rows = rows
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        leagueID = try container.decode(String.self, forKey: .leagueID)
        leagueName = try container.decode(String.self, forKey: .leagueName)
        stageName = try container.decodeIfPresent(String.self, forKey: .stageName)
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        groups = try container.decodeIfPresent([LeagueTableGroup].self, forKey: .groups) ?? []
        rows = try container.decodeIfPresent([LeagueTableRow].self, forKey: .rows) ?? []
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(leagueID, forKey: .leagueID)
        try container.encode(leagueName, forKey: .leagueName)
        try container.encodeIfPresent(stageName, forKey: .stageName)
        try container.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encode(groups, forKey: .groups)
        try container.encode(rows, forKey: .rows)
    }
}

struct LeagueTableGroup: Identifiable, Codable, Hashable, Sendable {
    let name: String?
    let rows: [LeagueTableRow]

    nonisolated var id: String {
        let rowIDs = rows.map(\.id).joined(separator: "|")
        return "\(name ?? "table")-\(rowIDs)"
    }

    enum CodingKeys: String, CodingKey {
        case name
        case rows
    }

    nonisolated init(name: String?, rows: [LeagueTableRow]) {
        self.name = name
        self.rows = rows
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        rows = try container.decodeIfPresent([LeagueTableRow].self, forKey: .rows) ?? []
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(rows, forKey: .rows)
    }
}

struct LeagueTableRow: Identifiable, Codable, Hashable, Sendable {
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

    nonisolated var id: String {
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

    nonisolated init(
        position: Int,
        team: String,
        played: Int,
        won: Int,
        drawn: Int,
        lost: Int,
        goalsFor: Int,
        goalsAgainst: Int,
        goalDifference: Int,
        points: Int,
        form: [String],
        rankStatus: String?
    ) {
        self.position = position
        self.team = team
        self.played = played
        self.won = won
        self.drawn = drawn
        self.lost = lost
        self.goalsFor = goalsFor
        self.goalsAgainst = goalsAgainst
        self.goalDifference = goalDifference
        self.points = points
        self.form = form
        self.rankStatus = rankStatus
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try container.decode(Int.self, forKey: .position)
        team = try container.decode(String.self, forKey: .team)
        played = try container.decode(Int.self, forKey: .played)
        won = try container.decode(Int.self, forKey: .won)
        drawn = try container.decode(Int.self, forKey: .drawn)
        lost = try container.decode(Int.self, forKey: .lost)
        goalsFor = try container.decode(Int.self, forKey: .goalsFor)
        goalsAgainst = try container.decode(Int.self, forKey: .goalsAgainst)
        goalDifference = try container.decode(Int.self, forKey: .goalDifference)
        points = try container.decode(Int.self, forKey: .points)
        form = try container.decodeIfPresent([String].self, forKey: .form) ?? []
        rankStatus = try container.decodeIfPresent(String.self, forKey: .rankStatus)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(position, forKey: .position)
        try container.encode(team, forKey: .team)
        try container.encode(played, forKey: .played)
        try container.encode(won, forKey: .won)
        try container.encode(drawn, forKey: .drawn)
        try container.encode(lost, forKey: .lost)
        try container.encode(goalsFor, forKey: .goalsFor)
        try container.encode(goalsAgainst, forKey: .goalsAgainst)
        try container.encode(goalDifference, forKey: .goalDifference)
        try container.encode(points, forKey: .points)
        try container.encode(form, forKey: .form)
        try container.encodeIfPresent(rankStatus, forKey: .rankStatus)
    }
}

struct LeagueTablesCachePayload: Codable, Sendable {
    let fetchedAt: Date
    let response: LeagueTablesResponse

    private enum CodingKeys: String, CodingKey {
        case fetchedAt
        case response
    }

    nonisolated init(fetchedAt: Date, response: LeagueTablesResponse) {
        self.fetchedAt = fetchedAt
        self.response = response
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        response = try container.decode(LeagueTablesResponse.self, forKey: .response)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encode(response, forKey: .response)
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
