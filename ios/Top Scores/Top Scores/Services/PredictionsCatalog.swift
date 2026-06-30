import Foundation

private struct PredictionsCachePayload: Codable, Sendable {
    let fetchedAt: Date
    let leagues: [PredictionLeague]

    private enum CodingKeys: String, CodingKey {
        case fetchedAt
        case leagues
    }

    nonisolated init(fetchedAt: Date, leagues: [PredictionLeague]) {
        self.fetchedAt = fetchedAt
        self.leagues = leagues
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        leagues = try container.decode([PredictionLeague].self, forKey: .leagues)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encode(leagues, forKey: .leagues)
    }
}

actor PredictionsCatalog {
    static let shared = PredictionsCatalog()

    private static let cacheTTL: TimeInterval = 60 * 60
    private static let cacheFileName = "predictions-cache.json"

    private var didLoadCache = false
    private var cachedLeaguesStore: [PredictionLeague] = []
    private var cachedFetchedAt: Date?
    private var refreshTask: Task<[PredictionLeague], Error>?

    private init() {}

    func ensureFresh(apiBaseURL: String) async {
        loadCacheIfNeeded()
        guard shouldRefresh(now: Date()) else { return }

        if let inFlight = refreshTask {
            _ = try? await inFlight.value
            return
        }

        guard let baseURL = URL(string: apiBaseURL) else {
            log("Invalid predictions base URL: \(apiBaseURL)")
            return
        }

        let task = Task<[PredictionLeague], Error> {
            let client = APIClient(baseURL: baseURL)
            return try await client.fetchPredictions()
        }
        refreshTask = task

        defer { refreshTask = nil }

        do {
            let fetched = try await task.value
            guard !fetched.isEmpty else {
                log("Predictions refresh returned an empty payload; keeping existing cache.")
                return
            }

            cachedLeaguesStore = fetched
            cachedFetchedAt = Date()
            persistCache()
            log("Predictions cache refreshed with \(fetched.count) leagues.")
        } catch {
            log("Predictions refresh failed: \(String(describing: error))")
        }
    }

    func cachedLeagues() -> [PredictionLeague] {
        loadCacheIfNeeded()
        return cachedLeaguesStore
    }

    private func shouldRefresh(now: Date) -> Bool {
        guard let fetchedAt = cachedFetchedAt else {
            return true
        }
        return now.timeIntervalSince(fetchedAt) >= Self.cacheTTL || cachedLeaguesStore.isEmpty
    }

    private func loadCacheIfNeeded() {
        guard !didLoadCache else { return }
        didLoadCache = true

        guard let data = try? Data(contentsOf: cacheURL) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(PredictionsCachePayload.self, from: data) else {
            log("Failed to decode predictions cache; ignoring stored data.")
            return
        }

        cachedFetchedAt = payload.fetchedAt
        cachedLeaguesStore = payload.leagues
    }

    private func persistCache() {
        guard let fetchedAt = cachedFetchedAt else { return }

        let payload = PredictionsCachePayload(
            fetchedAt: fetchedAt,
            leagues: cachedLeaguesStore
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }

        try? data.write(to: cacheURL, options: [.atomic])
    }

    private var cacheURL: URL {
        let fileManager = FileManager.default
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("TopScores", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(Self.cacheFileName)
    }

    private func log(_ message: String) {
        NSLog("[PredictionsCatalog] %@", message)
    }
}
