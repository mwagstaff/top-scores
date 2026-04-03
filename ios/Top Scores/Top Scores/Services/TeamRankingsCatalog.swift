import Foundation

struct TeamRatingResolution: Sendable {
    let rating: Double
    let usedDefault: Bool
}

struct TeamRatingLookup: Sendable {
    private struct Candidate: Sendable {
        let key: String
        let tokens: [String]
        let rating: Double
    }

    private let exactByKey: [String: Double]
    private let candidates: [Candidate]
    private let defaultPoints: Double
    private static let stopWords: Set<String> = [
        "fc", "cf", "sc", "afc", "ac", "sv", "fk", "bk", "bc", "ks", "nk", "club", "de", "the", "and"
    ]
    init(entries: [TeamRankingEntry], defaultPoints: Double = TeamRankingSettings.defaultDefaultElo) {
        var exact: [String: Double] = [:]
        var candidateList: [Candidate] = []
        candidateList.reserveCapacity(entries.count * 2)

        for entry in entries {
            guard let points = entry.points, points.isFinite else { continue }
            var names = [entry.name]
            names.append(contentsOf: entry.aliases)
            let dedupedNames = Array(
                Set(names.flatMap { TeamIdentityStore.shared.names(for: $0) })
            ).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            for name in dedupedNames {
                let key = Self.normalizedKey(name)
                guard !key.isEmpty else { continue }
                exact[key] = exact[key] ?? points
                candidateList.append(
                    Candidate(key: key, tokens: Self.normalizedTokens(name), rating: points)
                )
            }
        }

        self.defaultPoints = defaultPoints
        exactByKey = exact
        candidates = candidateList
    }

    func rating(for teamName: String) -> Double? {
        var bestRating: Double?
        var bestConfidence = 0.0

        for variant in TeamIdentityStore.shared.names(for: teamName) {
            let key = Self.normalizedKey(variant)
            guard !key.isEmpty else { continue }

            if let direct = exactByKey[key] {
                return direct
            }

            let sourceTokens = Self.normalizedTokens(variant)
            for candidate in candidates {
                let confidence = Self.similarity(
                    lhsKey: key,
                    rhsKey: candidate.key,
                    lhsTokens: sourceTokens,
                    rhsTokens: candidate.tokens
                )
                if confidence > bestConfidence {
                    bestConfidence = confidence
                    bestRating = candidate.rating
                }
            }
        }

        guard bestConfidence >= 0.86 else { return nil }
        return bestRating
    }

    func resolvedRating(for teamName: String) -> Double {
        resolveRating(for: teamName).rating
    }

    func resolveRating(for teamName: String) -> TeamRatingResolution {
        if let exactRating = rating(for: teamName) {
            return TeamRatingResolution(rating: exactRating, usedDefault: false)
        }
        return TeamRatingResolution(rating: defaultPoints, usedDefault: true)
    }

    private static func normalizedTokens(_ value: String) -> [String] {
        let normalized = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        return normalized
            .split { !$0.isLetter && !$0.isNumber }
            .map { String($0) }
            .filter { !stopWords.contains($0) }
    }

    private static func normalizedKey(_ value: String) -> String {
        let tokens = normalizedTokens(value)
        if !tokens.isEmpty {
            return tokens.joined()
        }
        return value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    private static func similarity(lhsKey: String, rhsKey: String, lhsTokens: [String], rhsTokens: [String]) -> Double {
        let base = normalizedEditSimilarity(lhsKey, rhsKey)
        let dice = diceCoefficient(lhsTokens, rhsTokens)
        let prefix = prefixSimilarity(lhsKey, rhsKey, lhsTokens, rhsTokens)
        return max(base, dice, prefix)
    }

    private static func normalizedEditSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let maxLength = max(lhs.count, rhs.count)
        guard maxLength > 0 else { return 1 }
        return 1 - (Double(levenshtein(lhs, rhs)) / Double(maxLength))
    }

    private static func diceCoefficient(_ lhs: [String], _ rhs: [String]) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 1 }
        let left = Set(lhs)
        let right = Set(rhs)
        let overlap = left.intersection(right).count
        return (2 * Double(overlap)) / Double(lhs.count + rhs.count)
    }

    private static func prefixSimilarity(
        _ lhsKey: String,
        _ rhsKey: String,
        _ lhsTokens: [String],
        _ rhsTokens: [String]
    ) -> Double {
        guard min(lhsTokens.count, rhsTokens.count) == 1 else { return 0 }
        if lhsKey.hasPrefix(rhsKey) || rhsKey.hasPrefix(lhsKey) {
            let shorter = min(lhsKey.count, rhsKey.count)
            let longer = max(lhsKey.count, rhsKey.count)
            guard longer > 0 else { return 1 }
            return min(1, (Double(shorter) / Double(longer)) + 0.30)
        }
        return 0
    }

    private static func levenshtein(_ lhs: String, _ rhs: String) -> Int {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)
        var previous = Array(0...rhsChars.count)
        var current = Array(repeating: 0, count: rhsChars.count + 1)

        for (i, lhsChar) in lhsChars.enumerated() {
            current[0] = i + 1
            for (j, rhsChar) in rhsChars.enumerated() {
                let cost = lhsChar == rhsChar ? 0 : 1
                current[j + 1] = min(
                    previous[j + 1] + 1,
                    current[j] + 1,
                    previous[j] + cost
                )
            }
            previous = current
        }

        return previous[rhsChars.count]
    }
}

struct TeamRankingSettings: Codable, Hashable {
    static let defaultDefaultElo = 1000.0

    let defaultElo: Double
    let updatedAt: Date?

    init(defaultElo: Double = TeamRankingSettings.defaultDefaultElo, updatedAt: Date? = nil) {
        self.defaultElo = defaultElo
        self.updatedAt = updatedAt
    }
}

private struct TeamRankingSettingsCachePayload: Codable {
    let fetchedAt: Date
    let settings: TeamRankingSettings
}

actor TeamRankingSettingsCatalog {
    static let shared = TeamRankingSettingsCatalog()

    private static let cacheTTL: TimeInterval = 24 * 60 * 60
    private static let cacheFileName = "team-ranking-settings-cache.json"

    private var didLoadCache = false
    private var cachedSettings = TeamRankingSettings()
    private var cachedFetchedAt: Date?
    private var refreshTask: Task<TeamRankingSettings, Error>?

    private init() {}

    func ensureFresh(apiBaseURL: String) async {
        loadCacheIfNeeded()
        guard shouldRefresh(now: Date()) else { return }

        if let inFlight = refreshTask {
            _ = try? await inFlight.value
            return
        }

        guard let baseURL = URL(string: apiBaseURL) else {
            log("Invalid team ranking settings base URL: \(apiBaseURL)")
            return
        }

        let task = Task<TeamRankingSettings, Error> {
            let client = APIClient(baseURL: baseURL)
            let response = try await client.fetchTeamRankingSettings()
            return TeamRankingSettings(
                defaultElo: response.defaultElo,
                updatedAt: response.updatedAt
            )
        }
        refreshTask = task

        defer { refreshTask = nil }

        do {
            let fetched = try await task.value
            cachedSettings = fetched
            cachedFetchedAt = Date()
            persistCache()
            log("Team ranking settings cache refreshed with default Elo \(Int(fetched.defaultElo.rounded())).")
        } catch {
            log("Team ranking settings refresh failed: \(String(describing: error))")
        }
    }

    func settings() -> TeamRankingSettings {
        loadCacheIfNeeded()
        return cachedSettings
    }

    private func shouldRefresh(now: Date) -> Bool {
        guard let fetchedAt = cachedFetchedAt else {
            return true
        }
        return now.timeIntervalSince(fetchedAt) >= Self.cacheTTL
    }

    private func loadCacheIfNeeded() {
        guard !didLoadCache else { return }
        didLoadCache = true

        guard let data = try? Data(contentsOf: cacheURL) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(TeamRankingSettingsCachePayload.self, from: data) else {
            log("Failed to decode team ranking settings cache; ignoring stored data.")
            return
        }

        cachedFetchedAt = payload.fetchedAt
        cachedSettings = payload.settings
    }

    private func persistCache() {
        guard let fetchedAt = cachedFetchedAt else { return }

        let payload = TeamRankingSettingsCachePayload(
            fetchedAt: fetchedAt,
            settings: cachedSettings
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
        NSLog("[TeamRankingSettingsCatalog] %@", message)
    }
}

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

private struct FantasyTeamShortNameMappingsCachePayload: Codable {
    let fetchedAt: Date
    let mappings: [String: String]
}

final class FantasyTeamShortNameMappingsStore {
    static let shared = FantasyTeamShortNameMappingsStore()

    private let lock = NSLock()
    private var mappings: [String: String] = [:]

    private init() {}

    func updateMappings(_ nextMappings: [String: String]) {
        lock.lock()
        mappings = nextMappings
        lock.unlock()
    }

    func resolveTeamName(for rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let canonical = TeamIdentityStore.shared.canonicalName(for: trimmed)
        if canonical.caseInsensitiveCompare(trimmed) != .orderedSame {
            return canonical
        }

        let key = trimmed.uppercased()
        lock.lock()
        let mapped = mappings[key]
        lock.unlock()
        return mapped ?? trimmed
    }
}

actor FantasyTeamShortNameMappingsCatalog {
    static let shared = FantasyTeamShortNameMappingsCatalog()

    private static let cacheTTL: TimeInterval = 24 * 60 * 60
    private static let cacheFileName = "fantasy-team-short-name-mappings-cache.json"

    private var didLoadCache = false
    private var cachedMappings: [String: String] = [:]
    private var cachedFetchedAt: Date?
    private var refreshTask: Task<[String: String], Error>?

    private init() {}

    func ensureFresh(apiBaseURL: String) async {
        loadCacheIfNeeded()
        applyCachedMappingsToStore()
        guard shouldRefresh(now: Date()) else { return }

        if let inFlight = refreshTask {
            _ = try? await inFlight.value
            return
        }

        guard let baseURL = URL(string: apiBaseURL) else {
            log("Invalid fantasy mappings base URL: \(apiBaseURL)")
            return
        }

        let task = Task<[String: String], Error> {
            let client = APIClient(baseURL: baseURL)
            let response = try await client.fetchFantasyTeamShortNameMappings()
            return Self.normalize(mappings: response.mappings)
        }
        refreshTask = task

        defer { refreshTask = nil }

        do {
            let fetchedMappings = try await task.value
            guard !fetchedMappings.isEmpty else {
                log("Fantasy mappings refresh returned empty payload; keeping existing cache.")
                return
            }

            cachedMappings = fetchedMappings
            cachedFetchedAt = Date()
            persistCache()
            applyCachedMappingsToStore()
            log("Fantasy mappings cache refreshed with \(fetchedMappings.count) entries.")
        } catch {
            log("Fantasy mappings refresh failed: \(String(describing: error))")
        }
    }

    private func shouldRefresh(now: Date) -> Bool {
        guard let fetchedAt = cachedFetchedAt else {
            return true
        }
        return now.timeIntervalSince(fetchedAt) >= Self.cacheTTL || cachedMappings.isEmpty
    }

    private func loadCacheIfNeeded() {
        guard !didLoadCache else { return }
        didLoadCache = true

        guard let data = try? Data(contentsOf: cacheURL) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(FantasyTeamShortNameMappingsCachePayload.self, from: data) else {
            log("Failed to decode fantasy mappings cache; ignoring stored data.")
            return
        }

        cachedFetchedAt = payload.fetchedAt
        cachedMappings = Self.normalize(mappings: payload.mappings)
    }

    private func persistCache() {
        guard let fetchedAt = cachedFetchedAt else { return }
        let payload = FantasyTeamShortNameMappingsCachePayload(
            fetchedAt: fetchedAt,
            mappings: cachedMappings
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: cacheURL, options: [.atomic])
    }

    private static func normalize(mappings rawMappings: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        normalized.reserveCapacity(rawMappings.count)

        for (rawKey, rawValue) in rawMappings {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            normalized[key] = value
        }

        return normalized
    }

    private func applyCachedMappingsToStore() {
        FantasyTeamShortNameMappingsStore.shared.updateMappings(cachedMappings)
    }

    private var cacheURL: URL {
        let fileManager = FileManager.default
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("TopScores", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(Self.cacheFileName)
    }

    private func log(_ message: String) {
        NSLog("[FantasyTeamShortNameMappingsCatalog] %@", message)
    }
}
