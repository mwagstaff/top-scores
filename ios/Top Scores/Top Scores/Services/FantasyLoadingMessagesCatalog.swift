import Foundation

private struct FantasyLoadingMessagesCachePayload: Codable {
    let fetchedAt: Date
    let messages: [String]
}

actor FantasyLoadingMessagesCatalog {
    static let shared = FantasyLoadingMessagesCatalog()

    private static let cacheTTL: TimeInterval = 24 * 60 * 60
    private static let cacheFileName = "fantasy-loading-messages-cache.json"
    private static let fallbackMessages: [String] = [
        "Loading your squad...",
        "Checking live bonus points...",
        "Sizing up the rivals...",
        "Pulling in your latest picks...",
        "Refreshing your Gameweek score...",
        "Scanning the bench...",
        "Lining up the captains...",
        "Fetching rival teams...",
        "Updating live Fantasy data...",
        "Crunching bonus point swings...",
        "Building your pitch view...",
        "Calculating rank movement...",
        "Checking who blanked...",
        "Checking who hauled...",
        "Finalising your Fantasy dashboard..."
    ]

    private var didLoadCache = false
    private var cachedMessages: [String] = []
    private var cachedFetchedAt: Date?
    private var refreshTask: Task<[String], Error>?

    private init() {}

    func ensureFresh(apiBaseURL: String) async {
        loadCacheIfNeeded()
        guard shouldRefresh(now: Date()) else { return }

        if let inFlight = refreshTask {
            _ = try? await inFlight.value
            return
        }

        guard let baseURL = URL(string: apiBaseURL) else {
            log("Invalid fantasy loading messages base URL: \(apiBaseURL)")
            return
        }

        let task = Task<[String], Error> {
            let client = APIClient(baseURL: baseURL)
            let response = try await client.fetchFantasyLoadingMessages()
            return Self.normalize(messages: response.messages)
        }
        refreshTask = task

        defer { refreshTask = nil }

        do {
            let fetchedMessages = try await task.value
            guard !fetchedMessages.isEmpty else {
                log("Fantasy loading messages refresh returned empty payload; keeping existing cache.")
                return
            }

            cachedMessages = fetchedMessages
            cachedFetchedAt = Date()
            persistCache()
            log("Fantasy loading messages cache refreshed with \(fetchedMessages.count) items.")
        } catch {
            log("Fantasy loading messages refresh failed: \(String(describing: error))")
        }
    }

    func randomMessage() -> String {
        loadCacheIfNeeded()
        let source = cachedMessages.isEmpty ? Self.fallbackMessages : cachedMessages
        return source.randomElement() ?? "Loading Fantasy Football..."
    }

    private func shouldRefresh(now: Date) -> Bool {
        guard let fetchedAt = cachedFetchedAt else {
            return true
        }
        return now.timeIntervalSince(fetchedAt) >= Self.cacheTTL || cachedMessages.isEmpty
    }

    private func loadCacheIfNeeded() {
        guard !didLoadCache else { return }
        didLoadCache = true

        guard let data = try? Data(contentsOf: cacheURL) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(FantasyLoadingMessagesCachePayload.self, from: data) else {
            log("Failed to decode fantasy loading messages cache; ignoring stored data.")
            return
        }

        cachedFetchedAt = payload.fetchedAt
        cachedMessages = Self.normalize(messages: payload.messages)
    }

    private func persistCache() {
        guard let fetchedAt = cachedFetchedAt else { return }
        let payload = FantasyLoadingMessagesCachePayload(
            fetchedAt: fetchedAt,
            messages: cachedMessages
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: cacheURL, options: [.atomic])
    }

    private static func normalize(messages rawMessages: [String]) -> [String] {
        rawMessages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var cacheURL: URL {
        let fileManager = FileManager.default
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("TopScores", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(Self.cacheFileName)
    }

    private func log(_ message: String) {
        NSLog("[FantasyLoadingMessagesCatalog] %@", message)
    }
}
