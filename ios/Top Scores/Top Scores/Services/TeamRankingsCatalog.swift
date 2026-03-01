import Foundation

private struct TeamRankingsCachePayload: Codable {
    let fetchedAt: Date
    let entries: [TeamRankingEntry]
}

actor TeamRankingsCatalog {
    static let shared = TeamRankingsCatalog()

    private static let cacheTTL: TimeInterval = 24 * 60 * 60
    private static let cacheFileName = "team-rankings-cache.json"

    private var didLoadCache = false
    private var cachedEntriesStore: [TeamRankingEntry] = []
    private var cachedFetchedAt: Date?
    private var refreshTask: Task<[TeamRankingEntry], Error>?

    private init() {}

    func ensureFresh(apiBaseURL: String) async {
        loadCacheIfNeeded()
        guard shouldRefresh(now: Date()) else { return }

        if let inFlight = refreshTask {
            _ = try? await inFlight.value
            return
        }

        guard let baseURL = URL(string: apiBaseURL) else {
            log("Invalid team rankings base URL: \(apiBaseURL)")
            return
        }

        let task = Task<[TeamRankingEntry], Error> {
            let client = APIClient(baseURL: baseURL)
            return try await client.fetchTeamRankings(type: "club")
        }
        refreshTask = task

        defer { refreshTask = nil }

        do {
            let fetched = try await task.value
            let normalized = normalize(entries: fetched)
            guard !normalized.isEmpty else {
                log("Team rankings refresh returned an empty payload; keeping existing cache.")
                return
            }

            cachedEntriesStore = normalized
            cachedFetchedAt = Date()
            persistCache()
            log("Team rankings cache refreshed with \(normalized.count) teams.")
        } catch {
            log("Team rankings refresh failed: \(String(describing: error))")
        }
    }

    func cachedEntries() -> [TeamRankingEntry] {
        loadCacheIfNeeded()
        return cachedEntriesStore
    }

    private func shouldRefresh(now: Date) -> Bool {
        guard let fetchedAt = cachedFetchedAt else {
            return true
        }
        return now.timeIntervalSince(fetchedAt) >= Self.cacheTTL || cachedEntriesStore.isEmpty
    }

    private func loadCacheIfNeeded() {
        guard !didLoadCache else { return }
        didLoadCache = true

        guard let data = try? Data(contentsOf: cacheURL) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(TeamRankingsCachePayload.self, from: data) else {
            log("Failed to decode team rankings cache; ignoring stored data.")
            return
        }

        cachedFetchedAt = payload.fetchedAt
        cachedEntriesStore = normalize(entries: payload.entries)
    }

    private func persistCache() {
        guard let fetchedAt = cachedFetchedAt else { return }

        let payload = TeamRankingsCachePayload(
            fetchedAt: fetchedAt,
            entries: cachedEntriesStore
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }

        try? data.write(to: cacheURL, options: [.atomic])
    }

    private func normalize(entries: [TeamRankingEntry]) -> [TeamRankingEntry] {
        var seen = Set<String>()
        var normalized: [TeamRankingEntry] = []
        normalized.reserveCapacity(entries.count)

        for entry in entries {
            let trimmedName = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { continue }

            let key = normalizedKey(trimmedName)
            guard !key.isEmpty else { continue }
            guard seen.insert(key).inserted else { continue }

            var aliasSet = Set<String>()
            let aliases = entry.aliases
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && normalizedKey($0) != key && aliasSet.insert(normalizedKey($0)).inserted }

            normalized.append(
                TeamRankingEntry(
                    name: trimmedName,
                    points: entry.points,
                    aliases: aliases
                )
            )
        }

        return normalized
    }

    private func normalizedKey(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    private var cacheURL: URL {
        let fileManager = FileManager.default
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("TopScores", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(Self.cacheFileName)
    }

    private func log(_ message: String) {
        NSLog("[TeamRankingsCatalog] %@", message)
    }
}
